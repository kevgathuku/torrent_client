defmodule TorrentClient.Utp do
  @moduledoc """
  uTP (BEP-29) packet codec: 20-byte header plus extension chain.

  Pure by design — no sockets, no timers. `TorrentClient.UtpSocket` owns
  the connection state machine; this module only renders and parses
  bytes. Anything malformed is `{:error, reason}`, never a crash.

  Wire facts below quote BEP-29 directly, cross-checked against
  libtorrent's `utp_stream.cpp` (extension chain layout, SACK bit order,
  `type_ver` nibble order) since that is the implementation our packets
  must interoperate with.
  """

  import Bitwise

  @version 1
  @ext_sack 1

  # BEP-29 controller constants.
  @target_delay_us 100_000
  @min_timeout_ms 500
  @initial_timeout_ms 1_000
  @min_window_bytes 150
  @gain_packets_per_rtt 1

  @types %{data: 0, fin: 1, state: 2, reset: 3, syn: 4}
  @type_names Map.new(@types, fn {k, v} -> {v, k} end)

  @typedoc "Decoded uTP header; `sack` lists sequence numbers the peer reports received."
  @type header :: %{
          type: :data | :fin | :state | :reset | :syn,
          conn_id: 0..65_535,
          ts: non_neg_integer(),
          ts_diff: non_neg_integer(),
          wnd: non_neg_integer(),
          seq: 0..65_535,
          ack: 0..65_535,
          sack: [non_neg_integer()]
        }

  @doc "Numeric uTP packet type, per BEP-29 §type."
  @spec type_to_int(:data | :fin | :state | :reset | :syn) :: 0..4
  def type_to_int(type), do: Map.fetch!(@types, type)

  @doc """
  Renders one packet: 20-byte header, extension chain, payload. `opts`
  takes `sack:` (a `MapSet` of received sequence numbers, sent only when
  the peer skipped one) and `raw_ext:` (a list of `{id, bytes}` for
  forward-compatibility tests — unknown ids on the wire).
  """
  @spec encode(map(), keyword()) :: binary()
  def encode(header, opts \\ []) do
    ext_bytes = extensions(opts, header)
    ext_id = if ext_bytes == <<>>, do: 0, else: first_ext_id(opts)
    type_ver = type_to_int(header.type) <<< 4 ||| @version

    <<type_ver, ext_id, header.conn_id::16-big, header.ts &&& 0xFFFFFFFF::32-big,
      header.ts_diff &&& 0xFFFFFFFF::32-big, header.wnd::32-big, header.seq &&& 0xFFFF::16-big,
      header.ack &&& 0xFFFF::16-big>> <> ext_bytes
  end

  @doc """
  Parses one packet, returning the header and trailing payload. Unknown
  extensions are skipped per BEP-29 (libtorrent drops only truncated
  ones); SACK bits decode LSB-first from `ack_nr + 2`.
  """
  @spec decode(binary()) :: {:ok, header(), binary()} | {:error, term()}
  def decode(
        <<type_ver, ext_id, conn_id::16-big, ts::32-big, ts_diff::32-big, wnd::32-big,
          seq::16-big, ack::16-big, rest::binary>>
      ) do
    with {:ok, type} <- to_type(type_ver >>> 4),
         :ok <- check_version(type_ver &&& 0x0F),
         {:ok, sack, payload} <- decode_ext(ext_id, rest, ack) do
      {:ok,
       %{
         type: type,
         conn_id: conn_id,
         ts: ts,
         ts_diff: ts_diff,
         wnd: wnd,
         seq: seq,
         ack: ack,
         sack: sack
       }, payload}
    end
  end

  def decode(_short), do: {:error, :too_short}

  @doc """
  Renders a SACK bitmask: bit *i* (LSB-first) covers `ack_nr + 2 + i`.
  Sized up to a multiple of 4 bytes covering the highest reported
  sequence, minimum 4 bytes per the spec.
  """
  @spec sack_encode(non_neg_integer(), MapSet.t(), pos_integer()) :: binary()
  def sack_encode(ack_nr, received, len) do
    for byte <- 0..(len - 1), reduce: <<>> do
      acc -> acc <> <<sack_byte(ack_nr, received, byte)>>
    end
  end

  defp sack_byte(ack_nr, received, byte) do
    for bit <- 0..7, reduce: 0 do
      v ->
        seq = ack_nr + 2 + byte * 8 + bit &&& 0xFFFF

        if MapSet.member?(received, seq) do
          v ||| 1 <<< bit
        else
          v
        end
    end
  end

  # -- internals ---------------------------------------------------------

  defp first_ext_id(opts) do
    cond do
      Keyword.has_key?(opts, :sack) -> @ext_sack
      [{id, _} | _] = Keyword.get(opts, :raw_ext, []) -> id
    end
  end

  defp extensions(opts, header) do
    case Keyword.get(opts, :sack) do
      nil -> raw_exts(Keyword.get(opts, :raw_ext, []))
      received -> sack_ext(header.ack, received) <> raw_exts(Keyword.get(opts, :raw_ext, []))
    end
  end

  # The chain links as (next_id, len, payload); a lone extension links
  # to 0. Matches libtorrent's write path byte-for-byte.
  defp raw_exts([]), do: <<>>

  defp raw_exts([{_id, bytes} | rest]) do
    {next, tail} =
      case rest do
        [] -> {0, <<>>}
        [{next_id, _} | _] -> {next_id, raw_exts(rest)}
      end

    <<next, byte_size(bytes)>> <> bytes <> tail
  end

  defp sack_ext(ack_nr, received) do
    # Forward distance on the 16-bit ring; only used for sizing, where
    # the window is small and wraparound is unambiguous.
    max_dist = Enum.reduce(received, 1, fn seq, acc -> max(seq - ack_nr &&& 0xFFFF, acc) end)
    len = max(4, round_up4(div(max_dist + 7, 8)))
    <<0, len>> <> sack_encode(ack_nr, received, len)
  end

  defp round_up4(n), do: div(n + 3, 4) * 4

  defp to_type(int) do
    case Map.fetch(@type_names, int) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_type}
    end
  end

  defp check_version(@version), do: :ok
  defp check_version(other), do: {:error, {:bad_version, other}}

  defp decode_ext(0, payload, _ack_nr), do: {:ok, [], payload}

  defp decode_ext(_id, bytes, _ack_nr) when byte_size(bytes) < 2, do: {:error, :bad_extension}

  defp decode_ext(id, <<next, len, rest::binary>>, ack_nr) do
    if byte_size(rest) < len do
      {:error, :bad_extension}
    else
      <<payload::binary-size(^len), tail::binary>> = rest

      with {:ok, sack, tail} <- decode_one(id, payload, tail, ack_nr),
           {:ok, more, payload} <- decode_ext(next, tail, ack_nr) do
        {:ok, sack ++ more, payload}
      end
    end
  end

  defp decode_one(@ext_sack, payload, tail, ack_nr) do
    if byte_size(payload) < 4 or rem(byte_size(payload), 4) != 0 do
      {:error, :bad_sack}
    else
      {:ok, sack_decode(ack_nr, payload), tail}
    end
  end

  defp decode_one(_unknown, _payload, tail, _ack_nr), do: {:ok, [], tail}

  defp sack_decode(ack_nr, mask) do
    mask
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {byte, idx} ->
      for bit <- 0..7, (byte >>> bit &&& 1) == 1 do
        ack_nr + 2 + idx * 8 + bit &&& 0xFFFF
      end
    end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  @doc """
  Ring comparison on 16-bit sequence numbers: `a` precedes `b` when the
  forward distance is nonzero and under half the ring, per BEP-29's
  wrapping counters (libtorrent's `compare_less_wrap`).
  """
  @spec seq_lt(0..65_535, 0..65_535) :: boolean()
  def seq_lt(a, b), do: a != b and (b - a &&& 0xFFFF) < 0x8000

  @doc "True when `seq` sits strictly ahead of `ack_nr` by at most `w`."
  @spec in_window?(0..65_535, 0..65_535, non_neg_integer()) :: boolean()
  def in_window?(seq, ack_nr, w) do
    d = seq - ack_nr &&& 0xFFFF
    d >= 1 and d <= w
  end

  @doc "Initial retransmit timeout in ms, per BEP-29 §timeouts."
  @spec initial_timeout_ms :: 1_000
  def initial_timeout_ms, do: @initial_timeout_ms

  @doc "Floor for the congestion window in bytes."
  @spec min_window_bytes :: 150
  def min_window_bytes, do: @min_window_bytes

  @doc """
  RTT estimators per BEP-29 §timeouts, updated only for packets sent
  exactly once: `rtt += (sample - rtt) / 8`,
  `rtt_var += (|rtt - sample| - rtt_var) / 4`.
  """
  @spec rtt_update(number(), number(), number()) :: {float(), float()}
  def rtt_update(rtt, rtt_var, sample) do
    delta = rtt - sample
    {rtt + (sample - rtt) / 8, rtt_var + (abs(delta) - rtt_var) / 4}
  end

  @doc "Retransmit timeout: `max(rtt + 4 * rtt_var, 500)` ms."
  @spec timeout_for(number(), number()) :: float()
  def timeout_for(rtt, rtt_var), do: max(rtt + rtt_var * 4, @min_timeout_ms)

  @doc """
  LEDBAT window update per BEP-29 §congestion control: drives the
  measured buffering delay toward the 100 ms target. Grows below
  target, shrinks above, never under the 150-byte floor. `mss` scales
  the per-RTT gain into bytes.
  """
  @spec ledbat_update(non_neg_integer(), non_neg_integer(), integer(), pos_integer()) ::
          non_neg_integer()
  def ledbat_update(max_window, outstanding, our_delay_us, mss) do
    off_target = @target_delay_us - our_delay_us
    window_factor = min(1.0, outstanding / max(max_window, 1))
    gain = @gain_packets_per_rtt * mss * (off_target / @target_delay_us) * window_factor
    trunc(max(max_window + gain, @min_window_bytes))
  end
end
