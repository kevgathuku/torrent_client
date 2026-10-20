defmodule PeerState do
  @moduledoc """
  Per-peer posture as pure data: choke/interest flags in both directions plus
  the wire bitfield. Evolves through `handle(state, message)`; selection
  consumes availability via `available_indices/1` as plain index sets, never
  bitstrings.
  """

  import Bitwise

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

  defstruct am_choking: true,
            peer_choking: true,
            am_interested: false,
            peer_interested: false,
            bitfield: <<>>

  @doc "Initial posture: choked and uninterested both ways, nothing known."
  def init, do: %__MODULE__{}

  @doc "Apply an incoming message. Unknown shapes are errors, never crashes."
  def handle(state, %Choke{}), do: {:ok, %{state | peer_choking: true}}
  def handle(state, %Unchoke{}), do: {:ok, %{state | peer_choking: false}}
  def handle(state, %Interested{}), do: {:ok, %{state | peer_interested: true}}
  def handle(state, %NotInterested{}), do: {:ok, %{state | peer_interested: false}}
  def handle(state, %Bitfield{bits: bits}), do: {:ok, %{state | bitfield: bits}}

  def handle(%{bitfield: <<>>} = state, %Have{index: index}) do
    {:ok, %{state | bitfield: set_bit(<<>>, index)}}
  end

  def handle(%{bitfield: bits} = state, %Have{index: index}) do
    if index < bit_size(bits) do
      {:ok, %{state | bitfield: set_bit(bits, index)}}
    else
      {:error, :piece_out_of_range}
    end
  end

  def handle(state, %KeepAlive{}), do: {:ok, state}
  def handle(state, %Request{}), do: {:ok, state}
  def handle(state, %Piece{}), do: {:ok, state}
  def handle(state, %Cancel{}), do: {:ok, state}
  def handle(_state, _message), do: {:error, :unknown_message}

  @doc "Indices the peer has, as a MapSet for selection."
  def available_indices(%{bitfield: bits}) do
    bits
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {byte, pos} ->
      for bit <- 0..7,
          band(byte, 1 <<< (7 - bit)) != 0,
          do: pos * 8 + bit
    end)
    |> MapSet.new()
  end

  defp set_bit(bits, index) do
    pos = div(index, 8)
    padded = bits <> :binary.copy(<<0>>, max(pos + 1 - byte_size(bits), 0))
    {head, <<byte, rest::binary>>} = :erlang.split_binary(padded, pos)
    head <> <<bor(byte, 1 <<< (7 - rem(index, 8)))>> <> rest
  end
end
