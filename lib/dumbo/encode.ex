defmodule Dumbo.EncodeOpts do
  @moduledoc """
  Options for configuring encoding behavior.

  ## Fields

    * `:datetime_struct` - The PHP class name to use when serialising `DateTime` structs.
      Defaults to `"DateTimeImmutable"`.
  """

  @type t :: %__MODULE__{datetime_struct: binary()}
  defstruct datetime_struct: "DateTimeImmutable"
end

defmodule Dumbo.Encode do
  @moduledoc """
  Low-level encoding functions for converting Elixir data types into PHP serialised iodata.
  """

  @type opts :: Dumbo.EncodeOpts.t()

  @doc """
  Encodes an integer into PHP serialised iodata.

  ## Examples

      iex> Dumbo.Encode.integer(42, %Dumbo.EncodeOpts{})
      ["i:", "42", ?;]

      iex> Dumbo.Encode.integer(-10, %Dumbo.EncodeOpts{})
      ["i:", "-10", ?;]

  """
  @spec integer(integer(), opts()) :: iodata()
  def integer(term, _opts), do: ["i:", :erlang.integer_to_binary(term), ?;]

  @doc """
  Encodes a float into PHP serialised iodata.

  Floats are rendered the way PHP's `serialize()` does with the default
  `serialize_precision = -1`: the shortest round-trip representation, without a
  trailing `.0` for integral values, and using scientific notation (e.g.
  `1.0E+25`) only when the decimal exponent falls outside `-4..16`.

  ## Examples

      iex> Dumbo.Encode.float(3.14, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "d:3.14;"

      iex> Dumbo.Encode.float(1.0, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "d:1;"

      iex> Dumbo.Encode.float(1.0e25, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "d:1.0E+25;"

  """
  @spec float(float(), opts()) :: iodata()
  def float(term, _opts), do: ["d:", php_float(term), ?;]

  defp php_float(value) do
    short = :erlang.float_to_binary(value, [:short])

    {sign, short} =
      case short do
        "-" <> rest -> {"-", rest}
        rest -> {"", rest}
      end

    if value == 0.0 do
      sign <> "0"
    else
      {digits, exponent} = decimals(short)
      sign <> format_decimals(digits, exponent)
    end
  end

  # Splits the shortest round-trip representation into its significant digits
  # and the decimal exponent `E`, where the value is `d.ddd... * 10^E`.
  defp decimals(short) do
    {mantissa, exponent} =
      case String.split(short, "e") do
        [mantissa] -> {mantissa, 0}
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
      end

    {int_part, frac_part} =
      case String.split(mantissa, ".") do
        [int_part] -> {int_part, ""}
        [int_part, frac_part] -> {int_part, frac_part}
      end

    digits = int_part <> frac_part
    leading_zeros = count_leading_zeros(digits, 0)
    significant = binary_part(digits, leading_zeros, byte_size(digits) - leading_zeros)
    exponent = String.length(int_part) - 1 - leading_zeros + exponent

    {significant, exponent}
  end

  defp count_leading_zeros(<<"0", rest::binary>>, count),
    do: count_leading_zeros(rest, count + 1)

  defp count_leading_zeros(_digits, count), do: count

  # Outside the decimal range PHP switches to scientific notation, always with
  # a decimal point in the mantissa and a signed exponent.
  defp format_decimals(<<first, rest::binary>>, exponent) when exponent < -4 or exponent >= 17 do
    {rest, exponent} =
      case rest do
        "" -> {"0", exponent}
        rest -> {rest, exponent}
      end

    sign = if exponent < 0, do: "-", else: "+"
    <<first>> <> "." <> rest <> "E" <> sign <> Integer.to_string(abs(exponent))
  end

  defp format_decimals(digits, exponent) do
    int_digits = exponent + 1
    length = byte_size(digits)

    cond do
      int_digits <= 0 ->
        "0." <> String.duplicate("0", -int_digits) <> digits

      int_digits >= length ->
        digits <> String.duplicate("0", int_digits - length)

      true ->
        {int_part, frac_part} = String.split_at(digits, int_digits)
        frac_part = String.trim_trailing(frac_part, "0")

        if frac_part == "" do
          int_part
        else
          int_part <> "." <> frac_part
        end
    end
  end

  @doc """
  Encodes a binary string into PHP serialised iodata.

  ## Examples

      iex> Dumbo.Encode.binary("hello", %Dumbo.EncodeOpts{})
      ["s:", "5", ~s':"', "hello", ~s'";']

  """
  @spec binary(binary(), opts()) :: iodata()
  def binary(term, _opts), do: ["s:", to_string(byte_size(term)), ~s':"', term, ~s'";']

  @doc """
  Encodes a map into PHP serialised iodata representing an associative array.

  ## Examples

      iex> Dumbo.Encode.map(%{"foo" => "bar"}, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      ~s'a:1:{s:3:"foo";s:3:"bar";}'

      iex> Dumbo.Encode.map(%{}, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "a:0:{}"

  """
  @spec map(map(), opts()) :: iodata()
  def map(term, opts) do
    [
      "a:",
      to_string(map_size(term)),
      ":{",
      for {key, value} <- term do
        [Dumbo.Encoder.encode(key, opts), Dumbo.Encoder.encode(value, opts)]
      end,
      ?}
    ]
  end

  @doc """
  Encodes an object with a PHP class name and fields into PHP serialised iodata.

  ## Examples

      iex> Dumbo.Encode.object("stdClass", %{"prop" => "value"}, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      ~s'O:8:"stdClass":1:{s:4:"prop";s:5:"value";}'

  """
  @spec object(binary(), map() | [{term(), term()}], opts()) :: iodata()
  def object(name, fields, opts) do
    [
      "O:",
      to_string(byte_size(name)),
      ":\"",
      name,
      "\":",
      to_string(Enum.count(fields)),
      ":{",
      for {key, value} <- fields do
        [Dumbo.Encoder.encode(key, opts), Dumbo.Encoder.encode(value, opts)]
      end,
      ?}
    ]
  end

  @doc """
  Encodes a list into PHP serialised iodata representing an indexed array.

  ## Examples

      iex> Dumbo.Encode.list(["first", "second"], %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      ~s'a:2:{i:0;s:5:"first";i:1;s:6:"second";}'

      iex> Dumbo.Encode.list([], %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "a:0:{}"

  """
  @spec list(list(), opts()) :: iodata()
  def list(term, opts) do
    [
      "a:",
      to_string(length(term)),
      ":{",
      for {value, key} <- Enum.with_index(term) do
        [Dumbo.Encoder.encode(key, opts), Dumbo.Encoder.encode(value, opts)]
      end,
      ?}
    ]
  end
end
