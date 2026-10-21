defmodule AnnounceFanoutTest do
  @moduledoc """
  Whole-announce fan-out through injected query funs: concurrent queries,
  maximum-coverage merging, bounded even when every tracker is black-holed.
  Zero real I/O — black holes are sleeps the timeout kills.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TorrentClient.Announcer

  defp peer(a, b, c, d), do: %Peer{ip_tuple: {a, b, c, d}, port: 6881}

  defp query_script(responses) do
    fn url ->
      case Map.fetch!(responses, url) do
        {:peers, peers, interval} -> {:ok, %{peers: peers, interval: interval}}
        {:after, ms, result} -> Process.sleep(ms) && result
        {:error, reason} -> {:error, reason}
        {:sleep, ms} -> Process.sleep(ms)
        {:raise} -> raise "tracker blew up"
      end
    end
  end

  test "merges peers from every answering tracker without stopping on first success" do
    # Slow answerer lands after the fast one: maximum coverage still merges it.
    query =
      query_script(%{
        "fast" => {:peers, [peer(1, 1, 1, 1)], 1800},
        "slow" => {:after, 100, {:ok, %{peers: [peer(2, 2, 2, 2)], interval: 900}}},
        "dead" => {:error, :econnrefused}
      })

    assert {:ok, %{peers: peers, interval: 900}} =
             Announcer.announce_all(["fast", "slow", "dead"], query, timeout: 500)

    assert Enum.sort_by(peers, & &1.ip_tuple) == [peer(1, 1, 1, 1), peer(2, 2, 2, 2)]
  end

  test "dedupes peers reported by several trackers" do
    query =
      query_script(%{
        "a" => {:peers, [peer(1, 1, 1, 1), peer(3, 3, 3, 3)], 900},
        "b" => {:peers, [peer(1, 1, 1, 1)], 900}
      })

    assert {:ok, %{peers: peers}} = Announcer.announce_all(["a", "b"], query, timeout: 500)
    assert Enum.sort_by(peers, & &1.ip_tuple) == [peer(1, 1, 1, 1), peer(3, 3, 3, 3)]
  end

  test "all-black-holed tracker list resolves in bounded time" do
    query =
      query_script(%{"x" => {:sleep, 5_000}, "y" => {:sleep, 5_000}, "z" => {:sleep, 5_000}})

    {elapsed_us, result} =
      :timer.tc(fn -> Announcer.announce_all(["x", "y", "z"], query, timeout: 200) end)

    assert {:ok, %{peers: [], interval: nil}} = result
    assert elapsed_us < 1_000_000
  end

  test "concurrent queries never exceed max_concurrency" do
    {:ok, tracker} = Agent.start_link(fn -> {0, 0} end)

    query = fn _url ->
      Agent.update(tracker, fn {active, peak} -> {active + 1, max(peak, active + 1)} end)
      Process.sleep(100)
      Agent.update(tracker, fn {active, peak} -> {active - 1, peak} end)
      {:ok, %{peers: [], interval: 900}}
    end

    urls = for i <- 1..5, do: "t#{i}"

    assert {:ok, %{peers: []}} =
             Announcer.announce_all(urls, query, max_concurrency: 2, timeout: 5_000)

    assert {0, 2} == Agent.get(tracker, & &1)
  end

  test "raising tracker counts as a failed tracker" do
    query =
      query_script(%{
        "boom" => {:raise},
        "fine" => {:peers, [peer(9, 9, 9, 9)], 900}
      })

    assert {:ok, %{peers: [peer]}} = Announcer.announce_all(["boom", "fine"], query, timeout: 500)
    assert peer == peer(9, 9, 9, 9)
  end

  test "empty tracker list is an error" do
    assert {:error, :no_trackers} =
             Announcer.announce_all([], fn _url -> {:error, :unreachable} end)
  end

  property "arbitrary answer mixes merge exactly the successful peers" do
    check all(
            answers <- list_of(answer_gen(), min_length: 1, max_length: 8),
            max_runs: 50
          ) do
      urls = Enum.with_index(answers, fn _answer, i -> "t#{i}" end)

      responses = Map.new(Enum.zip(urls, answers))

      query = fn url ->
        case Map.fetch!(responses, url) do
          {:ok_peers, peers, interval} -> {:ok, %{peers: peers, interval: interval}}
          {:error, reason} -> {:error, reason}
          {:raise} -> raise "tracker blew up"
        end
      end

      expected =
        answers
        |> Enum.flat_map(fn
          {:ok_peers, peers, _interval} -> peers
          _failed -> []
        end)

      expected_interval =
        answers
        |> Enum.flat_map(fn
          {:ok_peers, _peers, interval} -> [interval]
          _failed -> []
        end)
        |> case do
          [] -> nil
          intervals -> Enum.min(intervals)
        end

      # Arrival order is nondeterministic: compare as sets, interval pinned.
      assert {:ok, %{peers: peers, interval: ^expected_interval}} =
               Announcer.announce_all(urls, query, timeout: 1_000)

      assert MapSet.new(peers, &{&1.ip_tuple, &1.port}) ==
               MapSet.new(expected, &{&1.ip_tuple, &1.port})
    end
  end

  defp answer_gen do
    gen all(
          kind <- member_of([:ok_peers, :error, :raise]),
          peers <- list_of(peer_gen(), max_length: 3),
          interval <- member_of([300, 900, 1800])
        ) do
      case kind do
        :ok_peers -> {:ok_peers, peers, interval}
        :error -> {:error, :econnrefused}
        :raise -> {:raise}
      end
    end
  end

  defp peer_gen do
    gen all(n <- integer(0..7), port <- member_of([6881, 6882])) do
      %Peer{ip_tuple: {10, 0, 0, n}, port: port}
    end
  end
end
