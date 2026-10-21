defmodule TorrentClient.Application do
  @moduledoc """
  OTP Application entry point.

  Owns the session supervision tree: a unique Registry so per-torrent and
  per-peer processes are addressable by identity (never a single global
  name), a session DynamicSupervisor hosting every torrent subtree, and
  the singleton Session driving them.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    install_log_file()

    children = [
      Supervisor.child_spec(
        {Registry, keys: :unique, name: TorrentClient.Registry},
        id: TorrentClient.Registry
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, name: TorrentClient.SessionSupervisor, strategy: :one_for_one},
        id: TorrentClient.SessionSupervisor
      ),
      Supervisor.child_spec(
        {TorrentClient.Session, Application.get_env(:torrent_client, :session, [])},
        id: TorrentClient.Session
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # Debug-and-up file log for post-mortems; nil disables it (tests).
  defp install_log_file do
    case Application.get_env(:torrent_client, :log_file, "log/torrent_client.log") do
      nil ->
        :ok

      path ->
        case TorrentClient.Log.setup(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Could not open log file #{path}: #{inspect(reason)}")
        end
    end
  end
end
