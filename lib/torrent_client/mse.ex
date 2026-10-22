defmodule TorrentClient.MSE do
  @moduledoc """
  Message Stream Encryption (MSE/PE) handshake codec, per the spec archived
  from wiki.vuze.com/w/Message_Stream_Encryption.

  Covers the Diffie-Hellman key exchange (768-bit safe prime, generator 2),
  the req1/req2/req3 synchronisation hashes, the VC/crypto_provide/select
  negotiation, and the RC4 stream (first 1024 keystream bytes discarded).

  OTP's OpenSSL build ships without RC4, so the cipher is hand-rolled here
  with bitstring syntax (~40 lines); everything else uses `:crypto`. All
  parsers are fail-closed (`{:error, reason}`, never a crash).

  This module is transport-free: it encodes/parses handshake blobs and
  encrypts the post-handshake stream, but it does not own a socket.
  `TorrentClient.PeerWorker` drives it over the sock seam when its
  `:encryption` opt is not `:plaintext`.
  """

  import Bitwise

  @prime_hex "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563"
  @prime String.to_integer(@prime_hex, 16)
  @key_size 96
  @hash_size 20
  @rc4_drop 1024
  @max_pad 512
  # Fail-fast bounds from the spec's early-termination conditions.
  @max_req1_scan 628
  @max_vc_scan 616

  @crypto_plaintext 0x01
  @crypto_rc4 0x02
  @vc <<0::64>>

  @typedoc "RC4 stream state: 256-entry S-box tuple plus i/j indices."
  @type rc4_state :: {tuple(), 0..255, 0..255}
  @type crypto :: :plaintext | :rc4

  @doc "The 768-bit DH safe prime shared with every spec peer."
  @spec prime :: pos_integer()
  def prime, do: @prime

  @doc "Bit length of the prime (768)."
  @spec prime_bits :: 768
  def prime_bits, do: 768

  # 160-bit keys, per the spec's recommendation (minimum 128).
  @doc "Generates a DH private key."
  @spec generate_private :: pos_integer()
  def generate_private do
    # Loop instead of masking: keeps the full 160-bit range uniform.
    case :binary.decode_unsigned(:crypto.strong_rand_bytes(20)) do
      0 -> generate_private()
      priv -> priv
    end
  end

  @doc "Renders `G^priv mod P` as a 96-byte big-endian public key."
  @spec public_key(pos_integer()) :: <<_::768>>
  def public_key(priv) do
    2 |> powmod(priv) |> pad96()
  end

  @doc """
  Derives the 96-byte shared secret from the peer's public key. Rejects
  degenerate keys (`< 2` or `>= P - 1`) fail-closed, as libtorrent does.
  """
  @spec shared_secret(binary(), pos_integer()) :: {:ok, binary()} | {:error, :invalid_public_key}
  def shared_secret(their_pub, my_priv) when byte_size(their_pub) == @key_size do
    n = :binary.decode_unsigned(their_pub)

    if n >= 2 and n < @prime - 1 do
      {:ok, n |> powmod(my_priv) |> pad96()}
    else
      {:error, :invalid_public_key}
    end
  end

  def shared_secret(_their_pub, _my_priv), do: {:error, :invalid_public_key}

  @doc "Synchronisation marker the responder scans for: `SHA1('req1' <> S)`."
  @spec req1(binary()) :: <<_::160>>
  def req1(secret), do: :crypto.hash(:sha, "req1" <> secret)

  @doc "Info-hash proof, `SHA1('req2' <> SKEY)`, tried against each served torrent."
  @spec req2(binary()) :: <<_::160>>
  def req2(skey), do: :crypto.hash(:sha, "req2" <> skey)

  @doc "Mask the SKEY proof is XORed with: `SHA1('req3' <> S)`."
  @spec req3(binary()) :: <<_::160>>
  def req3(secret), do: :crypto.hash(:sha, "req3" <> secret)

  @doc "RC4 key for one direction: `SHA1('keyA'/'keyB' <> S <> SKEY)`."
  @spec stream_key(binary(), binary(), :initiator | :responder) :: <<_::160>>
  def stream_key(secret, skey, :initiator), do: :crypto.hash(:sha, "keyA" <> secret <> skey)
  def stream_key(secret, skey, :responder), do: :crypto.hash(:sha, "keyB" <> secret <> skey)

  @doc "Fresh RC4 state for `key`, with the first 1024 keystream bytes discarded."
  @spec rc4_new(binary()) :: rc4_state()
  def rc4_new(key) when is_binary(key) do
    {ksa(key), 0, 0} |> drop(@rc4_drop)
  end

  @doc "Encrypts/decrypts `data` through the stream, threading the state."
  @spec rc4_crypt(rc4_state(), binary()) :: {rc4_state(), binary()}
  def rc4_crypt(state, data) when is_binary(data) do
    {state, out} = crypt_bytes(state, data, [])
    {state, :erlang.list_to_binary(:lists.reverse(out))}
  end

  @doc "One-shot RC4, discarding `drop` keystream bytes first (1024 per spec)."
  @spec rc4_oneshot(binary(), binary(), non_neg_integer()) :: binary()
  def rc4_oneshot(key, data, drop \\ @rc4_drop) do
    {_state, out} = rc4_crypt(drop({ksa(key), 0, 0}, drop), data)
    out
  end

  @doc """
  Fresh RC4 state advanced past `n` keystream bytes. Continues a stream
  whose prefix was encrypted one-shot (the handshake builders below),
  so later payload calls line up with the peer's continuous stream.
  """
  @spec rc4_skip(binary(), non_neg_integer()) :: rc4_state()
  def rc4_skip(key, n) do
    {stream, _} = rc4_crypt(rc4_new(key), :binary.copy(<<0>>, n))
    stream
  end

  @doc "Random 0..512-byte padding, per the spec's PadA/PadB range."
  @spec random_pad :: binary()
  def random_pad, do: :crypto.strong_rand_bytes(:rand.uniform(@max_pad + 1) - 1)

  @doc "Splits a step-1/2 hello into its 96-byte public key and trailing pad."
  @spec split_hello(binary()) :: {:ok, binary(), binary()} | {:error, :too_short}
  def split_hello(<<pub::binary-size(@key_size), rest::binary>>), do: {:ok, pub, rest}
  def split_hello(_short), do: {:error, :too_short}

  @doc """
  Scans `data` for `req1` (the responder resync past PadA), searching at
  most #{@max_req1_scan} bytes per the spec bound. Returns the byte count
  consumed (req1 included) and what follows it.
  """
  @spec scan_for_req1(binary(), binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :req1_not_found}
  def scan_for_req1(data, secret) do
    scan_req1(data, req1(secret), 0)
  end

  @doc """
  Builds step 3: `req1`, the masked SKEY proof, then the RC4-encrypted
  `VC || provide || len(PadC) || PadC || len(IA)` followed by encrypted IA.
  """
  @spec build_step3(binary(), binary(), binary(), keyword()) :: binary()
  def build_step3(secret, skey, ia, opts \\ []) do
    provide = Keyword.get(opts, :provide, @crypto_rc4)
    pad_c = Keyword.get(opts, :pad_c, <<>>)
    key = stream_key(secret, skey, :initiator)
    masked = :crypto.exor(req2(skey), req3(secret))

    header =
      @vc <> <<provide::32-big, byte_size(pad_c)::16-big>> <> pad_c <> <<byte_size(ia)::16-big>>

    {_state, encrypted} = rc4_crypt(rc4_new(key), header <> ia)
    req1(secret) <> masked <> encrypted
  end

  @doc """
  Parses step 3 after `scan_for_req1`: XORs the proof field with `req3`
  and matches it against each candidate SKEY, then decrypts and checks VC.
  """
  @spec parse_step3(binary(), binary(), [binary()]) ::
          {:ok, binary(), binary(), non_neg_integer()}
          | {:error, :no_matching_info_hash | :bad_vc | :malformed}
  def parse_step3(<<masked::binary-size(@hash_size), rest::binary>>, secret, skeys) do
    proof = :crypto.exor(masked, req3(secret))

    case Enum.find(skeys, fn skey -> req2(skey) == proof end) do
      nil ->
        {:error, :no_matching_info_hash}

      skey ->
        {_state, plain} = rc4_crypt(rc4_new(stream_key(secret, skey, :initiator)), rest)

        case parse_negotiation(plain) do
          {:ok, ia, provide} -> {:ok, skey, ia, provide}
          {:error, _} = err -> err
        end
    end
  end

  def parse_step3(_short, _secret, _skeys), do: {:error, :malformed}

  @doc "Builds step 4: the RC4-encrypted `VC || select || len(PadD) || PadD`."
  @spec build_step4(binary(), binary(), crypto(), keyword()) :: binary()
  def build_step4(secret, skey, select, opts \\ []) do
    pad_d = Keyword.get(opts, :pad_d, <<>>)
    plain = @vc <> <<crypto_to_int(select)::32-big, byte_size(pad_d)::16-big>> <> pad_d
    {_state, encrypted} = rc4_crypt(rc4_new(stream_key(secret, skey, :responder)), plain)
    encrypted
  end

  @doc "Parses step 4 (already resynced): checks VC and returns the selection."
  @spec parse_step4(binary(), binary(), binary()) ::
          {:ok, crypto()} | {:error, :bad_vc | :malformed | :unknown_crypto}
  def parse_step4(data, secret, skey) do
    {_state, plain} = rc4_crypt(rc4_new(stream_key(secret, skey, :responder)), data)

    case plain do
      <<@vc::binary, select::32-big, len_d::16-big, pad_d::binary>>
      when byte_size(pad_d) == len_d ->
        int_to_crypto(select)

      _other ->
        {:error, :malformed}
    end
  end

  @doc """
  Decrypts one step-4 blob through a continuing responder stream (the
  peer's ENCRYPT stream runs past negotiation into the payload, so the
  caller replays the exact bytes it peeked, never a fresh stream). Only
  an RC4 selection is acceptable — anything else is a downgrade.
  """
  @spec parse_step4_stream(rc4_state(), binary()) ::
          {:ok, crypto(), rc4_state()} | {:error, :bad_vc | :unacceptable_crypto}
  def parse_step4_stream(stream, cipher) do
    {stream, plain} = rc4_crypt(stream, cipher)

    case plain do
      <<@vc::binary, @crypto_rc4::32-big, len::16-big, pad::binary>>
      when byte_size(pad) == len ->
        {:ok, :rc4, stream}

      <<@vc::binary, _select::32-big, _::binary>> ->
        {:error, :unacceptable_crypto}

      _other ->
        {:error, :bad_vc}
    end
  end

  @doc """
  Scans `data` for the responder's VC (the initiator resync past PadB),
  bounded by the spec's 616-byte limit. Returns the offset where step 4
  starts. Decrypting any 8-byte window with a fresh stream equals XORing
  it with the same keystream prefix, so matching the encrypted marker
  directly is equivalent to per-offset decryption, at one KSA cost.
  """
  @spec scan_for_vc(binary(), binary(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :vc_not_found}
  def scan_for_vc(data, secret, skey) do
    marker = rc4_oneshot(stream_key(secret, skey, :responder), @vc)
    window = binary_part(data, 0, min(byte_size(data), @max_vc_scan + 8))

    case :binary.match(window, marker) do
      {offset, _len} -> {:ok, offset}
      :nomatch -> {:error, :vc_not_found}
    end
  end

  @doc "Picks the responder's crypto: RC4 when offered, else plaintext, else refuse."
  @spec select_crypto(non_neg_integer()) :: {:ok, crypto()} | {:error, :no_supported_crypto}
  def select_crypto(provide) do
    cond do
      (provide &&& @crypto_rc4) != 0 -> {:ok, :rc4}
      (provide &&& @crypto_plaintext) != 0 -> {:ok, :plaintext}
      true -> {:error, :no_supported_crypto}
    end
  end

  # -- internals ---------------------------------------------------------

  defp powmod(base, exp), do: :crypto.mod_pow(base, exp, @prime)

  defp pad96(bin) do
    pad = @key_size - byte_size(bin)
    if pad > 0, do: <<0::size(pad)-unit(8)>> <> bin, else: bin
  end

  defp parse_negotiation(plain) do
    case plain do
      <<@vc::binary, provide::32-big, len_c::16-big, _pad_c::binary-size(len_c), len_ia::16-big,
        tail::binary>>
      when byte_size(tail) == len_ia ->
        {:ok, tail, provide}

      <<@vc::binary, _::binary>> ->
        {:error, :malformed}

      _other ->
        {:error, :bad_vc}
    end
  end

  defp scan_req1(data, marker, offset) do
    cond do
      byte_size(data) < @hash_size ->
        {:error, :req1_not_found}

      offset > @max_req1_scan ->
        {:error, :req1_not_found}

      :binary.part(data, 0, @hash_size) == marker ->
        {:ok, offset + @hash_size, :binary.part(data, @hash_size, byte_size(data) - @hash_size)}

      true ->
        scan_req1(:binary.part(data, 1, byte_size(data) - 1), marker, offset + 1)
    end
  end

  defp crypto_to_int(:plaintext), do: @crypto_plaintext
  defp crypto_to_int(:rc4), do: @crypto_rc4

  defp int_to_crypto(@crypto_plaintext), do: {:ok, :plaintext}
  defp int_to_crypto(@crypto_rc4), do: {:ok, :rc4}
  defp int_to_crypto(_other), do: {:error, :unknown_crypto}

  # -- RC4 ---------------------------------------------------------------

  defp ksa(key) do
    len = byte_size(key)

    {_, s} =
      Enum.reduce(0..255, {0, List.to_tuple(Enum.to_list(0..255))}, fn i, {j, s} ->
        j = j + elem(s, i) + :binary.at(key, rem(i, len)) &&& 0xFF
        {j, swap(s, i, j)}
      end)

    s
  end

  defp swap(s, i, j) do
    vi = elem(s, i)
    s |> put_elem(i, elem(s, j)) |> put_elem(j, vi)
  end

  defp prga_byte({s, i, j}) do
    i = i + 1 &&& 0xFF
    j = j + elem(s, i) &&& 0xFF
    s = swap(s, i, j)
    {{s, i, j}, elem(s, elem(s, i) + elem(s, j) &&& 0xFF)}
  end

  defp drop(state, 0), do: state

  defp drop(state, n) do
    {state, _} = prga_byte(state)
    drop(state, n - 1)
  end

  defp crypt_bytes(state, <<>>, acc), do: {state, acc}

  defp crypt_bytes(state, <<b, rest::binary>>, acc) do
    {state, k} = prga_byte(state)
    crypt_bytes(state, rest, [bxor(b, k) | acc])
  end
end
