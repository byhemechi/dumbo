defmodule DumboTest.DerivedUser do
  @moduledoc false
  @derive {Dumbo.Encoder, object_resolver: true}
  defstruct [:name, :email]
end

defmodule DumboTest.DerivedWithDefaults do
  @moduledoc false
  @derive {Dumbo.Encoder, object_resolver: true}
  defstruct name: "anonymous", email: "none@example.com"
end
