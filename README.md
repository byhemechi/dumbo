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

Use `Dumbo.encode/2` to serialize Elixir terms into a PHP serialized string:

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

Use `Dumbo.decode/1` to deserialize PHP serialized strings back into Elixir terms:

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
#=> {:object, "stdClass", %{"name" => "Alice"}}
```

### Structs

You can serialize Elixir structs into PHP objects by deriving `Dumbo.Encoder`:

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

### Date and Time

`DateTime` structs are automatically serialized as PHP `DateTimeImmutable` objects in UTC:

```elixir
dt = ~U[2024-01-15 09:30:00Z]
Dumbo.encode(dt)
#=> ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:20:"2024-01-15T09:30:00Z";s:8:"timezone";s:3:"UTC";s:13:"timezone_type";i:3;}'
```

You can specify a different PHP class (such as `"DateTime"`) using `Dumbo.EncodeOpts`:

```elixir
Dumbo.encode(dt, %Dumbo.EncodeOpts{datetime_struct: "DateTime"})
#=> ~s'O:8:"DateTime":3:{s:4:"date";s:20:"2024-01-15T09:30:00Z";s:8:"timezone";s:3:"UTC";s:13:"timezone_type";i:3;}'
```
