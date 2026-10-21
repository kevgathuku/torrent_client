defmodule TorrentClient.LogTest do
  @moduledoc """
  The file log handler: installs debug-and-up with level tags, removes
  cleanly, tolerates absence.
  """
  use ExUnit.Case, async: false

  require Logger

  alias TorrentClient.Log

  setup do
    tmp = Path.join(System.tmp_dir(), "kog10-log-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "setup installs a debug file handler with level tags", %{tmp: tmp} do
    path = Path.join([tmp, "nested", "client.log"])
    assert :ok = Log.setup(path)
    assert Log in :logger.get_handler_ids()

    Logger.debug("hello-debug-marker-#{:erlang.unique_integer([:positive])}")
    marker = "hello-debug-marker"

    assert poll_file(path, marker)
    assert Log.remove() == :ok
    refute Log in :logger.get_handler_ids()
  end

  test "remove is a no-op when absent" do
    Log.remove()
    assert Log.remove() == :ok
  end

  test "setup rejects a non-binary path" do
    bad = Enum.at([nil], 0)
    assert_raise FunctionClauseError, fn -> Log.setup(bad) end
  end

  defp poll_file(path, marker) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    poll_until(path, marker, deadline)
  end

  defp poll_until(path, marker, deadline) do
    cond do
      File.exists?(path) and String.contains?(File.read!(path), marker) ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        flunk("log file never contained #{marker}: #{inspect(File.read(path))}")

      true ->
        Process.sleep(50)
        poll_until(path, marker, deadline)
    end
  end
end
