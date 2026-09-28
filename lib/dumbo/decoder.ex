defmodule Dumbo.DecodeOpts do
  @moduledoc """
  Options for configuring decoding behavior.

  ## Fields

    * `:object_resolvers` - A map of PHP class names to resolvers. Each resolver is
      a function of arity 1 or a module implementing `Dumbo.ObjectResolver`.
      Defaults to `Dumbo.PHP.resolvers()`.

    * `:use_native_decoders` - When `true` (the default) and `dumbo_nif` is
      installed, numeric floats are parsed by that precompiled NIF. Set to
      `false` for the pure-Elixir path. Ignored without `dumbo_nif`.

    * `:resolve_references` - When `true` (the default), `R:`/`r:` references are
      resolved. When `false`, the value stack is not built and any reference
      raises `Dumbo.DecodeError`.
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
  Raised when a reference cannot be resolved: out of range, not an object
  (`r:`), or recursive. PHP allows cyclic data; Elixir terms cannot.
  """

  defexception [:message]
end

defmodule Dumbo.UnsupportedOperatorError do
  @moduledoc """
  Raised when the payload uses a PHP serialisation operator that Dumbo does not
  support.

  The format defines operators beyond the ones this library decodes, such as
  `C:` (objects implementing `Serializable`) and `E:` (enums).
  """

  @type t :: %__MODULE__{position: integer, operator: binary(), source: String.t()}

  defexception [:position, :operator, :source]

  @impl true
  def message(%{position: position, operator: operator}) do
    "unsupported operator at position #{position}: #{inspect(operator)}" <>
      operator_name(operator)
  end

  defp operator_name("C:"), do: " (custom-serialised object)"
  defp operator_name("E:"), do: " (enum)"
  defp operator_name(_operator), do: ""
end

defmodule Dumbo.Decoder do
  @moduledoc """
  Decoder implementation for the PHP serialisation format.
  """

  @type opts :: Dumbo.DecodeOpts.t()

  @compile {:inline,
            [
              advance: 2,
              boolean: 2,
              deref_object: 1,
              dot_pattern: 0,
              exponent_pattern: 0,
              integer: 2,
              key_context: 1,
              push: 4,
              reference_pattern: 0,
              reserve: 1,
              resolve_slot: 3
            ]}

  # `:binary.compile_pattern/1` returns a term containing a reference, which
  # cannot be embedded in a function literal, so the patterns are compiled once
  # at module load and fetched through `:persistent_term`.
  @on_load :__compile_patterns__
  @doc false
  def __compile_patterns__ do
    :persistent_term.put({__MODULE__, :reference_pattern}, :binary.compile_pattern(["R:", "r:"]))
    :persistent_term.put({__MODULE__, :exponent_pattern}, :binary.compile_pattern(["e", "E"]))
    :persistent_term.put({__MODULE__, :dot_pattern}, :binary.compile_pattern("."))
    :ok
  end

  defp reference_pattern, do: :persistent_term.get({__MODULE__, :reference_pattern})
  defp exponent_pattern, do: :persistent_term.get({__MODULE__, :exponent_pattern})
  defp dot_pattern, do: :persistent_term.get({__MODULE__, :dot_pattern})

  require Record

  #   * `opts`     - the active `Dumbo.DecodeOpts`.
  #   * `source`   - the original binary, for error positions.
  #   * `position` - absolute offset of the current `rest`.
  #   * `refs`     - PHP's `var_hash`: every parsed value, in push order but
  #                  stored most-recent-first (see `value/2`).
  #   * `push?`    - `false` while decoding a key.
  #   * `slot`     - counter used to reserve container reference slots.
  Record.defrecordp(:context,
    opts: %Dumbo.DecodeOpts{},
    source: <<>>,
    position: 0,
    refs: [],
    push?: true,
    slot: 0
  )

  @type decode_context :: record(:context)

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

  `R:` value references and `r:` object references resolve against a stack of
  every value seen so far (keys excluded):

      iex> Dumbo.Decoder.decode(~s'a:4:{i:0;i:10;i:1;i:20;i:2;i:30;i:3;R:2;}')
      %{0 => 10, 1 => 20, 2 => 30, 3 => 10}

      iex> Dumbo.Decoder.decode(~s'a:2:{i:0;O:8:"stdClass":1:{s:1:"x";i:1;}i:1;r:2;}')
      %{0 => %{"x" => 1}, 1 => %{"x" => 1}}

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
    opts = disable_unused_references(source, opts)

    case value(source, context(opts: opts, source: source)) do
      {value, _rest, _position, _context} -> value
    end
  end

  # Reference resolution keeps a growing `refs` stack and scans it on every
  # container. If the payload cannot contain an `R:`/`r:` token at all, skip that
  # work entirely, exactly as if `:resolve_references` had been set to `false`.
  defp disable_unused_references(source, %Dumbo.DecodeOpts{resolve_references: true} = opts) do
    if :binary.match(source, reference_pattern()) == :nomatch do
      %{opts | resolve_references: false}
    else
      opts
    end
  end

  defp disable_unused_references(_source, opts), do: opts

  # Returns `{value, rest, position, context}`.
  #
  # `refs` mirrors PHP's `var_hash`: every parsed value occupies a slot in push
  # order (arrays, objects, and their contained values included; keys and `R:`
  # excluded; `r:` included), and `R:n`/`r:n` are 1-based indices into that
  # order. `push?` is `false` while decoding a key, matching PHP parsing keys
  # with a `NULL` var_hash. Object slots are tagged `{:object_ref, value}` so
  # `r:` can verify its target is an object.
  defp value(rest, context(position: position) = context) do
    case rest do
      <<?N, ?;, rest::binary>> -> push(nil, rest, position + 2, context)
      <<?b, ?:, rest::binary>> -> boolean(rest, advance(context, 2))
      <<?i, ?:, rest::binary>> -> integer(rest, advance(context, 2))
      <<?R, ?:, rest::binary>> -> reference(rest, advance(context, 2))
      <<?r, ?:, rest::binary>> -> object_reference(rest, advance(context, 2))
      <<?d, ?:, rest::binary>> -> float(rest, advance(context, 2))
      <<?s, ?:, rest::binary>> -> string(rest, advance(context, 2))
      <<?a, ?:, rest::binary>> -> array(rest, advance(context, 2))
      <<?O, ?:, rest::binary>> -> object(rest, advance(context, 2))
      <<?C, ?:, _::binary>> -> unsupported_operator("C:", position, context)
      <<?E, ?:, _::binary>> -> unsupported_operator("E:", position, context)
      _ -> fail(rest, context)
    end
  end

  defp unsupported_operator(operator, position, context(source: source)) do
    raise Dumbo.UnsupportedOperatorError,
      source: source,
      position: position,
      operator: operator
  end

  defp advance(context(position: position) = context, by),
    do: context(context, position: position + by)

  # Appends to `refs` (most-recent-first), unless we are decoding a key or
  # reference resolution (and therefore the whole stack) is disabled.
  defp push(
         value,
         rest,
         position,
         context(opts: %Dumbo.DecodeOpts{resolve_references: false}) = context
       ),
       do: {value, rest, position, context}

  defp push(value, rest, position, context(push?: false) = context),
    do: {value, rest, position, context}

  defp push(value, rest, position, context(refs: refs) = context),
    do: {value, rest, position, context(context, refs: [value | refs])}

  defp key_context(context), do: context(context, push?: false)

  # Reserves a reference slot for a container before its children are decoded,
  # mirroring PHP pushing arrays and objects ahead of their contents. Nothing is
  # reserved when reference resolution is disabled.
  defp reserve(context(opts: %Dumbo.DecodeOpts{resolve_references: false}) = context),
    do: {nil, context}

  defp reserve(context(refs: refs, slot: slot) = context) do
    {slot, context(context, refs: [{:slot, slot} | refs], slot: slot + 1)}
  end

  defp resolve_slot(
         context(opts: %Dumbo.DecodeOpts{resolve_references: false}) = context,
         _slot,
         _value
       ),
       do: context

  defp resolve_slot(context(refs: refs) = context, slot, value),
    do: context(context, refs: replace_slot(refs, slot, value))

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

  defp boolean(rest, context(position: position) = context) do
    case rest do
      <<?0, ?;, rest::binary>> -> push(false, rest, position + 2, context)
      <<?1, ?;, rest::binary>> -> push(true, rest, position + 2, context)
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

  defp integer_digits(rest, context(source: source, position: position) = context, sign) do
    case take_digits(rest, 0) do
      {0, _rest} ->
        fail(rest, context)

      {count, <<?;, rest::binary>>} ->
        value =
          source
          |> :binary.part(position, count)
          |> :erlang.binary_to_integer()
          |> Kernel.*(sign)

        push(value, rest, position + count + 1, context)

      {count, _rest} ->
        fail(rest, advance(context, count))
    end
  end

  defp take_digits(rest, count) do
    case rest do
      <<c, rest::binary>> when is_digit(c) ->
        take_digits(rest, count + 1)

      _ ->
        {count, rest}
    end
  end

  defp float(rest, context(position: position) = context) do
    case rest do
      <<?I, ?N, ?F, ?;, rest::binary>> ->
        push(:infinity, rest, position + 4, context)

      <<?-, ?I, ?N, ?F, ?;, rest::binary>> ->
        push(:negative_infinity, rest, position + 5, context)

      <<?N, ?A, ?N, ?;, rest::binary>> ->
        push(:nan, rest, position + 4, context)

      _ ->
        numeric_float(rest, context)
    end
  end

  if Code.ensure_loaded?(Dumbo.Nif) do
    defp numeric_float(
           rest,
           context(
             opts: %Dumbo.DecodeOpts{use_native_decoders: true},
             source: source,
             position: position
           ) = context
         ) do
      case Dumbo.Nif.decode_numeric_float(rest) do
        {:ok, {value, count}} ->
          <<_::binary-size(^count), rest::binary>> = rest
          push(value, rest, position + count, advance(context, count))

        {:error, {:unexpected_end, %{position: offset}}} ->
          raise Dumbo.DecodeError, source: source, position: position + offset

        {:error, {:unexpected_sequence, %{position: offset, token: token}}} ->
          raise Dumbo.DecodeError, source: source, position: position + offset, token: token
      end
    end
  end

  defp numeric_float(rest, context(position: position) = context) do
    {token, rest, count} = float_token(rest, context, position, 0)

    case normalize_float(token) do
      {:ok, normalized} ->
        value = :erlang.binary_to_float(normalized)
        push(value, rest, position + count + 1, context)

      :error ->
        # Match the NIF: report the whole invalid token at its start.
        raise Dumbo.DecodeError,
          source: context(context, :source),
          position: position,
          token: token
    end
  end

  defp float_token(rest, context(source: source) = context, start, count) do
    case rest do
      <<?;, rest::binary>> ->
        {binary_part(source, start, count), rest, count}

      <<c, rest::binary>> when c in ~c"0123456789+-.eE" ->
        float_token(rest, context, start, count + 1)

      _ ->
        fail(rest, advance(context, count))
    end
  end

  # Mirrors the token grammar accepted by the NIF's `valid_float/1`:
  # `^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$`.
  defp valid_float?(<<"-", rest::binary>>), do: valid_float_mantissa?(rest)
  defp valid_float?(rest), do: valid_float_mantissa?(rest)

  defp valid_float_mantissa?(<<?., rest::binary>>) do
    case take_digits(rest, 0) do
      {count, rest} when count > 0 -> valid_float_exponent?(rest)
      _ -> false
    end
  end

  defp valid_float_mantissa?(rest) do
    case take_digits(rest, 0) do
      {count, rest} when count > 0 ->
        case rest do
          <<?., rest::binary>> ->
            {_fraction, rest} = take_digits(rest, 0)
            valid_float_exponent?(rest)

          _ ->
            valid_float_exponent?(rest)
        end

      _ ->
        false
    end
  end

  defp valid_float_exponent?(<<c, rest::binary>>) when c in [?e, ?E] do
    rest =
      case rest do
        <<sign, rest::binary>> when sign in [?+, ?-] -> rest
        _ -> rest
      end

    case take_digits(rest, 0) do
      {count, <<>>} when count > 0 -> true
      _ -> false
    end
  end

  defp valid_float_exponent?(<<>>), do: true
  defp valid_float_exponent?(_), do: false

  # `:erlang.binary_to_float/1` requires a decimal point, but PHP and Erlang emit
  # exponent notation that may omit it.
  defp normalize_float(token) do
    if valid_float?(token) do
      {mantissa, exponent} =
        case :binary.split(token, exponent_pattern()) do
          [mantissa] -> {mantissa, ""}
          [mantissa, exponent] -> {mantissa, "e" <> exponent}
        end

      {:ok, normalize_mantissa(mantissa) <> exponent}
    else
      :error
    end
  end

  defp normalize_mantissa("-" <> rest), do: "-" <> normalize_mantissa(rest)
  defp normalize_mantissa("." <> _ = mantissa), do: "0" <> mantissa

  defp normalize_mantissa(mantissa) do
    cond do
      :binary.match(mantissa, dot_pattern()) == :nomatch -> mantissa <> ".0"
      :binary.last(mantissa) == ?. -> mantissa <> "0"
      true -> mantissa
    end
  end

  defp sized(rest, context(source: source, position: position) = context, suffix) do
    {count, rest} = take_digits(rest, 0)

    case rest do
      <<^suffix, rest::binary>> when count > 0 ->
        size = :erlang.binary_to_integer(:binary.part(source, position, count))
        {size, rest, position + count + 1}

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

  defp reference(
         _rest,
         context(
           opts: %Dumbo.DecodeOpts{resolve_references: false},
           source: source,
           position: position
         )
       ) do
    raise Dumbo.DecodeError, source: source, position: position - 2, token: "R:"
  end

  defp reference(rest, context(refs: refs) = context) do
    {n, rest, position} = reference_id(rest, context)

    case fetch_reference(refs, n) do
      :missing ->
        raise Dumbo.ReferenceError, message: "Array reference #{inspect(n)} out of range"

      {:slot, _slot} ->
        raise Dumbo.ReferenceError, message: "Recursive references are not supported"

      entry ->
        # A reference is not itself pushed: pass it through without growing refs.
        {deref_object(entry), rest, position, context(context, push?: false)}
    end
  end

  # A lowercase `r:` clones an object (same instance) and, unlike `R:`, is
  # itself pushed onto the stack. The target must be an object.
  defp object_reference(
         _rest,
         context(
           opts: %Dumbo.DecodeOpts{resolve_references: false},
           source: source,
           position: position
         )
       ) do
    raise Dumbo.DecodeError, source: source, position: position - 2, token: "r:"
  end

  defp object_reference(rest, context(refs: refs) = context) do
    {n, rest, position} = reference_id(rest, context)

    case fetch_reference(refs, n) do
      {:object_ref, value} ->
        push_object(value, rest, position, context)

      {:slot, _slot} ->
        raise Dumbo.ReferenceError, message: "Recursive references are not supported"

      :missing ->
        raise Dumbo.ReferenceError, message: "Object reference #{inspect(n)} out of range"

      _value ->
        raise Dumbo.ReferenceError,
          message: "Object reference #{inspect(n)} does not point to an object"
    end
  end

  # Object slots are stored tagged so `r:` can verify the target is an object;
  # `R:` unwraps them so callers never see the tag.
  defp deref_object({:object_ref, value}), do: value
  defp deref_object(entry), do: entry

  defp push_object(value, rest, position, context(push?: false) = context),
    do: {value, rest, position, context}

  defp push_object(value, rest, position, context(refs: refs) = context),
    do: {value, rest, position, context(context, refs: [{:object_ref, value} | refs])}

  defp reference_id(rest, context(source: source, position: position) = context) do
    case take_digits(rest, 0) do
      {0, _rest} ->
        fail(rest, context)

      {count, <<?;, rest::binary>>} ->
        n = :erlang.binary_to_integer(:binary.part(source, position, count))
        {n, rest, position + count + 1}

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
          array_entries(rest, context(context, position: position + 1), size)

        case rest do
          <<?}, rest::binary>> ->
            value = Map.new(entries)
            context = resolve_slot(context, slot, value)
            {value, rest, position + 1, context}

          _ ->
            fail(rest, context(context, position: position))
        end

      _ ->
        fail(rest, context)
    end
  end

  defp array_entries(rest, context, size) do
    array_entries(rest, context, size, 0, [])
  end

  defp array_entries(rest, context(position: position) = context, size, index, entries) do
    if index == size do
      {:lists.reverse(entries), rest, position, context}
    else
      {key, rest, position, context} = value(rest, key_context(context))

      {entry, rest, position, context} =
        value(rest, context(context, position: position, push?: true))

      array_entries(
        rest,
        context(context, position: position),
        size,
        index + 1,
        [{key, entry} | entries]
      )
    end
  end

  defp object(rest, context(opts: opts) = context) do
    {name, rest, position} = bytes(rest, context)

    case rest do
      <<?:, rest::binary>> ->
        {slot, context} = reserve(context)

        {properties, rest, position, context} =
          property_list(rest, context(context, position: position + 1))

        value = resolve_object(name, properties, opts)
        context = resolve_slot(context, slot, {:object_ref, value})
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
          array_entries(rest, context(context, position: position + 1), size)

        case rest do
          <<?}, rest::binary>> -> {Map.new(entries), rest, position + 1, context}
          _ -> fail(rest, context(context, position: position))
        end

      _ ->
        fail(rest, context)
    end
  end

  defp fail(rest, context(source: source, position: position)) do
    case rest do
      <<>> ->
        raise Dumbo.DecodeError, source: source, position: position

      <<byte, _::binary>> ->
        raise Dumbo.DecodeError, source: source, position: position, token: <<byte>>
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
