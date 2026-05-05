defmodule Backend.Router do
  @moduledoc false

  use Plug.ErrorHandler
  use Plug.Router

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :dispatch

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
    case Backend.Config.role() do
      :api -> handle_fraud_score(conn)
      :engine -> send_resp(conn, 404, "not found")
    end
  end

  post "/internal/score" do
    case Backend.Config.role() do
      :engine -> handle_internal_score(conn)
      :api -> send_resp(conn, 404, "not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl true
  def handle_errors(conn, _error_info) do
    body = Jason.encode_to_iodata!(%{approved: true, fraud_score: 0.0})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_fraud_score(conn) do
    with {:ok, vector} <- Backend.FraudScorer.vectorize(conn.body_params),
         {:ok, result} <- Backend.EngineIndex.score(vector) do
      fraud_score = result.fraud_score
      approved = fraud_score < 0.6
      Backend.Metrics.record_candidate_count(result.candidate_count)

      body =
        Jason.encode_to_iodata!(%{
          approved: approved,
          fraud_score: Float.round(fraud_score, 6)
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _ ->
        Backend.Metrics.record_fallback()

        body = Jason.encode_to_iodata!(%{approved: true, fraud_score: 0.0})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
    end
  end

  defp handle_internal_score(conn) do
    vector = Map.get(conn.body_params, "vector")

    with {:ok, result} <- Backend.EngineIndex.score(vector) do
      body = Jason.encode_to_iodata!(result)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode_to_iodata!(%{error: "invalid vector"}))
    end
  end
end
