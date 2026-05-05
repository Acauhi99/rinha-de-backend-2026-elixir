defmodule Backend.Metrics do
  @moduledoc false

  use GenServer

  @keep 4_096

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
       engine_latency_us: :queue.new(),
       engine_latency_count: 0,
       candidate_count: :queue.new(),
       candidate_count_count: 0
     }}
  end

  @impl true
  def handle_cast({:engine_latency_us, value}, state) do
    {queue, count} = queue_push(state.engine_latency_us, state.engine_latency_count, value, @keep)
    {:noreply, %{state | engine_latency_us: queue, engine_latency_count: count}}
  end

  @impl true
  def handle_cast({:candidate_count, value}, state) do
    {queue, count} = queue_push(state.candidate_count, state.candidate_count_count, value, @keep)
    {:noreply, %{state | candidate_count: queue, candidate_count_count: count}}
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
      engine_latency_us: stats(:queue.to_list(state.engine_latency_us)),
      candidate_count: stats(:queue.to_list(state.candidate_count))
    }

    {:reply, snapshot, state}
  end

  defp queue_push(queue, count, value, keep) do
    queue = :queue.in(value, queue)

    if count < keep do
      {queue, count + 1}
    else
      {{:value, _oldest}, queue} = :queue.out(queue)
      {queue, count}
    end
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
