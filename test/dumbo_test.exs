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

  describe "Dumbo.decode/2 with :object_resolvers" do
    test "applies a resolver for a matching object name" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"stdClass" => fn obj -> obj end}}

      assert Dumbo.decode(~s'O:8:"stdClass":1:{s:3:"foo";s:3:"bar";}', opts) ==
               %{"foo" => "bar"}
    end

    test "applies resolvers to nested objects" do
      opts = %Dumbo.DecodeOpts{object_resolvers: %{"stdClass" => fn obj -> Map.new(obj) end}}

      source = ~s'O:8:"stdClass":1:{s:5:"inner";O:8:"stdClass":1:{s:1:"a";i:1;}}'

      assert Dumbo.decode(source, opts) == %{"inner" => %{"a" => 1}}
    end
  end

  describe "Dumbo.ObjectResolver" do
    test "integrates with Dumbo.decode/2 via :object_resolvers" do
      opts = %Dumbo.DecodeOpts{
        object_resolvers: %{"User" => Dumbo.ObjectResolver.resolver(DumboTest.User)}
      }

      source = ~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:3:"a@b";}'

      assert Dumbo.decode(source, opts) == %DumboTest.User{name: "Alice", email: "a@b"}
    end
  end

  describe "@derive Dumbo.Encoder with :object_resolver" do
    test "converts a decoded object into the struct" do
      opts = %Dumbo.DecodeOpts{
        object_resolvers: %{"User" => Dumbo.ObjectResolver.resolver(DumboTest.DerivedUser)}
      }

      source = ~s'O:4:"User":2:{s:4:"name";s:5:"Alice";s:5:"email";s:3:"a@b";}'

      assert Dumbo.decode(source, opts) == %DumboTest.DerivedUser{name: "Alice", email: "a@b"}
    end

    test "retains struct defaults for fields absent from the object" do
      opts = %Dumbo.DecodeOpts{
        object_resolvers: %{
          "User" => Dumbo.ObjectResolver.resolver(DumboTest.DerivedWithDefaults)
        }
      }

      assert Dumbo.decode(~s'O:4:"User":1:{s:4:"name";s:5:"Alice";}', opts) ==
               %DumboTest.DerivedWithDefaults{name: "Alice", email: "none@example.com"}
    end
  end
end
