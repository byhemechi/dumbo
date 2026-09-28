# Run with: mix run bench/encode.exs [options]
#
# Benchmarks encoding the terms decoded from the fixtures under `test/fixtures`,
# grouped by payload and size. See `--help` for the available options.
#
# Fixtures containing values the encoder cannot serialise (`{:object, name,
# props}` tuples from unresolved PHP objects) are skipped.

Code.require_file("bench_helper.exs", __DIR__)

# Objects decoded without a resolver become `{:object, name, props}` tuples,
# which the encoder cannot handle; `DateTime` structs are fine (the protocol
# implements them).
defmodule Dumbo.Bench.Encode do
  @moduledoc false

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

opts = Dumbo.Bench.parse_args(System.argv())

inputs =
  opts
  |> Dumbo.Bench.fixtures()
  |> Enum.reduce(%{}, fn {name, bin}, acc ->
    term = Dumbo.decode(bin)

    if Dumbo.Bench.Encode.encodable?(term) do
      Map.put(acc, name, fn -> Dumbo.encode(term) end)
    else
      IO.puts("skipping #{name} (contains values the encoder cannot handle)")
      acc
    end
  end)

summary =
  "Benchmarking encode of #{map_size(inputs)} fixtures " <>
    "(sizes: #{Enum.join(opts.sizes, ", ")}, only: #{opts.only || "all"})"

Dumbo.Bench.run(summary, inputs, opts)
