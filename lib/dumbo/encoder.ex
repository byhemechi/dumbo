defprotocol Dumbo.Encoder do
  @spec encode(value :: term(), opts :: Dumbo.Encode.opts()) :: iodata()
  def encode(term, opts)
end

defimpl Dumbo.Encoder, for: Any do
  defmacro __deriving__(module, _struct, opts) do
    php_name = Keyword.get(opts, :class_name, Macro.to_string(module))

    fields =
      for %{field: field_name} <- Macro.struct_info!(module, __CALLER__) do
        {field_name |> to_string(), field_name}
      end

    term_var = Macro.var(:term, nil)
    opts_var = Macro.var(:opts, nil)

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

    quote do
      defimpl Dumbo.Encoder, for: unquote(module) do
        def encode(unquote(term_var), unquote(opts_var)) do
          unquote(struct_label)
        end
      end
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

    Dumbo.Encode.object(
      opts.datetime_struct,
      %{
        "date" => @for.to_iso8601(date),
        "timezone_type" => 3,
        "timezone" => "UTC"
      },
      opts
    )
  end
end
