defmodule Dumbo.Utils do
  @moduledoc false

  @doc """
  Returns the byte at `position` in `source`, or raises `Dumbo.DecodeError` if out of bounds.
  """
  def byte_at(source, position) do
    if position < byte_size(source) do
      :binary.at(source, position)
    else
      raise(Dumbo.DecodeError, source: source, position: position)
    end
  end

  @doc """
  Asserts that `source` at `position` matches `flag` (a byte or binary) and returns the advanced position.

  Raises `Dumbo.DecodeError` if the byte or binary does not match or exceeds the binary size.
  """
  def flag(source, position, flag)

  def flag(source, position, flag) when is_integer(flag) do
    if byte_at(source, position) != flag do
      raise(Dumbo.DecodeError, source: source, position: position)
    end

    position + 1
  end

  def flag(source, position, flag) when is_binary(flag) do
    if position + byte_size(flag) > byte_size(source) or
         :binary.part(source, position, byte_size(flag)) != flag do
      raise(Dumbo.DecodeError, source: source, position: position)
    end

    position + byte_size(flag)
  end
end
