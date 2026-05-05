defmodule Backend.Config do
  @moduledoc false

  def role do
    case System.get_env("APP_ROLE", "api") do
      "engine" -> :engine
      _ -> :api
    end
  end

  def candidates_target do
    env_int("CANDIDATES_TARGET", 12_000)
  end

  def candidates_hard_cap do
    env_int("CANDIDATES_HARD_CAP", 20_000)
  end

  def engine_timeout_ms do
    env_int("ENGINE_TIMEOUT_MS", 8)
  end

  def engine_url do
    System.get_env("ENGINE_URL", "http://engine:4000/internal/score")
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

  defp at_least(value, min) when is_integer(value) and is_integer(min) do
    if value < min, do: min, else: value
  end
end
