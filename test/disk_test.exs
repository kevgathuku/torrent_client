defmodule DiskTest do
  @moduledoc """
  Disk seam through the real implementation on tmp dirs: layout init,
  piece read/write (including pieces spanning file boundaries), and a
  pause/resume cycle that round-trips verified bytes.
  """
  use ExUnit.Case, async: true

  alias TorrentClient.Disk

  setup do
    base = Path.join(System.tmp_dir!(), "kog7-disk-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  defp single_info do
    %{:"piece length" => 4, name: "f.bin", length: 10}
  end

  defp multi_info do
    %{
      :"piece length" => 5,
      name: "t",
      files: [
        %{path: ["f1"], length: 6},
        %{path: ["empty"], length: 0},
        %{path: ["sub", "f2"], length: 6}
      ]
    }
  end

  defp tiny_pieces, do: [<<0, 1, 2, 3>>, <<4, 5, 6, 7>>, <<8, 9>>]

  defp tiny_info do
    pieces = Enum.map_join(tiny_pieces(), &Utils.sha_sum/1)
    %{:"piece length" => 4, name: "tiny.bin", length: 10, pieces: pieces}
  end

  test "init_layout creates the single-file structure with declared size", %{base: base} do
    assert Disk.init_layout(base, single_info()) == :ok

    path = Path.join(base, "f.bin")
    assert {:ok, %File.Stat{size: 10}} = File.stat(path)
  end

  test "init_layout creates the multi-file structure under the torrent dir", %{base: base} do
    assert Disk.init_layout(base, multi_info()) == :ok

    assert {:ok, %File.Stat{size: 6}} = File.stat(Path.join([base, "t", "f1"]))
    assert {:ok, %File.Stat{size: 0}} = File.stat(Path.join([base, "t", "empty"]))
    assert {:ok, %File.Stat{size: 6}} = File.stat(Path.join([base, "t", "sub", "f2"]))
  end

  test "init_layout rejects an escape before creating anything", %{base: base} do
    evil = "kog7-evil-#{:erlang.unique_integer([:positive])}"
    evil_path = Path.join(System.tmp_dir!(), evil)

    info = %{
      :"piece length" => 1,
      name: "t",
      files: [%{path: ["..", evil], length: 1}]
    }

    assert {:error, _} = Disk.init_layout(base, info)
    assert File.ls!(base) == []
    refute File.exists?(evil_path)
  end

  test "init_layout fails closed on hostile shapes without touching the fs", %{base: base} do
    bad_infos = [
      %{},
      %{:"piece length" => 0, name: "f", length: 10},
      %{:"piece length" => 4, name: "f", length: -1},
      %{:"piece length" => 4, name: "", length: 10},
      %{:"piece length" => 4, name: "t", files: []},
      %{:"piece length" => 4, name: "t", files: [%{path: ["f"], length: -1}]},
      %{:"piece length" => 4, name: "t", files: [%{length: 1}]},
      "not-a-map"
    ]

    for bad <- bad_infos do
      assert {:error, _} = Disk.init_layout(base, bad)
    end

    assert File.ls!(base) == []
  end

  test "piece write/read round-trips on a single file", %{base: base} do
    info = single_info()
    assert Disk.init_layout(base, info) == :ok

    for {bytes, index} <- Enum.with_index(tiny_pieces()) do
      assert Disk.write_piece(base, info, index, bytes) == :ok
    end

    for {bytes, index} <- Enum.with_index(tiny_pieces()) do
      assert Disk.read_piece(base, info, index) == {:ok, bytes}
    end
  end

  test "piece write/read spans a file boundary", %{base: base} do
    # f1 holds global bytes 0..5, f2 holds 6..11: piece 1 is bytes 5..9.
    info = multi_info()
    assert Disk.init_layout(base, info) == :ok

    piece = <<5, 6, 7, 8, 9>>
    assert Disk.write_piece(base, info, 1, piece) == :ok
    assert Disk.read_piece(base, info, 1) == {:ok, piece}
  end

  test "write_piece rejects data of the wrong size", %{base: base} do
    info = single_info()
    assert Disk.init_layout(base, info) == :ok

    assert Disk.write_piece(base, info, 0, <<1, 2>>) == {:error, :piece_size_mismatch}
    assert Disk.write_piece(base, info, 2, <<1, 2, 3, 4>>) == {:error, :piece_size_mismatch}
  end

  test "write_piece rejects unknown pieces", %{base: base} do
    info = single_info()
    assert Disk.init_layout(base, info) == :ok
    assert Disk.write_piece(base, info, 99, <<1, 2, 3, 4>>) == {:error, :piece_out_of_bounds}
  end

  test "write_piece never creates files; only init_layout may", %{base: base} do
    info = single_info()

    # Missing file: stat gate fails before open could create it.
    assert Disk.write_piece(base, info, 0, <<1, 2, 3, 4>>) == {:error, :enoent}
    refute File.exists?(Path.join(base, "f.bin"))

    # Directory where the file belongs: open fails after stat succeeds.
    File.mkdir_p!(Path.join(base, "f.bin"))
    assert {:error, _} = Disk.write_piece(base, info, 0, <<1, 2, 3, 4>>)
  end

  test "init_layout fails when it cannot build the structure", %{base: base} do
    info = single_info()

    # Base is a file, not a dir: no parent can be created under it.
    file_base = Path.join(base, "not-a-dir")
    File.write!(file_base, "x")
    assert {:error, _} = Disk.init_layout(file_base, info)

    empty_info = %{:"piece length" => 4, name: "z", length: 0}
    assert {:error, _} = Disk.init_layout(file_base, empty_info)

    # Directory squatting the file path: sizing open fails.
    File.mkdir_p!(Path.join(base, "f.bin"))
    assert {:error, _} = Disk.init_layout(base, info)
  end

  test "init_layout rejects symlinked dirs before creating anything", %{base: base} do
    outside = Path.join(System.tmp_dir!(), "kog7-outside-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.write!(Path.join(outside, "evil"), "outside")

    File.mkdir_p!(Path.join(base, "t"))
    File.ln_s!(outside, Path.join(base, "t/sub"))

    info = %{
      :"piece length" => 4,
      name: "t",
      files: [%{path: ["ok"], length: 4}, %{path: ["sub", "f"], length: 4}]
    }

    assert Disk.init_layout(base, info) == {:error, :symlink_escape}
    # Sweep runs before any mkdir: the innocent first entry was never created.
    assert File.ls!(Path.join(base, "t")) == ["sub"]
    assert File.read!(Path.join(outside, "evil")) == "outside"
  end

  test "init_layout rejects a symlink at the final file path", %{base: base} do
    target = Path.join(base, "target")
    File.write!(target, "target")
    File.ln_s!(target, Path.join(base, "f.bin"))

    assert Disk.init_layout(base, single_info()) == {:error, :symlink_escape}
    assert File.read!(target) == "target"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(base, "f.bin"))
  end

  test "write_piece refuses a parent dir swapped for a symlink after init", %{base: base} do
    info = multi_info()
    assert Disk.init_layout(base, info) == :ok

    # Deterministic plant strictly between two completed calls: not a race.
    outside = Path.join(System.tmp_dir!(), "kog7-outside-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    sub = Path.join([base, "t", "sub"])
    File.rm_rf!(sub)
    File.ln_s!(outside, sub)

    # Piece 1 spans f1 and sub/f2: must fail before touching outside.
    assert Disk.write_piece(base, info, 1, <<5, 6, 7, 8, 9>>) == {:error, :symlink_escape}
    assert File.ls!(outside) == []
  end

  test "write_piece refuses a symlink at the file path", %{base: base} do
    info = single_info()
    assert Disk.init_layout(base, info) == :ok

    target = Path.join(base, "target")
    File.write!(target, "target")
    File.rm!(Path.join(base, "f.bin"))
    File.ln_s!(target, Path.join(base, "f.bin"))

    assert Disk.write_piece(base, info, 0, <<1, 2, 3, 4>>) == {:error, :symlink_escape}
    assert File.read!(target) == "target"
  end

  test "read_piece reports short files instead of returning partial bytes", %{base: base} do
    info = single_info()
    assert Disk.init_layout(base, info) == :ok

    File.write!(Path.join(base, "f.bin"), <<1, 2>>)
    assert Disk.read_piece(base, info, 0) == {:error, :short_read}

    File.write!(Path.join(base, "f.bin"), "")
    assert Disk.read_piece(base, info, 0) == {:error, :short_read}
  end

  test "pause/resume cycle through real disk round-trips verified bytes", %{base: base} do
    info = tiny_info()
    assert Disk.init_layout(base, info) == :ok

    # Download: write every piece, verify each hash like the coordinator would.
    for {bytes, index} <- Enum.with_index(tiny_pieces()) do
      assert Disk.write_piece(base, info, index, bytes) == :ok
      expected = binary_part(info.pieces, index * 20, 20)
      assert Torrent.verify_hash?(bytes, expected)
    end

    # Pause: encode resume state and persist it through the raw byte seam.
    info_hash = Utils.sha_sum("tiny")
    resume = %{info_hash: info_hash, verified: MapSet.new([0, 1, 2]), total: 10, piece_length: 4}
    assert {:ok, encoded} = Disk.encode_resume(resume)

    resume_path = Path.join(base, "resume.bin")
    assert Disk.write(resume_path, encoded) == :ok

    # Resume in a fresh state: load, decode, re-read and re-verify every byte.
    assert {:ok, stored} = Disk.read(resume_path)
    assert {:ok, decoded} = Disk.decode_resume(stored)
    assert decoded == %{info_hash: info_hash, verified: [0, 1, 2], total: 10, piece_length: 4}
    assert byte_size(decoded.info_hash) == 20

    for {bytes, index} <- Enum.with_index(tiny_pieces()) do
      assert Disk.read_piece(base, info, index) == {:ok, bytes}
      expected = binary_part(info.pieces, index * 20, 20)
      assert Torrent.verify_hash?(bytes, expected)
    end
  end

  test "resume round-trips through the real fixture layout", %{base: base} do
    {:ok, bento, _info} = Downloader.parse_torrent_file(TestHelpers.multi_file_torrent())
    info = bento.info

    assert {:ok, entries} = Torrent.layout(info)
    assert length(entries) == 3

    assert Enum.map(entries, & &1.path) == [
             "Big Buck Bunny/Big Buck Bunny.en.srt",
             "Big Buck Bunny/Big Buck Bunny.mp4",
             "Big Buck Bunny/poster.jpg"
           ]

    total = Enum.reduce(entries, 0, &(&1.length + &2))
    assert total == Torrent.remaining(bento)

    assert Disk.init_layout(base, info) == :ok

    for %{path: rel, length: length} <- entries do
      assert {:ok, %File.Stat{size: ^length}} = File.stat(Path.join(base, rel))
    end

    # Piece 0 spans the .srt tail into the .mp4 head: proves spanning on real shapes.
    {:ok, {_offset, size}} = Torrent.piece_span(info, 0)
    piece = :crypto.strong_rand_bytes(size)
    assert Disk.write_piece(base, info, 0, piece) == :ok
    assert Disk.read_piece(base, info, 0) == {:ok, piece}
  end

  test "decode_resume rejects garbage and hostile shapes", %{base: base} do
    assert {:error, _} = Disk.decode_resume(<<1, 2, 3>>)
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(%{"v" => 2}))
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(%{}))
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(%{"v" => 1}))

    assert {:ok, encoded} =
             Disk.encode_resume(%{
               info_hash: Utils.sha_sum("x"),
               verified: [0],
               total: 1,
               piece_length: 1
             })

    tampered = :erlang.term_to_binary(:erlang.binary_to_term(encoded) |> Map.delete("verified"))
    assert {:error, _} = Disk.decode_resume(tampered)

    bad_hex = :erlang.binary_to_term(encoded) |> Map.put("info_hash", %{"$hex" => "ZZ"})
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(bad_hex))

    assert {:error, _} =
             Disk.encode_resume(%{info_hash: "hex", verified: [-1], total: 1, piece_length: 1})

    assert {:error, _} =
             Disk.encode_resume(%{info_hash: "", verified: [], total: 0, piece_length: 1})

    assert {:error, _} = Disk.encode_resume("not-a-map")
    assert {:error, _} = Disk.decode_resume(:not_a_binary)
    assert {:error, _} = Disk.init_layout(:not_a_dir, single_info())
    assert {:error, _} = Disk.read_piece(:not_a_dir, single_info(), 0)
    assert {:error, _} = Disk.write_piece(base, single_info(), 0, :not_binary)

    assert {:error, _} =
             Disk.encode_resume(%{
               info_hash: Utils.sha_sum("x"),
               verified: 5,
               total: 1,
               piece_length: 1
             })

    bad_verified = :erlang.binary_to_term(encoded) |> Map.put("verified", [-1])
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(bad_verified))

    bad_tag = :erlang.binary_to_term(encoded) |> Map.put("info_hash", %{"$hex" => 5})
    assert {:error, _} = Disk.decode_resume(:erlang.term_to_binary(bad_tag))
  end

  test "id_from_path derives a readable id from the torrent filename" do
    assert Disk.id_from_path("/downloads/big-buck-bunny.torrent") == {:ok, "big-buck-bunny"}
    assert Disk.id_from_path("debian.torrent") == {:ok, "debian"}
    assert {:error, _} = Disk.id_from_path("")
    assert {:error, _} = Disk.id_from_path(:not_a_path)
  end
end
