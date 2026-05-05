defmodule Backend.EngineIndex do
  @moduledoc false

  use GenServer

  @k 5
  @dim 14
  @vector_bytes @dim * 4

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def score(vector) when is_list(vector) and length(vector) == @dim do
    GenServer.call(__MODULE__, {:score, vector}, :infinity)
  end

  @impl true
  def init(state) do
    {:ok, data} = load_index()
    :persistent_term.put({__MODULE__, :data}, data)
    {:ok, state}
  end

  @impl true
  def handle_call({:score, vector}, _from, state) do
    candidates_target = Backend.Config.candidates_target()
    hard_cap = Backend.Config.candidates_hard_cap()

    candidate_ids = collect_candidate_ids(vector, candidates_target, hard_cap)

    {fraud_hits, _total_hits} = topk_fraud_hits(candidate_ids, vector)
    fraud_score = fraud_hits / @k

    {:reply, {:ok, %{fraud_score: fraud_score, candidate_count: length(candidate_ids)}}, state}
  end

  defp load_index do
    base = Backend.Config.index_dir()

    with {:ok, vectors} <- File.read(Path.join(base, "vectors.bin")),
         {:ok, labels} <- File.read(Path.join(base, "labels.bin")),
         {:ok, postings} <- File.read(Path.join(base, "postings.bin")),
         {:ok, meta_bin} <- File.read(Path.join(base, "meta.etf")) do
      meta = :erlang.binary_to_term(meta_bin)

      {:ok,
       %{
         vectors: vectors,
         labels: labels,
         postings: postings,
         bucket_offsets: meta.bucket_offsets,
         total: meta.total
       }}
    else
      _ ->
        {:error, :index_load_failed}
    end
  end

  defp collect_candidate_ids(vector, candidates_target, hard_cap) do
    data = :persistent_term.get({__MODULE__, :data})
    buckets = Backend.IndexBucket.candidate_buckets(vector)
    query_key = query_key(vector)

    {ids, _count} =
      Enum.reduce_while(buckets, {[], 0}, fn bucket_id, {acc, count} ->
        needed = min(hard_cap - count, candidates_target - count)

        cond do
          needed <= 0 ->
            {:halt, {acc, count}}

          true ->
            {new_ids, added} = read_bucket_ids(data, bucket_id, needed, query_key)
            next_acc = [new_ids | acc]
            next_count = count + added

            if next_count >= candidates_target or next_count >= hard_cap do
              {:halt, {next_acc, next_count}}
            else
              {:cont, {next_acc, next_count}}
            end
        end
      end)

    ids
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.take(hard_cap)
  end

  defp read_bucket_ids(data, bucket_id, limit, query_key) do
    case Map.get(data.bucket_offsets, bucket_id) do
      nil -> {[], 0}
      {offset, count} ->
        max_take = min(limit, count)

        if max_take <= 0 do
          {[], 0}
        else
          shift = deterministic_shift(bucket_id, query_key, count)
          positions = Backend.CandidateSampler.sample_positions(count, max_take, shift)
          decode_positions(data.postings, offset, positions, [])
        end
    end
  end

  defp decode_positions(_postings, _offset, [], acc), do: {Enum.reverse(acc), length(acc)}

  defp decode_positions(postings, offset, [pos | rest], acc) do
    byte_offset = offset + pos * 4
    <<id::unsigned-little-32>> = binary_part(postings, byte_offset, 4)
    decode_positions(postings, offset, rest, [id | acc])
  end

  defp topk_fraud_hits(candidate_ids, query_vector) do
    data = :persistent_term.get({__MODULE__, :data})

    topk =
      Enum.reduce(candidate_ids, [], fn id, acc ->
        dist = distance_squared(data.vectors, id, query_vector)
        label = label_at(data.labels, id)
        upsert_topk(acc, {dist, label})
      end)

    fraud_hits =
      topk
      |> Enum.count(fn {_dist, label} -> label == 1 end)

    {fraud_hits, length(topk)}
  end

  defp upsert_topk(topk, candidate) do
    updated = [candidate | topk] |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(@k)
    updated
  end

  defp label_at(labels, id) do
    :binary.at(labels, id)
  end

  defp distance_squared(vectors, id, query_vector) do
    offset = id * @vector_bytes

    <<v0::float-little-32, v1::float-little-32, v2::float-little-32, v3::float-little-32,
      v4::float-little-32, v5::float-little-32, v6::float-little-32, v7::float-little-32,
      v8::float-little-32, v9::float-little-32, v10::float-little-32, v11::float-little-32,
      v12::float-little-32, v13::float-little-32>> = binary_part(vectors, offset, @vector_bytes)

    q0 = Enum.at(query_vector, 0)
    q1 = Enum.at(query_vector, 1)
    q2 = Enum.at(query_vector, 2)
    q3 = Enum.at(query_vector, 3)
    q4 = Enum.at(query_vector, 4)
    q5 = Enum.at(query_vector, 5)
    q6 = Enum.at(query_vector, 6)
    q7 = Enum.at(query_vector, 7)
    q8 = Enum.at(query_vector, 8)
    q9 = Enum.at(query_vector, 9)
    q10 = Enum.at(query_vector, 10)
    q11 = Enum.at(query_vector, 11)
    q12 = Enum.at(query_vector, 12)
    q13 = Enum.at(query_vector, 13)

    sq(q0 - v0) + sq(q1 - v1) + sq(q2 - v2) + sq(q3 - v3) + sq(q4 - v4) + sq(q5 - v5) +
      sq(q6 - v6) + sq(q7 - v7) + sq(q8 - v8) + sq(q9 - v9) + sq(q10 - v10) + sq(q11 - v11) +
      sq(q12 - v12) + sq(q13 - v13)
  end

  defp sq(value), do: value * value

  defp deterministic_shift(bucket_id, query_key, count) do
    :erlang.phash2({bucket_id, query_key}, count)
  end

  defp query_key(vector) do
    vector
    |> Enum.map(&trunc(&1 * 1000))
  end
end
