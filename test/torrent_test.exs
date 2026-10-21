defmodule TorrentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @multi_file_torrent TestHelpers.multi_file_torrent()
  @single_file_torrent TestHelpers.single_file_torrent()

  test "calculates the correct info hash for single file torrent" do
    {:ok, _bento, info} = TestHelpers.parse_torrent(@single_file_torrent)

    assert Torrent.info_hash(info) == "A9164E99D5181CFEF0C23C209334103619080908"
  end

  test "calculates the correct info hash for multi file torrent" do
    {:ok, _bento, info} = TestHelpers.parse_torrent(@multi_file_torrent)

    assert Torrent.info_hash(info) == "DD8255ECDC7CA55FB0BBF81323D87062DB1F6D1C"
  end

  test "get piece hashes for a single file torrent" do
    {:ok, bento_torrent, _info} = TestHelpers.parse_torrent(@single_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "get piece hashes for a multi file torrent" do
    {:ok, bento_torrent, _info} = TestHelpers.parse_torrent(@multi_file_torrent)
    piece_hashes = Torrent.get_piece_hashes(bento_torrent)

    assert Enum.all?(piece_hashes, fn x -> byte_size(x) == 20 end) == true
  end

  test "get piece hashes aligns on 20-byte boundaries past the first piece" do
    hashes = for i <- 0..2, do: :crypto.hash(:sha, "piece-#{i}")
    [h0, h1, h2] = Torrent.get_piece_hashes(%{info: %{pieces: Enum.join(hashes)}})
    assert h0 == :crypto.hash(:sha, "piece-0")
    assert h1 == :crypto.hash(:sha, "piece-1")
    assert h2 == :crypto.hash(:sha, "piece-2")
  end

  test "malformed pieces and non-binary input fail closed" do
    assert {:error, _} = Torrent.get_piece_hashes(%{info: %{pieces: <<1, 2, 3>>}})
    # Bento.torrent/1 validates info presence itself, so the missing_info
    # arm below is defensive (unreachable through this path) — kept so the
    # return shape stays total rather than raising CaseClauseError.
    assert {:error, _} = Torrent.parse_bytes(Bento.encode!(%{"nope" => %{}}))
    assert {:error, :invalid_torrent} = Torrent.parse_bytes(nil)
    assert Torrent.remaining(%{info: %{}}) == 0
    assert Torrent.validate_block("nope", 0, 0, <<1>>) == {:error, :invalid_block}
  end

  test "verifies data against its SHA1 hash" do
    hash = Utils.sha_sum("piece bytes")

    assert Torrent.verify_hash?("piece bytes", hash) == true
    assert Torrent.verify_hash?("tampered bytes", hash) == false
  end

  test "announce tiers fall back to announce when the list is empty" do
    {:ok, bento, _info} = TestHelpers.single_file_torrent() |> TestHelpers.parse_torrent()

    assert Torrent.announce_tiers(bento) == [[bento.announce]]
  end

  test "announce tiers preserve tier structure" do
    {:ok, bento, _info} =
      "test/_data/manjaro-gnome-17.1.9-stable-x86_64.torrent" |> TestHelpers.parse_torrent()

    assert Torrent.announce_tiers(bento) == [
             ["http://linuxtracker.org:2710/00000000000000000000000000000000/announce"],
             ["udp://mirror.strits.dk:6969"]
           ]
  end

  describe "validate_block/4" do
    setup do
      {:ok, bento, _info} = TestHelpers.single_file_torrent() |> TestHelpers.parse_torrent()
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

    test "accepts every real path in the multi-file fixtures" do
      multi =
        for path <- Path.wildcard("test/_data/*.torrent"),
            {:ok, bento, _info} = TestHelpers.parse_torrent(path),
            Map.has_key?(bento.info, :files) do
          {path, bento.info.files}
        end

      assert multi != [], "expected at least one multi-file fixture"

      for {path, files} <- multi, file <- files do
        assert {:ok, _} = Torrent.validate_path(file.path), "rejects real path in #{path}"
      end
    end

    test "rejects a real multi-file path with an injected escape" do
      {:ok, bento, _info} =
        TestHelpers.parse_torrent("test/_data/big-buck-bunny.torrent")

      [first | _] = bento.info.files
      assert {:error, _} = Torrent.validate_path([".." | first.path])
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

  describe "layout/1" do
    test "single-file info yields one entry at offset zero" do
      info = %{:"piece length" => 4, name: "f.bin", length: 10}
      assert Torrent.layout(info) == {:ok, [%{path: "f.bin", length: 10, offset: 0}]}
    end

    test "multi-file info yields cumulative offsets under the torrent dir" do
      info = %{
        :"piece length" => 5,
        name: "t",
        files: [%{path: ["a"], length: 6}, %{path: ["sub", "b"], length: 4}]
      }

      assert Torrent.layout(info) ==
               {:ok,
                [%{path: "t/a", length: 6, offset: 0}, %{path: "t/sub/b", length: 4, offset: 6}]}
    end

    test "rejects hostile and malformed info before any mkdir could run" do
      escape = %{:"piece length" => 1, name: "t", files: [%{path: ["..", "evil"], length: 1}]}
      assert {:error, _} = Torrent.layout(escape)
      assert {:error, _} = Torrent.layout(%{})
      assert {:error, _} = Torrent.layout(%{:"piece length" => 0, name: "f", length: 1})
      assert {:error, _} = Torrent.layout(%{:"piece length" => 4, name: "..", length: 1})
      assert {:error, _} = Torrent.layout(%{:"piece length" => 4, name: "x"})
      assert {:error, _} = Torrent.layout("nope")
    end
  end

  describe "url_list/1" do
    test "reads list, bare-string, and missing url-list from torrent bytes" do
      {:ok, debian} = File.read(TestHelpers.single_file_torrent())

      assert Torrent.url_list(debian) == [
               "https://cdimage.debian.org/cdimage/release/12.1.0/amd64/iso-cd/debian-12.1.0-amd64-netinst.iso",
               "https://cdimage.debian.org/cdimage/archive/12.1.0/amd64/iso-cd/debian-12.1.0-amd64-netinst.iso"
             ]

      {:ok, bbb} = File.read(TestHelpers.multi_file_torrent())
      assert Torrent.url_list(bbb) == ["https://webtorrent.io/torrents/"]

      {:ok, manjaro} = File.read("test/_data/manjaro-gnome-17.1.9-stable-x86_64.torrent")

      assert Torrent.url_list(manjaro) == [
               "https://osdn.net/dl/manjaro/manjaro-gnome-17.1.9-stable-x86_64.iso"
             ]

      {:ok, ubuntu} = File.read("test/_data/ubuntu-22.04.2-desktop-amd64.iso.torrent")
      assert Torrent.url_list(ubuntu) == []
    end

    test "bento structs drop url-list, so structs read empty" do
      {:ok, bento, _info} = TestHelpers.parse_torrent(TestHelpers.single_file_torrent())
      assert Torrent.url_list(bento) == []
    end

    test "raw maps accept string and atom keys, dropping non-binaries" do
      assert Torrent.url_list(%{"url-list" => "https://x/y"}) == ["https://x/y"]

      assert Torrent.url_list(%{"url-list" => ["https://a", 7, nil]}) == ["https://a"]
      assert Torrent.url_list(%{:"url-list" => ["https://a"]}) == ["https://a"]
      assert Torrent.url_list(%{"url-list" => 7}) == []
      assert Torrent.url_list(%{}) == []
      assert Torrent.url_list("nope") == []
      assert Torrent.url_list(nil) == []
    end
  end

  describe "piece_span/2 and split_span/3" do
    test "last piece may be short" do
      info = %{:"piece length" => 4, name: "f.bin", length: 10}
      assert Torrent.piece_span(info, 0) == {:ok, {0, 4}}
      assert Torrent.piece_span(info, 2) == {:ok, {8, 2}}
      assert {:error, _} = Torrent.piece_span(info, 3)
      assert {:error, _} = Torrent.piece_span(info, -1)
      assert {:error, _} = Torrent.piece_span(%{}, 0)
    end

    test "split_span slices a span across entries" do
      entries = [%{path: "a", length: 6, offset: 0}, %{path: "b", length: 6, offset: 6}]
      assert Torrent.split_span(entries, 5, 5) == [{"a", 5, 1}, {"b", 0, 4}]
      assert Torrent.split_span(entries, 0, 6) == [{"a", 0, 6}]
    end
  end
end
