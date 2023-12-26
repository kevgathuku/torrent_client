defmodule HandshakeTest do
  use ExUnit.Case

  @extensions <<0, 0, 0, 0, 0, 0, 0, 0>>

  test "correctly serializes the handshake" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"
    h = Handshake.init(info_hash, peer_id)
    assert Handshake.serialize(h) |> byte_size == 68
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
        108 >> <> @extensions <> info_hash <> peer_id <> peer_id

    assert Handshake.deserialize(result) == {:error, :invalid_byte_size}
  end
end
