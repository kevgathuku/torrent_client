defmodule WebseedStub do
  @moduledoc """
  ETS-backed webseed HTTP double. Fetch tasks run in their own processes,
  so Mox cannot see private expectations across the coordinator/worker/task
  boundary; tests register a per-URL handler fun here instead (the fun may
  close over the test pid, gates, and data — it runs in the task).

  The table is suite-lifetime; keys must be unique per test because async
  tests share it. `calls/1` counts hits per URL so tests keep the exact
  call-count assertions `expect` used to enforce.
  """

  @table __MODULE__

  def start_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  def register(url, fun) when is_binary(url) and is_function(fun, 2) do
    start_table()
    :ets.insert(@table, {url, fun})
    :ets.insert(@table, {{:calls, url}, 0})
    :ok
  end

  def unregister(url) do
    :ets.delete(@table, url)
    :ets.delete(@table, {:calls, url})
    :ok
  end

  def calls(url) do
    case :ets.lookup(@table, {:calls, url}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  def get(url, headers) do
    case :ets.lookup(@table, url) do
      [{_, fun}] ->
        :ets.update_counter(@table, {:calls, url}, 1)
        fun.(url, headers)

      [] ->
        {:error, :no_webseed_stub}
    end
  end
end
