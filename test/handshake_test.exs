defmodule HandshakeTest do
  use ExUnit.Case

  test "correctly serializes the handshake" do
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"
    h = Handshake.init(info_hash, peer_id)
    assert Handshake.serialize(h) |> byte_size == 68
  end

  test "correctly deserializes a stream" do
    extensions = <<0, 0, 0, 0, 0, 0, 0, 0>>
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"

    result =
      <<19, 66, 105, 116, 84, 111, 114, 114, 101, 110, 116, 32, 112, 114, 111, 116, 111, 99, 111,
        108, 0, 0, 0, 0, 0, 0, 0, 0>> <> info_hash <> peer_id

    assert Handshake.deserialize(result) == {:ok, Handshake.init(info_hash, peer_id)}
  end

  test "returns error given an invalid stream" do
    extensions = <<0, 0, 0, 0, 0, 0, 0, 0>>
    peer_id = "ffffffffffffffffffff"
    info_hash = "eeeeeeeeeeeeeeeeeeee"

    result =
      <<19, 66, 105, 116, 84, 111, 114, 114, 101, 110, 116, 32, 112, 114, 111, 116, 111, 99, 111,
        108, 0, 0, 0, 0, 0, 0, 0, 0>> <> info_hash <> peer_id <> peer_id

    assert Handshake.deserialize(result) == {:error, :invalid_byte_size}
  end
end
