# Run with: mix run bench/decode.exs [options]
#
# Benchmarks decoding of the PHP-serialised fixtures under `test/fixtures`, so
# regressions in a particular shape or size are easy to spot. See `--help` for
# the available options.

Code.require_file("bench_helper.exs", __DIR__)

opts = Dumbo.Bench.parse_args(System.argv())
inputs = Dumbo.Bench.fixtures(opts)

summary =
  "Benchmarking decode of #{map_size(inputs)} fixtures " <>
    "(sizes: #{Enum.join(opts.sizes, ", ")}, only: #{opts.only || "all"})"

Dumbo.Bench.run(
  summary,
  %{
    "decode" => &Dumbo.decode(&1, %Dumbo.DecodeOpts{use_native_decoders: false}),
    "decode_native" => &Dumbo.decode(&1, %Dumbo.DecodeOpts{use_native_decoders: true})
  },
  inputs,
  opts
)
