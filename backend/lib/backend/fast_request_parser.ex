defmodule Backend.FastRequestParser do
  @moduledoc false

  @k_transaction ~s("transaction")
  @k_customer ~s("customer")
  @k_merchant ~s("merchant")
  @k_terminal ~s("terminal")
  @k_last_transaction ~s("last_transaction")
  @k_known_merchants ~s("known_merchants")
  @k_requested_at ~s("requested_at")
  @k_timestamp ~s("timestamp")
  @k_amount ~s("amount")
  @k_installments ~s("installments")
  @k_avg_amount ~s("avg_amount")
  @k_tx_count_24h ~s("tx_count_24h")
  @k_id ~s("id")
  @k_mcc ~s("mcc")
  @k_km_from_home ~s("km_from_home")
  @k_is_online ~s("is_online")
  @k_card_present ~s("card_present")
  @k_km_from_current ~s("km_from_current")

  def parse_vector(body) when is_binary(body) do
    norms = Backend.ReferenceData.normalization()
    mcc_risk = Backend.ReferenceData.mcc_risk()

    tx_scope = section_scope(body, @k_transaction, 0)
    customer_scope = section_scope(body, @k_customer, 0)
    merchant_scope = section_scope(body, @k_merchant, 0)
    terminal_scope = section_scope(body, @k_terminal, 0)

    amount = number_at(body, field_value_pos(body, @k_amount, tx_scope))
    installments = number_at(body, field_value_pos(body, @k_installments, tx_scope))
    requested_at = string_at(body, field_value_pos(body, @k_requested_at, tx_scope))
    requested_at_dt = parse_datetime!(requested_at)

    avg_amount = number_at(body, field_value_pos(body, @k_avg_amount, customer_scope))
    tx_count_24h = number_at(body, field_value_pos(body, @k_tx_count_24h, customer_scope))

    known_merchants_scope =
      array_scope(body, field_value_pos(body, @k_known_merchants, customer_scope))

    merchant_id = string_at(body, field_value_pos(body, @k_id, merchant_scope))
    merchant_mcc = string_at(body, field_value_pos(body, @k_mcc, merchant_scope))
    merchant_avg_amount = number_at(body, field_value_pos(body, @k_avg_amount, merchant_scope))

    is_online = bool_at(body, field_value_pos(body, @k_is_online, terminal_scope))
    card_present = bool_at(body, field_value_pos(body, @k_card_present, terminal_scope))
    km_from_home = number_at(body, field_value_pos(body, @k_km_from_home, terminal_scope))

    {minutes_since_last_tx, km_from_last_tx} = last_tx_features(body, requested_at_dt, 0)

    vector = [
      clamp(amount / norms["max_amount"]),
      clamp(installments / norms["max_installments"]),
      clamp(amount / max(avg_amount, 0.000001) / norms["amount_vs_avg_ratio"]),
      requested_at_dt.hour / 23,
      day_of_week(requested_at_dt) / 6,
      normalize_last_tx_minutes(minutes_since_last_tx, norms["max_minutes"]),
      normalize_last_tx_km(km_from_last_tx, norms["max_km"]),
      clamp(km_from_home / norms["max_km"]),
      clamp(tx_count_24h / norms["max_tx_count_24h"]),
      as_binary_flag(is_online),
      as_binary_flag(card_present),
      unknown_merchant_flag(body, known_merchants_scope, merchant_id),
      Map.get(mcc_risk, merchant_mcc, 0.5),
      clamp(merchant_avg_amount / norms["max_merchant_avg_amount"])
    ]

    {:ok, vector}
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp last_tx_features(body, requested_at_dt, from) do
    pos = key_pos(body, @k_last_transaction, from, byte_size(body))
    value_pos = skip_to_value(body, pos + byte_size(@k_last_transaction), byte_size(body))

    if starts_with?(body, value_pos, "null") do
      {nil, nil}
    else
      scope = section_scope_from_value(body, value_pos, byte_size(body))
      timestamp = string_at(body, field_value_pos(body, @k_timestamp, scope))
      km = number_at(body, field_value_pos(body, @k_km_from_current, scope))
      last_dt = parse_datetime!(timestamp)
      minutes = max(DateTime.diff(requested_at_dt, last_dt, :second), 0) / 60
      {minutes, km}
    end
  end

  defp section_scope(body, section_key, from) do
    key_start = key_pos(body, section_key, from, byte_size(body))
    value_pos = skip_to_value(body, key_start + byte_size(section_key), byte_size(body))
    section_scope_from_value(body, value_pos, byte_size(body))
  end

  defp section_scope_from_value(body, value_pos, max_pos) do
    open_pos = find_char(body, value_pos, max_pos, ?{)
    close_pos = matching_close(body, open_pos, max_pos, ?{, ?})
    {open_pos + 1, close_pos - open_pos - 1, close_pos + 1}
  end

  defp array_scope(body, value_pos) do
    open_pos = find_char(body, value_pos, byte_size(body), ?[)
    close_pos = matching_close(body, open_pos, byte_size(body), ?[, ?])
    {open_pos + 1, close_pos - open_pos - 1}
  end

  defp field_value_pos(body, key, {start, len, _next}) do
    key_pos = key_pos(body, key, start, start + len)
    skip_to_value(body, key_pos + byte_size(key), start + len)
  end

  defp key_pos(body, key, start, stop) do
    scope_len = max(stop - start, 0)

    case :binary.match(body, key, scope: {start, scope_len}) do
      {pos, _len} -> pos
      :nomatch -> raise "key not found: #{key}"
    end
  end

  defp skip_to_value(body, pos, stop) do
    colon =
      walk_until(body, pos, stop, fn c ->
        c == ?:
      end)

    walk_until(body, colon + 1, stop, fn c ->
      c not in [?\s, ?\n, ?\r, ?\t]
    end)
  end

  defp find_char(body, from, stop, needle) do
    walk_until(body, from, stop, fn c -> c == needle end)
  end

  defp walk_until(body, pos, stop, predicate) do
    cond do
      pos >= stop ->
        raise "delimiter not found"

      predicate.(:binary.at(body, pos)) ->
        pos

      true ->
        walk_until(body, pos + 1, stop, predicate)
    end
  end

  defp matching_close(body, open_pos, stop, open_char, close_char) do
    do_matching_close(body, open_pos, stop, open_char, close_char, 0)
  end

  defp do_matching_close(_body, pos, stop, _open_char, _close_char, _depth) when pos >= stop do
    raise "unbalanced section"
  end

  defp do_matching_close(body, pos, stop, open_char, close_char, depth) do
    case :binary.at(body, pos) do
      ^open_char ->
        do_matching_close(body, pos + 1, stop, open_char, close_char, depth + 1)

      ^close_char when depth == 1 ->
        pos

      ^close_char ->
        do_matching_close(body, pos + 1, stop, open_char, close_char, depth - 1)

      _ ->
        do_matching_close(body, pos + 1, stop, open_char, close_char, depth)
    end
  end

  defp number_at(body, pos) do
    {num_end, _} =
      walk_number(body, pos, byte_size(body), false)

    number_bin = binary_part(body, pos, num_end - pos)

    case Float.parse(number_bin) do
      {value, ""} ->
        value

      _ ->
        case Integer.parse(number_bin) do
          {value, ""} -> value * 1.0
          _ -> raise "invalid number: #{number_bin}"
        end
    end
  end

  defp walk_number(_body, pos, stop, started?) when pos >= stop do
    {pos, started?}
  end

  defp walk_number(body, pos, stop, started?) do
    c = :binary.at(body, pos)

    cond do
      c in [?0, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?., ?-, ?+, ?e, ?E] ->
        walk_number(body, pos + 1, stop, true)

      started? ->
        {pos, true}

      true ->
        raise "number expected at #{pos}"
    end
  end

  defp bool_at(body, pos) do
    cond do
      starts_with?(body, pos, "true") -> true
      starts_with?(body, pos, "false") -> false
      true -> raise "invalid bool"
    end
  end

  defp string_at(body, pos) do
    quote_pos = find_char(body, pos, byte_size(body), ?")
    close_pos = matching_quote(body, quote_pos + 1, byte_size(body))
    binary_part(body, quote_pos + 1, close_pos - quote_pos - 1)
  end

  defp matching_quote(_body, pos, stop) when pos >= stop do
    raise "unterminated string"
  end

  defp matching_quote(body, pos, stop) do
    case :binary.at(body, pos) do
      ?" ->
        if :binary.at(body, pos - 1) == ?\\ do
          matching_quote(body, pos + 1, stop)
        else
          pos
        end

      _ ->
        matching_quote(body, pos + 1, stop)
    end
  end

  defp starts_with?(body, pos, prefix) do
    prefix_bin = :erlang.iolist_to_binary(prefix)
    len = byte_size(prefix_bin)
    pos + len <= byte_size(body) and binary_part(body, pos, len) == prefix_bin
  end

  defp parse_datetime!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp day_of_week(datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.day_of_week()
    |> Kernel.-(1)
  end

  defp normalize_last_tx_minutes(nil, _max_minutes), do: -1.0
  defp normalize_last_tx_minutes(minutes, max_minutes), do: clamp(minutes / max_minutes)

  defp normalize_last_tx_km(nil, _max_km), do: -1.0
  defp normalize_last_tx_km(km, max_km), do: clamp(km / max_km)

  defp as_binary_flag(true), do: 1.0
  defp as_binary_flag(false), do: 0.0

  defp unknown_merchant_flag(body, {start, len}, merchant_id) do
    if merchant_known?(body, start, start + len, merchant_id), do: 0.0, else: 1.0
  end

  defp merchant_known?(_body, pos, stop, _merchant_id) when pos >= stop, do: false

  defp merchant_known?(body, pos, stop, merchant_id) do
    pos = skip_array_junk(body, pos, stop)

    cond do
      pos >= stop ->
        false

      :binary.at(body, pos) == ?" ->
        close = matching_quote(body, pos + 1, stop)
        current = binary_part(body, pos + 1, close - pos - 1)

        if current == merchant_id do
          true
        else
          merchant_known?(body, close + 1, stop, merchant_id)
        end

      true ->
        merchant_known?(body, pos + 1, stop, merchant_id)
    end
  end

  defp skip_array_junk(_body, pos, stop) when pos >= stop, do: pos

  defp skip_array_junk(body, pos, stop) do
    case :binary.at(body, pos) do
      c when c in [?\s, ?\n, ?\r, ?\t, ?,] -> skip_array_junk(body, pos + 1, stop)
      _ -> pos
    end
  end

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
