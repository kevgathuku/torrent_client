defmodule TorrentClient.MSETest do
  use ExUnit.Case, async: true

  alias TorrentClient.MSE

  @info_hash :crypto.hash(:sha, "mse-fixture-info")
  @other_hash :crypto.hash(:sha, "another-fixture-info")

  test "prime is the 768-bit spec prime rendered as 96 bytes" do
    assert MSE.prime_bits() == 768
    assert MSE.prime() > 2
    assert byte_size(MSE.public_key(1)) == 96
  end

  test "random_pad stays inside the spec 0..512 range" do
    for _ <- 1..20 do
      assert byte_size(MSE.random_pad()) in 0..512
    end
  end

  test "rc4 matches the published Wikipedia vector" do
    assert MSE.rc4_oneshot("Key", "Plaintext", 0) ==
             <<0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3>>
  end

  test "rc4 stream round-trips and drops the first 1024 keystream bytes" do
    key = :crypto.strong_rand_bytes(20)
    msg = :crypto.strong_rand_bytes(68)
    {st, cipher} = MSE.rc4_crypt(MSE.rc4_new(key), msg)
    {_st2, plain} = MSE.rc4_crypt(MSE.rc4_new(key), cipher)
    assert plain == msg
    refute MSE.rc4_oneshot(key, msg, 0) == cipher
    assert byte_size(cipher) == 68
    assert tuple_size(elem(st, 0)) == 256
    assert MSE.rc4_oneshot(key, msg) == MSE.rc4_oneshot(key, msg, 1024)
  end

  test "diffie-hellman keypairs agree on a 96-byte secret" do
    a_priv = MSE.generate_private()
    b_priv = MSE.generate_private()
    a_pub = MSE.public_key(a_priv)
    b_pub = MSE.public_key(b_priv)
    assert byte_size(a_pub) == 96
    assert {:ok, secret} = MSE.shared_secret(b_pub, a_priv)
    assert {:ok, ^secret} = MSE.shared_secret(a_pub, b_priv)
    assert byte_size(secret) == 96
  end

  test "out-of-range public keys are rejected fail-closed" do
    priv = MSE.generate_private()
    assert {:error, :invalid_public_key} = MSE.shared_secret(<<0::768>>, priv)
    assert {:error, :invalid_public_key} = MSE.shared_secret(<<1, 2, 3>>, priv)
  end

  test "request hashes are 20 bytes and req2 binds the info hash" do
    secret = :crypto.strong_rand_bytes(96)
    assert byte_size(MSE.req1(secret)) == 20
    assert byte_size(MSE.req3(secret)) == 20
    assert MSE.req2(@info_hash) != MSE.req2(@other_hash)
  end

  test "stream keys differ by direction" do
    secret = :crypto.strong_rand_bytes(96)

    assert MSE.stream_key(secret, @info_hash, :initiator) !=
             MSE.stream_key(secret, @info_hash, :responder)
  end

  test "rc4_skip continues a one-shot prefix at the right keystream position" do
    key = :crypto.strong_rand_bytes(20)
    msg = :crypto.strong_rand_bytes(48)
    prefix_len = 37
    {_s, full} = MSE.rc4_crypt(MSE.rc4_new(key), :binary.copy(<<0>>, prefix_len) <> msg)
    {_s, tail} = MSE.rc4_crypt(MSE.rc4_skip(key, prefix_len), msg)
    assert binary_part(full, prefix_len, byte_size(msg)) == tail
  end

  test "parse_step4_stream consumes through a continuing stream" do
    secret = :crypto.strong_rand_bytes(96)
    key = MSE.stream_key(secret, @info_hash, :responder)
    payload = :crypto.strong_rand_bytes(16)
    {_s, c4} = MSE.rc4_crypt(MSE.rc4_new(key), step4_plain(:rc4))
    {_s, cp} = MSE.rc4_crypt(MSE.rc4_skip(key, byte_size(c4)), payload)
    # The blob plus pipelined payload decrypt through one stream.
    assert {:ok, :rc4, stream} = MSE.parse_step4_stream(MSE.rc4_new(key), c4)
    {_s, ^payload} = MSE.rc4_crypt(stream, cp)

    {_s, bad} = MSE.rc4_crypt(MSE.rc4_new(key), step4_plain(:plaintext))
    assert {:error, :unacceptable_crypto} = MSE.parse_step4_stream(MSE.rc4_new(key), bad)

    assert {:error, :bad_vc} =
             MSE.parse_step4_stream(MSE.rc4_new(key), :crypto.strong_rand_bytes(14))
  end

  defp step4_plain(select) do
    provide = if select == :rc4, do: 0x02, else: 0x01
    <<0::64, provide::32-big, 0::16-big>>
  end

  test "responder prefers rc4 over plaintext when both are provided" do
    assert {:ok, :rc4} = MSE.select_crypto(0x03)
    assert {:ok, :plaintext} = MSE.select_crypto(0x01)
    assert {:error, :no_supported_crypto} = MSE.select_crypto(0x00)
  end

  # Full initiator<->responder run: both ends built only from spec shapes,
  # so either side doubles as the known-good peer for the other.
  test "encrypted handshake interop between initiator and responder" do
    a_priv = MSE.generate_private()
    b_priv = MSE.generate_private()
    ia = :crypto.strong_rand_bytes(68)

    # 1. A -> B: Ya + PadA; B reads Ya as the first 96 bytes.
    hello_a = MSE.public_key(a_priv) <> :crypto.strong_rand_bytes(37)
    assert {:ok, ya, _pad_a} = MSE.split_hello(hello_a)

    # 2. B -> A: Yb + PadB; A reads Yb as the first 96 bytes.
    hello_b = MSE.public_key(b_priv) <> :crypto.strong_rand_bytes(113)
    assert {:ok, yb, _pad_b} = MSE.split_hello(hello_b)

    assert {:ok, secret} = MSE.shared_secret(yb, a_priv)
    assert {:ok, ^secret} = MSE.shared_secret(ya, b_priv)

    # 3. A -> B: req1, req2^req3, encrypted VC/provide/padC/IA.
    step3 = MSE.build_step3(secret, @info_hash, ia)
    step3_padded = MSE.build_step3(secret, @info_hash, ia, pad_c: :crypto.strong_rand_bytes(19))
    assert byte_size(step3_padded) > byte_size(step3)
    # B scans past PadA for req1, recovers the info hash, decrypts the rest.
    assert {:ok, _consumed, rest} = MSE.scan_for_req1(hello_a <> step3, secret)

    assert {:ok, @info_hash, ^ia, 0x02} =
             MSE.parse_step3(rest, secret, [@other_hash, @info_hash])

    # 4. B -> A: encrypted VC/select/padD; A scans past PadB for VC.
    assert {:ok, :rc4} = MSE.select_crypto(0x02)
    step4 = MSE.build_step4(secret, @info_hash, :rc4, pad_d: :crypto.strong_rand_bytes(7))
    assert {:ok, 0} = MSE.scan_for_vc(step4, secret, @info_hash)
    assert {:ok, :rc4} = MSE.parse_step4(step4, secret, @info_hash)

    # 5. Post-handshake stream: A encrypts, B decrypts and vice versa.
    ka = MSE.stream_key(secret, @info_hash, :initiator)
    kb = MSE.stream_key(secret, @info_hash, :responder)
    probe = :crypto.strong_rand_bytes(32)
    {_s, c1} = MSE.rc4_crypt(MSE.rc4_new(ka), probe)
    {_s, ^probe} = MSE.rc4_crypt(MSE.rc4_new(ka), c1)
    {_s, c2} = MSE.rc4_crypt(MSE.rc4_new(kb), probe)
    {_s, ^probe} = MSE.rc4_crypt(MSE.rc4_new(kb), c2)
  end

  test "resync scans give up past the spec bounds" do
    secret = :crypto.strong_rand_bytes(96)
    assert {:error, :req1_not_found} = MSE.scan_for_req1(:binary.copy(<<0>>, 700), secret)
    assert {:error, :vc_not_found} = MSE.scan_for_vc(:binary.copy(<<1>>, 700), secret, @info_hash)
  end

  test "step3 rejects a bad VC and a truncated negotiation" do
    a_priv = MSE.generate_private()
    b_priv = MSE.generate_private()
    {:ok, secret} = MSE.shared_secret(MSE.public_key(b_priv), a_priv)
    ia = :crypto.strong_rand_bytes(68)
    step3 = MSE.build_step3(secret, @info_hash, ia)
    {:ok, _, rest} = MSE.scan_for_req1(step3, secret)
    <<masked::binary-size(20), _::binary>> = rest
    # Random trailing bytes decrypt to a non-zero VC almost surely.
    assert {:error, :bad_vc} =
             MSE.parse_step3(masked <> :crypto.strong_rand_bytes(32), secret, [@info_hash])

    # VC prefix with a length claim the bytes cannot satisfy.
    key = MSE.stream_key(secret, @info_hash, :initiator)

    {_s, enc} =
      MSE.rc4_crypt(MSE.rc4_new(key), <<0::64, 2::32-big, 0::16-big, 5::16-big, 1, 2, 3>>)

    assert {:error, :malformed} = MSE.parse_step3(masked <> enc, secret, [@info_hash])
    assert {:error, :malformed} = MSE.parse_step3(<<1, 2, 3>>, secret, [@info_hash])
  end

  test "step4 parses plaintext selection and rejects garbage" do
    a_priv = MSE.generate_private()
    b_priv = MSE.generate_private()
    {:ok, secret} = MSE.shared_secret(MSE.public_key(b_priv), a_priv)
    step4 = MSE.build_step4(secret, @info_hash, :plaintext)
    assert {:ok, :plaintext} = MSE.parse_step4(step4, secret, @info_hash)
    assert {:error, :malformed} = MSE.parse_step4(<<1, 2, 3>>, secret, @info_hash)
    # A well-formed VC naming an unknown method fails closed, not silent.
    key = MSE.stream_key(secret, @info_hash, :responder)
    {_s, enc} = MSE.rc4_crypt(MSE.rc4_new(key), <<0::64, 0x04::32-big, 0::16-big>>)
    assert {:error, :unknown_crypto} = MSE.parse_step4(enc, secret, @info_hash)
  end

  # Residue: generate_private retries only when 20 random bytes decode to
  # zero (probability 2^-160) — not forceable without seam injection, and
  # the loop is total either way.
  test "hello and step parsers reject short garbage" do
    assert {:error, :too_short} = MSE.split_hello(<<1, 2, 3>>)

    assert {:error, :req1_not_found} =
             MSE.scan_for_req1(<<0::800>>, :crypto.strong_rand_bytes(96))

    assert {:error, :no_matching_info_hash} =
             MSE.parse_step3(<<0::400>>, :crypto.strong_rand_bytes(96), [@info_hash])

    assert {:error, :vc_not_found} =
             MSE.scan_for_vc(<<1, 2, 3>>, :crypto.strong_rand_bytes(96), @info_hash)
  end
end
