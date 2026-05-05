defmodule Backend.Server do
  @moduledoc false

  def child_spec(_arg) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Backend.Router,
      options: [
        ip: {0, 0, 0, 0},
        port: port(),
        compress: true,
        protocol_options: [max_keepalive: :infinity]
      ]
    )
  end

  defp port do
    System.get_env("PORT", "4000")
    |> String.to_integer()
  end
end
