defmodule PeerSupervisorTest do
  @moduledoc """
  The peer supervisor through the real supervisor: unnamed children,
  crash restarts with a fresh worker, and a bounded restart storm.
  """
  use ExUnit.Case, async: true

  import Mox

  setup :set_mox_private
  setup :verify_on_exit!

  alias TorrentClient.PeerSupervisor

  defp worker_opts(extra \\ []) do
    Keyword.merge(
      [
        peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: 1},
        info_hash: :crypto.strong_rand_bytes(20),
        peer_id: String.duplicate("T", 20),
        info: %{:"piece length" => 16_384, name: "f.bin", length: 16_384},
        piece_index: 0,
        piece_hash: :crypto.hash(:sha, :binary.copy(<<0>>, 16_384)),
        base_dir: System.tmp_dir!(),
        network: TorrentClient.NetworkMock
      ],
      extra
    )
  end

  defp child_pid(supervisor) do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(supervisor)
    pid
  end

  defp await_new_child(supervisor, old_pid) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case DynamicSupervisor.which_children(supervisor) do
        [{_, ^old_pid, _, _}] ->
          Process.sleep(20)
          {:cont, nil}

        [{_, pid, _, _}] ->
          {:halt, pid}
      end
    end)
  end

  test "starts unnamed workers" do
    stub(TorrentClient.NetworkMock, :connect, fn _peer ->
      receive do
      after
        5_000 -> {:error, :hang}
      end
    end)

    supervisor = start_supervised!(PeerSupervisor)
    {:ok, pid} = PeerSupervisor.start_peer(supervisor, worker_opts())

    assert Process.info(pid, :registered_name) == {:registered_name, []}
    assert child_pid(supervisor) == pid
  end

  test "crashed workers restart under the supervisor" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # First connection hands back a dead socket (the worker stops
    # fail-closed); the restarted worker blocks, so no storm follows.
    stub(TorrentClient.NetworkMock, :connect, fn _peer ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
        {:ok, :bogus}
      else
        receive do
        after
          5_000 -> {:error, :hang}
        end
      end
    end)

    supervisor = start_supervised!(PeerSupervisor)
    {:ok, pid} = PeerSupervisor.start_peer(supervisor, worker_opts())
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:send_failed, :badarg}}, 2_000

    new_pid = await_new_child(supervisor, pid)
    assert is_pid(new_pid) and new_pid != pid
    assert Process.alive?(new_pid)
  end

  test "restart storm is bounded by the supervisor intensity" do
    stub(TorrentClient.NetworkMock, :connect, fn _peer -> {:ok, :bogus} end)

    Process.flag(:trap_exit, true)
    {:ok, supervisor} = PeerSupervisor.start_link()
    ref = Process.monitor(supervisor)

    {:ok, _pid} = PeerSupervisor.start_peer(supervisor, worker_opts())

    assert_receive {:DOWN, ^ref, :process, ^supervisor, :shutdown}, 5_000
  end
end
