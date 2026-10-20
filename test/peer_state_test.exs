defmodule PeerStateTest do
  use ExUnit.Case, async: true

  alias PeerMessage.{
    Bitfield,
    Cancel,
    Choke,
    Have,
    Interested,
    KeepAlive,
    NotInterested,
    Piece,
    Request,
    Unchoke
  }

  test "starts choked and uninterested with no pieces" do
    assert PeerState.init() == %PeerState{
             am_choking: true,
             peer_choking: true,
             am_interested: false,
             peer_interested: false,
             bitfield: <<>>
           }
  end

  test "choke and unchoke move peer_choking" do
    assert {:ok, %{peer_choking: false}} = PeerState.init() |> PeerState.handle(%Unchoke{})

    state = %PeerState{PeerState.init() | peer_choking: false}
    assert {:ok, %{peer_choking: true}} = PeerState.handle(state, %Choke{})
  end

  test "interest moves peer_interested" do
    assert {:ok, %{peer_interested: true}} = PeerState.init() |> PeerState.handle(%Interested{})

    state = %PeerState{PeerState.init() | peer_interested: true}
    assert {:ok, %{peer_interested: false}} = PeerState.handle(state, %NotInterested{})
  end

  test "have sets the bit in the known bitfield" do
    {:ok, state} = PeerState.init() |> PeerState.handle(%Bitfield{bits: <<0x00, 0x00>>})
    assert {:ok, %{bitfield: <<0x00, 0x02>>}} = PeerState.handle(state, %Have{index: 14})
  end

  test "have grows an unknown (empty) bitfield" do
    assert {:ok, %{bitfield: <<0x40>>}} = PeerState.init() |> PeerState.handle(%Have{index: 1})
  end

  test "have beyond a known bitfield is an error" do
    {:ok, state} = PeerState.init() |> PeerState.handle(%Bitfield{bits: <<0x00>>})
    assert {:error, _} = PeerState.handle(state, %Have{index: 9})
  end

  test "bitfield replaces the previous one" do
    {:ok, state} = PeerState.init() |> PeerState.handle(%Bitfield{bits: <<0xFF>>})
    assert {:ok, %{bitfield: <<0x00>>}} = PeerState.handle(state, %Bitfield{bits: <<0x00>>})
  end

  test "bitfield converts to an index set for selection" do
    {:ok, state} =
      PeerState.init() |> PeerState.handle(%Bitfield{bits: <<0b10100000, 0b00000001>>})

    assert PeerState.available_indices(state) == MapSet.new([0, 2, 15])
  end

  test "unknown message shapes are errors" do
    assert {:error, :unknown_message} = PeerState.handle(PeerState.init(), :bogus)
  end

  test "transfer messages leave posture unchanged" do
    state = PeerState.init()

    for msg <- [
          %KeepAlive{},
          %Request{index: 0, begin: 0, length: 1},
          %Piece{index: 0, begin: 0, block: <<1>>},
          %Cancel{index: 0, begin: 0, length: 1}
        ] do
      assert {:ok, ^state} = PeerState.handle(state, msg)
    end
  end
end
