import Config

config :torrent_client, :requests_impl, TorrentClient.Requests.RequestsTeslaImpl

# import_config "#{config_env()}.exs"
