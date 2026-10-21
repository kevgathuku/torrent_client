import Config

config :torrent_client, :requests_impl, TorrentClient.Requests.TeslaClient

import_config "#{config_env()}.exs"
