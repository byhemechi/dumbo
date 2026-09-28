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

  describe "float decoding" do
    test "accepts exponent notation emitted by PHP and Erlang" do
      assert Dumbo.decode("d:1.0E+25;") == 1.0e25
      assert Dumbo.decode("d:1.5e+00;") == 1.5
      assert Dumbo.decode("d:1e3;") == 1.0e3
      assert Dumbo.decode("d:-1.0e-3;") == -0.001
    end

    test "accepts floats with a missing leading or trailing digit" do
      assert Dumbo.decode("d:.5;") == 0.5
      assert Dumbo.decode("d:1.;") == 1.0
      assert Dumbo.decode("d:-.5;") == -0.5
    end

    test "raises for malformed floats" do
      for source <- ["d:1e;", "d:1.2.3;", "d:e3;", "d:;"] do
        assert_raise Dumbo.DecodeError, fn -> Dumbo.decode(source) end
      end
    end
  end

  describe "array references" do
    test "resolves a reference to an earlier value like PHP" do
      # Values are: P0, P1, P2, P3; R:2 targets the value two slots back.
      assert Dumbo.decode(~s'a:5:{i:0;s:2:"P0";i:1;s:2:"P1";i:2;s:2:"P2";i:3;s:2:"P3";i:4;R:2;}') ==
               %{0 => "P0", 1 => "P1", 2 => "P2", 3 => "P3", 4 => "P0"}

      assert Dumbo.decode(~s'a:5:{i:0;s:2:"P0";i:1;s:2:"P1";i:2;s:2:"P2";i:3;s:2:"P3";i:4;R:5;}') ==
               %{0 => "P0", 1 => "P1", 2 => "P2", 3 => "P3", 4 => "P3"}
    end

    test "counts arrays as a single slot in the reference stack" do
      # nest is slot 3 (array, inner, x, y); R:2 targets the inner array.
      assert Dumbo.decode(~s'a:2:{s:4:"nest";a:2:{i:0;s:1:"x";i:1;s:1:"y";}s:3:"ref";R:3;}') ==
               %{"nest" => %{0 => "x", 1 => "y"}, "ref" => "x"}
    end

    test "references an outer value from a nested array" do
      assert Dumbo.decode(
               ~s'a:3:{i:0;s:1:"A";i:1;s:1:"B";s:4:"nest";a:2:{i:0;s:5:"inner";i:1;R:2;}}'
             ) == %{0 => "A", 1 => "B", "nest" => %{0 => "inner", 1 => "A"}}
    end

    test "resolves references inside object properties" do
      assert Dumbo.decode(
               ~s'O:1:"C":3:{s:1:"a";a:3:{i:0;i:1;i:1;i:2;i:2;i:3;}s:1:"b";s:3:"bee";s:1:"c";R:2;}'
             ) ==
               {:object, "C",
                %{
                  "a" => %{0 => 1, 1 => 2, 2 => 3},
                  "b" => "bee",
                  "c" => %{0 => 1, 1 => 2, 2 => 3}
                }}
    end

    test "resolves references to falsy values" do
      assert Dumbo.decode(~s'a:3:{i:0;N;i:1;i:9;i:2;R:2;}') == %{0 => nil, 1 => 9, 2 => nil}
      assert Dumbo.decode(~s'a:3:{i:0;b:0;i:1;i:9;i:2;R:2;}') == %{0 => false, 1 => 9, 2 => false}
    end

    test "raises for out-of-range references" do
      assert_raise Dumbo.ReferenceError, fn ->
        Dumbo.decode(~s'a:2:{i:0;i:1;i:1;R:9;}')
      end
    end

    test "raises for recursive references" do
      assert_raise Dumbo.ReferenceError, fn ->
        Dumbo.decode(~s'a:1:{i:0;R:1;}')
      end
    end
  end

  describe "object references" do
    test "resolves a duplicated object with a lowercase r reference" do
      # Both entries are the same object instance in PHP; Elixir yields equal
      # (immutable) terms.
      assert Dumbo.decode(~s'a:2:{i:0;O:1:"A":2:{s:1:"x";i:1;s:1:"y";i:2;}i:1;r:2;}') ==
               %{
                 0 => {:object, "A", %{"x" => 1, "y" => 2}},
                 1 => {:object, "A", %{"x" => 1, "y" => 2}}
               }
    end

    test "counts r references in the value stack like PHP" do
      # PHP: a:4:{i:0;O(A,id=1);i:1;r:2;i:2;O(A,id=2);i:3;r:5;}
      assert Dumbo.decode(
               ~s'a:4:{i:0;O:1:"A":1:{s:2:"id";i:1;}i:1;r:2;i:2;O:1:"A":1:{s:2:"id";i:2;}i:3;r:5;}'
             ) == %{
               0 => {:object, "A", %{"id" => 1}},
               1 => {:object, "A", %{"id" => 1}},
               2 => {:object, "A", %{"id" => 2}},
               3 => {:object, "A", %{"id" => 2}}
             }
    end

    test "references an object nested inside another object" do
      assert Dumbo.decode(
               ~s'O:1:"C":2:{s:1:"a";O:1:"C":2:{s:1:"a";a:2:{i:0;i:1;i:1;i:2;}s:1:"b";R:3;}s:1:"b";r:2;}'
             ) ==
               {:object, "C",
                %{
                  "a" => {:object, "C", %{"a" => %{0 => 1, 1 => 2}, "b" => %{0 => 1, 1 => 2}}},
                  "b" => {:object, "C", %{"a" => %{0 => 1, 1 => 2}, "b" => %{0 => 1, 1 => 2}}}
                }}
    end

    test "raises when the target is not an object" do
      assert_raise Dumbo.ReferenceError, fn ->
        Dumbo.decode(~s'a:2:{i:0;a:1:{i:0;i:1;}i:1;r:2;}')
      end
    end

    test "raises for out-of-range object references" do
      assert_raise Dumbo.ReferenceError, fn ->
        Dumbo.decode(~s'a:1:{i:0;r:5;}')
      end
    end
  end

  describe "references disabled" do
    test "decodes payloads without references" do
      opts = %Dumbo.DecodeOpts{resolve_references: false}

      assert Dumbo.decode(~s'a:3:{i:0;i:1;i:1;s:2:"hi";i:2;a:1:{i:0;b:1;}}', opts) ==
               %{0 => 1, 1 => "hi", 2 => %{0 => true}}
    end

    test "raises Dumbo.DecodeError when a reference is encountered" do
      opts = %Dumbo.DecodeOpts{resolve_references: false}

      assert_raise Dumbo.DecodeError, fn ->
        Dumbo.decode(~s'a:2:{i:0;i:1;i:1;R:2;}', opts)
      end

      assert_raise Dumbo.DecodeError, fn ->
        Dumbo.decode(~s'a:2:{i:0;O:1:"A":1:{s:1:"x";i:1;}i:1;r:2;}', opts)
      end
    end
  end

  describe "float encoding" do
    test "matches PHP's serialize() formatting" do
      cases = [
        {0.0, "d:0;"},
        {-0.0, "d:-0;"},
        {1.0, "d:1;"},
        {-1.0, "d:-1;"},
        {1.5, "d:1.5;"},
        {3.14, "d:3.14;"},
        {0.1, "d:0.1;"},
        {0.1 + 0.2, "d:0.30000000000000004;"},
        {19.99, "d:19.99;"},
        {0.14285714285714285, "d:0.14285714285714285;"},
        {100_000.0, "d:100000;"},
        {0.0001, "d:0.0001;"},
        {1.0e-5, "d:1.0E-5;"},
        {-1.0e-25, "d:-1.0E-25;"},
        {1.0e16, "d:10000000000000000;"},
        {9.999999999999999e16, "d:99999999999999980;"},
        {1.0e17, "d:1.0E+17;"},
        {123_456_789_012_345_678.0, "d:1.2345678901234568E+17;"},
        {1.2345e20, "d:1.2345E+20;"},
        {1.0e25, "d:1.0E+25;"},
        {1.0e100, "d:1.0E+100;"},
        {1.7976931348623157e308, "d:1.7976931348623157E+308;"},
        {5.0e-324, "d:5.0E-324;"}
      ]

      for {value, expected} <- cases do
        assert Dumbo.encode(value) == expected
      end
    end

    test "round-trips floats through the decoder" do
      for value <- [0.0, -0.0, 1.5, 3.14, 0.14285714285714285, 1.0e-5, 1.0e17, -1.0e-25] do
        assert value |> Dumbo.encode() |> Dumbo.decode() == value
      end
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
