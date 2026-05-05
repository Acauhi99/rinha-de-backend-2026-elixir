defmodule Backend.EngineClient do
  @moduledoc false

  def score_vector(vector) when is_list(vector) do
    started = System.monotonic_time(:microsecond)

    body = Jason.encode!(%{"vector" => vector})
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
        parse_response(response_body)

      _ ->
        {:error, :engine_unavailable}
    end
  end

  defp parse_response(response_body) do
    with {:ok, decoded} <- Jason.decode(response_body),
         fraud_score when is_number(fraud_score) <- decoded["fraud_score"],
         candidate_count when is_integer(candidate_count) <- decoded["candidate_count"] do
      Backend.Metrics.record_candidate_count(candidate_count)

      {:ok,
       %{
         fraud_score: fraud_score * 1.0,
         candidate_count: candidate_count
       }}
    else
      _ -> {:error, :invalid_engine_payload}
    end
  end
end
