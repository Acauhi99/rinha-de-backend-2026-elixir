defmodule Backend.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Backend.Config.role() do
        :api ->
          [
            Backend.ReferenceData,
            Backend.Metrics,
            Backend.Server
          ]

        :engine ->
          [
            Backend.ReferenceData,
            Backend.EngineIndex,
            Backend.Metrics,
            Backend.Server
          ]
      end

    opts = [strategy: :one_for_one, name: Backend.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
