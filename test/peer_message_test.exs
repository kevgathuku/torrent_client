defmodule PeerMessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  describe "control messages and keep-alive" do
    test "keep-alive encodes to four zero bytes" do
      assert PeerMessage.encode(%KeepAlive{}) == {:ok, <<0, 0, 0, 0>>}
    end

    test "control messages encode to length 1 plus id" do
      assert PeerMessage.encode(%Choke{}) == {:ok, <<0, 0, 0, 1, 0>>}
      assert PeerMessage.encode(%Unchoke{}) == {:ok, <<0, 0, 0, 1, 1>>}
      assert PeerMessage.encode(%Interested{}) == {:ok, <<0, 0, 0, 1, 2>>}
      assert PeerMessage.encode(%NotInterested{}) == {:ok, <<0, 0, 0, 1, 3>>}
    end

    test "decode consumes one message and returns the rest" do
      assert PeerMessage.decode(<<0, 0, 0, 1, 0, 0, 0, 0, 1, 1>>) ==
               {:ok, %Choke{}, <<0, 0, 0, 1, 1>>}
    end

    test "empty input is an error, not a crash" do
      assert {:error, _} = PeerMessage.decode(<<>>)
    end

    property "control messages round-trip" do
      check all(
              msg <-
                member_of([%KeepAlive{}, %Choke{}, %Unchoke{}, %Interested{}, %NotInterested{}])
            ) do
        assert {:ok, bin} = PeerMessage.encode(msg)
        assert PeerMessage.decode(bin) == {:ok, msg, <<>>}
      end
    end
  end

  describe "have and bitfield" do
    test "have carries a 4-byte piece index" do
      assert PeerMessage.decode(<<0, 0, 0, 5, 4, 0, 0, 0, 7>>) ==
               {:ok, %Have{index: 7}, <<>>}

      assert PeerMessage.encode(%Have{index: 7}) == {:ok, <<0, 0, 0, 5, 4, 0, 0, 0, 7>>}
    end

    test "bitfield carries raw bytes" do
      assert PeerMessage.decode(<<0, 0, 0, 2, 5, 0xFF>>) == {:ok, %Bitfield{bits: <<0xFF>>}, <<>>}
    end

    test "short have payload is an error" do
      assert {:error, _} = PeerMessage.decode(<<0, 0, 0, 4, 4, 0, 0, 0>>)
    end

    test "unknown message id is an error" do
      assert {:error, _} = PeerMessage.decode(<<0, 0, 0, 1, 9>>)
    end

    test "truncated message is an error" do
      assert {:error, _} = PeerMessage.decode(<<0, 0, 0, 5, 4, 0>>)
    end

    test "bitfield spare bits are accepted liberally" do
      # Receivers do not enforce zeroed spare bits; piece count is unknown here.
      assert {:ok, %Bitfield{}, <<>>} = PeerMessage.decode(<<0, 0, 0, 2, 5, 0xFF>>)
    end

    property "have and bitfield round-trip" do
      check all(
              index <- integer(0..1_000_000),
              bits <- binary(min_length: 0, max_length: 64)
            ) do
        assert {:ok, have_bin} = PeerMessage.encode(%Have{index: index})
        assert PeerMessage.decode(have_bin) == {:ok, %Have{index: index}, <<>>}

        assert {:ok, bitfield_bin} = PeerMessage.encode(%Bitfield{bits: bits})
        assert PeerMessage.decode(bitfield_bin) == {:ok, %Bitfield{bits: bits}, <<>>}
      end
    end
  end

  describe "request, piece and cancel" do
    test "request carries index, begin and length" do
      msg = %Request{index: 3, begin: 0, length: 16_384}
      assert {:ok, bin} = PeerMessage.encode(msg)
      assert bin == <<0, 0, 0, 13, 6, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 64, 0>>
      assert PeerMessage.decode(bin) == {:ok, msg, <<>>}
    end

    test "piece carries index, begin and block" do
      msg = %Piece{index: 3, begin: 0, block: <<1, 2, 3>>}
      assert {:ok, bin} = PeerMessage.encode(msg)
      assert PeerMessage.decode(bin) == {:ok, msg, <<>>}
    end

    test "cancel mirrors request" do
      msg = %Cancel{index: 3, begin: 0, length: 1024}
      assert {:ok, bin} = PeerMessage.encode(msg)
      assert PeerMessage.decode(bin) == {:ok, msg, <<>>}
    end

    test "oversize request is rejected on encode" do
      assert {:error, _} = PeerMessage.encode(%Request{index: 0, begin: 0, length: 16_385})
    end

    test "oversize piece block is rejected on encode" do
      assert {:error, _} =
               PeerMessage.encode(%Piece{index: 0, begin: 0, block: :binary.copy(<<0>>, 16_385)})
    end

    test "oversize request is rejected on decode" do
      # length prefix 13, id 6, length field 32768
      bin = <<0, 0, 0, 13, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0>>
      assert {:error, _} = PeerMessage.decode(bin)
    end

    test "empty piece block is rejected on decode" do
      bin = <<0, 0, 0, 9, 7, 0, 0, 0, 0, 0, 0, 0, 0>>
      assert {:error, _} = PeerMessage.decode(bin)
    end

    property "request, piece and cancel round-trip within the block cap" do
      check all(
              index <- integer(0..1_000_000),
              begin <- integer(0..1_000_000),
              length <- integer(1..16_384),
              block <- binary(min_length: 1, max_length: 4096)
            ) do
        for msg <- [
              %Request{index: index, begin: begin, length: length},
              %Piece{index: index, begin: begin, block: block},
              %Cancel{index: index, begin: begin, length: length}
            ] do
          assert {:ok, bin} = PeerMessage.encode(msg)
          assert PeerMessage.decode(bin) == {:ok, msg, <<>>}
        end
      end
    end
  end

  describe "fail-closed decoding" do
    property "truncating any suffix is rejected" do
      check all({bin, drop} <- truncation_case()) do
        assert {:error, _} = PeerMessage.decode(:binary.part(bin, 0, byte_size(bin) - drop))
      end
    end

    property "corrupting the length prefix is rejected" do
      check all({bin, bad_first} <- prefix_case()) do
        <<_first, rest::binary>> = bin
        assert {:error, _} = PeerMessage.decode(<<bad_first, rest::binary>>)
      end
    end

    property "decode never raises on arbitrary bytes" do
      check all(bytes <- binary(max_length: 64)) do
        assert (case PeerMessage.decode(bytes) do
                  {:ok, _, _} -> true
                  {:error, _} -> true
                end)
      end
    end
  end

  defp truncation_case do
    gen all(
          bin <- valid_message_binary(),
          drop <- integer(1..byte_size(bin))
        ) do
      {bin, drop}
    end
  end

  defp prefix_case do
    gen all(
          bin <- valid_message_binary(),
          bad_first <- integer(1..255)
        ) do
      {bin, bad_first}
    end
  end

  defp valid_message_binary do
    gen all(msg <- valid_message()) do
      {:ok, bin} = PeerMessage.encode(msg)
      bin
    end
  end

  defp valid_message do
    one_of([
      constant(%KeepAlive{}),
      member_of([%Choke{}, %Unchoke{}, %Interested{}, %NotInterested{}]),
      gen all(index <- integer(0..1000)) do
        %Have{index: index}
      end,
      gen all(bits <- binary(min_length: 0, max_length: 8)) do
        %Bitfield{bits: bits}
      end,
      gen all(
            index <- integer(0..1000),
            begin <- integer(0..1000),
            length <- integer(1..16_384)
          ) do
        %Request{index: index, begin: begin, length: length}
      end,
      gen all(
            index <- integer(0..1000),
            begin <- integer(0..1000),
            length <- integer(1..16_384)
          ) do
        %Cancel{index: index, begin: begin, length: length}
      end,
      gen all(
            index <- integer(0..1000),
            begin <- integer(0..1000),
            block <- binary(min_length: 1, max_length: 256)
          ) do
        %Piece{index: index, begin: begin, block: block}
      end
    ])
  end
end
