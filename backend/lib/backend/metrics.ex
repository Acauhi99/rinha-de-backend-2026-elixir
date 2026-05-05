defmodule Backend.Metrics do
  @moduledoc false

  use GenServer

  @keep 20_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def record_engine_latency_us(value) when is_integer(value) do
    GenServer.cast(__MODULE__, {:engine_latency_us, value})
  end

  def record_candidate_count(value) when is_integer(value) do
    GenServer.cast(__MODULE__, {:candidate_count, value})
  end

  def record_fallback do
    GenServer.cast(__MODULE__, :fallback)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(_) do
    {:ok,
     %{
       fallback_count: 0,
       engine_latency_us: [],
       candidate_count: []
     }}
  end

  @impl true
  def handle_cast({:engine_latency_us, value}, state) do
    {:noreply, %{state | engine_latency_us: keep_latest([value | state.engine_latency_us])}}
  end

  @impl true
  def handle_cast({:candidate_count, value}, state) do
    {:noreply, %{state | candidate_count: keep_latest([value | state.candidate_count])}}
  end

  @impl true
  def handle_cast(:fallback, state) do
    {:noreply, %{state | fallback_count: state.fallback_count + 1}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      role: Backend.Config.role(),
      fallback_count: state.fallback_count,
      engine_latency_us: stats(state.engine_latency_us),
      candidate_count: stats(state.candidate_count)
    }

    {:reply, snapshot, state}
  end

  defp keep_latest(values) do
    values
    |> Enum.take(@keep)
  end

  defp stats([]), do: %{count: 0, p50: nil, p95: nil, p99: nil, max: nil}

  defp stats(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    %{
      count: count,
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      max: List.last(sorted)
    }
  end

  defp percentile(sorted, ratio) do
    idx = max(0, ceil(length(sorted) * ratio) - 1)
    Enum.at(sorted, idx)
  end
end
