defmodule DownloadState do
  @moduledoc """
  Pure per-torrent download planning: which pieces are needed, in flight,
  or verified. Evolves through plain data functions returning updated
  state; the coordinator owns the single instance and workers only report
  events upward, never sharing it.

  Allocation is rarest-first over eligible-holder counts supplied by the
  caller: the rarest needed piece with at least one holder wins, ties go
  to the lowest index, and pieces with no count are treated as universally
  available (picked last) so unknown swarms still start. A zero count
  means nobody eligible holds the piece and it is skipped. When every
  needed piece is already in flight (`endgame?/1`), assignment duplicates
  an in-flight piece instead of erroring; the first completion wins and
  the coordinator cancels the losers.

  Stall state is a timestamp: `note_progress/2` stamps block/piece
  progress, `stalled?/3` compares against the watchdog budget. Time comes
  in from the caller so this stays pure.
  """

  defstruct total: 0, verified: MapSet.new(), inflight: MapSet.new(), last_progress: nil

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          verified: MapSet.t(),
          inflight: MapSet.t(),
          last_progress: integer() | nil
        }

  @doc "Fresh state for a torrent of `total` pieces."
  @spec init(non_neg_integer()) :: t()
  def init(total) when is_integer(total) and total >= 0 do
    %__MODULE__{total: total}
  end

  @doc "Pieces neither verified nor in flight."
  @spec needed(t()) :: MapSet.t()
  def needed(%__MODULE__{total: total, verified: verified, inflight: inflight}) do
    all = if total > 0, do: MapSet.new(0..(total - 1)), else: MapSet.new()
    MapSet.difference(all, MapSet.union(verified, inflight))
  end

  @doc "True when every piece is verified."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{total: total, verified: verified}) do
    total > 0 and MapSet.size(verified) >= total
  end

  @doc "True when nothing remains unassigned but pieces are still out."
  @spec endgame?(t()) :: boolean()
  def endgame?(state) do
    not complete?(state) and MapSet.size(needed(state)) == 0
  end

  @doc """
  Assign a piece: rarest-first over `counts` (`%{index => holders}`),
  skipping in-flight and verified pieces. Duplicates an in-flight piece
  in endgame, rarest first. Errors when complete or when no piece with
  a holder is assignable.
  """
  @spec assign(t(), %{non_neg_integer() => non_neg_integer()}) ::
          {:ok, non_neg_integer(), t()} | {:error, :complete | :no_available_piece}
  def assign(state, counts) when is_map(counts) do
    cond do
      complete?(state) ->
        {:error, :complete}

      MapSet.size(needed(state)) > 0 ->
        case rarest(needed(state), counts) do
          nil -> {:error, :no_available_piece}
          index -> {:ok, index, %{state | inflight: MapSet.put(state.inflight, index)}}
        end

      MapSet.size(state.inflight) > 0 ->
        case rarest(state.inflight, counts) do
          nil -> {:error, :no_available_piece}
          index -> {:ok, index, state}
        end

      true ->
        {:error, :no_available_piece}
    end
  end

  @doc "Mark a piece verified (idempotent: duplicates finishing together)."
  @spec complete(t(), non_neg_integer()) :: t()
  def complete(state, index) do
    %{
      state
      | verified: MapSet.put(state.verified, index),
        inflight: MapSet.delete(state.inflight, index)
    }
  end

  @doc """
  Seed a fresh state with already-verified pieces (resume load).
  Out-of-range indices are dropped: resume bytes are hostile input.
  """
  @spec restore(t(), [non_neg_integer()] | MapSet.t()) :: t()
  def restore(%__MODULE__{total: total} = state, indices) do
    valid =
      indices
      |> MapSet.new()
      |> MapSet.filter(&(is_integer(&1) and &1 >= 0 and &1 < total))

    %{state | verified: valid}
  end

  @doc "Return an in-flight piece to needed (no-op when idle)."
  @spec requeue(t(), non_neg_integer()) :: t()
  def requeue(state, index) do
    %{state | inflight: MapSet.delete(state.inflight, index)}
  end

  @doc "Stamp progress at `now_ms` (block receipts, completions)."
  @spec note_progress(t(), integer()) :: t()
  def note_progress(state, now_ms) when is_integer(now_ms) do
    %{state | last_progress: now_ms}
  end

  @doc "True when no progress was stamped within `timeout_ms` of `now_ms`."
  @spec stalled?(t(), integer(), non_neg_integer()) :: boolean()
  def stalled?(%__MODULE__{last_progress: nil}, _now_ms, _timeout_ms), do: false

  def stalled?(%__MODULE__{last_progress: last}, now_ms, timeout_ms) do
    now_ms - last >= timeout_ms
  end

  # Rarest needed piece with at least one holder; uncounted pieces sort
  # after every counted one; ties go to the lowest index.
  defp rarest(needed, counts) do
    needed
    |> MapSet.to_list()
    |> Enum.map(fn index -> {Map.get(counts, index, 1_000_000), index} end)
    |> Enum.filter(fn {holders, _index} -> holders > 0 end)
    |> case do
      [] -> nil
      scored -> scored |> Enum.min() |> elem(1)
    end
  end
end
