defmodule TorrentClient.ApplicationTest do
  use ExUnit.Case, async: false

  test "supervision tree hosts a Registry and a session supervisor" do
    children =
      TorrentClient.Application
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
      |> Enum.sort()

    assert children == [TorrentClient.Registry, TorrentClient.SessionSupervisor]
  end

  test "two children start under distinct registry keys without already_started" do
    start_named = fn key ->
      child = %{
        id: {{:named_probe}, key},
        start:
          {Agent, :start_link,
           [fn -> %{} end, [name: {:via, Registry, {TorrentClient.Registry, key}}]]},
        restart: :temporary
      }

      DynamicSupervisor.start_child(TorrentClient.SessionSupervisor, child)
    end

    assert {:ok, pid_a} = start_named.("torrent-a")
    assert {:ok, pid_b} = start_named.("torrent-b")
    assert pid_a != pid_b

    assert [{^pid_a, _}] = Registry.lookup(TorrentClient.Registry, "torrent-a")
    assert [{^pid_b, _}] = Registry.lookup(TorrentClient.Registry, "torrent-b")

    on_exit(fn ->
      DynamicSupervisor.terminate_child(TorrentClient.SessionSupervisor, pid_a)
      DynamicSupervisor.terminate_child(TorrentClient.SessionSupervisor, pid_b)
    end)
  end
end
