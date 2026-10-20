defmodule TorrentClient.Application do
  @moduledoc """
  OTP Application entry point.

  Owns the session supervision tree: a unique Registry so per-torrent and
  per-peer processes are addressable by identity (never a single global
  name), and a session DynamicSupervisor everything later plugs into.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Supervisor.child_spec(
        {Registry, keys: :unique, name: TorrentClient.Registry},
        id: TorrentClient.Registry
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, name: TorrentClient.SessionSupervisor, strategy: :one_for_one},
        id: TorrentClient.SessionSupervisor
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
