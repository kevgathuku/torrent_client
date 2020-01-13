defmodule TorrentClient do
  @moduledoc """
  Documentation for TorrentClient.
  """

  @doc """
  Hello world.

  ## Examples

      iex> TorrentClient.hello()
      :world

  """
  def hello do
    :world
  end

  def parse(filename) do
    File.read!(filename) |> Bento.torrent!()
  end
end
