defmodule BackoffTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TorrentClient.Backoff

  test "doubles from the base" do
    assert Backoff.delay(0, 1_000, 30_000) == 1_000
    assert Backoff.delay(1, 1_000, 30_000) == 2_000
    assert Backoff.delay(2, 1_000, 30_000) == 4_000
  end

  test "caps instead of overflowing" do
    assert Backoff.delay(10, 1_000, 30_000) == 30_000
    assert Backoff.delay(100, 1_000, 30_000) == 30_000
  end

  property "never exceeds the cap and never goes negative" do
    check all(
            attempt <- integer(0..1_000),
            base <- integer(1..60_000),
            cap <- integer(1..300_000)
          ) do
      delay = Backoff.delay(attempt, base, cap)
      assert delay >= 0
      assert delay <= cap
    end
  end
end
