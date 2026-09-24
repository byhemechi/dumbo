# Dumbo [![][hex-badge]][hex-url]

[PHP serialisation format](https://en.wikipedia.org/wiki/PHP_serialization_format) encoder/decoder for Elixir.

[hex-badge]: https://img.shields.io/hexpm/v/dumbo
[hex-url]: https://hex.pm/packages/dumbo

## Installation

Add `dumbo` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dumbo, "~> 0.1.0"}
  ]
end
```

## Usage

### Encoding

Use `Dumbo.encode/2` to serialise Elixir terms into a PHP serialised string:

```elixir
# Primitives
Dumbo.encode(42)
#=> "i:42;"

Dumbo.encode("hello world")
#=> ~s's:11:"hello world";'

Dumbo.encode(true)
#=> "b:1;"

Dumbo.encode(nil)
#=> "N;"

# Lists and Maps
Dumbo.encode([1, 2, 3])
#=> "a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}"

Dumbo.encode(%{"name" => "Alice", "role" => "admin"})
#=> ~s'a:2:{s:4:"name";s:5:"Alice";s:4:"role";s:5:"admin";}'

# Special float values
Dumbo.encode(:infinity)
#=> "d:INF;"

Dumbo.encode(:nan)
#=> "d:NAN;"
```

To encode to `iodata` without allocating an intermediate binary:

```elixir
Dumbo.encode_to_iodata("hello")
#=> ["s:", "5", ":\"", "hello", "\";"]
```

### Decoding

Use `Dumbo.decode/1` to deserialise PHP serialised strings back into Elixir terms:

```elixir
# Primitives
Dumbo.decode("i:42;")
#=> 42

Dumbo.decode(~s's:11:"hello world";')
#=> "hello world"

Dumbo.decode("b:1;")
#=> true

Dumbo.decode("N;")
#=> nil

# Arrays
Dumbo.decode(~s'a:2:{i:0;s:3:"foo";i:1;s:3:"bar";}')
#=> %{0 => "foo", 1 => "bar"}

# Objects
Dumbo.decode(~s'O:8:"stdClass":1:{s:4:"name";s:5:"Alice";}')
#=> %{"name" => "Alice"}
```

Common PHP classes are resolved into native Elixir types automatically (see
[Built-in resolvers](#built-in-resolvers)). Supply an empty `:object_resolvers`
map to receive raw `{:object, class_name, properties}` tuples instead:

```elixir
opts = %Dumbo.DecodeOpts{object_resolvers: %{}}

Dumbo.decode(~s'O:8:"stdClass":1:{s:4:"name";s:5:"Alice";}', opts)
#=> {:object, "stdClass", %{"name" => "Alice"}}
```

Use the `:object_resolvers` option to supply your own resolvers. A resolver is
either a function of arity 1 or a module implementing `Dumbo.ObjectResolver`:

```elixir
opts = %Dumbo.DecodeOpts{
  object_resolvers: %{
    "stdClass" => fn properties -> properties end
  }
}

Dumbo.decode(~s'O:8:"stdClass":1:{s:4:"name";s:5:"Alice";}', opts)
#=> %{"name" => "Alice"} (handled by the explicit resolver, not the built-in one)
```

### Built-in resolvers

Dumbo ships with resolvers for common PHP classes that map directly onto native
Elixir types:

| PHP class             | Elixir term |
| --------------------- | ----------- |
| `stdClass`            | map         |
| `DateTime`            | `DateTime`  |
| `DateTimeImmutable`   | `DateTime`  |
| `ArrayObject`         | map         |
| `ArrayIterator`       | map         |
| `SplFixedArray`       | list        |
| `SplDoublyLinkedList` | list        |
| `SplStack`            | list        |
| `SplQueue`            | list        |

They are the default `:object_resolvers` of `%Dumbo.DecodeOpts{}`, so they apply
automatically. `Dumbo.PHP.resolvers/0` returns the map, and each mapping is also
exposed as a public function (for example `Dumbo.PHP.resolve_datetime/1`), so you
can extend or override the defaults:

```elixir
resolvers = Map.put(Dumbo.PHP.resolvers(), "Money", &App.Money.resolve/1)
opts = %Dumbo.DecodeOpts{object_resolvers: resolvers}

Dumbo.decode(~s'O:13:"SplFixedArray":3:{i:0;i:1;i:1;i:2;i:2;i:3;}', opts)
#=> [1, 2, 3]
```

`DateTime` values are resolved from PHP's native representation. Fixed-offset and
UTC time zones resolve out of the box; other identifiers need a configured time
zone database (for example [`tzdata`](https://hex.pm/packages/tzdata)) and raise
`Dumbo.ResolveError` otherwise:

```elixir
Dumbo.decode(~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}')
#=> ~U[2024-01-15 09:30:00.000000Z]
```

### Structs

You can serialise Elixir structs into PHP objects by deriving `Dumbo.Encoder`:

```elixir
defmodule User do
  @derive Dumbo.Encoder
  defstruct [:name, :email]
end

user = %User{name: "Alice", email: "alice@example.com"}
Dumbo.encode(user)
#=> ~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:17:"alice@example.com";}'
```

You can customize the PHP class name using the `:class_name` option:

```elixir
defmodule User do
  @derive {Dumbo.Encoder, class_name: "App\\Models\\User"}
  defstruct [:name, :email]
end

user = %User{name: "Alice", email: "alice@example.com"}
Dumbo.encode(user)
#=> ~s'O:15:"App\\Models\\User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:17:"alice@example.com";}'
```

Deriving with `object_resolver: true` additionally implements the `Dumbo.ObjectResolver`
behaviour, so decoded PHP objects can be converted back into the struct:

```elixir
defmodule User do
  @derive {Dumbo.Encoder, object_resolver: true}
  defstruct [:name, :email]
end

opts = %Dumbo.DecodeOpts{
  object_resolvers: %{"User" => User}
}

Dumbo.decode(~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:17:"alice@example.com";}', opts)
#=> %User{name: "Alice", email: "alice@example.com"}
```

### Date and Time

`DateTime` structs are automatically serialised as PHP `DateTimeImmutable` objects in
UTC, using PHP's native representation:

```elixir
dt = ~U[2024-01-15 09:30:00Z]
Dumbo.encode(dt)
#=> ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}'
```

You can specify a different PHP class (such as `"DateTime"`) using `Dumbo.EncodeOpts`:

```elixir
Dumbo.encode(dt, %Dumbo.EncodeOpts{datetime_struct: "DateTime"})
#=> ~s'O:8:"DateTime":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}'
```
