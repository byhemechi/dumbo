# AGENTS.md

Single-package Elixir library (`:dumbo`) that encodes/decodes the PHP serialization
format. No umbrella, no credo/dialyzer — only `mix` tooling. GitHub Actions CI
(`.github/workflows/ci.yml`) runs formatting and tests on a small Elixir/OTP matrix.

## Commands

- `mix test` — full suite.
- `mix test test/dumbo_test.exs:20` — single test (line number).
- `mix format` / `mix format --check-formatted`.
- `mix docs` — ExDoc (dev-only dep).
- `mix run bench/decode.exs [options]` / `bench/encode.exs` — Benchee benchmarks
  over `test/fixtures` (Benchee is a `:dev`-only dep). Options: `--size`,
  `--only`, `--warmup`, `--time`, `--memory-time`, `--reduction-time`; see
  `--help`. Shared logic lives in `bench/bench_helper.exs`.

## Testing quirks

- Most of the suite is **doctests** (39 of 44 assertions). They are wired up in
  `test/dumbo_test.exs` for `Dumbo`, `Dumbo.Decoder`, `Dumbo.Encode`, and
  `Dumbo.Encoder`. Doc examples in `@doc`/`@moduledoc` are executable — keep them
  correct and formatted, and add new behavior docs there.
- Modules under `test/support/` are only compiled in `:test` (see
  `elixirc_paths/1` in `mix.exs`). Put test-only structs there, not in `lib`.
- `test/fixtures/` holds PHP-serialised sample payloads (`realistic/`, plus
  `synthetic/best|worst/` at `small`/`medium`/`large`). Load them with
  `DumboTest.Fixtures`; `test/fixtures_test.exs` asserts every fixture decodes
  and that `decode(encode(decode(bin)))` returns an equal term. All sizes run by
  default.

## Architecture

- `lib/dumbo.ex` — public API only (`encode/2`, `encode_to_iodata/2`, `decode/2`).
- `lib/dumbo/encoder.ex` — `Dumbo.Encoder` **protocol** plus all `defimpl`s, and the
  `__deriving__` macro for structs. Add a new encodable type by adding a `defimpl`
  here. Structs without `@derive Dumbo.Encoder` raise `Protocol.UndefinedError` at
  runtime; there is no fallback impl.
- `lib/dumbo/encode.ex` — low-level iodata builders. Everything returns iodata;
  only `Dumbo.encode/2` calls `IO.iodata_to_binary/1`.
- `lib/dumbo/decoder.ex` — recursive-descent parser tracking byte positions in the
  source binary. `Dumbo.Utils` provides `byte_at/2` and `flag/3` bounds-checked
  byte assertions — use them instead of raw `:binary.at/2` so malformed input still
  raises `Dumbo.DecodeError`.
- `lib/dumbo/object_resolver.ex` — behaviour for converting decoded PHP objects to
  Elixir terms.
- `lib/dumbo/php.ex` — `Dumbo.PHP` built-in resolvers for common PHP classes with
  direct Elixir equivalents (`stdClass`, `DateTime`/`DateTimeImmutable`,
  `ArrayObject`/`ArrayIterator`, the `Spl*` list types), plus `Dumbo.ResolveError`.
  They are the default `:object_resolvers` of `Dumbo.DecodeOpts`; override by
  passing your own map. Named time zones need a configured time zone database.

## Format gotchas

- All lengths in the PHP format are **byte sizes**, not character counts — use
  `byte_size/1` everywhere (strings, object names).
- Decoded PHP objects default to `{:object, name, properties_map}` unless an
  `:object_resolvers` entry matches.
- Float encoding matches PHP's `serialize()` with the default
  `serialize_precision = -1`: shortest round-trip digits, no trailing `.0` for
  integral floats, and scientific notation with a signed uppercase `E` (e.g.
  `d:1.0E+25;`) only when the decimal exponent falls outside `-4..16`. See
  `Dumbo.Encode.float/2`; the fixture round-trips depend on this.
- `R:` references use PHP's global value stack: every parsed value occupies a
  slot in push order (arrays and objects included, keys excluded, references
  excluded), and `R:n` is a 1-based index into that order. Recursive references
  (a container referencing itself) raise `Dumbo.ReferenceError`, since Elixir
  terms cannot be cyclic. See `Dumbo.Decoder.Context`.
