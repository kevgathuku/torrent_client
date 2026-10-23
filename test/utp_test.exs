defmodule TorrentClient.UtpTest do
  use ExUnit.Case, async: true

  alias TorrentClient.Utp

  # BEP-29 wire shapes, quoted byte-for-byte from the spec's header diagram:
  # byte0 = type (high nibble) | version (low nibble), all big-endian.

  test "encodes the 20-byte header in network order" do
    header = %{
      type: :syn,
      conn_id: 0x1234,
      ts: 0xAABBCCDD,
      ts_diff: 0x11223344,
      wnd: 0x00010000,
      seq: 1,
      ack: 0
    }

    assert Utp.encode(header, []) ==
             <<0x41, 0x00, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44, 0x00, 0x01,
               0x00, 0x00, 0x00, 0x01, 0x00, 0x00>>
  end

  test "decodes a header and passes the payload through" do
    bytes =
      <<0x01, 0x00, 0x00, 0x7B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0x05, 0x00, 0x03, "hello">>

    assert {:ok, header, "hello"} = Utp.decode(bytes)

    assert header == %{
             type: :data,
             conn_id: 123,
             ts: 1,
             ts_diff: 0,
             wnd: 0x100000,
             seq: 5,
             ack: 3,
             sack: []
           }
  end

  test "type atoms round-trip through the high nibble" do
    for {atom, int} <- [data: 0, fin: 1, state: 2, reset: 3, syn: 4] do
      header = %{type: atom, conn_id: 0, ts: 0, ts_diff: 0, wnd: 0, seq: 0, ack: 0}
      assert {:ok, %{type: ^atom}, <<>>} = header |> Utp.encode([]) |> Utp.decode()
      assert int == Utp.type_to_int(atom)
    end
  end

  test "selective ack bitmask is LSB-first from ack_nr + 2" do
    # ack = 10, received {12, 14}: bits 0 and 2 set -> 0b00000101.
    assert Utp.sack_encode(10, MapSet.new([12, 14]), 4) == <<0b00000101, 0, 0, 0>>

    header = %{type: :state, conn_id: 9, ts: 0, ts_diff: 0, wnd: 0, seq: 0, ack: 10}

    assert {:ok, %{sack: [12, 14]}, <<>>} =
             header
             |> Utp.encode(sack: MapSet.new([12, 14]))
             |> Utp.decode()
  end

  test "sack spans multiple mask words" do
    received = MapSet.new([12, 40, 41])

    assert {:ok, %{sack: [12, 40, 41]}, <<>>} =
             %{type: :state, conn_id: 0, ts: 0, ts_diff: 0, wnd: 0, seq: 0, ack: 10}
             |> Utp.encode(sack: received)
             |> Utp.decode()
  end

  test "unknown extensions are skipped, not rejected" do
    header = %{type: :state, conn_id: 1, ts: 0, ts_diff: 0, wnd: 0, seq: 0, ack: 0}
    # Extension 9 (unknown), length 3, then terminator-less end.
    raw = Utp.encode(header, raw_ext: [{9, <<1, 2, 3>>}])
    assert {:ok, %{sack: []}, <<>>} = Utp.decode(raw)
  end

  test "sequence arithmetic wraps the 16-bit ring" do
    assert Utp.seq_lt(0xFFFF, 0)
    refute Utp.seq_lt(0, 0xFFFF)
    refute Utp.seq_lt(7, 7)
    assert Utp.seq_lt(100, 200)
    refute Utp.seq_lt(200, 100)
    assert Utp.in_window?(11, 10, 5)
    refute Utp.in_window?(10, 10, 5)
    refute Utp.in_window?(16, 10, 5)
    assert Utp.in_window?(0, 0xFFFF, 5)
  end

  test "rtt and timeout follow the spec formulas" do
    assert Utp.initial_timeout_ms() == 1_000
    assert Utp.min_window_bytes() == 150
    {rtt, var} = Utp.rtt_update(0, 0, 80)
    assert_in_delta rtt, 10.0, 0.001
    assert_in_delta var, 20.0, 0.001
    # Floor: tiny samples still time out at 500 ms.
    assert Utp.timeout_for(0, 0) == 500
    assert Utp.timeout_for(100, 50) == 500
    assert Utp.timeout_for(400, 50) == 600
  end

  test "ledbat drives the window toward the 100 ms target" do
    mss = 1_400
    # No queueing delay: window grows.
    assert Utp.ledbat_update(1_400, 1_400, 0, mss) > 1_400
    # Past the target: window shrinks.
    assert Utp.ledbat_update(10_000, 10_000, 200_000, mss) < 10_000
    # Crushing delay never breaches the floor.
    assert Utp.ledbat_update(150, 150, 10_000_000, mss) == 150
  end

  test "malformed packets fail closed" do
    assert {:error, :too_short} = Utp.decode(<<1, 2, 3>>)
    # Version 2 is not ours.
    assert {:error, {:bad_version, 2}} =
             Utp.decode(<<0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)

    assert {:error, :unknown_type} =
             Utp.decode(<<0x71, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>)

    # Truncated extension header (one byte past the 20-byte header).
    assert {:error, :bad_extension} = Utp.decode(<<0x21, 1, 0::152>>)
    # SACK length not a multiple of 4.
    assert {:error, :bad_sack} = Utp.decode(<<0x21, 1, 0::144>> <> <<0, 3, 9, 9, 9>>)
  end
end
