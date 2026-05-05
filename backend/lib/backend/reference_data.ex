defmodule Backend.ReferenceData do
  @moduledoc false

  use GenServer

  @table :backend_reference_data

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])

    {:ok, data} = load_data()
    :ets.insert(@table, {:normalization, data.normalization})
    :ets.insert(@table, {:mcc_risk, data.mcc_risk})

    {:ok, state}
  end

  def normalization do
    lookup!(:normalization)
  end

  def mcc_risk do
    lookup!(:mcc_risk)
  end

  defp lookup!(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> raise "reference data not loaded: #{inspect(key)}"
    end
  end

  defp load_data do
    base_dir = resources_dir()

    with {:ok, normalization} <- read_json(Path.join(base_dir, "normalization.json")),
         {:ok, mcc_risk} <- read_json(Path.join(base_dir, "mcc_risk.json")) do
      {:ok, %{normalization: normalization, mcc_risk: mcc_risk}}
    end
  end

  defp read_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      _ ->
        {:error, "failed to load #{path}"}
    end
  end

  defp resources_dir do
    System.get_env("RINHA_RESOURCES_DIR") || default_resources_dir()
  end

  defp default_resources_dir do
    cond do
      File.dir?("resources") -> "resources"
      File.dir?("../resources") -> "../resources"
      true -> "/app/resources"
    end
  end
end
