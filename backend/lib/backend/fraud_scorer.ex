defmodule Backend.FraudScorer do
  @moduledoc false

  @k 5

  def vectorize(payload) do
    norms = Backend.ReferenceData.normalization()
    mcc_risk = Backend.ReferenceData.mcc_risk()

    tx = fetch!(payload, "transaction")
    customer = fetch!(payload, "customer")
    merchant = fetch!(payload, "merchant")
    terminal = fetch!(payload, "terminal")
    last_tx = Map.get(payload, "last_transaction")

    requested_at = parse_datetime!(fetch!(tx, "requested_at"))

    amount = as_float(fetch!(tx, "amount"))
    customer_avg_amount = max(as_float(fetch!(customer, "avg_amount")), 0.000001)

    minutes_since_last_tx = minutes_since_last_tx(requested_at, last_tx)

    vector = [
      clamp(amount / norms["max_amount"]),
      clamp(as_float(fetch!(tx, "installments")) / norms["max_installments"]),
      clamp(amount / customer_avg_amount / norms["amount_vs_avg_ratio"]),
      requested_at.hour / 23,
      day_of_week(requested_at) / 6,
      normalize_last_tx_minutes(minutes_since_last_tx, norms["max_minutes"]),
      normalize_last_tx_km(last_tx, norms["max_km"]),
      clamp(as_float(fetch!(terminal, "km_from_home")) / norms["max_km"]),
      clamp(as_float(fetch!(customer, "tx_count_24h")) / norms["max_tx_count_24h"]),
      as_binary_flag(fetch!(terminal, "is_online")),
      as_binary_flag(fetch!(terminal, "card_present")),
      unknown_merchant_flag(fetch!(merchant, "id"), fetch!(customer, "known_merchants")),
      Map.get(mcc_risk, fetch!(merchant, "mcc"), 0.5),
      clamp(as_float(fetch!(merchant, "avg_amount")) / norms["max_merchant_avg_amount"])
    ]

    {:ok, vector}
  rescue
    _ -> {:error, :vectorization_failed}
  end

  def reference_k, do: @k

  defp parse_datetime!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp minutes_since_last_tx(_requested_at, nil), do: nil

  defp minutes_since_last_tx(requested_at, last_tx) do
    last_timestamp = last_tx |> fetch!("timestamp") |> parse_datetime!()

    DateTime.diff(requested_at, last_timestamp, :second)
    |> max(0)
    |> Kernel./(60)
  end

  defp normalize_last_tx_minutes(nil, _max_minutes), do: -1.0
  defp normalize_last_tx_minutes(minutes, max_minutes), do: clamp(minutes / max_minutes)

  defp normalize_last_tx_km(nil, _max_km), do: -1.0

  defp normalize_last_tx_km(last_tx, max_km) do
    clamp(as_float(fetch!(last_tx, "km_from_current")) / max_km)
  end

  defp day_of_week(datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.day_of_week()
    |> Kernel.-(1)
  end

  defp fetch!(map, key), do: Map.fetch!(map, key)

  defp as_float(value) when is_integer(value), do: value * 1.0
  defp as_float(value) when is_float(value), do: value

  defp as_binary_flag(true), do: 1.0
  defp as_binary_flag(false), do: 0.0

  defp unknown_merchant_flag(merchant_id, known_merchants) when is_list(known_merchants) do
    if merchant_id in known_merchants, do: 0.0, else: 1.0
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
