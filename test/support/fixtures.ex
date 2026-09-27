defmodule DumboTest.Fixtures do
  @moduledoc false

  # Helpers for loading the PHP-serialised sample payloads under `test/fixtures`.
  #
  # `realistic/` mirrors shapes seen in real applications, while `synthetic/`
  # contains generated `best/` and `worst/` case payloads at three sizes
  # (`small`, `medium`, `large`).

  @root Path.expand("../fixtures", __DIR__)

  @doc "Absolute path to the fixtures directory."
  @spec root() :: binary()
  def root, do: @root

  @doc "Every fixture path, sorted."
  @spec all() :: [binary()]
  def all do
    @root
    |> Path.join("**/*.ser")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc "Absolute path for a fixture relative to the fixtures directory."
  @spec path(binary()) :: binary()
  def path(relative), do: Path.join(@root, relative)

  @doc "Reads a fixture as a binary."
  @spec read(binary()) :: binary()
  def read(relative), do: relative |> path() |> File.read!()

  @doc "Reads and decodes a fixture."
  @spec load(binary()) :: term()
  def load(relative), do: relative |> read() |> Dumbo.decode()
end
