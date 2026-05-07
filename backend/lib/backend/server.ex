defmodule Backend.Server do
  @moduledoc false

  def child_spec(_arg) do
    maybe_remove_socket_file()

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Backend.Router,
      options: [
        ip: ip(),
        port: port(),
        compress: false,
        transport_options: [
          num_acceptors: Backend.Config.cowboy_num_acceptors(),
          max_connections: Backend.Config.cowboy_max_connections(),
          post_listen_callback: &__MODULE__.post_listen_callback/1
        ],
        protocol_options: [
          request_timeout: Backend.Config.cowboy_request_timeout_ms(),
          idle_timeout: Backend.Config.cowboy_idle_timeout_ms(),
          max_keepalive: Backend.Config.cowboy_max_keepalive()
        ]
      ]
    )
  end

  def post_listen_callback(socket) do
    case :ranch_tcp.sockname(socket) do
      {:ok, {:local, socket_path}} ->
        :file.change_mode(socket_path, 0o777)

      _ ->
        :ok
    end
  end

  defp maybe_remove_socket_file do
    case Backend.Config.socket_path() do
      nil -> :ok
      socket_path -> File.rm(socket_path)
    end
  end

  defp ip do
    case Backend.Config.socket_path() do
      nil -> {0, 0, 0, 0}
      socket_path -> {:local, socket_path}
    end
  end

  defp port do
    case Backend.Config.socket_path() do
      nil ->
        System.get_env("PORT", "4000")
        |> String.to_integer()

      _ ->
        0
    end
  end
end
