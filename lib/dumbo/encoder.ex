defprotocol Dumbo.Encoder do
  @spec encode(value :: term(), opts :: Dumbo.Encode.opts()) :: iodata()
  def encode(value, opts)
end
