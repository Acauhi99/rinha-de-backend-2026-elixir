defmodule Backend.IndexBucket do
  @moduledoc false

  @hour_bins 6
  @mcc_bins 5
  # 6 * 5 * 2 * 2 * 2 = 120 possible bucket ids (index space)
  @total_buckets @hour_bins * @mcc_bins * 2 * 2 * 2

  @rings_key {__MODULE__, :rings_table}

  def hour_bins, do: @hour_bins
  def mcc_bins, do: @mcc_bins
  def total_buckets, do: @total_buckets

  @doc """
  Computes the bucket id (0..#{@total_buckets - 1}) for a vector.
  """
  def bucket_id(vector) when is_list(vector) do
    hour_bin = quantize(Enum.at(vector, 3), @hour_bins)
    mcc_bin = quantize(Enum.at(vector, 12), @mcc_bins)
    is_online = bool_bin(Enum.at(vector, 9))
    card_present = bool_bin(Enum.at(vector, 10))
    unknown_merchant = bool_bin(Enum.at(vector, 11))

    encode(hour_bin, mcc_bin, is_online, card_present, unknown_merchant)
  end

  @doc """
  Builds the precomputed candidate_buckets table and stores it in
  `:persistent_term`. Must be called at application boot.
  """
  def cache_rings! do
    :persistent_term.put(@rings_key, build_rings_table())
    :ok
  end

  @doc """
  Returns a tuple indexed by bucket_id where each element is the ordered list
  of candidate bucket ids (rings) to probe.
  """
  def build_rings_table do
    for h <- 0..(@hour_bins - 1),
        m <- 0..(@mcc_bins - 1),
        o <- 0..1,
        p <- 0..1,
        u <- 0..1 do
      candidate_buckets_for_key(h, m, o, p, u)
    end
    |> List.to_tuple()
  end

  def candidate_buckets(vector) when is_list(vector) do
    key = bucket_id(vector)
    elem(rings_table(), key)
  end

  def candidate_buckets(vector, limit) when is_list(vector) and is_integer(limit) and limit > 0 do
    # The full ring list is always <= @total_buckets (120). Any reasonable
    # NPROBE_PRIMARY (e.g. 240) makes Enum.take a no-op, but we keep it for
    # safety when callers pass smaller limits.
    buckets = candidate_buckets(vector)

    if limit >= length(buckets) do
      buckets
    else
      Enum.take(buckets, limit)
    end
  end

  def candidate_buckets(vector, _limit) when is_list(vector) do
    candidate_buckets(vector)
  end

  def decode(id) when is_integer(id) do
    unknown_merchant = rem(id, 2)
    rem1 = div(id, 2)

    card_present = rem(rem1, 2)
    rem2 = div(rem1, 2)

    is_online = rem(rem2, 2)
    rem3 = div(rem2, 2)

    mcc_bin = rem(rem3, @mcc_bins)
    hour_bin = div(rem3, @mcc_bins)

    {hour_bin, mcc_bin, is_online, card_present, unknown_merchant}
  end

  # Pure function of the 5 bin coordinates; used both for precompute and tests.
  defp candidate_buckets_for_key(hour_bin, mcc_bin, is_online, card_present, unknown_merchant) do
    rings = [
      {0, 0, [unknown_merchant], [is_online], [card_present]},
      {1, 1, [unknown_merchant], [is_online], [card_present]},
      {2, 1, [unknown_merchant], [is_online, 1 - is_online], [card_present]},
      {2, 2, [unknown_merchant, 1 - unknown_merchant], [is_online, 1 - is_online],
       [card_present, 1 - card_present]}
    ]

    rings
    |> Enum.flat_map(fn {hour_radius, mcc_radius, unknown_vals, online_vals, present_vals} ->
      hour_candidates = around(hour_bin, @hour_bins, hour_radius)
      mcc_candidates = around(mcc_bin, @mcc_bins, mcc_radius)

      for h <- hour_candidates,
          m <- mcc_candidates,
          o <- online_vals,
          p <- present_vals,
          u <- unknown_vals do
        encode(h, m, o, p, u)
      end
    end)
    |> Enum.uniq()
  end

  defp rings_table do
    case :persistent_term.get(@rings_key, :not_cached) do
      :not_cached ->
        table = build_rings_table()
        :persistent_term.put(@rings_key, table)
        table

      table ->
        table
    end
  end

  defp around(center, max_bins, radius) do
    (center - radius)..(center + radius)
    |> Enum.filter(&(&1 >= 0 and &1 < max_bins))
  end

  defp encode(hour_bin, mcc_bin, is_online, card_present, unknown_merchant) do
    (((hour_bin * @mcc_bins + mcc_bin) * 2 + is_online) * 2 + card_present) * 2 + unknown_merchant
  end

  defp quantize(value, bins) do
    value
    |> clamp01()
    |> Kernel.*(bins)
    |> floor()
    |> min(bins - 1)
  end

  defp bool_bin(value) when value >= 0.5, do: 1
  defp bool_bin(_value), do: 0

  defp clamp01(value) when value < 0.0, do: 0.0
  defp clamp01(value) when value > 1.0, do: 1.0
  defp clamp01(value), do: value
end
