defmodule Dumbo do
  @moduledoc """
  An encoder and decoder for the [PHP serialisation format](https://en.wikipedia.org/wiki/PHP_serialization_format).

  Dumbo allows you to serialize Elixir data structures into PHP's serialisation format
  and deserialize PHP serialized strings back into Elixir terms.
  """

  @doc """
  Deserializes a PHP serialized string into an Elixir term.

  See `decode/2` for details and options.

  ## Examples

      iex> Dumbo.decode("i:42;")
      42

      iex> Dumbo.decode(~s's:5:"hello";')
      "hello"

      iex> Dumbo.decode("b:1;")
      true

      iex> Dumbo.decode("b:0;")
      false

      iex> Dumbo.decode("N;")
      nil

      iex> Dumbo.decode(~s'a:2:{i:0;s:3:"foo";i:1;s:3:"bar";}')
      %{0 => "foo", 1 => "bar"}

      iex> Dumbo.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}')
      {:object, "stdClass", %{"foo" => "bar"}}

  """
  defdelegate decode(source), to: Dumbo.Decoder

  @doc """
  Serializes an Elixir term into a PHP serialized binary string.

  Accepts an optional `%Dumbo.EncodeOpts{}` struct to configure encoding behavior.

  ## Examples

      iex> Dumbo.encode(42)
      "i:42;"

      iex> Dumbo.encode("hello")
      ~s's:5:"hello";'

      iex> Dumbo.encode(true)
      "b:1;"

      iex> Dumbo.encode(false)
      "b:0;"

      iex> Dumbo.encode(nil)
      "N;"

      iex> Dumbo.encode([1, 2, 3])
      "a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}"

      iex> Dumbo.encode(%{"foo" => "bar"})
      ~s'a:1:{s:3:"foo";s:3:"bar";}'

  """
  @spec encode(term :: term(), opts :: Dumbo.EncodeOpts.t()) :: binary()
  def encode(term, opts \\ %Dumbo.EncodeOpts{}) do
    term
    |> Dumbo.Encoder.encode(opts)
    |> IO.iodata_to_binary()
  end

  @doc """
  Serializes an Elixir term into iodata representing the PHP serialized format.

  Accepts an optional `%Dumbo.EncodeOpts{}` struct to configure encoding behavior.

  ## Examples

      iex> Dumbo.encode_to_iodata(42)
      ["i:", "42", ?;]

      iex> Dumbo.encode_to_iodata("hello")
      ["s:", "5", ~s':"', "hello", ~s'";']

      iex> Dumbo.encode_to_iodata(42) |> IO.iodata_to_binary()
      "i:42;"

  """
  @spec encode_to_iodata(term :: term(), opts :: Dumbo.EncodeOpts.t()) :: iodata()
  def encode_to_iodata(term, opts \\ %Dumbo.EncodeOpts{}) do
    Dumbo.Encoder.encode(term, opts)
  end
end
