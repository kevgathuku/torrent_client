import Config

config :torrent_client, :requests_impl, TorrentClient.Requests.TeslaClient
config :torrent_client, :webseed_http_impl, TorrentClient.WebseedHttpClient

import_config "#{config_env()}.exs"
