defmodule TorrentClient.TorrentFile do
  defstruct [:announce, :info_hash, :piece_hashes, :piece_length, :length, :name]
end

# TorrentFile{
# 	Announce:    bto.Announce,
# 	InfoHash:    infoHash, #  computed the SHA-1 hash of the entire bencoded info dict
# 	PieceHashes: pieceHashes, # a slice of hashes (each [20]byte) to enable easily accessing individual hashes
# 	PieceLength: bto.Info.PieceLength,
# 	Length:      bto.Info.Length,
# 	Name:        bto.Info.Name,
# }
