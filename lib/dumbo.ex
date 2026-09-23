defmodule Dumbo do
  defdelegate decode(source), to: Dumbo.Decoder
  defdelegate decode(source, opts), to: Dumbo.Decoder

  @spec encode(source :: binary(), opts :: Dumbo.EncodeOpts.t()) :: binary()
  def encode(source, opts \\ %Dumbo.EncodeOpts{}) do
    source
    |> Dumbo.Encoder.encode(opts)
    |> IO.iodata_to_binary()
  end

  @spec encode_to_iodata(source :: binary(), opts :: Dumbo.EncodeOpts.t()) :: iodata()
  def encode_to_iodata(source, opts \\ %Dumbo.EncodeOpts{}) do
    Dumbo.Encoder.encode(source, opts)
  end
end
