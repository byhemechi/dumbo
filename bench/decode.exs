# Run with: mix run bench/decode.exs [options]
#
# Benchmarks decoding of the PHP-serialised fixtures under `test/fixtures`,
# grouped by payload so regressions in a particular shape or size are easy to
# spot. See `--help` for the available options.

Code.require_file("bench_helper.exs", __DIR__)

opts = Dumbo.Bench.parse_args(System.argv())
fixtures = Dumbo.Bench.fixtures(opts)

summary =
  "Benchmarking decode of #{length(fixtures)} fixtures " <>
    "(sizes: #{Enum.join(opts.sizes, ", ")}, only: #{opts.only || "all"})"

inputs = Map.new(fixtures, fn {name, bin} -> {name, fn -> Dumbo.decode(bin) end} end)

Dumbo.Bench.run(summary, inputs, opts)
