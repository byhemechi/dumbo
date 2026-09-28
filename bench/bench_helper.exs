# Shared helpers for the Benchee scripts in this directory. Loaded with
# `Code.require_file("bench_helper.exs", __DIR__)`.

defmodule Dumbo.Bench do
  @moduledoc false

  @sizes ~w(small medium large)

  @options [
    help: :boolean,
    size: :keep,
    warmup: :float,
    time: :float,
    memory_time: :float,
    reduction_time: :float,
    only: :string,
    format: :string
  ]

  @doc """
  Parses `System.argv/0` into an option map, exiting on bad input or `--help`.

  See `usage/0` for the accepted options.
  """
  def parse_args(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @options)

    cond do
      opts[:help] -> usage()
      invalid != [] -> abort("invalid option(s): #{format_invalid(invalid)}")
      rest != [] -> abort("unexpected argument(s): #{Enum.join(rest, ", ")}")
      true -> build_opts(opts)
    end
  end

  defp build_opts(opts) do
    sizes = opts |> Keyword.get_values(:size) |> Enum.flat_map(&String.split(&1, ","))

    if sizes != [] and Enum.any?(sizes, &(&1 not in @sizes)) do
      abort("--size must be one of #{Enum.join(@sizes, ", ")}")
    end

    %{
      sizes: if(sizes == [], do: @sizes, else: sizes),
      only: opts[:only],
      warmup: Keyword.get(opts, :warmup, 1),
      time: Keyword.get(opts, :time, 3),
      memory_time: Keyword.get(opts, :memory_time, 1),
      reduction_time: Keyword.get(opts, :reduction_time, 1),
      format: opts[:format] || "console"
    }
  end

  @doc """
  Loads every fixture matching the `:sizes` and `:only` options as a map of
  fixture name to binary, suitable for Benchee's `:inputs` option.

  A fixture's size is the final `.`-separated token of its name
  (`users.small.ser`); fixtures without one are always included.
  """
  def fixtures(%{sizes: sizes, only: only}) do
    Path.wildcard("test/fixtures/**/*.ser")
    |> Enum.filter(fn path -> size_in?(path, sizes) end)
    |> Enum.filter(fn path -> only == nil or String.contains?(path, only) end)
    |> Map.new(fn path -> {Path.relative_to(path, "test/fixtures"), File.read!(path)} end)
  end

  defp size_in?(path, sizes) do
    case Path.basename(path, ".ser") |> String.split(".") do
      [_name, size] -> size in sizes
      [_name] -> true
    end
  end

  @doc """
  Runs Benchee over the `jobs` map (`%{name => function}`) against every entry
  in `inputs` via Benchee's `:inputs` option, using the measurement options from
  `parse_args/1`. Prints the summary line first.

  `inputs` is a map of fixture name to value; Benchee groups the results by input
  name.
  """
  def run(title, jobs, inputs, %{format: format} = opts) when is_map(jobs) do
    if format != "console" do
      abort("unsupported --format #{inspect(format)} (only \"console\")")
    end

    IO.puts("#{title}\n")

    Benchee.run(jobs, benchee_config(opts) ++ [inputs: inputs])
  end

  defp benchee_config(opts) do
    [
      warmup: opts.warmup,
      time: opts.time,
      memory_time: opts.memory_time,
      reduction_time: opts.reduction_time,
      formatters: [Benchee.Formatters.Console]
    ]
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn
      {name, nil} -> name
      {name, value} -> "#{name}=#{value}"
    end)
  end

  defp usage do
    IO.puts("""
    Usage: mix run bench/<script>.exs [options]

    Options:
          --size SIZE[,SIZE...]   fixtured sizes to include (#{Enum.join(@sizes, ", ")})
          --only SUBSTRING        run only fixtures whose path contains SUBSTRING
          --warmup SECONDS        warmup time per fixture (default: 1)
          --time SECONDS          measurement time per fixture (default: 3)
          --memory-time SECONDS   memory measurement time, 0 disables (default: 1)
          --reduction-time SEC    reduction measurement time, 0 disables (default: 1)
          --format NAME           output formatter: console (default)

    Examples:
          mix run bench/decode.exs --size small
          mix run bench/encode.exs --size small,medium --time 5
          mix run bench/decode.exs --only worst
    """)

    System.halt(0)
  end

  defp abort(message) do
    IO.puts(:stderr, "error: #{message}")
    System.halt(1)
  end
end
