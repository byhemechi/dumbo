# Run with: MIX_ENV=test mix run bench/decode.exs
#
# Benchmarks decoding of the PHP-serialised fixtures under `test/fixtures`,
# grouped by payload so regressions in a particular shape or size are easy to
# spot. Pass one or more sizes to narrow it down, e.g.
# `MIX_ENV=test mix run bench/decode.exs small`.

sizes = System.argv()
sizes = if sizes == [], do: ~w(small medium large), else: sizes

fixtures =
  Path.wildcard("test/fixtures/**/*.ser")
  |> Enum.filter(fn path ->
    case Path.basename(path, ".ser") |> String.split(".") do
      [_name, size] -> size in sizes
      [_name] -> true
    end
  end)
  |> Enum.map(fn path -> {Path.relative_to(path, "test/fixtures"), File.read!(path)} end)
  |> Enum.sort()

IO.puts(
  "Benchmarking decode of #{length(fixtures)} fixtures (sizes: #{Enum.join(sizes, ", ")})\n"
)

Benchee.run(
  Map.new(fixtures, fn {name, bin} -> {name, fn -> Dumbo.decode(bin) end} end),
  warmup: 1,
  time: 3,
  memory_time: 1,
  reduction_time: 1,
  formatters: [Benchee.Formatters.Console]
)
