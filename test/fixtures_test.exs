defmodule Dumbo.FixturesTest do
  use ExUnit.Case, async: true

  alias DumboTest.Fixtures

  @fixtures Fixtures.all()

  for fixture <- @fixtures do
    relative = Path.relative_to(fixture, Fixtures.root())

    test "decodes #{relative}" do
      # The assertion is that decoding does not raise; the decoded value itself
      # may legitimately be `nil` or `false`.
      _ = unquote(fixture) |> File.read!() |> Dumbo.decode()
    end

    test "round-trips #{relative}" do
      term = unquote(fixture) |> File.read!() |> Dumbo.decode()

      assert Dumbo.decode(Dumbo.encode(term)) == term
    end
  end

  describe "realistic fixtures" do
    test "decodes a single user record" do
      assert Fixtures.load("realistic/user_record.ser") == %{
               "id" => 100_000,
               "uuid" => "8873a114-6ce3-5eff-a5fa-c8ec2a4c1515",
               "name" => "Ada Lovelace",
               "email" => "ada.lovelace@example.com",
               "active" => false,
               "score" => 0.0,
               "created_at" => "2024-01-01T00:00:00+00:00",
               "roles" => %{0 => "admin"},
               "address" => %{
                 "street" => "100 Example Street",
                 "city" => "London",
                 "country" => "GB",
                 "postal_code" => "00000"
               },
               "preferences" => %{
                 "theme" => "dark",
                 "locale" => "en_GB",
                 "notifications" => false
               }
             }
    end

    test "decodes a session payload" do
      assert Fixtures.load("realistic/session.ser") == %{
               "id" => "8873a114-6ce3-5eff-a5fa-c8ec2a4c1515",
               "user_id" => 100_001,
               "ip" => "203.0.113.42",
               "user_agent" =>
                 "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
               "csrf_token" => "7ce12ba8782a32f74357cefb81edb8c20ea4d755",
               "started_at" => 1_705_315_800,
               "expires_at" => 1_705_319_400,
               "flash" => %{"success" => "Saved"},
               "data" => %{
                 "cart" => %{
                   "items" => %{0 => %{"sku" => "SKU-00001", "qty" => 2}},
                   "total" => 29.98
                 },
                 "last_route" => "/checkout"
               }
             }
    end

    test "decodes a cache entry wrapping a user record" do
      assert Fixtures.load("realistic/cache_entry.ser") == %{
               "key" => "users:100001:profile",
               "ttl" => 3600,
               "tags" => %{0 => "users", 1 => "profiles"},
               "created_at" => 1_705_315_800,
               "value" => %{
                 "id" => 100_001,
                 "uuid" => "185ec7f2-62f0-e81d-4c41-9661f74a6094",
                 "name" => "Alan Turing",
                 "email" => "alan.turing@example.com",
                 "active" => true,
                 "score" => 1.1,
                 "created_at" => "2024-02-02T01:07:13+00:00",
                 "roles" => %{0 => "admin", 1 => "editor"},
                 "address" => %{
                   "street" => "101 Example Street",
                   "city" => "Paris",
                   "country" => "FR",
                   "postal_code" => "00037"
                 },
                 "preferences" => %{
                   "theme" => "light",
                   "locale" => "fr_FR",
                   "notifications" => true
                 }
               }
             }
    end

    test "decodes a queued job payload with class names containing backslashes" do
      assert Fixtures.load("realistic/job_payload.ser") == %{
               "uuid" => "59ffff98-f4b3-4c92-4589-841520b23df4",
               "display_name" => "App\\Jobs\\SendInvoice",
               "job" => "App\\Jobs\\SendInvoice",
               "max_tries" => 3,
               "attempts" => 0,
               "backoff" => %{0 => 5, 1 => 15, 2 => 60},
               "created_at" => "2024-10-10T09:03:57+00:00",
               "payload" => %{"invoice_id" => 42, "email" => "ada@example.com"}
             }
    end

    test "resolves a serialised DateTimeImmutable" do
      assert Fixtures.load("realistic/datetime_object.ser") == ~U[2024-01-15 09:30:00.123456Z]
    end

    test "decodes a list of users" do
      users = Fixtures.load("realistic/users.small.ser")

      assert is_map(users)
      assert map_size(users) == 30
      assert users[0]["id"] == 100_000
      assert users[0]["name"] == "Ada Lovelace"
      assert users[29]["id"] == 100_029
      assert users[29]["name"] == "Ken Thompson"
      assert Enum.all?(Map.values(users), &(map_size(&1) == 10))
    end

    test "decodes a list of orders with nested customers" do
      orders = Fixtures.load("realistic/api_orders.small.ser")

      assert map_size(orders) == 14
      assert orders[0]["order_id"] == 500_000
      assert orders[0]["status"] == "pending"
      assert orders[0]["currency"] == "EUR"
      assert orders[0]["total"] == 19.99
      assert orders[0]["customer"]["name"] == "Ada Lovelace"
      assert orders[0]["items"][0]["sku"] == "SKU-00000"
      assert orders[0]["meta"]["campaign"] == nil
    end

    test "decodes a configuration document with a large plugin list" do
      config = Fixtures.load("realistic/config.small.ser")

      assert config["app"] == %{"name" => "example", "debug" => false, "version" => "1.2.3"}
      assert config["database"]["driver"] == "pgsql"
      assert config["database"]["port"] == 5432
      assert config["cache"]["stores"]["redis"]["ttl"] == 3600
      assert map_size(config["plugins"]) == 71
      assert config["plugins"][0]["name"] == "vendor/plugin-0"
      assert config["plugins"][0]["options"]["tags"] == %{0 => "a", 1 => "b"}
    end

    test "decodes a list of events" do
      events = Fixtures.load("realistic/events.small.ser")

      assert map_size(events) == 47
      assert events[0]["event"] == "order.updated"
      assert events[0]["severity"] == "info"
      assert events[0]["occurred_at"] == "2024-01-01T00:00:00+00:00"
      assert events[0]["payload"] == %{"order_id" => 500_000, "from" => "pending", "to" => "paid"}
      assert events[0]["tags"] == %{0 => "worker", 1 => "eu-west-1"}
    end

    test "resolves a list of DateTimeImmutable objects" do
      datetimes = Fixtures.load("realistic/datetimes.small.ser")

      assert map_size(datetimes) == 58
      assert datetimes[0] == ~U[2024-01-01 00:00:00.000000Z]
      assert Enum.all?(Map.values(datetimes), &match?(%DateTime{}, &1))
    end

    test "decodes a list of stdClass records" do
      records = Fixtures.load("realistic/stdclass_records.small.ser")

      assert map_size(records) == 90
      assert records[0] == %{"id" => 100_000, "name" => "Ada", "active" => true, "score" => 0.0}
    end
  end

  describe "synthetic best-case fixtures" do
    test "decodes a binary blob" do
      blob = Fixtures.load("synthetic/best/binary_blob.small.ser")

      assert is_binary(blob)
      assert byte_size(blob) == 10_000
      assert :binary.part(blob, 0, 4) == <<0, 1, 2, 3>>
    end

    test "decodes a long string" do
      string = Fixtures.load("synthetic/best/long_string.small.ser")

      assert is_binary(string)
      assert byte_size(string) == 10_000
      assert String.starts_with?(string, "The quick brown fox jumps over the lazy dog.")
    end

    test "decodes a list of booleans" do
      booleans = Fixtures.load("synthetic/best/bool_list.small.ser")

      assert map_size(booleans) == 714
      assert booleans[0] == true
      assert booleans[1] == false
      assert booleans[713] == false
      assert Enum.all?(Map.values(booleans), &is_boolean/1)
    end

    test "decodes an indexed list of integers" do
      integers = Fixtures.load("synthetic/best/int_list.small.ser")

      assert map_size(integers) == 909
      assert Enum.all?(0..908, fn index -> integers[index] == index end)
    end
  end

  describe "synthetic worst-case fixtures" do
    test "decodes deeply nested arrays" do
      nested = Fixtures.load("synthetic/worst/deep_nesting.small.ser")

      assert levels(nested) == Enum.to_list(31..0//-1)
    end

    test "decodes a large list of floats" do
      floats = Fixtures.load("synthetic/worst/floats.small.ser")

      assert map_size(floats) == 625
      assert floats[0] == 0.0
      assert floats[7] == 1.0
      assert Enum.all?(Map.values(floats), &is_float/1)
    end

    test "decodes mixed nested values" do
      mixed = Fixtures.load("synthetic/worst/mixed_nested.small.ser")

      assert map_size(mixed) == 71
      assert mixed[0]["int"] == 0
      assert mixed[0]["float"] == 0
      assert mixed[0]["bool"] == true
      assert mixed[0]["null"] == nil
      assert mixed[0]["string"] == "value-0"
      assert mixed[0]["nested"] == %{"a" => %{0 => 0, 1 => 1}, "b" => %{"deep" => true}}
    end

    test "decodes a list of nulls" do
      nulls = Fixtures.load("synthetic/worst/null_list.small.ser")

      assert map_size(nulls) == 909
      assert nulls[0] == nil
      assert nulls[908] == nil
      assert Enum.all?(Map.values(nulls), &is_nil/1)
    end

    test "decodes short string keys" do
      keys = Fixtures.load("synthetic/worst/short_string_keys.small.ser")

      assert map_size(keys) == 384
      assert keys["k0000"] == 0
      assert keys["k0383"] == 383
    end

    test "decodes a list of tiny strings" do
      strings = Fixtures.load("synthetic/worst/tiny_strings.small.ser")

      assert map_size(strings) == 555
      assert strings[0] == "a"
      assert strings[1] == "b"
      assert Enum.all?(Map.values(strings), &(byte_size(&1) == 1))
    end
  end

  defp levels(%{"level" => level, "value" => nested}) when is_map(nested) do
    [level | levels(nested)]
  end

  defp levels(%{"level" => level}), do: [level]
end
