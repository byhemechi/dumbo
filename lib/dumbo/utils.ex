defmodule Dumbo.Utils do
  @moduledoc false

  def byte_at(source, position) do
    if position < byte_size(source) do
      :binary.at(source, position)
    else
      raise(Dumbo.DecodeError, source: source, position: position)
    end
  end

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
