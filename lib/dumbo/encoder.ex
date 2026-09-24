defprotocol Dumbo.Encoder do
  @moduledoc """
  Protocol controlling how Elixir data structures are encoded into PHP serialised format.

  Any Elixir type implementing `Dumbo.Encoder` can be serialised using `Dumbo.encode/2`
  or `Dumbo.encode_to_iodata/2`.

  ## Deriving

  The protocol can be derived for structs using `@derive`:

      defmodule User do
        @derive Dumbo.Encoder
        defstruct [:name, :email]
      end

  To customize the serialised PHP class name:

      defmodule User do
        @derive {Dumbo.Encoder, class_name: "App\\\\Models\\\\User"}
        defstruct [:name, :email]
      end

  To additionally implement the `Dumbo.ObjectResolver` behaviour:

      defmodule User do
        @derive {Dumbo.Encoder, object_resolver: true}
        defstruct [:name, :email]
      end

      opts = %Dumbo.DecodeOpts{
        object_resolvers: %{"User" => Dumbo.ObjectResolver.resolver(User)}
      }
  """

  @doc """
  Encodes `term` into iodata following the PHP serialisation format.

  ## Examples

      iex> Dumbo.Encoder.encode(42, %Dumbo.EncodeOpts{})
      ["i:", "42", ?;]

      iex> Dumbo.Encoder.encode("hello", %Dumbo.EncodeOpts{})
      ["s:", "5", ~s':"', "hello", ~s'";']

  """
  @spec encode(value :: term(), opts :: Dumbo.Encode.opts()) :: iodata()
  def encode(term, opts)
end

defimpl Dumbo.Encoder, for: Any do
  @doc """
  Derives the `Dumbo.Encoder` protocol for a struct module.

  Called automatically when using `@derive Dumbo.Encoder` or
  `@derive {Dumbo.Encoder, options}`.

  ## Options

    * `:class_name` - The PHP class name to serialise the struct as.
      Defaults to the string representation of the module name.

    * `:object_resolver` - When `true`, also implements `Dumbo.ObjectResolver`.
      Defaults to `false`.
  """
  defmacro __deriving__(module, _struct, opts) do
    php_name = Keyword.get(opts, :class_name, Macro.to_string(module))
    object_resolver? = Keyword.get(opts, :object_resolver, false)

    fields =
      for %{field: field_name} <- Macro.struct_info!(module, __CALLER__) do
        {field_name |> to_string(), field_name}
      end

    term_var = Macro.var(:term, nil)
    opts_var = Macro.var(:opts, nil)
    object_var = Macro.var(:object, nil)

    struct_label = [
      "O:#{byte_size(php_name)}:\"#{php_name}\":#{length(fields)}:{",
      for {name, field} <- fields do
        [
          Dumbo.encode(name),
          quote do
            Dumbo.Encoder.encode(unquote(term_var).unquote(field), unquote(opts_var))
          end
        ]
      end,
      ?}
    ]

    resolver =
      if object_resolver? do
        mapping = Macro.escape(Map.new(fields))

        quote do
          @behaviour Dumbo.ObjectResolver

          @impl Dumbo.ObjectResolver
          def resolve(unquote(object_var)) do
            mapping = unquote(mapping)

            fields =
              unquote(object_var)
              |> Map.take(Map.keys(mapping))
              |> Map.new(fn {name, value} -> {Map.fetch!(mapping, name), value} end)

            struct!(__MODULE__, fields)
          end
        end
      end

    quote do
      defimpl Dumbo.Encoder, for: unquote(module) do
        def encode(unquote(term_var), unquote(opts_var)) do
          unquote(struct_label)
        end
      end

      unquote(resolver)
    end
  end

  def encode(value, _opts) do
    raise Protocol.UndefinedError,
      protocol: @protocol,
      value: value,
      description: "Dumbo.Encoder protocol must always be explicitly implemented"
  end
end

defimpl Dumbo.Encoder, for: Integer do
  def encode(term, opts), do: Dumbo.Encode.integer(term, opts)
end

defimpl Dumbo.Encoder, for: Float do
  def encode(term, opts), do: Dumbo.Encode.float(term, opts)
end

defimpl Dumbo.Encoder, for: Map do
  def encode(term, opts), do: Dumbo.Encode.map(term, opts)
end

defimpl Dumbo.Encoder, for: List do
  def encode(term, opts), do: Dumbo.Encode.list(term, opts)
end

defimpl Dumbo.Encoder, for: BitString do
  def encode(binary, opts) when is_binary(binary), do: Dumbo.Encode.binary(binary, opts)

  def encode(bitstring, _opts) do
    raise Protocol.UndefinedError,
      protocol: @protocol,
      value: bitstring,
      description: "bitstrings have no equivalent in PHP representation"
  end
end

defimpl Dumbo.Encoder, for: Atom do
  def encode(nil, _opts), do: "N;"
  def encode(false, _opts), do: "b:0;"
  def encode(true, _opts), do: "b:1;"
  def encode(:infinity, _opts), do: "d:INF;"
  def encode(:negative_infinity, _opts), do: "d:-INF;"
  def encode(:nan, _opts), do: "d:NAN;"

  def encode(bitstring, _opts) do
    raise Protocol.UndefinedError,
      protocol: @protocol,
      value: bitstring,
      description: "atoms have no equivalent in PHP representation"
  end
end

defimpl Dumbo.Encoder, for: DateTime do
  def encode(date, opts) do
    date = DateTime.shift_zone!(date, "Etc/UTC")
    date = %{date | microsecond: {elem(date.microsecond, 0), 6}}

    Dumbo.Encode.object(
      opts.datetime_struct,
      [
        {"date", Calendar.strftime(date, "%Y-%m-%d %H:%M:%S.%f")},
        {"timezone_type", 3},
        {"timezone", "UTC"}
      ],
      opts
    )
  end
end
