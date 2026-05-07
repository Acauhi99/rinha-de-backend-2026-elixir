defmodule Backend.Config do
  @moduledoc false

  def role, do: :api

  def candidates_target do
    env_int("CANDIDATES_TARGET", 12_000)
  end

  def candidates_hard_cap do
    env_int("CANDIDATES_HARD_CAP", 20_000)
  end

  def bucket_limit_primary do
    env_int("NPROBE_PRIMARY", 240)
    |> at_least(1)
  end

  def bucket_limit_second_pass do
    env_int("NPROBE_SECOND_PASS", 240)
    |> at_least(1)
  end

  def borderline_second_pass_enabled do
    env_bool("BORDERLINE_SECOND_PASS_ENABLED", false)
  end

  def borderline_hits_min do
    env_int("BORDERLINE_HITS_MIN", 2)
    |> at_least(0)
  end

  def borderline_hits_max do
    env_int("BORDERLINE_HITS_MAX", 3)
    |> at_least(0)
  end

  def socket_path do
    case System.get_env("SOCKET_PATH") do
      nil -> nil
      "" -> nil
      path -> path
    end
  end

  def cowboy_max_connections do
    env_int("COWBOY_MAX_CONNECTIONS", 128)
    |> at_least(1)
  end

  def cowboy_num_acceptors do
    env_int("COWBOY_NUM_ACCEPTORS", 8)
    |> at_least(1)
  end

  def cowboy_idle_timeout_ms do
    env_int("COWBOY_IDLE_TIMEOUT_MS", 5_000)
    |> at_least(1)
  end

  def cowboy_request_timeout_ms do
    env_int("COWBOY_REQUEST_TIMEOUT_MS", 5_000)
    |> at_least(1)
  end

  def cowboy_max_keepalive do
    env_int("COWBOY_MAX_KEEPALIVE", 100)
    |> at_least(1)
  end

  def index_dir do
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
