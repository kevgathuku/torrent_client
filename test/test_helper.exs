# Suite-lifetime owner for the webseed stub table: created here so async
# tests share one stable table instead of one owned by whichever test
# happens to register first (owner death would wipe every test's rows).
WebseedStub.start_table()

ExUnit.start()

Mox.defmock(TorrentClientRequestsMock, for: TorrentClient.Requests.RequestsBehaviour)
Mox.defmock(TorrentClient.WebseedHttpMock, for: TorrentClient.WebseedHttpBehaviour)
Mox.defmock(TorrentClient.NetworkMock, for: TorrentClient.NetworkBehaviour)
Mox.defmock(TorrentClient.DiskMock, for: TorrentClient.DiskBehaviour)
Mox.defmock(TorrentClient.ClockMock, for: TorrentClient.ClockBehaviour)
Mox.defmock(TorrentClient.UdpMock, for: TorrentClient.UdpBehaviour)
Application.put_env(:torrent_client, :requests_impl, TorrentClient.Requests.RequestsMock)
