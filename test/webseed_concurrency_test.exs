defmodule ConcHttpAgent do
  @moduledoc false
  # Shared mutable state for the concurrency double below: per-URL bodies
  # plus the in-flight gauge. A plain Agent, not Mox: fetch tasks are
  # separate processes and Mox cannot see expectations across the
  # GenServer/task boundary (see the kog.39 notes).
  def start_link(responses) do
    Agent.start_link(fn -> %{responses: responses, in_flight: 0, peak: 0} end, name: __MODULE__)
  end

  def peak, do: Agent.get(__MODULE__, & &1.peak)
end

defmodule ConcHttp do
  @moduledoc false
  # Sleeps long enough that overlapping fetches are a scheduling
  # certainty, not a timing bet; records the peak overlap.
  def get(url, _headers) do
    Agent.update(ConcHttpAgent, fn s ->
      in_flight = s.in_flight + 1
      %{s | in_flight: in_flight, peak: max(s.peak, in_flight)}
    end)

    Process.sleep(150)

    body =
      Agent.get_and_update(ConcHttpAgent, fn s ->
        {Map.fetch!(s.responses, url), %{s | in_flight: s.in_flight - 1}}
      end)

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
    {:ok, _} = ConcHttpAgent.start_link(bodies)

    assert Webseed.fetch_piece(ConcHttp, ["https://x/pub/"], info, 0) ==
             {:ok, bodies[hd(urls)] <> bodies[Enum.at(urls, 1)] <> bodies[List.last(urls)]}

    assert ConcHttpAgent.peak() == 3
  end

  test "six slices stay within the four-wide budget" do
    files = for name <- ~w(a b c d e f), do: %{path: [name], length: 3_000}

    info = %{:"piece length" => 16_384, name: "t", files: files}

    urls = for name <- ~w(a b c d e f), do: "https://x/pub/t/#{name}"
    lengths = [3_000, 3_000, 3_000, 3_000, 3_000, 1_384]
    bodies = responses(urls, lengths)
    {:ok, _} = ConcHttpAgent.start_link(bodies)

    assert {:ok, data} = Webseed.fetch_piece(ConcHttp, ["https://x/pub/"], info, 0)
    assert data == Enum.map_join(urls, &bodies[&1])
    assert ConcHttpAgent.peak() == 4
  end
end
