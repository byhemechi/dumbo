defmodule Dumbo.EncodeOpts do
  @type t :: %__MODULE__{datetime_struct: binary()}
  defstruct datetime_struct: "DateTimeImmutable"
end

defmodule Dumbo.Encode do
  @type opts :: Dumbo.EncodeOpts.t()

  def integer(term, _opts), do: ["i:", :erlang.integer_to_binary(term), ?;]
  def float(term, _opts), do: ["d:", :erlang.float_to_binary(term), ?;]
  def binary(term, _opts), do: ["s:", to_string(byte_size(term)), ~s':"', term, ~s'";']

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

  def object(name, fields, opts) do
    [
      "O:",
      to_string(byte_size(name)),
      ":\"",
      name,
      "\":",
      to_string(map_size(fields)),
      ":{",
      for {key, value} <- fields do
        [Dumbo.Encoder.encode(key, opts), Dumbo.Encoder.encode(value, opts)]
      end,
      ?}
    ]
  end

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
