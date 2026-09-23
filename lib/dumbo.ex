defmodule Dumbo do
  defdelegate decode(source), to: Dumbo.Decoder
  defdelegate decode(source, opts), to: Dumbo.Decoder
end
