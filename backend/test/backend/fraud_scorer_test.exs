defmodule Backend.FraudScorerTest do
  use ExUnit.Case, async: true

  test "vectorize follows sentinel rule when last transaction is null" do
    payload = %{
      "id" => "tx-1",
      "transaction" => %{
        "amount" => 100.0,
        "installments" => 1,
        "requested_at" => "2026-03-11T20:23:35Z"
      },
      "customer" => %{
        "avg_amount" => 50.0,
        "tx_count_24h" => 2,
        "known_merchants" => ["MERC-001"]
      },
      "merchant" => %{"id" => "MERC-999", "mcc" => "5912", "avg_amount" => 80.0},
      "terminal" => %{"is_online" => true, "card_present" => false, "km_from_home" => 10.0},
      "last_transaction" => nil
    }

    {:ok, vector} = Backend.FraudScorer.vectorize(payload)

    assert Enum.at(vector, 5) == -1.0
    assert Enum.at(vector, 6) == -1.0
    assert Enum.at(vector, 11) == 1.0
  end

  test "vectorize returns 14 dimensions" do
    payload = %{
      "id" => "tx-1",
      "transaction" => %{
        "amount" => 100.0,
        "installments" => 1,
        "requested_at" => "2026-03-11T20:23:35Z"
      },
      "customer" => %{
        "avg_amount" => 50.0,
        "tx_count_24h" => 2,
        "known_merchants" => ["MERC-001"]
      },
      "merchant" => %{"id" => "MERC-999", "mcc" => "5912", "avg_amount" => 80.0},
      "terminal" => %{"is_online" => true, "card_present" => false, "km_from_home" => 10.0},
      "last_transaction" => nil
    }

    assert {:ok, vector} = Backend.FraudScorer.vectorize(payload)
    assert length(vector) == 14
  end
end
