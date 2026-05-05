defmodule Mix.Tasks.Rinha.BuildIndex do
  @moduledoc false

  use Mix.Task

  @shortdoc "Builds vector index files from references.json.gz"
  @progress_every 100_000
  @q16_scale 32_767.0

  @impl true
  def run(args) do
    {resources_dir, output_dir} = parse_args(args)

    references_path = Path.join(resources_dir, "references.json.gz")

    Mix.shell().info("Building index from #{references_path}")
    File.mkdir_p!(output_dir)

    vectors_path = Path.join(output_dir, "vectors.bin")
    labels_path = Path.join(output_dir, "labels.bin")
    postings_path = Path.join(output_dir, "postings.bin")
    meta_path = Path.join(output_dir, "meta.etf")

    bucket_tmp_dir = Path.join(output_dir, "buckets")
    File.mkdir_p!(bucket_tmp_dir)

    bucket_ids = all_bucket_ids()
    bucket_ios = open_bucket_ios(bucket_ids, bucket_tmp_dir)

    {:ok, vectors_io} = File.open(vectors_path, [:write, :binary])
    {:ok, labels_io} = File.open(labels_path, [:write, :binary])

    total =
      references_path
      |> objects_stream()
      |> Enum.reduce(0, fn entry, index ->
        {vector, label} = fetch_vector_label!(entry)

        write_vector(vectors_io, vector)
        write_label(labels_io, label)

        bucket_id = Backend.IndexBucket.bucket_id(vector)
        bucket_io = Map.fetch!(bucket_ios, bucket_id)
        :ok = IO.binwrite(bucket_io, <<index::unsigned-little-32>>)

        processed = index + 1

        if rem(processed, @progress_every) == 0 do
          Mix.shell().info("Indexed #{processed} records...")
        end

        processed
      end)

    File.close(vectors_io)
    File.close(labels_io)
    close_bucket_ios(bucket_ios)

    {bucket_offsets, postings_size} = assemble_postings(postings_path, bucket_ids, bucket_tmp_dir)

    meta = %{
      version: 2,
      vector_format: :q16,
      vector_scale: @q16_scale,
      dim: 14,
      total: total,
      postings_size: postings_size,
      bucket_offsets: bucket_offsets
    }

    File.write!(meta_path, :erlang.term_to_binary(meta, [:compressed]))
    File.rm_rf!(bucket_tmp_dir)

    Mix.shell().info("Index build complete. total=#{total}")
  end

  defp parse_args([resources_dir, output_dir]), do: {resources_dir, output_dir}
  defp parse_args([resources_dir]), do: {resources_dir, "priv/index"}
  defp parse_args(_), do: {"../resources", "priv/index"}

  defp objects_stream(references_path) do
    references_path
    |> Backend.IndexGzipStream.chunk_stream()
    |> Jaxon.Stream.from_enumerable()
    |> Jaxon.Stream.query([:all])
    |> Stream.flat_map(&normalize_entries/1)
  end

  defp normalize_entries(entry) when is_map(entry), do: [entry]
  defp normalize_entries(entry) when is_list(entry), do: entry

  defp normalize_entries(other) do
    raise ArgumentError,
          "entrada JSON invalida no index builder: esperado mapa/lista, recebido #{inspect(other)}"
  end

  defp fetch_vector_label!(%{"vector" => vector, "label" => label}), do: {vector, label}

  defp fetch_vector_label!(other) do
    raise ArgumentError,
          "registro invalido no index builder: esperado %{\\\"vector\\\" => ..., \\\"label\\\" => ...}, recebido #{inspect(other)}"
  end

  defp write_vector(io, vector) when is_list(vector) do
    [v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13] = vector

    IO.binwrite(
      io,
      <<as_q16(v0)::signed-little-16, as_q16(v1)::signed-little-16,
        as_q16(v2)::signed-little-16, as_q16(v3)::signed-little-16,
        as_q16(v4)::signed-little-16, as_q16(v5)::signed-little-16,
        as_q16(v6)::signed-little-16, as_q16(v7)::signed-little-16,
        as_q16(v8)::signed-little-16, as_q16(v9)::signed-little-16,
        as_q16(v10)::signed-little-16, as_q16(v11)::signed-little-16,
        as_q16(v12)::signed-little-16, as_q16(v13)::signed-little-16>>
    )
  end

  defp write_label(io, "fraud"), do: IO.binwrite(io, <<1>>)
  defp write_label(io, _), do: IO.binwrite(io, <<0>>)

  defp all_bucket_ids do
    for hour <- 0..(Backend.IndexBucket.hour_bins() - 1),
        mcc <- 0..(Backend.IndexBucket.mcc_bins() - 1),
        online <- 0..1,
        present <- 0..1,
        unknown <- 0..1 do
      to_bucket_id([hour, mcc, online, present, unknown])
    end
  end

  defp to_bucket_id([hour, mcc, online, present, unknown]) do
    (((hour * Backend.IndexBucket.mcc_bins() + mcc) * 2 + online) * 2 + present) * 2 + unknown
  end

  defp open_bucket_ios(bucket_ids, bucket_tmp_dir) do
    Enum.reduce(bucket_ids, %{}, fn bucket_id, acc ->
      path = Path.join(bucket_tmp_dir, "bucket_#{bucket_id}.bin")
      {:ok, io} = File.open(path, [:write, :binary])
      Map.put(acc, bucket_id, io)
    end)
  end

  defp close_bucket_ios(bucket_ios) do
    Enum.each(bucket_ios, fn {_id, io} -> File.close(io) end)
  end

  defp assemble_postings(postings_path, bucket_ids, bucket_tmp_dir) do
    {:ok, postings_io} = File.open(postings_path, [:write, :binary])

    {offsets, final_offset} =
      Enum.reduce(bucket_ids, {%{}, 0}, fn bucket_id, {acc, offset} ->
        bucket_path = Path.join(bucket_tmp_dir, "bucket_#{bucket_id}.bin")

        size =
          case File.stat(bucket_path) do
            {:ok, stat} -> stat.size
            _ -> 0
          end

        count = div(size, 4)

        if count > 0 do
          {:ok, data} = File.read(bucket_path)
          IO.binwrite(postings_io, data)
        end

        {Map.put(acc, bucket_id, {offset, count}), offset + size}
      end)

    File.close(postings_io)

    {offsets, final_offset}
  end

  defp as_q16(value) when is_integer(value), do: as_q16(value * 1.0)

  defp as_q16(value) when is_float(value) do
    value
    |> clamp_range(-1.0, 1.0)
    |> Kernel.*(@q16_scale)
    |> Float.round()
    |> trunc()
  end

  defp clamp_range(value, min_value, _max_value) when value < min_value, do: min_value
  defp clamp_range(value, _min_value, max_value) when value > max_value, do: max_value
  defp clamp_range(value, _min_value, _max_value), do: value
end
