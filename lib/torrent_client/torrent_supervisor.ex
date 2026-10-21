defmodule TorrentClient.TorrentSupervisor do
  @moduledoc """
  One supervised subtree per torrent: a `PeerSupervisor` owning the
  per-peer workers plus the `Coordinator` assigning their pieces.

  Strategy is one-for-one so a coordinator restart (bounded by the
  intensity below) never kills in-flight workers: the new incarnation
  reaps stale workers on init and resumes from its own fresh plan. The
  coordinator stops `:normal` on completion and is never restarted then.
  """

  use Supervisor

  alias TorrentClient.{Coordinator, PeerSupervisor}

  @doc """
  Start the subtree. Required opt: `:info_hash` (20-byte binary) — the
  peer supervisor and coordinator register under it in
  `TorrentClient.Registry`, so many torrents share one node.
  Remaining opts pass through to the coordinator.
  """
  def start_link(opts) do
    info_hash = Keyword.fetch!(opts, :info_hash)
    {name, coord_opts} = Keyword.pop(opts, :name)

    sup_name = {:via, Registry, {TorrentClient.Registry, {info_hash, :peer_sup}}}
    coord_name = {:via, Registry, {TorrentClient.Registry, {info_hash, :coordinator}}}

    children = [
      %{id: PeerSupervisor, start: {PeerSupervisor, :start_link, [[name: sup_name]]}},
      # Transient: a :normal stop means the torrent completed and must
      # stay down; abnormal stops restart bounded by the intensity below.
      %{
        id: Coordinator,
        start: {Coordinator, :start_link, [coord_opts ++ [peer_sup: sup_name, name: coord_name]]},
        restart: :transient
      }
    ]

    case name do
      nil -> Supervisor.start_link(__MODULE__, children, [])
      name -> Supervisor.start_link(__MODULE__, children, name: name)
    end
  end

  @impl true
  def init(children) do
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
