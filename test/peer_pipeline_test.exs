defmodule PeerPipelineTest do
  @moduledoc """
  Per-peer congestion state as pure data: latency exponentially weighted
  moving average, additive-increase / multiplicative-decrease depth, and
  the receive timeout derived from them.
  """
  use ExUnit.Case, async: true

  alias TorrentClient.PeerPipeline

  test "starts at depth 5 bounded by the cap" do
    assert %{depth: 5, max_depth: 16} = PeerPipeline.init(16)
    assert %{depth: 2, max_depth: 2} = PeerPipeline.init(2)
  end

  test "first sample seeds the average, later ones blend at quarter weight" do
    pipe = PeerPipeline.init(16) |> PeerPipeline.note_received(0, 400)
    assert pipe.ewma == 400

    pipe = PeerPipeline.note_received(pipe, 400, 1_200)
    assert pipe.ewma == 500.0
  end

  test "depth grows one per window of sustained receipts, capped at max" do
    pipe = PeerPipeline.init(6)

    # Five receipts fill the window at depth 5, the sixth is not needed:
    # growth fires on the fifth.
    pipe = Enum.reduce(1..5, pipe, fn i, p -> PeerPipeline.note_received(p, 0, i) end)
    assert pipe.depth == 6

    # At the cap growth stops instead of overshooting.
    pipe = Enum.reduce(1..20, pipe, fn i, p -> PeerPipeline.note_received(p, 0, i) end)
    assert pipe.depth == 6
  end

  test "a timeout halves depth (floor 1) and resets the growth count" do
    pipe = PeerPipeline.init(16)

    pipe = Enum.reduce(1..5, pipe, fn i, p -> PeerPipeline.note_received(p, 0, i) end)
    assert pipe.depth == 6

    assert %{depth: 3} = PeerPipeline.note_timeout(pipe)
    assert %{depth: 1} = pipe |> PeerPipeline.note_timeout() |> PeerPipeline.note_timeout()
  end

  test "timeouts count consecutively and receipts reset the count" do
    pipe = PeerPipeline.init(16)

    pipe = pipe |> PeerPipeline.note_timeout() |> PeerPipeline.note_timeout()
    assert pipe.consecutive_timeouts == 2

    pipe = PeerPipeline.note_received(pipe, 0, 10)
    assert pipe.consecutive_timeouts == 0
  end

  test "receive timeout is three times the average, floored and capped" do
    # No samples yet: the configured ceiling applies untouched.
    assert PeerPipeline.recv_timeout(PeerPipeline.init(16), 10_000) == 10_000

    # Fast peer: 3x90ms would be 270ms, floored to a full second.
    pipe = PeerPipeline.init(16) |> PeerPipeline.note_received(0, 90)
    assert PeerPipeline.recv_timeout(pipe, 10_000) == 1_000

    # Ordinary peer: triple the average.
    pipe = PeerPipeline.init(16) |> PeerPipeline.note_received(0, 2_000)
    assert PeerPipeline.recv_timeout(pipe, 10_000) == 6_000

    # Slow peer: capped at the configured ceiling, never above it.
    pipe = PeerPipeline.init(16) |> PeerPipeline.note_received(0, 9_000)
    assert PeerPipeline.recv_timeout(pipe, 2_000) == 2_000
  end

  test "first byte due only when nothing arrived within the budget" do
    pipe = PeerPipeline.init(16)

    refute PeerPipeline.first_byte_due?(pipe, 0, 4_999, 5_000)
    assert PeerPipeline.first_byte_due?(pipe, 0, 5_000, 5_000)

    # One block resets the deadline forever.
    pipe = PeerPipeline.note_received(pipe, 0, 100)
    refute PeerPipeline.first_byte_due?(pipe, 0, 60_000, 5_000)
  end
end
