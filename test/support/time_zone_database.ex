defmodule DumboTest.TimeZoneDatabase do
  @moduledoc false

  # Minimal stand-in for a real time zone database (such as tzdata), used to
  # exercise `Dumbo.PHP`'s named-time-zone resolution in tests.
  @behaviour Calendar.TimeZoneDatabase

  @new_york %{utc_offset: -5 * 3600, std_offset: 0, zone_abbr: "EST"}
  @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

  @impl true
  def time_zone_periods_from_wall_datetime(_naive_datetime, "America/New_York"),
    do: {:ok, @new_york}

  def time_zone_periods_from_wall_datetime(_naive_datetime, "Etc/UTC"), do: {:ok, @utc}

  def time_zone_periods_from_wall_datetime(_naive_datetime, _time_zone),
    do: {:error, :time_zone_not_found}

  @impl true
  def time_zone_period_from_utc_iso_days(_iso_days, "America/New_York"), do: {:ok, @new_york}

  def time_zone_period_from_utc_iso_days(_iso_days, "Etc/UTC"), do: {:ok, @utc}

  def time_zone_period_from_utc_iso_days(_iso_days, _time_zone),
    do: {:error, :time_zone_not_found}
end
