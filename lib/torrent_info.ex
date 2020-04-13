defmodule TorrentClient.TorrentInfo do
  defstruct [:pieces, :piece_length, :length, :name]
end

# type bencodeInfo struct {
# 	Pieces      string `bencode:"pieces"`
# 	PieceLength int    `bencode:"piece length"`
# 	Length      int    `bencode:"length"`
# 	Name        string `bencode:"name"`
# }
