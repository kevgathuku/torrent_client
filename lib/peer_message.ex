defmodule PeerMessage do
  @moduledoc """
  BEP-3 peer wire messages as structs, built and parsed with bitstring syntax.

  `encode/1` renders a struct to its length-prefixed wire form.
  `decode/1` consumes exactly one message, returning the rest for the caller
  to loop over — this layer never does stream reassembly. Anything
  malformed is `{:error, reason}`, never a crash.
  """

  @max_block_length 16_384

  defmodule KeepAlive do
    @moduledoc "Zero-length keep-alive."
    defstruct []
  end

  defmodule Choke do
    @moduledoc "Choke: no payload."
    defstruct []
  end

  defmodule Unchoke do
    @moduledoc "Unchoke: no payload."
    defstruct []
  end

  defmodule Interested do
    @moduledoc "Interested: no payload."
    defstruct []
  end

  defmodule NotInterested do
    @moduledoc "Not interested: no payload."
    defstruct []
  end

  defmodule Have do
    @moduledoc "Have: index of the just-completed piece."
    @enforce_keys [:index]
    defstruct [:index]
  end

  defmodule Bitfield do
    @moduledoc "Bitfield: first message, index 0 is the high bit of byte 0."
    @enforce_keys [:bits]
    defstruct [:bits]
  end

  defmodule Request do
    @moduledoc "Request: index, begin offset, length."
    @enforce_keys [:index, :begin, :length]
    defstruct [:index, :begin, :length]
  end

  defmodule Piece do
    @moduledoc "Piece: index, begin offset, block bytes."
    @enforce_keys [:index, :begin, :block]
    defstruct [:index, :begin, :block]
  end

  defmodule Cancel do
    @moduledoc "Cancel: same payload as request."
    @enforce_keys [:index, :begin, :length]
    defstruct [:index, :begin, :length]
  end

  alias __MODULE__.{
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

  @doc "Render a message struct to its length-prefixed wire form."
  def encode(%KeepAlive{}), do: {:ok, <<0::32-big>>}
  def encode(%Choke{}), do: {:ok, <<1::32-big, 0>>}
  def encode(%Unchoke{}), do: {:ok, <<1::32-big, 1>>}
  def encode(%Interested{}), do: {:ok, <<1::32-big, 2>>}
  def encode(%NotInterested{}), do: {:ok, <<1::32-big, 3>>}
  def encode(%Have{index: index}), do: {:ok, <<5::32-big, 4, index::32-big>>}

  def encode(%Bitfield{bits: bits}) do
    {:ok, <<byte_size(bits) + 1::32-big, 5, bits::binary>>}
  end

  def encode(%Request{index: index, begin: begin, length: length}) do
    encode_sized(6, <<index::32-big, begin::32-big, length::32-big>>, length)
  end

  def encode(%Piece{index: index, begin: begin, block: block}) do
    encode_sized(7, <<index::32-big, begin::32-big, block::binary>>, byte_size(block))
  end

  def encode(%Cancel{index: index, begin: begin, length: length}) do
    encode_sized(8, <<index::32-big, begin::32-big, length::32-big>>, length)
  end

  defp encode_sized(id, payload, size) when size in 1..@max_block_length do
    {:ok, <<byte_size(payload) + 1::32-big, id, payload::binary>>}
  end

  defp encode_sized(_id, _payload, _size), do: {:error, :block_out_of_bounds}

  @doc """
  Consume one length-prefixed message, returning the unconsumed rest.
  Malformed input is `{:error, reason}`, never a crash.
  """
  def decode(<<0::32-big, rest::binary>>), do: {:ok, %KeepAlive{}, rest}

  def decode(<<length::32-big, rest::binary>>) do
    if byte_size(rest) >= length and length >= 1 do
      {message, remainder} = :erlang.split_binary(rest, length)
      decode_message(message, remainder)
    else
      {:error, :truncated_message}
    end
  end

  def decode(_binary), do: {:error, :truncated_message}

  defp decode_message(<<0>>, rest), do: {:ok, %Choke{}, rest}
  defp decode_message(<<1>>, rest), do: {:ok, %Unchoke{}, rest}
  defp decode_message(<<2>>, rest), do: {:ok, %Interested{}, rest}
  defp decode_message(<<3>>, rest), do: {:ok, %NotInterested{}, rest}
  defp decode_message(<<4, index::32-big>>, rest), do: {:ok, %Have{index: index}, rest}
  defp decode_message(<<5, bits::binary>>, rest), do: {:ok, %Bitfield{bits: bits}, rest}

  defp decode_message(<<6, index::32-big, begin::32-big, length::32-big>>, rest)
       when length in 1..@max_block_length do
    {:ok, %Request{index: index, begin: begin, length: length}, rest}
  end

  defp decode_message(<<7, index::32-big, begin::32-big, block::binary>>, rest)
       when byte_size(block) in 1..@max_block_length do
    {:ok, %Piece{index: index, begin: begin, block: block}, rest}
  end

  defp decode_message(<<8, index::32-big, begin::32-big, length::32-big>>, rest)
       when length in 1..@max_block_length do
    {:ok, %Cancel{index: index, begin: begin, length: length}, rest}
  end

  defp decode_message(<<6, _::binary>>, _rest), do: {:error, :block_out_of_bounds}
  defp decode_message(<<7, _::binary>>, _rest), do: {:error, :block_out_of_bounds}
  defp decode_message(<<8, _::binary>>, _rest), do: {:error, :block_out_of_bounds}
  defp decode_message(_message, _rest), do: {:error, :unknown_message_id}
end
