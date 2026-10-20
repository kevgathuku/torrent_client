ExUnit.start()

Mox.defmock(TorrentClientRequestsMock, for: TorrentClient.Requests.RequestsBehaviour)
Mox.defmock(TorrentClient.NetworkMock, for: TorrentClient.NetworkBehaviour)
Mox.defmock(TorrentClient.DiskMock, for: TorrentClient.DiskBehaviour)
Mox.defmock(TorrentClient.ClockMock, for: TorrentClient.ClockBehaviour)
Application.put_env(:torrent_client, :requests_impl, TorrentClient.Requests.RequestsMock)
