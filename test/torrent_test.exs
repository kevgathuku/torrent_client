defmodule TorrentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @multi_file_torrent TestHelpers.multi_file_torrent()
  @single_file_torrent TestHelpers.single_file_torrent()

  test "calculates the correct info hash for single file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@single_file_torrent)
    info_hash = Torrent.info_hash(bento_torrent)

    assert info_hash == "A9164E99D5181CFEF0C23C209334103619080908"
  end

  test "calculates the correct info hash for multi file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@multi_file_torrent)
    info_hash = Torrent.info_hash(bento_torrent)

    assert info_hash == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C"
  end

  test "get piece hashes for a single file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@single_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "get piece hashes for a multi file torrent" do
    {:ok, bento_torrent} = Downloader.parse_torrent_file(@multi_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "verifies data against its SHA1 hash" do
    hash = Utils.sha_sum("piece bytes")

    assert Torrent.verify_hash?("piece bytes", hash) == true
    assert Torrent.verify_hash?("tampered bytes", hash) == false
  end

  test "announce tiers fall back to announce when the list is empty" do
    {:ok, bento} = TestHelpers.single_file_torrent() |> Downloader.parse_torrent_file()

    assert Torrent.announce_tiers(bento) == [[bento.announce]]
  end

  test "announce tiers preserve tier structure" do
    {:ok, bento} =
      "test/_data/manjaro-gnome-17.1.9-stable-x86_64.torrent" |> Downloader.parse_torrent_file()

    assert Torrent.announce_tiers(bento) == [
             ["http://linuxtracker.org:2710/00000000000000000000000000000000/announce"],
             ["udp://mirror.strits.dk:6969"]
           ]
  end

  describe "validate_block/4" do
    setup do
      {:ok, bento} = TestHelpers.single_file_torrent() |> Downloader.parse_torrent_file()
      %{info: bento.info}
    end

    test "accepts a block inside the first piece", %{info: info} do
      assert Torrent.validate_block(info, 0, 0, <<1, 2, 3>>) == :ok
    end

    test "rejects an out-of-range piece", %{info: info} do
      assert {:error, _} = Torrent.validate_block(info, 1_000_000, 0, <<1>>)
    end

    test "rejects a block overrunning the piece", %{info: info} do
      piece_length = Map.get(info, :"piece length")

      assert {:error, _} =
               Torrent.validate_block(info, 0, 0, :binary.copy(<<0>>, piece_length + 1))
    end

    test "rejects an empty block", %{info: info} do
      assert {:error, _} = Torrent.validate_block(info, 0, 0, <<>>)
    end
  end

  describe "validate_path/1" do
    test "accepts clean components" do
      assert Torrent.validate_path(["dir", "file.iso"]) == {:ok, "dir/file.iso"}
    end

    test "rejects parent escapes" do
      assert {:error, _} = Torrent.validate_path(["..", "evil.iso"])
      assert {:error, _} = Torrent.validate_path(["dir", ".", "file.iso"])
    end

    test "rejects absolute components" do
      assert {:error, _} = Torrent.validate_path(["/etc", "passwd"])
    end

    test "rejects empty paths" do
      assert {:error, _} = Torrent.validate_path([])
      assert {:error, _} = Torrent.validate_path(["dir", ""])
    end
  end

  describe "hostile mutations" do
    property "valid blocks accepted, single-field mutations rejected" do
      check all({info, index, begin, data} <- valid_block()) do
        # Positive invariant: generator output is always accepted.
        assert Torrent.validate_block(info, index, begin, data) == :ok

        piece_length = Map.get(info, :"piece length")
        total = Map.get(info, :length)
        count = div(total + piece_length - 1, piece_length)

        assert {:error, _} = Torrent.validate_block(info, count, begin, data)
        assert {:error, _} = Torrent.validate_block(info, index, begin, <<>>)

        piece_size = min(piece_length, total - index * piece_length)
        assert {:error, _} = Torrent.validate_block(info, index, piece_size, <<0>>)
      end
    end

    property "injected escapes are rejected" do
      check all(
              parts <- list_of(valid_component(), min_length: 1, max_length: 4),
              evil <- member_of(["..", ".", "/abs", ""]),
              at <- integer(0..length(parts))
            ) do
        assert {:error, _} = Torrent.validate_path(List.insert_at(parts, at, evil))
      end
    end
  end

  defp valid_block do
    gen all(
          piece_length <- integer(1..65_536),
          total <- integer(1..65_536),
          index <- integer(0..(div(total + piece_length - 1, piece_length) - 1)),
          begin <- integer(0..(min(piece_length, total - index * piece_length) - 1)),
          size <- integer(1..(min(piece_length, total - index * piece_length) - begin)),
          bytes <- list_of(byte(), length: size)
        ) do
      {%{:"piece length" => piece_length, :length => total}, index, begin,
       :erlang.list_to_binary(bytes)}
    end
  end

  defp valid_component do
    gen all(
          first <- member_of(Enum.to_list(?a..?z)),
          rest <- list_of(member_of(Enum.to_list(?a..?z) ++ [?., ?-, ?_]), max_length: 8)
        ) do
      to_string([first | rest])
    end
  end
end
