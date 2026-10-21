defmodule TorrentClient.PeerSupervisor do
  @moduledoc """
  One-for-one owner of `TorrentClient.PeerWorker` processes.

  Children are transient: a worker that finishes its piece exits `:normal`
  and is never restarted, while a crashed worker restarts with a fresh
  connection. Restart storms are bounded by the intensity below, so a
  poison peer (or a persistently failing edge) takes the supervisor down
  instead of spinning forever — the coordinator above (kog.9) restarts
  from last published progress.
  """

  use DynamicSupervisor

  @doc "Start the supervisor. Pass `name:` to register it."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, opts)
  end

  @doc "Start one unnamed worker under `supervisor`."
  def start_peer(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {TorrentClient.PeerWorker, opts})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end
end
