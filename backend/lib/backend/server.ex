defmodule Backend.Server do
  @moduledoc false

  def child_spec(_arg) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Backend.Router,
      options: [
        ip: {0, 0, 0, 0},
        port: port(),
        compress: false,
        transport_options: [
          num_acceptors: Backend.Config.cowboy_num_acceptors(),
          max_connections: Backend.Config.cowboy_max_connections()
        ],
        protocol_options: [
          request_timeout: Backend.Config.cowboy_request_timeout_ms(),
          idle_timeout: Backend.Config.cowboy_idle_timeout_ms(),
          max_keepalive: Backend.Config.cowboy_max_keepalive()
        ]
      ]
    )
  end

  defp port do
    System.get_env("PORT", "4000")
    |> String.to_integer()
  end
end
