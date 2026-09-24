# AGENTS.md

Single-package Elixir library (`:dumbo`) that encodes/decodes the PHP serialization
format. No umbrella, no CI, no credo/dialyzer — only `mix` tooling.

## Commands

- `mix test` — full suite.
- `mix test test/dumbo_test.exs:20` — single test (line number).
- `mix format` / `mix format --check-formatted`.
- `mix docs` — ExDoc (dev-only dep).

## Testing quirks

- Most of the suite is **doctests** (39 of 44 assertions). They are wired up in
  `test/dumbo_test.exs` for `Dumbo`, `Dumbo.Decoder`, `Dumbo.Encode`, and
  `Dumbo.Encoder`. Doc examples in `@doc`/`@moduledoc` are executable — keep them
  correct and formatted, and add new behavior docs there.
- Modules under `test/support/` are only compiled in `:test` (see
  `elixirc_paths/1` in `mix.exs`). Put test-only structs there, not in `lib`.

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

## Format gotchas

- All lengths in the PHP format are **byte sizes**, not character counts — use
  `byte_size/1` everywhere (strings, object names).
- Decoded PHP objects default to `{:object, name, properties_map}` unless an
  `:object_resolvers` entry matches.
- Float encoding uses `:erlang.float_to_binary/1`, which does not match PHP's
  precision (see the `d:3.14000000000000012434e+00;` doctest) — don't "fix" the
  doctest to a rounded value.
- `R:` array references are only resolved within arrays; recursive refs
  (`R:1;` at the top level) raise `Dumbo.ReferenceError`.
