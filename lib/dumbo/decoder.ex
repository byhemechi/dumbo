defmodule Dumbo.DecodeOpts do
  @moduledoc """
  Options for configuring decoding behavior.

  ## Fields

    * `:object_resolvers` - A map of PHP class names to resolvers. Each resolver is
      a function of arity 1 or a module implementing `Dumbo.ObjectResolver`.
      Defaults to `Dumbo.PHP.resolvers()`.

    * `:use_native_decoders` - When `true` (the default) and the optional
      [`dumbo_nif`](https://hex.pm/packages/dumbo_nif) dependency is installed,
      numeric floats are parsed by a precompiled Rust NIF instead of the
      pure-Elixir decoder. Set to `false` to force the pure-Elixir path. Ignored
      when `dumbo_nif` is not available.

    * `:resolve_references` - When `true` (the default), `R:` references are
      resolved against PHP's value stack. Set to `false` to reject them: the
      decoder then does not build the stack at all, and encountering a reference
      raises `Dumbo.DecodeError`. Use this when the input is known to be free of
      references and the stack overhead should be avoided.
  """

  @type object_resolver :: (object :: map() -> term()) | module()

  @type t :: %__MODULE__{
          object_resolvers: %{(object_name :: binary()) => object_resolver()},
          use_native_decoders: boolean(),
          resolve_references: boolean()
        }

  defstruct object_resolvers: Dumbo.PHP.resolvers(),
            use_native_decoders: true,
            resolve_references: true
end

defmodule Dumbo.DecodeError do
  @moduledoc """
  Exception raised when decoding a PHP serialised string fails.
  """

  @type t :: %__MODULE__{position: integer, source: String.t(), token: byte() | binary()}

  defexception [:position, :token, :source]

  @impl true
  def message(%{position: position, token: token}) when is_binary(token) do
    "unexpected sequence at position #{position}: #{inspect(token)}"
  end

  def message(%{position: position, source: source}) when position == byte_size(source) do
    "unexpected end of input at position #{position}"
  end

  def message(%{position: position, source: source}) do
    byte = :binary.at(source, position)
    str = <<byte>>

    if String.printable?(str) do
      "unexpected byte at position #{position}: " <>
        "#{inspect(byte, base: :hex)} (#{inspect(str)})"
    else
      "unexpected byte at position #{position}: " <>
        "#{inspect(byte, base: :hex)}"
    end
  end
end

defmodule Dumbo.ReferenceError do
  @moduledoc """
  Exception raised when a reference (`R:n`) cannot be resolved, either because it
  is out of range or because it is recursive (PHP allows cyclic data, Elixir
  terms cannot).
  """

  defexception [:message]
end

defmodule Dumbo.Decoder do
  @moduledoc """
  Decoder implementation for the PHP serialisation format.
  """

  @type opts :: Dumbo.DecodeOpts.t()

  @doc """
  Deserialises a PHP serialised string into an Elixir term.

  Accepts an optional `%Dumbo.DecodeOpts{}` struct. See `Dumbo.DecodeOpts`.

  ## Examples

      iex> Dumbo.Decoder.decode("N;")
      nil

      iex> Dumbo.Decoder.decode("b:0;")
      false
      iex> Dumbo.Decoder.decode("b:1;")
      true

      iex> Dumbo.Decoder.decode("i:685230;")
      685230
      iex> Dumbo.Decoder.decode("i:-685230;")
      -685230

      iex> Dumbo.Decoder.decode("d:685230.15;")
      685230.15
      iex> Dumbo.Decoder.decode("d:.5;")
      0.5
      iex> Dumbo.Decoder.decode("d:1e3;")
      1.0e3
      iex> Dumbo.Decoder.decode("d:1.0E+25;")
      1.0e25
      iex> Dumbo.Decoder.decode("d:INF;")
      :infinity
      iex> Dumbo.Decoder.decode("d:-INF;")
      :negative_infinity
      iex> Dumbo.Decoder.decode("d:NAN;")
      :nan

      iex> Dumbo.Decoder.decode(~s's:6:"foobar";')
      "foobar"

      iex> Dumbo.Decoder.decode(~s'a:2:{i:42;b:1;s:6:"A to Z";a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}}')
      %{42 => true, "A to Z" => %{0 => 1, 1 => 2, 2 => 3}}
      iex> Dumbo.Decoder.decode("a:0:{}")
      %{}

      iex> Dumbo.Decoder.decode(~s'O:8:"stdClass":2:{s:4:"John";d:3.14;s:4:"Jane";d:2.718;}')
      %{"John" => 3.14, "Jane" => 2.718}

  References are resolved as PHP resolves them, using a stack of every value
  pushed while decoding (arrays and objects included, keys excluded):

      iex> Dumbo.Decoder.decode(~s'a:4:{i:0;i:10;i:1;i:20;i:2;i:30;i:3;R:2;}')
      %{0 => 10, 1 => 20, 2 => 30, 3 => 10}

  Common PHP classes are resolved into native Elixir types automatically. Supply
  an empty `:object_resolvers` map to receive raw objects instead:

      iex> opts = %Dumbo.DecodeOpts{object_resolvers: %{}}
      iex> Dumbo.Decoder.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}', opts)
      {:object, "stdClass", %{"foo" => "bar"}}

  Objects can also be decoded with the `:object_resolvers` option:

      iex> opts = %Dumbo.DecodeOpts{object_resolvers: %{"stdClass" => fn obj -> obj end}}
      iex> Dumbo.Decoder.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}', opts)
      %{"foo" => "bar"}

  Malformed input raises `Dumbo.DecodeError` pointing at the offending byte:

      iex> Dumbo.Decoder.decode(~s'a:1:{i:0;i:1;x}')
      ** (Dumbo.DecodeError) unexpected sequence at position 13: "x"

  """
  def decode(source, opts \\ %Dumbo.DecodeOpts{}) do
    case value(source, context_init(source, opts)) do
      {value, _rest, _position, _context} -> value
    end
  end

  defmodule Context do
    @moduledoc false
    defstruct opts: %Dumbo.DecodeOpts{}, source: <<>>, position: 0, refs: [], push?: true, slot: 0
  end

  @type decode_context :: %__MODULE__.Context{}

  defp context_init(source, opts), do: %Context{source: source, opts: opts}

  # Returns `{value, rest, position, context}`.
  #
  # `refs` mirrors PHP's `var_hash`: every parsed value occupies a slot in push
  # order (arrays and objects included, keys excluded, `R:` references excluded),
  # and `R:n` is a 1-based index into that order. `push?` is `false` while
  # decoding a key, matching PHP parsing keys with a `NULL` var_hash.
  defp value(rest, context) do
    case rest do
      <<?N, ?;, rest::binary>> -> push(nil, rest, context.position + 2, context)
      <<?b, ?:, rest::binary>> -> boolean(rest, advance(context, 2))
      <<?i, ?:, rest::binary>> -> integer(rest, advance(context, 2))
      <<?R, ?:, rest::binary>> -> reference(rest, advance(context, 2))
      <<?d, ?:, rest::binary>> -> float(rest, advance(context, 2))
      <<?s, ?:, rest::binary>> -> string(rest, advance(context, 2))
      <<?a, ?:, rest::binary>> -> array(rest, advance(context, 2))
      <<?O, ?:, rest::binary>> -> object(rest, advance(context, 2))
      _ -> fail(rest, context)
    end
  end

  defp advance(context, by), do: %{context | position: context.position + by}

  # Appends to `refs` (most-recent-first), unless we are decoding a key or
  # reference resolution (and therefore the whole stack) is disabled.
  defp push(value, rest, position, %{opts: %{resolve_references: false}} = context),
    do: {value, rest, position, context}

  defp push(value, rest, position, %{push?: false} = context),
    do: {value, rest, position, context}

  defp push(value, rest, position, context),
    do: {value, rest, position, %{context | refs: [value | context.refs]}}

  defp key_context(context), do: %{context | push?: false}

  # Reserves a reference slot for a container before its children are decoded,
  # mirroring PHP pushing arrays and objects ahead of their contents. Nothing is
  # reserved when reference resolution is disabled.
  defp reserve(%{opts: %{resolve_references: false}} = context), do: {nil, context}

  defp reserve(context) do
    slot = context.slot
    {slot, %{context | refs: [{:slot, slot} | context.refs], slot: slot + 1}}
  end

  defp resolve_slot(%{opts: %{resolve_references: false}} = context, _slot, _value), do: context

  defp resolve_slot(context, slot, value) do
    refs = replace_slot(context.refs, slot, value)
    %{context | refs: refs}
  end

  # The slot was reserved first, so its decoded children sit ahead of it. The
  # scan therefore only crosses the current container's children.
  defp replace_slot([{:slot, slot} | rest], slot, value), do: [value | rest]
  defp replace_slot([head | rest], slot, value), do: [head | replace_slot(rest, slot, value)]
  defp replace_slot([], _slot, _value), do: []

  # `refs` is most-recent-first, but PHP's `R:n` is a 1-based index into the
  # push order, so count from the end.
  defp fetch_reference(refs, n) do
    index = length(refs) - n

    if index < 0 do
      :missing
    else
      Enum.at(refs, index)
    end
  end

  defp boolean(rest, context) do
    case rest do
      <<?0, ?;, rest::binary>> -> push(false, rest, context.position + 2, context)
      <<?1, ?;, rest::binary>> -> push(true, rest, context.position + 2, context)
      _ -> fail(rest, context)
    end
  end

  defguardp is_digit(c) when c in ?0..?9

  defp integer(rest, context) do
    case rest do
      <<?-, rest::binary>> -> integer_digits(rest, advance(context, 1), -1)
      _ -> integer_digits(rest, context, 1)
    end
  end

  defp integer_digits(rest, context, sign) do
    case take_digits(rest, 0) do
      {0, _rest} ->
        fail(rest, context)

      {count, <<?;, rest::binary>>} ->
        value =
          context.source
          |> :binary.part(context.position, count)
          |> :erlang.binary_to_integer()
          |> Kernel.*(sign)

        push(value, rest, context.position + count + 1, context)

      {count, _rest} ->
        fail(rest, advance(context, count))
    end
  end

  defp take_digits(rest, count) do
    case rest do
      <<c, _::binary>> when is_digit(c) ->
        take_digits(binary_part(rest, 1, byte_size(rest) - 1), count + 1)

      _ ->
        {count, rest}
    end
  end

  defp float(rest, context) do
    case rest do
      <<?I, ?N, ?F, ?;, rest::binary>> ->
        push(:infinity, rest, context.position + 4, context)

      <<?-, ?I, ?N, ?F, ?;, rest::binary>> ->
        push(:negative_infinity, rest, context.position + 5, context)

      <<?N, ?A, ?N, ?;, rest::binary>> ->
        push(:nan, rest, context.position + 4, context)

      _ ->
        numeric_float(rest, context)
    end
  end

  if Code.ensure_loaded?(Dumbo.Nif) do
    defp numeric_float(
           rest,
           context = %__MODULE__.Context{opts: %Dumbo.DecodeOpts{use_native_decoders: true}}
         ) do
      case Dumbo.Nif.decode_numeric_float(rest) do
        {:ok, {value, count}} ->
          <<_::binary-size(^count), rest::binary>> = rest
          push(value, rest, context.position + count, advance(context, count))

        {:error, {:unexpected_end, %{position: position}}} ->
          raise Dumbo.DecodeError, source: context.source, position: context.position + position

        {:error, {:unexpected_sequence, %{position: position, token: token}}} ->
          raise Dumbo.DecodeError,
            source: context.source,
            position: context.position + position,
            token: token
      end
    end
  end

  defp numeric_float(rest, context) do
    {token, rest} = float_token(rest, context, context.position)

    case normalize_float(token) do
      {:ok, normalized} ->
        value = :erlang.binary_to_float(normalized)
        push(value, rest, context.position + byte_size(token) + 1, context)

      :error ->
        fail(rest, context)
    end
  end

  defp float_token(rest, context, start) do
    case rest do
      <<?;, rest::binary>> ->
        {binary_part(context.source, start, context.position - start), rest}

      <<c, _::binary>> when c in ~c"0123456789+-.eE" ->
        float_token(binary_part(rest, 1, byte_size(rest) - 1), advance(context, 1), start)

      _ ->
        fail(rest, context)
    end
  end

  @float_pattern ~r/^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/

  # `:erlang.binary_to_float/1` requires a decimal point, but PHP and Erlang emit
  # exponent notation that may omit it.
  defp normalize_float(token) do
    if Regex.match?(@float_pattern, token) do
      {mantissa, exponent} =
        case :binary.split(String.downcase(token), "e") do
          [mantissa] -> {mantissa, ""}
          [mantissa, exponent] -> {mantissa, "e" <> exponent}
        end

      {:ok, normalize_mantissa(mantissa) <> exponent}
    else
      :error
    end
  end

  defp normalize_mantissa("-" <> rest), do: "-" <> normalize_mantissa(rest)

  defp normalize_mantissa(mantissa) do
    cond do
      String.starts_with?(mantissa, ".") -> "0" <> mantissa
      not String.contains?(mantissa, ".") -> mantissa <> ".0"
      String.ends_with?(mantissa, ".") -> mantissa <> "0"
      true -> mantissa
    end
  end

  defp sized(rest, context, suffix) do
    {count, rest} = take_digits(rest, 0)

    case rest do
      <<^suffix, rest::binary>> when count > 0 ->
        size = :erlang.binary_to_integer(:binary.part(context.source, context.position, count))
        {size, rest, context.position + count + 1}

      _ ->
        fail(rest, advance(context, count))
    end
  end

  defp bytes(rest, context) do
    {size, rest, position} = sized(rest, context, ?:)

    case rest do
      <<?", data::binary-size(^size), ?", rest::binary>> ->
        {data, rest, position + 1 + size + 1}

      _ ->
        fail(rest, context)
    end
  end

  defp string(rest, context) do
    {data, rest, position} = bytes(rest, context)

    case rest do
      <<?;, rest::binary>> -> push(data, rest, position + 1, context)
      _ -> fail(rest, context)
    end
  end

  defp reference(_rest, %{opts: %{resolve_references: false}} = context) do
    raise Dumbo.DecodeError,
      source: context.source,
      position: context.position - 2,
      token: "R:"
  end

  defp reference(rest, context) do
    {n, rest, position} = reference_id(rest, context)

    case fetch_reference(context.refs, n) do
      :missing ->
        raise Dumbo.ReferenceError, message: "Array reference #{inspect(n)} out of range"

      {:slot, _slot} ->
        raise Dumbo.ReferenceError, message: "Recursive references are not supported"

      value ->
        # A reference is not itself pushed: pass it through without growing refs.
        {value, rest, position, %{context | push?: false}}
    end
  end

  defp reference_id(rest, context) do
    case take_digits(rest, 0) do
      {0, _rest} ->
        fail(rest, context)

      {count, <<?;, rest::binary>>} ->
        n = :erlang.binary_to_integer(:binary.part(context.source, context.position, count))
        {n, rest, context.position + count + 1}

      {count, _rest} ->
        fail(rest, advance(context, count))
    end
  end

  defp array(rest, context) do
    {size, rest, position} = sized(rest, context, ?:)

    case rest do
      <<?{, rest::binary>> ->
        # Reserve the array's ref slot before decoding its children.
        {slot, context} = reserve(context)

        {entries, rest, position, context} =
          array_entries(rest, %{context | position: position + 1}, size)

        case rest do
          <<?}, rest::binary>> ->
            value = Map.new(entries)
            context = resolve_slot(context, slot, value)
            {value, rest, position + 1, context}

          _ ->
            fail(rest, %{context | position: position})
        end

      _ ->
        fail(rest, context)
    end
  end

  defp array_entries(rest, context, size) do
    array_entries(rest, context, size, 0, [])
  end

  defp array_entries(rest, context, size, index, entries) do
    if index == size do
      {:lists.reverse(entries), rest, context.position, context}
    else
      {key, rest, position, context} = value(rest, key_context(context))
      {entry, rest, position, context} = value(rest, %{context | position: position, push?: true})

      array_entries(
        rest,
        %{context | position: position},
        size,
        index + 1,
        [{key, entry} | entries]
      )
    end
  end

  defp object(rest, context) do
    {name, rest, position} = bytes(rest, context)

    case rest do
      <<?:, rest::binary>> ->
        {slot, context} = reserve(context)

        {properties, rest, position, context} =
          property_list(rest, %{context | position: position + 1})

        value = resolve_object(name, properties, context.opts)
        context = resolve_slot(context, slot, value)
        {value, rest, position, context}

      _ ->
        fail(rest, context)
    end
  end

  defp property_list(rest, context) do
    {size, rest, position} = sized(rest, context, ?:)

    case rest do
      <<?{, rest::binary>> ->
        {entries, rest, position, context} =
          array_entries(rest, %{context | position: position + 1}, size)

        case rest do
          <<?}, rest::binary>> -> {Map.new(entries), rest, position + 1, context}
          _ -> fail(rest, %{context | position: position})
        end

      _ ->
        fail(rest, context)
    end
  end

  defp fail(rest, context) do
    case rest do
      <<>> ->
        raise Dumbo.DecodeError, source: context.source, position: context.position

      <<byte, _::binary>> ->
        raise Dumbo.DecodeError,
          source: context.source,
          position: context.position,
          token: <<byte>>
    end
  end

  defp resolve_object(name, value, opts) do
    case Map.fetch(opts.object_resolvers, name) do
      {:ok, resolver} -> apply_resolver(name, resolver, value)
      :error -> {:object, name, value}
    end
  end

  defp apply_resolver(name, resolver, value) do
    try do
      cond do
        is_function(resolver, 1) ->
          resolver.(value)

        is_atom(resolver) ->
          resolve_with_module(resolver, value)

        true ->
          raise ArgumentError,
                "object resolver for #{inspect(name)} must be a function of arity 1 " <>
                  "or a module implementing Dumbo.ObjectResolver, got: #{inspect(resolver)}"
      end
    rescue
      error in Dumbo.ResolveError ->
        reraise %{error | class: error.class || name}, __STACKTRACE__
    end
  end

  defp resolve_with_module(module, value) do
    if Code.ensure_loaded?(module) and function_exported?(module, :resolve, 1) do
      module.resolve(value)
    else
      raise ArgumentError,
            "object resolver #{inspect(module)} does not implement Dumbo.ObjectResolver"
    end
  end
end
