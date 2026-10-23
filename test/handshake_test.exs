defmodule HandshakeTest do
  use ExUnit.Case

  @extensions <<0, 0, 0, 0, 0, 0, 0, 0>>

  test "correctly serializes the handshake" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"
    h = Handshake.init(info_hash, peer_id)
    assert Handshake.serialize(h) |> byte_size == 68
  end

  test "serializes BEP-3's exact protocol identifier" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"
    h = Handshake.init(info_hash, peer_id)
    # Lowercase 'p': strict peers drop anything else, so the bytes
    # themselves are asserted, not just the length.
    assert Handshake.serialize(h) ==
             <<19>> <> "BitTorrent protocol" <> @extensions <> info_hash <> peer_id
  end

  test "correctly deserializes a stream" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"

    result =
      <<19, 66, 105, 116, 84, 111, 114, 114, 101, 110, 116, 32, 112, 114, 111, 116, 111, 99, 111,
        108>> <> @extensions <> info_hash <> peer_id

    assert Handshake.deserialize(result) == {:ok, Handshake.init(info_hash, peer_id)}
  end

  test "returns error given an invalid stream" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"

    result =
      <<19, 66, 105, 116, 84, 111, 114, 114, 101, 110, 116, 32, 112, 114, 111, 116, 111, 99, 111,
        108>> <> @extensions <> info_hash <> peer_id <> peer_id

    assert Handshake.deserialize(result) == {:error, :invalid_byte_size}
  end

  test "rejects a bogus length prefix instead of crashing" do
    # pstrlen 0 in a 68-byte stream: the old match would raise MatchError.
    assert Handshake.deserialize(<<0>> <> :binary.copy(<<0>>, 67)) ==
             {:error, :bad_handshake}
  end
end
