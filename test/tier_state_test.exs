defmodule TierStateTest do
  use ExUnit.Case, async: true

  alias TorrentClient.TierState

  test "walks tiers in order" do
    state = TierState.new([["a", "b"], ["c"]])

    assert {:ok, "a", state} = TierState.next(state)
    assert {:ok, "a", _} = TierState.next(state)
  end

  test "failure advances within the tier, then to the next tier" do
    state = TierState.new([["a", "b"], ["c"]])

    {:ok, "a", state} = TierState.next(state)
    {:ok, state} = TierState.report(state, :error, "a")
    assert {:ok, "b", state} = TierState.next(state)

    {:ok, state} = TierState.report(state, :error, "b")
    assert {:ok, "c", _} = TierState.next(state)
  end

  test "exhaustion is an error" do
    state = TierState.new([["a"]])

    {:ok, "a", state} = TierState.next(state)
    {:ok, state} = TierState.report(state, :error, "a")
    assert {:error, :exhausted} = TierState.next(state)
  end

  test "success moves the tracker to the front and restarts order" do
    state = TierState.new([["a", "b"], ["c"]])

    {:ok, "a", state} = TierState.next(state)
    {:ok, state} = TierState.report(state, :error, "a")
    {:ok, "b", state} = TierState.next(state)
    {:ok, state} = TierState.report(state, :ok, "b")

    assert {:ok, "b", _} = TierState.next(state)
  end

  test "empty tiers exhaust immediately" do
    assert {:error, :exhausted} = TierState.new([]) |> TierState.next()
    assert {:error, :exhausted} = TierState.new([[], []]) |> TierState.next()
  end
end
