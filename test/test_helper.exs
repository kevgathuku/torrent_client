ExUnit.start()

Mox.defmock(TorrentClient.Requests.Mock, for: TorrentClient.Requests.RequestsBehaviour)
Application.put_env(:torrent_client, :requests_impl, TorrentClient.Requests.Mock)
