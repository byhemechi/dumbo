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

  ## Examples

      iex> Dumbo.Encode.float(3.14, %Dumbo.EncodeOpts{}) |> IO.iodata_to_binary()
      "d:3.14000000000000012434e+00;"

  """
  @spec float(float(), opts()) :: iodata()
  def float(term, _opts), do: ["d:", :erlang.float_to_binary(term), ?;]

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
