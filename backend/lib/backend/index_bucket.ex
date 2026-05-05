defmodule Backend.IndexBucket do
  @moduledoc false

  @hour_bins 6
  @mcc_bins 5

  def hour_bins, do: @hour_bins
  def mcc_bins, do: @mcc_bins

  def bucket_id(vector) when is_list(vector) do
    hour_bin = quantize(Enum.at(vector, 3), @hour_bins)
    mcc_bin = quantize(Enum.at(vector, 12), @mcc_bins)
    is_online = bool_bin(Enum.at(vector, 9))
    card_present = bool_bin(Enum.at(vector, 10))
    unknown_merchant = bool_bin(Enum.at(vector, 11))

    encode(hour_bin, mcc_bin, is_online, card_present, unknown_merchant)
  end

  def candidate_buckets(vector) when is_list(vector) do
    hour_bin = quantize(Enum.at(vector, 3), @hour_bins)
    mcc_bin = quantize(Enum.at(vector, 12), @mcc_bins)
    is_online = bool_bin(Enum.at(vector, 9))
    card_present = bool_bin(Enum.at(vector, 10))
    unknown_merchant = bool_bin(Enum.at(vector, 11))

    rings = [
      {0, 0, [unknown_merchant], [is_online], [card_present]},
      {1, 1, [unknown_merchant], [is_online], [card_present]},
      {2, 1, [unknown_merchant], [is_online, 1 - is_online], [card_present]},
      {2, 2, [unknown_merchant, 1 - unknown_merchant], [is_online, 1 - is_online], [card_present, 1 - card_present]}
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

  defp around(center, max_bins, radius) do
    center - radius..center + radius
    |> Enum.filter(&(&1 >= 0 and &1 < max_bins))
  end

  defp encode(hour_bin, mcc_bin, is_online, card_present, unknown_merchant) do
    ((((hour_bin * @mcc_bins + mcc_bin) * 2 + is_online) * 2 + card_present) * 2 + unknown_merchant)
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
