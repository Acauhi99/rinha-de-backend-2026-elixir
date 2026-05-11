defmodule Backend.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Prime persistent_term caches before any request handler comes online.
    # These are cheap, deterministic, and eliminate per-request env/ring work.
    Backend.Config.cache!()
    Backend.IndexBucket.cache_rings!()

    children = [
      Backend.ReferenceData,
      Backend.EngineIndex,
      Backend.Metrics,
      Backend.Server
    ]

    opts = [strategy: :one_for_one, name: Backend.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
