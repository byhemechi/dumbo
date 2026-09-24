defmodule Dumbo.ObjectResolver do
  @moduledoc """
  Behaviour for converting a decoded PHP object into an Elixir term, typically a struct.

  Modules implementing this behaviour can be used with `resolver/1`:

      defmodule User do
        @behaviour Dumbo.ObjectResolver

        defstruct [:name, :email]

        @impl Dumbo.ObjectResolver
        def resolve(%{"name" => name, "email" => email}) do
          %__MODULE__{name: name, email: email}
        end
      end

      opts = %Dumbo.DecodeOpts{
        object_resolvers: %{"User" => Dumbo.ObjectResolver.resolver(User)}
      }
  """

  @doc """
  Converts a decoded PHP object's properties map into an Elixir term.
  """
  @callback resolve(object :: map()) :: term()

  @doc """
  Returns a resolver function for `module`, suitable for the `:object_resolvers`
  option of `Dumbo.DecodeOpts`.
  """
  @spec resolver(module()) :: (object :: map() -> term())
  def resolver(module) when is_atom(module) do
    fn object -> module.resolve(object) end
  end
end
