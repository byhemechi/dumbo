defmodule Dumbo.ResolveError do
  @moduledoc """
  Raised when a resolver matches a PHP class but cannot represent its value.

  The most common cause is a `DateTime` whose time zone needs a configured time
  zone database (see `Calendar.TimeZoneDatabase`).
  """

  @type t :: %__MODULE__{
          message: String.t(),
          class: binary() | nil,
          properties: map() | nil,
          reason: atom() | nil
        }

  defexception [:message, :class, :properties, :reason]

  @impl true
  def message(%__MODULE__{class: class, reason: reason}) do
    subject =
      case class do
        nil -> "PHP object"
        name -> "PHP object #{inspect(name)}"
      end

    "cannot resolve #{subject} into an Elixir term" <>
      case reason do
        nil ->
          ""

        :utc_only_time_zone_database ->
          " (configure a time zone database, such as tzdata, to resolve this time zone)"

        :time_zone_not_found ->
          " (unknown time zone identifier)"

        :invalid_datetime ->
          " (invalid date string)"

        :missing_date ->
          ~s' (missing "date" property)'

        other ->
          " (#{inspect(other)})"
      end
  end
end

defmodule Dumbo.PHP do
  @moduledoc """
  Resolvers for common PHP classes that map directly onto native Elixir types.

  They are the default `:object_resolvers` of `%Dumbo.DecodeOpts{}`, so
  `Dumbo.decode/2` applies them automatically.

  | PHP class                                  | Elixir term |
  | ------------------------------------------ | ----------- |
  | `stdClass`                                 | `Map`       |
  | `DateTime`, `DateTimeImmutable`            | `DateTime`  |
  | `ArrayObject`, `ArrayIterator`             | `Map`       |
  | `SplFixedArray`, `SplDoublyLinkedList`, `SplStack`, `SplQueue` | `List` |

  `DateTime` offsets and UTC aliases always resolve; other time zones need a
  configured time zone database and otherwise raise `Dumbo.ResolveError`.

  ## Examples

      iex> Dumbo.PHP.resolve_std_class(%{"name" => "Alice"})
      %{"name" => "Alice"}

      iex> Dumbo.PHP.resolve_datetime(%{
      ...>   "date" => "2024-01-15 09:30:00.000000",
      ...>   "timezone_type" => 3,
      ...>   "timezone" => "UTC"
      ...> })
      ~U[2024-01-15 09:30:00.000000Z]

      iex> Dumbo.PHP.resolve_spl_fixed_array(%{0 => 1, 1 => 2, 2 => 3})
      [1, 2, 3]

  """

  @doc """
  Returns the default map of PHP class names to resolver functions.

      iex> Dumbo.PHP.resolvers() |> Map.keys() |> Enum.sort()
      [
        "ArrayIterator",
        "ArrayObject",
        "DateTime",
        "DateTimeImmutable",
        "SplDoublyLinkedList",
        "SplFixedArray",
        "SplQueue",
        "SplStack",
        "stdClass"
      ]

  """
  @spec resolvers() :: %{(class :: binary()) => (properties :: map() -> term())}
  def resolvers do
    %{
      "stdClass" => &Dumbo.PHP.resolve_std_class/1,
      "DateTime" => &Dumbo.PHP.resolve_datetime/1,
      "DateTimeImmutable" => &Dumbo.PHP.resolve_datetime/1,
      "ArrayObject" => &Dumbo.PHP.resolve_array_object/1,
      "ArrayIterator" => &Dumbo.PHP.resolve_array_object/1,
      "SplFixedArray" => &Dumbo.PHP.resolve_spl_fixed_array/1,
      "SplDoublyLinkedList" => &Dumbo.PHP.resolve_spl_list/1,
      "SplStack" => &Dumbo.PHP.resolve_spl_list/1,
      "SplQueue" => &Dumbo.PHP.resolve_spl_list/1
    }
  end

  @doc """
  Returns the PHP class names that have a built-in resolver.
  """
  @spec known_classes() :: [binary()]
  def known_classes, do: resolvers() |> Map.keys() |> Enum.sort()

  @doc """
  Resolves a `stdClass` object to its properties map.
  """
  @spec resolve_std_class(properties :: map()) :: map()
  def resolve_std_class(properties), do: properties

  @doc """
  Resolves a `DateTime` or `DateTimeImmutable` object to a `DateTime`.
  """
  @spec resolve_datetime(properties :: map()) :: DateTime.t()
  def resolve_datetime(%{"date" => date} = properties) do
    with {:ok, naive} <- parse_naive(date),
         {:ok, datetime} <- build_datetime(naive, properties) do
      datetime
    else
      {:error, reason} ->
        raise Dumbo.ResolveError, properties: properties, reason: reason
    end
  end

  def resolve_datetime(properties) do
    raise Dumbo.ResolveError, properties: properties, reason: :missing_date
  end

  @doc """
  Resolves an `ArrayObject` or `ArrayIterator` to its private storage map.
  """
  @spec resolve_array_object(properties :: map()) :: map()
  def resolve_array_object(properties), do: Map.get(properties, 1, %{})

  @doc """
  Resolves a `SplFixedArray` to a list.
  """
  @spec resolve_spl_fixed_array(properties :: map()) :: list()
  def resolve_spl_fixed_array(properties), do: indexed_to_list(properties)

  @doc """
  Resolves an `SplDoublyLinkedList`, `SplStack` or `SplQueue` to a list.
  """
  @spec resolve_spl_list(properties :: map()) :: list()
  def resolve_spl_list(properties) do
    properties
    |> Map.get(1, %{})
    |> indexed_to_list()
  end

  defp indexed_to_list(properties) do
    properties
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp parse_naive(date) do
    case NaiveDateTime.from_iso8601(String.replace(date, " ", "T")) do
      {:ok, naive} -> {:ok, naive}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp build_datetime(naive, properties) do
    type = Map.get(properties, "timezone_type", 3)
    timezone = Map.get(properties, "timezone", "UTC")

    build_datetime(naive, type, timezone)
  end

  # Fixed UTC offset, resolvable without a time zone database.
  defp build_datetime(naive, 1, offset) do
    case DateTime.from_iso8601(NaiveDateTime.to_iso8601(naive) <> offset) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  # Time zone abbreviation: UTC aliases resolve without a database, everything
  # else is looked up as an identifier.
  defp build_datetime(naive, 2, timezone) do
    build_datetime(naive, 3, timezone)
  end

  # Named time zone identifier.
  defp build_datetime(naive, _type, timezone) do
    case DateTime.from_naive(naive, utc_zone(timezone)) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  # Maps UTC aliases onto "Etc/UTC", which the default UTC-only time zone
  # database understands. Other identifiers pass through unchanged.
  defp utc_zone(zone) when zone in ~w(Z UT UTC GMT Etc/UTC Etc/GMT), do: "Etc/UTC"
  defp utc_zone(zone), do: zone
end
