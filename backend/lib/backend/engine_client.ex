defmodule Backend.EngineClient do
  @moduledoc false

  def score_payload(payload) when is_map(payload) do
    request_payload(payload)
  end

  def score_vector(vector) when is_list(vector) do
    request_payload(%{"vector" => vector})
  end

  defp request_payload(payload) when is_map(payload) do
    started = System.monotonic_time(:microsecond)

    body = Jason.encode!(payload)
    headers = [{'content-type', 'application/json'}]

    request = {String.to_charlist(Backend.Config.engine_url()), headers, 'application/json', body}
    timeout = Backend.Config.engine_timeout_ms()

    http_opts = [timeout: timeout, connect_timeout: timeout]
    options = [body_format: :binary]

    result = :httpc.request(:post, request, http_opts, options)

    elapsed_us = System.monotonic_time(:microsecond) - started
    Backend.Metrics.record_engine_latency_us(elapsed_us)

    case result do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        {:ok, response_body}

      _ ->
        {:error, :engine_unavailable}
    end
  end
end
