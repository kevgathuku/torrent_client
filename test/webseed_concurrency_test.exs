defmodule ConcHttpAgent do
  @moduledoc false
  # Rendezvous state: tasks park in get/2 until `target` of them are
  # inside at once, then all are released together. `timeouts` counts
  # tasks that gave up waiting (only a sequential fetch does that);
  # `peak` still bounds real overlap after release. A plain Agent, not
  # Mox: fetch tasks are separate processes and Mox cannot see
  # expectations across the GenServer/task boundary (see the kog.39 notes).
  def start_link(responses, target) do
    Agent.start_link(
      fn ->
        %{
          responses: responses,
          target: target,
          arrived: 0,
          released: false,
          waiters: [],
          timeouts: 0,
          in_flight: 0,
          peak: 0
        }
      end,
      name: __MODULE__
    )
  end

  def peak, do: Agent.get(__MODULE__, & &1.peak)
  def timeouts, do: Agent.get(__MODULE__, & &1.timeouts)
end

defmodule ConcHttp do
  @moduledoc false
  # Parks at the gate until the test's expected concurrency is parked
  # alongside, then proceeds with the rest. The short settle keeps real
  # overlap observable for the peak gauge; the rendezvous (not the
  # sleep) carries the proof, and the 5s bound keeps a sequential
  # implementation failing instead of hanging.
  @settle 50
  @wait 5_000

  def get(url, _headers) do
    me = self()

    {body, proceed?} =
      Agent.get_and_update(ConcHttpAgent, fn
        %{released: true} = s ->
          {{Map.fetch!(s.responses, url), true}, s}

        %{arrived: n, target: t} = s when n + 1 >= t ->
          Enum.each(s.waiters, &send(&1, :release))
          {{Map.fetch!(s.responses, url), true}, %{s | arrived: n + 1, released: true}}

        %{arrived: n} = s ->
          {{Map.fetch!(s.responses, url), false},
           %{s | arrived: n + 1, waiters: [me | s.waiters]}}
      end)

    unless proceed? do
      receive do
        :release -> :ok
      after
        @wait -> Agent.update(ConcHttpAgent, &%{&1 | timeouts: &1.timeouts + 1})
      end
    end

    Agent.update(ConcHttpAgent, fn s ->
      in_flight = s.in_flight + 1
      %{s | in_flight: in_flight, peak: max(s.peak, in_flight)}
    end)

    Process.sleep(@settle)

    Agent.update(ConcHttpAgent, fn s -> %{s | in_flight: s.in_flight - 1} end)
    {:ok, %Tesla.Env{status: 206, body: body}}
  end
end

defmodule WebseedConcurrencyTest do
  use ExUnit.Case, async: false

  alias TorrentClient.Webseed

  setup do
    on_exit(fn -> if pid = Process.whereis(ConcHttpAgent), do: Agent.stop(pid) end)
    :ok
  end

  defp responses(urls, lengths) do
    Map.new(Enum.zip(urls, Enum.map(lengths, &:crypto.strong_rand_bytes/1)))
  end

  test "three independent slices fly together" do
    info = %{
      :"piece length" => 16_384,
      name: "t",
      files: [
        %{path: ["a"], length: 8_000},
        %{path: ["b"], length: 8_000},
        %{path: ["c"], length: 8_000}
      ]
    }

    urls = ["https://x/pub/t/a", "https://x/pub/t/b", "https://x/pub/t/c"]
    bodies = responses(urls, [8_000, 8_000, 384])
    {:ok, _} = ConcHttpAgent.start_link(bodies, 3)

    assert Webseed.fetch_piece(ConcHttp, ["https://x/pub/"], info, 0) ==
             {:ok, bodies[hd(urls)] <> bodies[Enum.at(urls, 1)] <> bodies[List.last(urls)]}

    assert ConcHttpAgent.peak() == 3
    assert ConcHttpAgent.timeouts() == 0
  end

  test "six slices stay within the four-wide budget" do
    files = for name <- ~w(a b c d e f), do: %{path: [name], length: 3_000}

    info = %{:"piece length" => 16_384, name: "t", files: files}

    urls = for name <- ~w(a b c d e f), do: "https://x/pub/t/#{name}"
    lengths = [3_000, 3_000, 3_000, 3_000, 3_000, 1_384]
    bodies = responses(urls, lengths)
    {:ok, _} = ConcHttpAgent.start_link(bodies, 4)

    assert {:ok, data} = Webseed.fetch_piece(ConcHttp, ["https://x/pub/"], info, 0)
    assert data == Enum.map_join(urls, &bodies[&1])
    assert ConcHttpAgent.peak() == 4
    assert ConcHttpAgent.timeouts() == 0
  end
end
