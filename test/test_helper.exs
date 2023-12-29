ExUnit.start()

Mox.defmock(TorrentClientRequestsMock, for: TorrentClient.Requests.RequestsBehaviour)
Application.put_env(:torrent_client, :requests_impl, TorrentClient.Requests.RequestsMock)
