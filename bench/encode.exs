# Run with: MIX_ENV=test mix run bench/encode.exs
#
# Benchmarks encoding the terms decoded from the fixtures under `test/fixtures`,
# grouped by payload and size. Pass one or more sizes to narrow it down, e.g.
# `MIX_ENV=test mix run bench/encode.exs small`.
#
# Note: the terms include resolved `DateTime` structs where fixtures use them,
# and objects fall back to `{:object, name, props}` tuples, which the encoder
# cannot serialise; those fixtures are skipped.

sizes = System.argv()
sizes = if sizes == [], do: ~w(small medium large), else: sizes

# Objects decoded without a resolver become `{:object, name, props}` tuples, and
# special float atoms only partly round-trip; skip fixtures that contain them.
defmodule Bench do
  def encodable?(%DateTime{}), do: true
  def encodable?(term) when is_map(term), do: Enum.all?(term, &encodable?/1)
  def encodable?(term) when is_list(term), do: Enum.all?(term, &encodable?/1)
  def encodable?({:object, _name, _props}), do: false

  def encodable?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&encodable?/1)

  def encodable?(term) when is_atom(term),
    do: term in [nil, true, false, :infinity, :negative_infinity, :nan]

  def encodable?(_term), do: true
end

fixtures =
  Path.wildcard("test/fixtures/**/*.ser")
  |> Enum.filter(fn path ->
    case Path.basename(path, ".ser") |> String.split(".") do
      [_name, size] -> size in sizes
      [_name] -> true
    end
  end)
  |> Enum.map(fn path ->
    name = Path.relative_to(path, "test/fixtures")
    term = path |> File.read!() |> Dumbo.decode()

    if Bench.encodable?(term) do
      {name, term}
    else
      IO.puts("skipping #{name} (contains values the encoder cannot handle)")
      nil
    end
  end)
  |> Enum.reject(&is_nil/1)
  |> Enum.sort()

IO.puts(
  "Benchmarking encode of #{length(fixtures)} fixtures (sizes: #{Enum.join(sizes, ", ")})\n"
)

Benchee.run(
  Map.new(fixtures, fn {name, term} -> {name, fn -> Dumbo.encode(term) end} end),
  warmup: 1,
  time: 3,
  memory_time: 1,
  reduction_time: 1,
  formatters: [Benchee.Formatters.Console]
)
