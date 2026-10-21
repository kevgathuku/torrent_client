defmodule RaisingHttp do
  @moduledoc false
  def get(_url, _headers), do: raise("boom")
end

defmodule ExitingHttp do
  @moduledoc false
  def get(_url, _headers), do: exit(:boom)
end

defmodule WebseedTest do
  use ExUnit.Case, async: true

  import Mox
  setup :verify_on_exit!

  alias TorrentClient.Webseed

  @plen 16_384

  defp single_info do
    %{:"piece length" => @plen, name: "f.bin", length: 2 * @plen}
  end

  defp multi_info do
    %{
      :"piece length" => @plen,
      name: "t",
      files: [%{path: ["a.bin"], length: @plen}, %{path: ["b.bin"], length: @plen}]
    }
  end

  defp env(status, body), do: {:ok, %Tesla.Env{status: status, body: body}}

  test "single-file dir base appends the name; full URL passes through" do
    assert Webseed.file_url("https://x/torrents/", single_info(), "f.bin") ==
             {:ok, "https://x/torrents/f.bin"}

    assert Webseed.file_url("https://x/f.bin", single_info(), "f.bin") ==
             {:ok, "https://x/f.bin"}
  end

  test "multi-file dir base appends name and path; bare base is unusable" do
    assert Webseed.file_url("https://x/pub/", multi_info(), "t/a.bin") ==
             {:ok, "https://x/pub/t/a.bin"}

    assert Webseed.file_url("https://x/pub", multi_info(), "t/a.bin") == :error
  end

  test "path components are percent-encoded, the base is untouched" do
    info = %{:"piece length" => 1, name: "my dir", length: 1}

    assert Webseed.file_url("https://x/torrents/", info, "my dir/a b.bin") ==
             {:ok, "https://x/torrents/my%20dir/a%20b.bin"}
  end

  test "fetches a single-file piece with a Range header" do
    data = :crypto.strong_rand_bytes(@plen)

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn "https://x/f.bin", [{"range", "bytes=0-16383"}] ->
      env(206, data)
    end)

    assert Webseed.fetch_piece(
             TorrentClient.WebseedHttpMock,
             ["https://x/f.bin"],
             single_info(),
             0
           ) ==
             {:ok, data}
  end

  test "dir base builds the file URL before ranging" do
    data = :crypto.strong_rand_bytes(@plen)

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn "https://x/torrents/f.bin", [{"range", "bytes=16384-32767"}] ->
      env(206, data)
    end)

    assert Webseed.fetch_piece(
             TorrentClient.WebseedHttpMock,
             ["https://x/torrents/"],
             single_info(),
             1
           ) ==
             {:ok, data}
  end

  test "a piece spanning two files concatenates per-file ranges" do
    a = :crypto.strong_rand_bytes(@plen)
    b = :crypto.strong_rand_bytes(@plen)

    info = %{
      :"piece length" => 2 * @plen,
      name: "t",
      files: [%{path: ["a"], length: @plen}, %{path: ["b"], length: @plen}]
    }

    TorrentClient.WebseedHttpMock
    |> expect(:get, 2, fn
      "https://x/pub/t/a", [{"range", "bytes=0-16383"}] -> env(206, a)
      "https://x/pub/t/b", [{"range", "bytes=0-16383"}] -> env(206, b)
    end)

    assert Webseed.fetch_piece(TorrentClient.WebseedHttpMock, ["https://x/pub/"], info, 0) ==
             {:ok, a <> b}
  end

  test "falls over to the next base when the first fails" do
    data = :crypto.strong_rand_bytes(@plen)

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn "https://bad/f.bin", _ -> env(500, "nope") end)
    |> expect(:get, fn "https://good/f.bin", _ -> env(206, data) end)

    assert Webseed.fetch_piece(
             TorrentClient.WebseedHttpMock,
             ["https://bad/f.bin", "https://good/f.bin"],
             single_info(),
             0
           ) == {:ok, data}
  end

  test "a 200 carrying the whole file is windowed to the slice" do
    first = :crypto.strong_rand_bytes(@plen)
    second = :crypto.strong_rand_bytes(@plen)

    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers -> env(200, first <> second) end)

    assert Webseed.fetch_piece(
             TorrentClient.WebseedHttpMock,
             ["https://x/f.bin"],
             single_info(),
             1
           ) ==
             {:ok, second}
  end

  test "unknown schemes are never dialed and total failure errors" do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn "https://bad/f.bin", _ -> {:error, :econnrefused} end)

    assert {:error, _} =
             Webseed.fetch_piece(
               TorrentClient.WebseedHttpMock,
               ["ftp://x/f.bin", "https://bad/f.bin", "not a url"],
               single_info(),
               0
             )
  end

  test "garbage inputs fail closed without dialing" do
    assert :error = Webseed.file_url(nil, single_info(), "f.bin")
    assert :error = Webseed.file_url("https://x/pub", %{"files" => []}, "t/a")

    assert {:error, _} =
             Webseed.fetch_piece(TorrentClient.WebseedHttpMock, "nope", single_info(), 0)

    assert {:error, _} = Webseed.fetch_piece(TorrentClient.WebseedHttpMock, [], single_info(), 9)

    assert {:error, _} =
             Webseed.fetch_piece(TorrentClient.WebseedHttpMock, [123], single_info(), 0)
  end

  test "crashing http impls are ordinary fetch failures" do
    assert {:error, _} = Webseed.fetch_piece(RaisingHttp, ["https://x/f.bin"], single_info(), 0)
    assert {:error, _} = Webseed.fetch_piece(ExitingHttp, ["https://x/f.bin"], single_info(), 0)
  end

  test "short 200 bodies fail closed" do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _headers -> env(200, <<1, 2, 3>>) end)

    assert {:error, _} =
             Webseed.fetch_piece(
               TorrentClient.WebseedHttpMock,
               ["https://x/f.bin"],
               single_info(),
               0
             )
  end

  test "short bodies and unknown pieces fail closed" do
    TorrentClient.WebseedHttpMock
    |> expect(:get, fn _url, _ -> env(206, <<1, 2, 3>>) end)

    assert {:error, _} =
             Webseed.fetch_piece(
               TorrentClient.WebseedHttpMock,
               ["https://x/f.bin"],
               single_info(),
               0
             )

    assert {:error, _} =
             Webseed.fetch_piece(
               TorrentClient.WebseedHttpMock,
               ["https://x/f.bin"],
               single_info(),
               9
             )
  end
end
