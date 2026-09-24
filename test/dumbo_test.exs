defmodule DumboTest.User do
  @moduledoc false
  @behaviour Dumbo.ObjectResolver

  defstruct [:name, :email]

  @impl Dumbo.ObjectResolver
  def resolve(%{"name" => name, "email" => email}) do
    %__MODULE__{name: name, email: email}
  end
end

defmodule DumboTest do
  use ExUnit.Case
  doctest Dumbo
  doctest Dumbo.Decoder
  doctest Dumbo.Encode
  doctest Dumbo.Encoder
  doctest Dumbo.PHP

  describe "Dumbo.decode/2 with :object_resolvers" do
    test "applies resolvers to nested objects" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"stdClass" => fn obj -> Map.new(obj) end}}

      source = ~s'O:8:"stdClass":1:{s:5:"inner";O:8:"stdClass":1:{s:1:"a";i:1;}}'

      assert Dumbo.decode(source, opts) == %{"inner" => %{"a" => 1}}
    end
  end

  describe "Dumbo.ObjectResolver" do
    test "accepts a module name as a resolver" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"User" => DumboTest.User}}

      source = ~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:3:"a@b";}'

      assert Dumbo.decode(source, opts) == %DumboTest.User{name: "Alice", email: "a@b"}
    end

    test "raises when a resolver module does not implement the behaviour" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"User" => String}}

      source = ~s'O:4:"User":1:{s:4:"name";s:5:"Alice";}'

      assert_raise ArgumentError, fn -> Dumbo.decode(source, opts) end
    end
  end

  describe "@derive Dumbo.Encoder with :object_resolver" do
    test "converts a decoded object into the struct" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"User" => DumboTest.DerivedUser}}

      source = ~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:3:"a@b";}'

      assert Dumbo.decode(source, opts) == %DumboTest.DerivedUser{name: "Alice", email: "a@b"}
    end

    test "retains struct defaults for fields absent from the object" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"User" => DumboTest.DerivedWithDefaults}}

      assert Dumbo.decode(~s'O:4:"User":1:{s:4:"name";s:5:"Alice";}', opts) ==
               %DumboTest.DerivedWithDefaults{name: "Alice", email: "none@example.com"}
    end
  end

  describe "DateTime resolution" do
    test "resolves a fixed-offset time zone without a time zone database" do
      source =
        ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:1;s:8:"timezone";s:6:"+02:00";}'

      assert Dumbo.decode(source) == ~U[2024-01-15 07:30:00.000000Z]
    end

    test "resolves a UTC abbreviation" do
      source =
        ~s'O:8:"DateTime":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:2;s:8:"timezone";s:1:"Z";}'

      assert Dumbo.decode(source) == ~U[2024-01-15 09:30:00.000000Z]
    end

    test "raises Dumbo.ResolveError when no time zone database can resolve the zone" do
      source =
        ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:16:"America/New_York";}'

      assert_raise Dumbo.ResolveError, fn -> Dumbo.decode(source) end
    end

    test "resolves a named time zone when a time zone database is configured" do
      database = Calendar.get_time_zone_database()
      Calendar.put_time_zone_database(DumboTest.TimeZoneDatabase)

      try do
        source =
          ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:16:"America/New_York";}'

        expected =
          DateTime.from_naive!(
            ~N[2024-01-15 09:30:00.000000],
            "America/New_York",
            DumboTest.TimeZoneDatabase
          )

        assert Dumbo.decode(source) == expected
      after
        Calendar.put_time_zone_database(database)
      end
    end

    test "raises Dumbo.ResolveError for malformed date properties" do
      assert_raise Dumbo.ResolveError, fn ->
        Dumbo.PHP.resolve_datetime(%{"timezone_type" => 3, "timezone" => "UTC"})
      end
    end
  end

  describe "Spl and ArrayObject resolution" do
    test "resolves ArrayObject to its storage map" do
      source =
        ~s'O:11:"ArrayObject":4:{i:0;i:0;i:1;a:2:{s:1:"a";i:1;s:1:"b";i:2;}i:2;a:0:{}i:3;N;}'

      assert Dumbo.decode(source) == %{"a" => 1, "b" => 2}
    end

    test "resolves SplFixedArray to a list" do
      source = ~s'O:13:"SplFixedArray":3:{i:0;i:1;i:1;i:2;i:2;i:3;}'

      assert Dumbo.decode(source) == [1, 2, 3]
    end

    test "resolves SplStack, SplQueue and SplDoublyLinkedList to lists" do
      stack = ~s'O:8:"SplStack":3:{i:0;i:6;i:1;a:2:{i:0;s:1:"a";i:1;s:1:"b";}i:2;a:0:{}}'
      queue = ~s'O:8:"SplQueue":3:{i:0;i:4;i:1;a:2:{i:0;s:1:"a";i:1;s:1:"b";}i:2;a:0:{}}'

      list =
        ~s'O:19:"SplDoublyLinkedList":3:{i:0;i:0;i:1;a:2:{i:0;s:1:"a";i:1;s:1:"b";}i:2;a:0:{}}'

      assert Dumbo.decode(stack) == ["a", "b"]
      assert Dumbo.decode(queue) == ["a", "b"]
      assert Dumbo.decode(list) == ["a", "b"]
    end
  end

  describe "DateTime encoding" do
    test "matches PHP's native serialisation shape" do
      assert Dumbo.encode(~U[2024-01-15 09:30:00Z]) ==
               ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}'
    end

    test "preserves microseconds" do
      assert Dumbo.encode(~U[2024-01-15 09:30:00.123456Z]) ==
               ~s'O:17:"DateTimeImmutable":3:{s:4:"date";s:26:"2024-01-15 09:30:00.123456";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}'
    end

    test "honours the :datetime_struct option" do
      opts = %Dumbo.EncodeOpts{datetime_struct: "DateTime"}

      assert Dumbo.encode(~U[2024-01-15 09:30:00Z], opts) ==
               ~s'O:8:"DateTime":3:{s:4:"date";s:26:"2024-01-15 09:30:00.000000";s:13:"timezone_type";i:3;s:8:"timezone";s:3:"UTC";}'
    end
  end
end
