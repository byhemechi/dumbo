defmodule Dumbo.DecodeOpts do
  @moduledoc """
  Options for configuring decoding behavior.

  ## Fields

    * `:object_resolvers` - A map of PHP class names to resolvers. Each resolver is
      a function of arity 1 or a module implementing `Dumbo.ObjectResolver`.
      Defaults to `Dumbo.PHP.resolvers()`.
  """

  @type object_resolver :: (object :: map() -> term()) | module()

  @type t :: %__MODULE__{
          object_resolvers: %{(object_name :: binary()) => object_resolver()}
        }

  defstruct object_resolvers: Dumbo.PHP.resolvers()
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
  Exception raised when an invalid or unsupported reference is encountered during decoding.
  """

  defexception [:message]
end

defmodule Dumbo.Decoder do
  @moduledoc """
  Decoder implementation for the PHP serialisation format.
  """

  import Dumbo.Utils

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

  Common PHP classes are resolved into native Elixir types automatically. Supply
  an empty `:object_resolvers` map to receive raw objects instead:

      iex> opts = %Dumbo.DecodeOpts{object_resolvers: %{}}
      iex> Dumbo.Decoder.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}', opts)
      {:object, "stdClass", %{"foo" => "bar"}}

  Objects can also be decoded with the `:object_resolvers` option:

      iex> opts = %Dumbo.DecodeOpts{object_resolvers: %{"stdClass" => fn obj -> obj end}}
      iex> Dumbo.Decoder.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}', opts)
      %{"foo" => "bar"}

  """
  def decode(source, opts \\ %Dumbo.DecodeOpts{}) do
    case value(source, 0, opts) do
      {value, _pos} ->
        value
    end
  end

  defp value(source, position, opts) do
    if byte_size(source) < position + 2 do
      raise Dumbo.DecodeError, source: source, position: position
    end

    case :binary.part(source, position, 2) do
      "N;" -> {nil, position + 2}
      "b:" -> boolean(source, position + 2)
      "i:" -> integer(source, position + 2)
      "R:" -> reference(source, position + 2)
      "d:" -> float(source, position + 2)
      "s:" -> string(source, position + 2)
      "a:" -> array(source, position + 2, opts)
      "O:" -> object(source, position + 2, opts)
      _ -> raise Dumbo.DecodeError, source: source, position: position
    end
  end

  defp boolean(source, position) do
    {v, position} =
      case :binary.at(source, position) do
        ?0 -> {false, position + 1}
        ?1 -> {true, position + 1}
        _ -> raise(Dumbo.DecodeError, source: source, position: position)
      end

    {v, flag(source, position, ?;)}
  end

  defguardp is_digit(c) when c in ~c"1234567890"

  defp integer(source, position, count \\ 0, allow_negative \\ true, terminator \\ ?;) do
    case :binary.at(source, position + count) do
      ?- when allow_negative == true ->
        integer(source, position, count + 1, false, terminator)

      c when is_digit(c) ->
        integer(source, position, count + 1, allow_negative, terminator)

      ^terminator when count > 0 ->
        {source
         |> :binary.part(position, count)
         |> :erlang.binary_to_integer(), position + count + 1}

      _ ->
        raise(Dumbo.DecodeError, source: source, position: position + count)
    end
  end

  defp float(source, position) do
    cond do
      matches?(source, position, "INF;") -> {:infinity, position + 4}
      matches?(source, position, "-INF;") -> {:negative_infinity, position + 5}
      matches?(source, position, "NAN;") -> {:nan, position + 4}
      true -> numeric_float(source, position)
    end
  end

  defp numeric_float(source, position) do
    token = float_token(source, position, 0)

    value =
      case normalize_float(token) do
        {:ok, normalized} ->
          :erlang.binary_to_float(normalized)

        :error ->
          raise Dumbo.DecodeError, source: source, position: position
      end

    {value, position + byte_size(token) + 1}
  end

  defp float_token(source, position, count) do
    case byte_at(source, position + count) do
      ?; when count > 0 ->
        :binary.part(source, position, count)

      c when c in ~c"0123456789+-.eE" ->
        float_token(source, position, count + 1)

      _ ->
        raise Dumbo.DecodeError, source: source, position: position + count
    end
  end

  @float_pattern ~r/^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/

  # PHP emits exponent notation (e.g. `1.0E+25`) and Erlang emits zero-padded
  # exponents (e.g. `1.5e+00`); `:erlang.binary_to_float/1` requires a decimal
  # point, so normalise the token before parsing it.
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

  defp matches?(source, position, value) do
    position + byte_size(value) <= byte_size(source) and
      :binary.part(source, position, byte_size(value)) == value
  end

  defp bytes(source, position) do
    {size, position} = integer(source, position, 0, false, ?:)

    position = flag(source, position, ?")

    if position + size + 2 > byte_size(source) do
      raise(Dumbo.DecodeError, source: source, position: position)
    end

    data = :binary.part(source, position, size)

    {data, flag(source, position + size, ?")}
  end

  defp string(source, position) do
    {data, position} = bytes(source, position)

    {data, flag(source, position, ?;)}
  end

  defp reference(source, position) do
    {v, pos} = integer(source, position)
    {{:array_reference, v}, pos}
  end

  defp array(source, position, opts) do
    {size, position} = integer(source, position, 0, false, ?:)

    position = flag(source, position, ?{)

    {acc, collector} = Collectable.into(%{})

    {_, acc, position} =
      for idx <- 1..size//1, reduce: {[], acc, position} do
        {values, acc, position} ->
          {key, position} = value(source, position, opts)
          {value, position} = value(source, position, opts)

          value =
            case value do
              {:array_reference, 1} ->
                raise Dumbo.ReferenceError, message: "Recursive references are not supported"

              {:array_reference, pos} when pos < idx ->
                Enum.at(values, idx - pos)

              {:array_reference, pos} when pos < idx ->
                raise Dumbo.ReferenceError,
                  message: "Array reference #{inspect(pos)} out of range (1..#{idx - 1})"

              v ->
                v
            end

          {[value | values], collector.(acc, {:cont, {key, value}}), position}
      end

    acc = collector.(acc, :done)

    {acc, flag(source, position, ?})}
  end

  defp object(source, position, opts) do
    {name, position} = bytes(source, position)
    position = flag(source, position, ?:)

    {value, position} = array(source, position, opts)

    {resolve_object(name, value, opts), position}
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
