defmodule DownloadStateTest do
  @moduledoc """
  Pure allocation rules: rarest-first over eligible-holder counts,
  in-flight tracking, endgame duplication, requeue, and stall state.
  """
  use ExUnit.Case, async: true

  alias DownloadState

  defp counts(pairs), do: Map.new(pairs)

  test "init tracks nothing verified or in flight" do
    state = DownloadState.init(3)
    assert DownloadState.needed(state) == MapSet.new([0, 1, 2])
    refute DownloadState.complete?(state)
    refute DownloadState.endgame?(state)
  end

  test "empty torrent assigns nothing and never completes" do
    state = DownloadState.init(0)
    assert DownloadState.needed(state) == MapSet.new()
    refute DownloadState.complete?(state)
    assert {:error, :no_available_piece} = DownloadState.assign(state, %{})
  end

  test "assign picks the rarest available piece" do
    state = DownloadState.init(3)
    assert {:ok, 1, state} = DownloadState.assign(state, counts([{0, 5}, {1, 1}, {2, 3}]))
    assert DownloadState.needed(state) == MapSet.new([0, 2])
  end

  test "assign breaks rarity ties by lowest index" do
    state = DownloadState.init(3)
    assert {:ok, 0, _} = DownloadState.assign(state, counts([{0, 2}, {1, 2}, {2, 2}]))
  end

  test "assign treats unreported pieces as universally available, picked last" do
    state = DownloadState.init(3)
    assert {:ok, 0, _} = DownloadState.assign(state, counts([{0, 1}]))
  end

  test "assign skips pieces nobody eligible holds" do
    state = DownloadState.init(2)
    assert {:ok, 1, _} = DownloadState.assign(state, counts([{0, 0}, {1, 2}]))
    assert {:error, :no_available_piece} = DownloadState.assign(state, counts([{0, 0}, {1, 0}]))
  end

  test "assign never repeats an in-flight or verified piece while needed remain" do
    state = DownloadState.init(2)
    {:ok, 0, state} = DownloadState.assign(state, counts([{0, 1}, {1, 1}]))
    assert {:ok, 1, state} = DownloadState.assign(state, counts([{0, 1}, {1, 1}]))
    assert DownloadState.endgame?(state)
  end

  test "endgame duplicates an in-flight piece instead of erroring" do
    state = DownloadState.init(1)
    {:ok, 0, state} = DownloadState.assign(state, counts([{0, 1}]))
    assert DownloadState.endgame?(state)
    assert {:ok, 0, _} = DownloadState.assign(state, counts([{0, 1}]))
  end

  test "complete marks verified and clears in-flight" do
    state = DownloadState.init(1)
    {:ok, 0, state} = DownloadState.assign(state, counts([{0, 1}]))
    state = DownloadState.complete(state, 0)
    assert DownloadState.complete?(state)
    refute DownloadState.endgame?(state)
    assert {:error, :complete} = DownloadState.assign(state, %{})
  end

  test "complete is idempotent for duplicate workers finishing together" do
    state = DownloadState.init(1)
    state = DownloadState.complete(state, 0)
    assert %DownloadState{} = DownloadState.complete(state, 0)
    assert DownloadState.complete?(state)
  end

  test "requeue returns an in-flight piece to needed" do
    state = DownloadState.init(2)
    {:ok, 0, state} = DownloadState.assign(state, counts([{0, 1}, {1, 1}]))
    state = DownloadState.requeue(state, 0)
    refute DownloadState.endgame?(state)
    assert {:ok, 0, _} = DownloadState.assign(state, counts([{0, 1}, {1, 1}]))
  end

  test "requeue of an idle piece is a no-op" do
    state = DownloadState.init(1)
    assert %DownloadState{} = DownloadState.requeue(state, 0)
  end

  test "stall state starts un-stalled and trips after a quiet window" do
    now = 1_000_000
    state = DownloadState.init(1)
    # No progress ever stamped: not stalled, just unknown.
    refute DownloadState.stalled?(state, now + 10_000, 100)
    state = DownloadState.note_progress(state, now)
    refute DownloadState.stalled?(state, now + 99, 100)
    assert DownloadState.stalled?(state, now + 100, 100)
    assert DownloadState.stalled?(state, now + 10_000, 100)
  end

  test "progress resets the stall window" do
    state = DownloadState.init(1) |> DownloadState.note_progress(0)
    assert DownloadState.stalled?(state, 10_000, 100)
    state = DownloadState.note_progress(state, 10_000)
    refute DownloadState.stalled?(state, 10_050, 100)
  end
end
