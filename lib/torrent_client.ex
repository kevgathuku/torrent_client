defmodule TorrentClient do
  @moduledoc """
  Documentation for TorrentClient.
  """

  require Logger

  def parse(filename) do
    File.read!(filename) |> Bento.torrent!()
  end

  def peers() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
    |> Tracker.request_peers()
    |> Tracker.parse_peer_response()
  end

  def random_peer() do
    Enum.random(peers())
  end

  def sample_bento() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent")
  end

  def sample_torrent() do
    parse("test/_data/debian-10.2.0-amd64-netinst.iso.torrent") |> Torrent.from_bento()
  end

  @doc """
  Establish a connection to the specified peer
  """
  def connect() do
    torrent = sample_torrent()
    peer = random_peer()

    {:ok, address} = :inet.parse_address(peer.ip)

    # timeout -> 3 seconds
    case :gen_tcp.connect(address, peer.port, [active: false], 3000) do
      {:ok, socket} ->
        Logger.info("Connected with #{peer.ip}")

        # Get handshake from Torrent.handshake_message
        handshake = Torrent.handshake_message(torrent)

        # Send handshake message to peer
        :gen_tcp.send(socket, handshake)

        socket

      {:error, reason} ->
        Logger.error("Could not connect: #{reason}")
    end
  end

  def read_line(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0)
    data
  end
end
