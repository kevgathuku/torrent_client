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
    child = fn key ->
      %{
        id: {Agent, key},
        start:
          {Agent, :start_link,
           [fn -> %{} end, [name: {:via, Registry, {TorrentClient.Registry, key}}]]}
      }
    end

    pid_a = start_supervised!(child.("torrent-a"))
    pid_b = start_supervised!(child.("torrent-b"))
    assert pid_a != pid_b

    assert [{^pid_a, _}] = Registry.lookup(TorrentClient.Registry, "torrent-a")
    assert [{^pid_b, _}] = Registry.lookup(TorrentClient.Registry, "torrent-b")
  end
end
