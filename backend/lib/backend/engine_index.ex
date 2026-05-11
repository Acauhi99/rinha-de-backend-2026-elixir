defmodule Backend.EngineIndex do
  @moduledoc false

  use GenServer
  require Logger

  @k 5
  @dim 14
  @vector_bytes @dim * 2
  @default_q16_scale 32_767.0

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def score(vector) when is_list(vector) and length(vector) == @dim do
    case :persistent_term.get({__MODULE__, :data}, :not_loaded) do
      :not_loaded -> {:error, :index_not_ready}
      data -> do_score(data, vector)
    end
  end

  @impl true
  def init(state) do
    case load_index() do
      {:ok, data} ->
        :persistent_term.put({__MODULE__, :data}, data)

      {:error, reason} ->
        Logger.error("engine index unavailable: #{inspect(reason)}")
        :persistent_term.put({__MODULE__, :data}, :not_loaded)
    end

    {:ok, state}
  end

  defp do_score(data, vector) do
    cfg = Backend.Config.snapshot()
    query = as_query_tuple(vector, data.vector_scale)
    query_seed = :erlang.phash2(query)

    {topk, candidate_count} =
      topk_from_buckets(
        data,
        vector,
        query,
        query_seed,
        cfg.candidates_target,
        cfg.candidates_hard_cap,
        cfg.bucket_limit_primary
      )

    fraud_hits = Enum.count(topk, fn {_dist, label} -> label == 1 end)

    {fraud_hits, candidate_count} =
      maybe_second_pass(
        data,
        vector,
        query,
        query_seed,
        cfg,
        fraud_hits,
        candidate_count
      )

    {:ok, %{fraud_hits: fraud_hits, candidate_count: candidate_count}}
  end

  defp maybe_second_pass(
         data,
         vector,
         query,
         query_seed,
         %{
           borderline_second_pass_enabled: true,
           bucket_limit_primary: primary_bucket_limit,
           bucket_limit_second_pass: second_pass_bucket_limit,
           borderline_hits_min: borderline_hits_min,
           borderline_hits_max: borderline_hits_max,
           candidates_target: candidates_target,
           candidates_hard_cap: hard_cap
         },
         fraud_hits,
         candidate_count
       ) do
    should_rerank =
      second_pass_bucket_limit > primary_bucket_limit and
        fraud_hits >= borderline_hits_min and fraud_hits <= borderline_hits_max

    if should_rerank do
      {second_topk, second_candidate_count} =
        topk_from_buckets(
          data,
          vector,
          query,
          query_seed,
          candidates_target,
          hard_cap,
          second_pass_bucket_limit
        )

      second_fraud_hits = Enum.count(second_topk, fn {_dist, label} -> label == 1 end)
      {second_fraud_hits, second_candidate_count}
    else
      {fraud_hits, candidate_count}
    end
  end

  defp maybe_second_pass(_data, _vector, _query, _query_seed, _cfg, fraud_hits, candidate_count) do
    {fraud_hits, candidate_count}
  end

  defp load_index do
    base = Backend.Config.index_dir()

    with {:ok, vectors} <- File.read(Path.join(base, "vectors.bin")),
         {:ok, labels} <- File.read(Path.join(base, "labels.bin")),
         {:ok, postings} <- File.read(Path.join(base, "postings.bin")),
         {:ok, meta_bin} <- File.read(Path.join(base, "meta.etf")) do
      meta = :erlang.binary_to_term(meta_bin)
      :ok = validate_meta!(meta)
      :ok = validate_vectors_size!(vectors, meta.total)

      bucket_offsets_tuple = build_offsets_tuple(meta.bucket_offsets)

      {:ok,
       %{
         vectors: vectors,
         labels: labels,
         postings: postings,
         vector_scale: Map.get(meta, :vector_scale, @default_q16_scale),
         bucket_offsets: bucket_offsets_tuple,
         total: meta.total
       }}
    else
      _ ->
        {:error, :index_load_failed}
    end
  end

  defp build_offsets_tuple(bucket_offsets_map) when is_map(bucket_offsets_map) do
    total = Backend.IndexBucket.total_buckets()

    0..(total - 1)
    |> Enum.map(fn id -> Map.get(bucket_offsets_map, id, {0, 0}) end)
    |> List.to_tuple()
  end

  defp validate_meta!(meta) do
    case Map.get(meta, :vector_format) do
      :q16 -> :ok
      other -> raise "unsupported index vector_format=#{inspect(other)} (expected :q16)"
    end

    case Map.get(meta, :dim) do
      @dim -> :ok
      other -> raise "unsupported index dim=#{inspect(other)} (expected #{@dim})"
    end
  end

  defp validate_vectors_size!(vectors, total) when is_integer(total) and total >= 0 do
    expected = total * @vector_bytes

    if byte_size(vectors) == expected do
      :ok
    else
      raise "invalid vectors.bin size=#{byte_size(vectors)} expected=#{expected} (did you rebuild index?)"
    end
  end

  defp topk_from_buckets(
         data,
         vector,
         query,
         query_seed,
         candidates_target,
         hard_cap,
         bucket_limit
       ) do
    buckets = Backend.IndexBucket.candidate_buckets(vector, bucket_limit)

    Enum.reduce_while(buckets, {[], 0}, fn bucket_id, {topk, count} ->
      needed = min(hard_cap - count, candidates_target - count)

      if needed <= 0 do
        {:halt, {topk, count}}
      else
        {next_topk, added} = read_bucket_topk(data, bucket_id, needed, query_seed, query, topk)
        next_count = count + added

        if next_count >= candidates_target or next_count >= hard_cap do
          {:halt, {next_topk, next_count}}
        else
          {:cont, {next_topk, next_count}}
        end
      end
    end)
  end

  defp read_bucket_topk(data, bucket_id, limit, query_seed, query, topk) do
    case elem(data.bucket_offsets, bucket_id) do
      {_offset, 0} ->
        {topk, 0}

      {offset, count} ->
        max_take = min(limit, count)

        if max_take <= 0 do
          {topk, 0}
        else
          shift = deterministic_shift(bucket_id, query_seed, count)
          # Single recursive stride loop: no intermediate position list, no
          # Enum.reduce closure, no list allocation per candidate. Top-k is
          # kept as a list but insertion is inlined; for k=5 this is fine.
          scan_stride(data, offset, 0, max_take, count, shift, query, topk)
        end
    end
  end

  # scan_stride/8: for i in 0..max_take-1, compute pos = rem(div(i*count, max_take) + shift, count),
  # read the 4-byte posting id at offset+pos*4, compute squared distance, update topk.
  defp scan_stride(_data, _offset, i, max_take, _count, _shift, _query, topk)
       when i >= max_take do
    {topk, i}
  end

  defp scan_stride(data, offset, i, max_take, count, shift, query, topk) do
    base = div(i * count, max_take)
    pos = rem(base + shift, count)
    byte_offset = offset + pos * 4
    <<id::unsigned-little-32>> = binary_part(data.postings, byte_offset, 4)
    dist = distance_squared(data.vectors, id, query)
    label = :binary.at(data.labels, id)
    new_topk = upsert_topk(topk, dist, label)
    scan_stride(data, offset, i + 1, max_take, count, shift, query, new_topk)
  end

  # upsert_topk keeps a list of at most @k {dist, label} tuples, ordered so the
  # head is always the current max distance. For @k=5 this beats a heap.
  defp upsert_topk([], dist, label), do: [{dist, label}]

  defp upsert_topk([{max_d, _} = top | rest] = topk, dist, label) do
    len = length(topk)

    cond do
      len < @k ->
        # Still filling; keep invariant head = max.
        if dist > max_d do
          [{dist, label} | topk]
        else
          [top | insert_preserving_max(rest, dist, label, max_d)]
        end

      dist >= max_d ->
        # Worse than current max: drop.
        topk

      true ->
        # Better than max: replace head and recompute new max.
        new_list = [{dist, label} | rest]
        promote_max(new_list)
    end
  end

  # Used only while filling (< @k elements). Inserts while preserving that
  # the caller's head remains the overall max.
  defp insert_preserving_max(list, dist, label, _head_max) do
    [{dist, label} | list]
  end

  # Finds the max element in a list of @k tuples and moves it to the head.
  defp promote_max([a, b, c, d, e]) do
    {da, _} = a
    {db, _} = b
    {dc, _} = c
    {dd, _} = d
    {de, _} = e

    max_d = max(da, max(db, max(dc, max(dd, de))))

    cond do
      da == max_d -> [a, b, c, d, e]
      db == max_d -> [b, a, c, d, e]
      dc == max_d -> [c, a, b, d, e]
      dd == max_d -> [d, a, b, c, e]
      true -> [e, a, b, c, d]
    end
  end

  defp promote_max(list) do
    # Fallback for any size (e.g. < @k during tests).
    {max_idx, _max_d} =
      list
      |> Enum.with_index()
      |> Enum.reduce({0, -1.0e308}, fn {{d, _}, idx}, {bi, bd} ->
        if d > bd, do: {idx, d}, else: {bi, bd}
      end)

    {top, rest} = List.pop_at(list, max_idx)
    [top | rest]
  end

  defp distance_squared(vectors, id, query) do
    offset = id * @vector_bytes

    <<v0::signed-little-16, v1::signed-little-16, v2::signed-little-16, v3::signed-little-16,
      v4::signed-little-16, v5::signed-little-16, v6::signed-little-16, v7::signed-little-16,
      v8::signed-little-16, v9::signed-little-16, v10::signed-little-16, v11::signed-little-16,
      v12::signed-little-16, v13::signed-little-16>> = binary_part(vectors, offset, @vector_bytes)

    {q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13} = query

    sq(q0 - v0) + sq(q1 - v1) + sq(q2 - v2) + sq(q3 - v3) + sq(q4 - v4) + sq(q5 - v5) +
      sq(q6 - v6) + sq(q7 - v7) + sq(q8 - v8) + sq(q9 - v9) + sq(q10 - v10) + sq(q11 - v11) +
      sq(q12 - v12) + sq(q13 - v13)
  end

  defp sq(value), do: value * value

  defp deterministic_shift(bucket_id, query_seed, count) do
    :erlang.phash2({bucket_id, query_seed}, count)
  end

  defp as_query_tuple([q0, q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13], scale) do
    {q16(q0, scale), q16(q1, scale), q16(q2, scale), q16(q3, scale), q16(q4, scale),
     q16(q5, scale), q16(q6, scale), q16(q7, scale), q16(q8, scale), q16(q9, scale),
     q16(q10, scale), q16(q11, scale), q16(q12, scale), q16(q13, scale)}
  end

  defp q16(value, scale) when is_integer(value), do: q16(value * 1.0, scale)

  defp q16(value, scale) when is_float(value) do
    value
    |> clamp_range(-1.0, 1.0)
    |> Kernel.*(scale)
    |> Float.round()
    |> trunc()
  end

  defp clamp_range(value, min_value, _max_value) when value < min_value, do: min_value
  defp clamp_range(value, _min_value, max_value) when value > max_value, do: max_value
  defp clamp_range(value, _min_value, _max_value), do: value
end
