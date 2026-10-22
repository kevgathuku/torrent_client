defmodule TorrentClient.PeerPipeline do
  @moduledoc """
  Per-peer congestion state as pure data: latency exponentially weighted
  moving average, additive-increase / multiplicative-decrease pipeline
  depth, and the receive timeout derived from them.

  The worker owns the clock and the socket; this module only evolves
  numbers, so every branch is exactly unit-testable. Depth starts at 5
  (today's fixed pipeline, no slow-start regression), grows one per
  window of sustained receipts up to the configured cap, and halves on
  timeout with a floor of 1. The receive timeout triples the average
  block latency, floored at a second (loopback jitter must not
  trip it) and capped at the configured ceiling.
  """

  @initial_depth 5
  @latency_factor 3
  @recv_floor_ms 1_000
  @ewma_alpha 0.25

  defstruct depth: @initial_depth,
            max_depth: @initial_depth,
            since_grow: 0,
            consecutive_timeouts: 0,
            ewma: nil,
            received_count: 0

  @type t :: %__MODULE__{
          depth: pos_integer(),
          max_depth: pos_integer(),
          since_grow: non_neg_integer(),
          consecutive_timeouts: non_neg_integer(),
          ewma: number() | nil,
          received_count: non_neg_integer()
        }

  @doc "Fresh state capped at `max_depth`."
  @spec init(pos_integer()) :: t()
  def init(max_depth) when is_integer(max_depth) and max_depth >= 1 do
    %__MODULE__{depth: min(@initial_depth, max_depth), max_depth: max_depth}
  end

  @doc """
  Fold in one received block sent at `sent_at`, seen at `now` (both ms):
  blend the latency sample, count the receipt, grow the depth once per
  full window of sustained receipts.
  """
  @spec note_received(t(), integer(), integer()) :: t()
  def note_received(%__MODULE__{} = pipe, sent_at, now) do
    pipe = %{
      pipe
      | ewma: blend(pipe.ewma, now - sent_at),
        received_count: pipe.received_count + 1,
        consecutive_timeouts: 0
    }

    if pipe.since_grow + 1 >= pipe.depth and pipe.depth < pipe.max_depth do
      %{pipe | depth: pipe.depth + 1, since_grow: 0}
    else
      %{pipe | since_grow: pipe.since_grow + 1}
    end
  end

  @doc """
  Back off on a silent peer: halve the depth (floor 1), restart growth,
  and count the consecutive silence (receipts reset it). The worker
  gives up after a few in a row: a timeout mid-frame leaves the stream
  desynchronized, so spinning on it can never complete.
  """
  @spec note_timeout(t()) :: t()
  def note_timeout(%__MODULE__{} = pipe) do
    %{
      pipe
      | depth: max(div(pipe.depth, 2), 1),
        since_grow: 0,
        consecutive_timeouts: pipe.consecutive_timeouts + 1
    }
  end

  @doc "Effective per-message receive timeout: triple the average within floor and ceiling."
  @spec recv_timeout(t(), pos_integer()) :: pos_integer()
  def recv_timeout(%__MODULE__{ewma: nil}, ceiling), do: ceiling

  def recv_timeout(%__MODULE__{ewma: ewma}, ceiling) do
    min(max(trunc(ewma * @latency_factor), @recv_floor_ms), ceiling)
  end

  @doc "True when no block arrived within `budget` ms of `served_at`: poison shape."
  @spec first_byte_due?(t(), integer(), integer(), pos_integer()) :: boolean()
  def first_byte_due?(%__MODULE__{received_count: 0}, served_at, now, budget) do
    now - served_at >= budget
  end

  def first_byte_due?(%__MODULE__{}, _served_at, _now, _budget), do: false

  defp blend(nil, sample), do: sample
  defp blend(ewma, sample), do: ewma + @ewma_alpha * (sample - ewma)
end
