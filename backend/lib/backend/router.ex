defmodule Backend.Router do
  @moduledoc false

  use Plug.ErrorHandler
  use Plug.Router

  @fraud_responses %{
    0 => ~s({"approved":true,"fraud_score":0.0}),
    1 => ~s({"approved":true,"fraud_score":0.2}),
    2 => ~s({"approved":true,"fraud_score":0.4}),
    3 => ~s({"approved":false,"fraud_score":0.6}),
    4 => ~s({"approved":false,"fraud_score":0.8}),
    5 => ~s({"approved":false,"fraud_score":1.0})
  }
  @fallback_body @fraud_responses[0]

  plug(:match)

  plug(:dispatch)

  get "/ready" do
    send_resp(conn, 200, "ready")
  end

  get "/internal/metrics" do
    body = Jason.encode_to_iodata!(Backend.Metrics.snapshot())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  post "/fraud-score" do
    handle_fraud_score(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl true
  def handle_errors(conn, _error_info) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, @fallback_body)
  end

  defp handle_fraud_score(conn) do
    started = System.monotonic_time(:microsecond)

    case do_score(conn) do
      {:ok, conn, fraud_hits, candidate_count} ->
        Backend.Metrics.record_engine_latency_us(System.monotonic_time(:microsecond) - started)
        Backend.Metrics.record_candidate_count(candidate_count)
        response_body = Map.get(@fraud_responses, fraud_hits, @fallback_body)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, response_body)

      _ ->
        Backend.Metrics.record_fallback()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, @fallback_body)
    end
  end

  defp do_score(conn) do
    with {:ok, body, conn} <- read_full_body(conn, []),
         {:ok, vector} <- Backend.FastRequestParser.parse_vector(body),
         {:ok, %{fraud_hits: fraud_hits, candidate_count: candidate_count}} <-
           Backend.EngineIndex.score(vector) do
      {:ok, conn, fraud_hits, candidate_count}
    else
      _ -> {:error, :score_failed}
    end
  end

  defp read_full_body(conn, acc) do
    case read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 3_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [chunk | acc])

      {:error, _reason} ->
        {:error, :body_read_failed}
    end
  end
end
