defmodule TorrentClient.ConfigTest do
  use ExUnit.Case, async: true

  alias TorrentClient.Config

  defp write_config(contents) do
    path = Path.join(System.tmp_dir(), "kog10-cfg-#{:erlang.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "loads the listen port" do
    assert {:ok, %{port: 6881}} = Config.load(write_config("port=6881\n"))
  end

  test "missing port defaults to nil; comments and blanks are ignored" do
    assert {:ok, %{port: nil}} = Config.load(write_config("# comment\n\n"))
  end

  test "unknown keys are ignored for forward compatibility" do
    assert {:ok, %{port: 6882}} = Config.load(write_config("port = 6882\nfuture_flag=yes\n"))
  end

  test "rejects out-of-range and non-numeric ports" do
    assert {:error, {:invalid_config, _}} = Config.load(write_config("port=0"))
    assert {:error, {:invalid_config, _}} = Config.load(write_config("port=65536"))
    assert {:error, {:invalid_config, _}} = Config.load(write_config("port=abc"))
    assert {:error, {:invalid_config, _}} = Config.load(write_config("port=68.81"))
  end

  test "rejects lines without a separator" do
    assert {:error, {:invalid_config, _}} = Config.load(write_config("port 6881"))
  end

  test "missing file passes the read error through" do
    assert {:error, :enoent} = Config.load("/nonexistent/torrent_client.conf")
  end
end
