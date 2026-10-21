defmodule TorrentClient.WebseedWorker do
  @moduledoc """
  Unnamed webseed GenServer: downloads one assigned piece over HTTP
  Range requests (BEP-19) and feeds the coordinator's existing piece
  path — SHA1 verify, then persist via the disk seam.

  Owned one-for-one by `TorrentClient.PeerSupervisor` next to the peer
  workers; never registered. Reports `{:piece_complete, index}` after a
  verified write and `{:block_progress, index}` once the bytes land (so
  the coordinator watchdog sees liveness on slow links), then stops
  `:normal` like a finished peer worker. Anything else — fetch failure,
  hash mismatch, disk error — stops abnormally; the coordinator requeues
  from the DOWN the same way it does for peers. Unlike peer workers, a
  failed fetch carries no new information (same URL, same bytes), so the
  child is `:temporary`: no supervisor restart, no redundant refetch,
  no intensity pressure on the shared peer supervisor.

  A `{:cancel_piece, index}` arriving while the fetch is in flight drops
  the fetched bytes instead of writing them: the piece was already
  verified elsewhere. The worker never leaves its initial fetch, so
  cancel is honored by a mailbox check before the write — anything still
  queued (stale indices included) dies with the process.
  """

  use GenServer

  require Logger

  alias TorrentClient.Webseed

  @doc """
  Start an unnamed worker downloading `piece_index` from `webseed_urls`.

  Required opts: `:webseed_urls` (non-empty list of base URL strings),
  `:info` (torrent info map), `:piece_index`, `:piece_hash` (20-byte
  expected SHA1), `:base_dir`. Seams: `:http` (default
  `TorrentClient.WebseedHttpClient`, implementing
  `TorrentClient.WebseedHttpBehaviour`), `:disk` (default
  `TorrentClient.Disk`), `:report_to` pid receiving the same
  `{:piece_complete, index}` / `{:block_progress, index}` reports peer
  workers send (default `nil`).
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Temporary: the coordinator owns retry (requeue plus its failure
  # budget), and a restarted fetch would only repeat identical bytes.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @impl true
  def init(opts) do
    state = %{
      webseed_urls: Keyword.fetch!(opts, :webseed_urls),
      info: Keyword.fetch!(opts, :info),
      piece_index: Keyword.fetch!(opts, :piece_index),
      piece_hash: Keyword.fetch!(opts, :piece_hash),
      base_dir: Keyword.fetch!(opts, :base_dir),
      http: Keyword.get(opts, :http, TorrentClient.WebseedHttpClient),
      disk: Keyword.get(opts, :disk, TorrentClient.Disk),
      report_to: Keyword.get(opts, :report_to, nil)
    }

    case Torrent.piece_span(state.info, state.piece_index) do
      {:ok, _} -> {:ok, state, {:continue, :fetch}}
      {:error, _} -> {:stop, :invalid_piece}
    end
  end

  @impl true
  def handle_continue(:fetch, state) do
    case Webseed.fetch_piece(state.http, state.webseed_urls, state.info, state.piece_index) do
      {:ok, data} ->
        report(state, {:block_progress, state.piece_index})

        if cancelled?(state.piece_index),
          do: {:stop, :normal, state},
          else: verify_and_write(state, data)

      {:error, reason} ->
        {:stop, {:webseed_error, reason}, state}
    end
  end

  defp verify_and_write(state, data) do
    if Torrent.verify_hash?(data, state.piece_hash) do
      write_verified(state, data)
    else
      {:stop, :piece_mismatch, state}
    end
  end

  defp write_verified(state, data) do
    case state.disk.write_piece(state.base_dir, state.info, state.piece_index, data) do
      :ok ->
        Logger.debug("Piece #{state.piece_index} verified via webseed and written")
        report(state, {:piece_complete, state.piece_index})
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:disk_error, reason}, state}
    end
  end

  # A pending cancel for our index means the coordinator already has
  # these bytes; drop ours instead of double-reporting.
  defp cancelled?(index) do
    receive do
      {:cancel_piece, ^index} -> true
    after
      0 -> false
    end
  end

  # Best-effort upward reports: the coordinator may be gone, and the
  # worker must never block on it.
  defp report(%{report_to: nil}, _message), do: :ok
  defp report(%{report_to: pid}, message), do: send(pid, message)
end
