defmodule Backend.Config do
  @moduledoc false

  @snapshot_key {__MODULE__, :snapshot}

  def role, do: :api

  @doc """
  Reads all environment variables once and stores an immutable snapshot in
  `:persistent_term`. Must be called at application boot (before any hot-path
  request). Subsequent calls refresh the snapshot.
  """
  def cache! do
    snapshot = build_snapshot()
    :persistent_term.put(@snapshot_key, snapshot)
    snapshot
  end

  @doc """
  Returns the cached config snapshot. If the cache is missing (e.g. tests),
  builds one on demand and caches it.
  """
  def snapshot do
    case :persistent_term.get(@snapshot_key, :not_cached) do
      :not_cached -> cache!()
      snapshot -> snapshot
    end
  end

  def candidates_target, do: snapshot().candidates_target
  def candidates_hard_cap, do: snapshot().candidates_hard_cap
  def bucket_limit_primary, do: snapshot().bucket_limit_primary
  def bucket_limit_second_pass, do: snapshot().bucket_limit_second_pass
  def borderline_second_pass_enabled, do: snapshot().borderline_second_pass_enabled
  def borderline_hits_min, do: snapshot().borderline_hits_min
  def borderline_hits_max, do: snapshot().borderline_hits_max
  def socket_path, do: snapshot().socket_path
  def cowboy_max_connections, do: snapshot().cowboy_max_connections
  def cowboy_num_acceptors, do: snapshot().cowboy_num_acceptors
  def cowboy_idle_timeout_ms, do: snapshot().cowboy_idle_timeout_ms
  def cowboy_request_timeout_ms, do: snapshot().cowboy_request_timeout_ms
  def cowboy_max_keepalive, do: snapshot().cowboy_max_keepalive
  def index_dir, do: snapshot().index_dir

  defp build_snapshot do
    %{
      candidates_target: env_int("CANDIDATES_TARGET", 12_000),
      candidates_hard_cap: env_int("CANDIDATES_HARD_CAP", 20_000),
      bucket_limit_primary: env_int("NPROBE_PRIMARY", 240) |> at_least(1),
      bucket_limit_second_pass: env_int("NPROBE_SECOND_PASS", 240) |> at_least(1),
      borderline_second_pass_enabled: env_bool("BORDERLINE_SECOND_PASS_ENABLED", false),
      borderline_hits_min: env_int("BORDERLINE_HITS_MIN", 2) |> at_least(0),
      borderline_hits_max: env_int("BORDERLINE_HITS_MAX", 3) |> at_least(0),
      socket_path: socket_path_env(),
      cowboy_max_connections: env_int("COWBOY_MAX_CONNECTIONS", 128) |> at_least(1),
      cowboy_num_acceptors: env_int("COWBOY_NUM_ACCEPTORS", 8) |> at_least(1),
      cowboy_idle_timeout_ms: env_int("COWBOY_IDLE_TIMEOUT_MS", 5_000) |> at_least(1),
      cowboy_request_timeout_ms: env_int("COWBOY_REQUEST_TIMEOUT_MS", 5_000) |> at_least(1),
      cowboy_max_keepalive: env_int("COWBOY_MAX_KEEPALIVE", 100) |> at_least(1),
      index_dir: index_dir_env()
    }
  end

  defp socket_path_env do
    case System.get_env("SOCKET_PATH") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end

  defp index_dir_env do
    System.get_env("INDEX_DIR") || default_index_dir()
  end

  defp default_index_dir do
    cond do
      File.dir?("priv/index") -> "priv/index"
      File.dir?("../priv/index") -> "../priv/index"
      true -> "/app/index"
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp env_bool(key, default) do
    case System.get_env(key) do
      nil -> default
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
      _ -> default
    end
  end

  defp at_least(value, min) when is_integer(value) and is_integer(min) do
    if value < min, do: min, else: value
  end
end
