defmodule Dumbo.DecodeOpts do
  @moduledoc """
  Options for configuring decoding behavior.

  ## Fields

    * `:object_resolvers` - A map of PHP class names to functions that convert an
      object's properties map into an Elixir term. Defaults to `%{}`. See
      `Dumbo.ObjectResolver` for converting objects into structs.
  """

  @type object_resolver :: (object :: map() -> term())

  @type t :: %__MODULE__{
          object_resolvers: %{(object_name :: binary()) => object_resolver()}
        }

  defstruct object_resolvers: %{}
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
      {:object, "stdClass", %{"John" => 3.14, "Jane" => 2.718}}

  Objects can be decoded with the `:object_resolvers` option:

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

  defp float(source, position, count \\ 0, is_negative \\ false, fraction_part \\ false) do
    case :binary.at(source, position + count) do
      ?- when count == 0 ->
        float(source, position, 1, true, fraction_part)

      ?I when count == 0 ->
        {:infinity, flag(source, position, "INF;")}

      ?I when count == 1 and is_negative == true ->
        {:negative_infinity, flag(source, position, "-INF;")}

      ?N when count == 0 ->
        {:nan, flag(source, position, "NAN;")}

      ?. when fraction_part == false ->
        float(source, position, count + 1, is_negative, true)

      c when is_digit(c) ->
        float(source, position, count + 1, is_negative, fraction_part)

      ?; when count > 0 and fraction_part == false ->
        v =
          source
          |> :binary.part(position, count)
          |> :erlang.binary_to_integer()
          |> :erlang.float()

        {v, position + count + 1}

      ?; when count > 0 ->
        prefix = if(:binary.at(source, position) == ?., do: "0", else: "")

        suffix =
          cond do
            !fraction_part -> ".0"
            :binary.at(source, position + count - 1) == ?. -> "0"
            true -> ""
          end

        v =
          if prefix == "" and suffix == "" do
            :binary.part(source, position, count)
          else
            <<prefix::binary, :binary.part(source, position, count)::binary, suffix::binary>>
          end
          |> :erlang.binary_to_float()

        {v, position + count + 1}

      _ ->
        raise(Dumbo.DecodeError, source: source, position: position + count)
    end
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

    case Map.fetch(opts.object_resolvers, name) do
      {:ok, resolver} when is_function(resolver, 1) ->
        {resolver.(value), position}

      {:ok, _other} ->
        raise ArgumentError, "object resolver for #{inspect(name)} must be a function of arity 1"

      :error ->
        {{:object, name, value}, position}
    end
  end
end
