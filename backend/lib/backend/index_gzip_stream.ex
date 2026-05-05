defmodule Backend.IndexGzipStream do
  @moduledoc false

  def chunk_stream(path) do
    Stream.resource(
      fn -> open_port(path) end,
      &next_chunk/1,
      &close_port/1
    )
  end

  defp open_port(path) do
    gzip = System.find_executable("gzip") || raise "gzip not found"

    port =
      Port.open({:spawn_executable, gzip}, [
        :binary,
        :exit_status,
        args: ["-dc", path]
      ])

    %{port: port, done: false}
  end

  defp next_chunk(%{done: true} = state), do: {:halt, state}

  defp next_chunk(%{port: port} = state) do
    receive do
      {^port, {:data, data}} -> {[data], state}
      {^port, {:exit_status, _status}} -> {:halt, %{state | done: true}}
    after
      30_000 ->
        {:halt, %{state | done: true}}
    end
  end

  defp close_port(%{port: port}) do
    Port.close(port)
  catch
    _, _ -> :ok
  end
end
