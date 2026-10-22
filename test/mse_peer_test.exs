defmodule MsePeerTest do
  @moduledoc """
  The MSE-encrypted peer path: loopback responders speaking the handshake
  from `TorrentClient.MSE`, proving the worker completes a piece over an
  actually-encrypted stream, falls back to plaintext when asked, and fails
  closed otherwise.
  """
  use ExUnit.Case, async: true

  import Mox

  setup :set_mox_private
  setup :verify_on_exit!

  alias TorrentClient.{Disk, MSE, PeerWorker}

  alias PeerMessage.{Bitfield, Interested, Piece, Request, Unchoke}

  defmodule CountingSock do
    @moduledoc false
    # Real loopback bytes, but sends at/after `fail_at` fail a fixed way:
    # proves the encrypted send path fails closed on transport errors.
    @behaviour TorrentClient.SocketBehaviour

    def send({real, counter}, bytes) do
      {n, fail_at, kind} =
        Agent.get_and_update(counter, fn {c, f, k} -> {{c, f, k}, {c + 1, f, k}} end)

      if n + 1 >= fail_at do
        case kind do
          :error -> {:error, :closed}
          :raise -> raise "boom"
        end
      else
        TorrentClient.GenTcpSocket.send(real, bytes)
      end
    end

    def recv({real, _counter}, count, timeout),
      do: TorrentClient.GenTcpSocket.recv(real, count, timeout)

    def close({real, _counter}), do: TorrentClient.GenTcpSocket.close(real)
  end

  @peer_id String.duplicate("T", 20)
  @fake_id String.duplicate("F", 20)
  @piece_length 32_768

  setup do
    base = Path.join(System.tmp_dir!(), "kog41-mse-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    info = %{:"piece length" => @piece_length, name: "f.bin", length: @piece_length}
    :ok = Disk.init_layout(base, info)
    data = :crypto.strong_rand_bytes(@piece_length)

    %{base: base, info: info, data: data, hash: :crypto.hash(:sha, data)}
  end

  defp worker_opts(ctx, info_hash, port, extra \\ []) do
    Keyword.merge(
      [
        peer: %Peer{ip_tuple: {127, 0, 0, 1}, port: port},
        info_hash: info_hash,
        peer_id: @peer_id,
        info: ctx.info,
        piece_index: 0,
        piece_hash: ctx.hash,
        base_dir: ctx.base,
        recv_timeout: 2_000
      ],
      extra
    )
  end

  defp listen! do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  # -- MSE responder -----------------------------------------------------

  # Full MSE responder: DH, step 3/4, then serves piece 0 over RC4.
  # `select` is the crypto the responder picks (:rc4 serves, anything
  # else proves the worker rejects a plaintext downgrade).
  defp serve_mse(listen, info_hash, data, parent, select, pad_d \\ <<>>) do
    spawn(fn -> mse_responder(listen, info_hash, data, parent, select, pad_d) end)
  end

  defp mse_responder(listen, info_hash, data, parent, select, pad_d) do
    {:ok, sock} = :gen_tcp.accept(listen, 5_000)
    {:ok, ya} = :gen_tcp.recv(sock, 96, 5_000)
    priv = MSE.generate_private()
    :ok = :gen_tcp.send(sock, MSE.public_key(priv) <> :crypto.strong_rand_bytes(19))
    {:ok, secret} = MSE.shared_secret(ya, priv)
    {:ok, rest} = recv_until_req(sock, secret, <<>>)
    {:ok, ^info_hash, ia, _provide} = MSE.parse_step3(rest, secret, [info_hash])

    ia_ok =
      try do
        {:ok, %Handshake{info_hash: ^info_hash}} = Handshake.deserialize(ia)
        true
      rescue
        _ -> false
      end

    # The IA handshake must have arrived as ciphertext, never as the
    # plaintext greeting the wire would show without encryption.
    <<_masked::binary-size(20), cipher::binary>> = rest
    send(parent, {:mse_proof, ia_ok and :binary.match(cipher, ia) == :nomatch})

    c4 = MSE.build_step4(secret, info_hash, select, pad_d: pad_d)
    kb = MSE.stream_key(secret, info_hash, :responder)
    # The responder's ENCRYPT stream is continuous: step 4, then payload.
    # Fast-forward past the step-4 bytes before encrypting the handshake.
    {sst, _} = MSE.rc4_crypt(MSE.rc4_new(kb), :binary.copy(<<0>>, byte_size(c4)))

    {sst, hs_cipher} =
      MSE.rc4_crypt(sst, Handshake.init(info_hash, @fake_id) |> Handshake.serialize())

    if select == :rc4 do
      # One segment: responders commonly pipeline payload right after
      # step 4, so the worker must resync without a readahead buffer.
      :ok = :gen_tcp.send(sock, c4 <> hs_cipher)
      ka = MSE.stream_key(secret, info_hash, :initiator)
      # Same continuity the other way: the initiator's stream runs past
      # step 3, so skip its encrypted bytes (all of rest past the proof).
      {rst, _} = MSE.rc4_crypt(MSE.rc4_new(ka), :binary.copy(<<0>>, byte_size(rest) - 20))
      serve_encrypted(sock, data, parent, rst, sst, false, <<>>)
    else
      :ok = :gen_tcp.send(sock, c4)
    end
  end

  defp recv_until_req(sock, secret, buf) do
    case MSE.scan_for_req1(buf, secret) do
      {:ok, _consumed, rest} ->
        {:ok, rest}

      {:error, :req1_not_found} when byte_size(buf) < 1_200 ->
        {:ok, chunk} = :gen_tcp.recv(sock, 0, 5_000)
        recv_until_req(sock, secret, buf <> chunk)

      {:error, _} = err ->
        err
    end
  end

  defp serve_encrypted(sock, data, parent, rst, sst, greeted, buf) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} ->
        {rst, plain} = MSE.rc4_crypt(rst, chunk)
        {sst, greeted, rest} = serve_frames(sock, data, sst, greeted, buf <> plain)
        serve_encrypted(sock, data, parent, rst, sst, greeted, rest)

      {:error, :closed} ->
        send(parent, :responder_done)
    end
  end

  # Only complete frames are consumed; the partial tail stays buffered
  # for the next chunk.
  defp serve_frames(sock, data, sst, greeted, <<len::32-big, rest::binary>>)
       when byte_size(rest) >= len do
    <<payload::binary-size(len), tail::binary>> = rest
    {:ok, msg, <<>>} = PeerMessage.decode(<<len::32-big, payload::binary>>)
    {sst, greeted} = handle_encrypted(sock, data, sst, greeted, msg)
    serve_frames(sock, data, sst, greeted, tail)
  end

  defp serve_frames(_sock, _data, sst, greeted, partial), do: {sst, greeted, partial}

  # First contact arms the piece offer; anything else is served or ignored.
  defp handle_encrypted(sock, _data, sst, false, %Interested{}) do
    {:ok, bits} = PeerMessage.encode(%Bitfield{bits: <<0b10000000>>})
    {:ok, unchoke} = PeerMessage.encode(%Unchoke{})
    {sst, c1} = MSE.rc4_crypt(sst, bits)
    {sst, c2} = MSE.rc4_crypt(sst, unchoke)
    :ok = :gen_tcp.send(sock, c1 <> c2)
    {sst, true}
  end

  defp handle_encrypted(sock, data, sst, greeted, %Request{index: 0, begin: begin, length: length}) do
    {:ok, frame} =
      PeerMessage.encode(%Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})

    {sst, cipher} = MSE.rc4_crypt(sst, frame)
    :ok = :gen_tcp.send(sock, cipher)
    {sst, greeted}
  end

  defp handle_encrypted(_sock, _data, sst, greeted, _other), do: {sst, greeted}

  # -- legacy plaintext seed ----------------------------------------------

  # Legacy peer: drops non-handshake bytes and keeps listening, serves
  # plaintext once a valid greeting arrives. Reports each accept.
  defp serve_legacy(listen, info_hash, data, parent) do
    spawn(fn -> legacy_loop(listen, info_hash, data, parent, 1) end)
  end

  defp legacy_loop(listen, info_hash, data, parent, n) do
    {:ok, sock} = :gen_tcp.accept(listen, 10_000)
    send(parent, {:accepted, n})

    with {:ok, bytes} <- :gen_tcp.recv(sock, 68, 5_000),
         {:ok, %Handshake{info_hash: ^info_hash}} <- safe_handshake(bytes) do
      :ok = :gen_tcp.send(sock, Handshake.init(info_hash, @fake_id) |> Handshake.serialize())
      {:ok, %Interested{}, <<>>} = recv_frame(sock)
      {:ok, %Unchoke{}, <<>>} = recv_frame(sock)
      send_message(sock, %Bitfield{bits: <<0b10000000>>})
      send_message(sock, %Unchoke{})
      serve_piece(sock, data)
      serve_piece(sock, data)
      send(parent, :legacy_done)
    else
      _ ->
        :gen_tcp.close(sock)
        legacy_loop(listen, info_hash, data, parent, n + 1)
    end
  end

  defp safe_handshake(bytes) do
    Handshake.deserialize(bytes)
  rescue
    _ -> {:error, :bad_handshake}
  end

  defp recv_frame(sock) do
    {:ok, <<length::32-big>>} = :gen_tcp.recv(sock, 4, 5_000)
    {:ok, payload} = :gen_tcp.recv(sock, length, 5_000)
    PeerMessage.decode(<<length::32-big, payload::binary>>)
  end

  defp send_message(sock, message) do
    {:ok, bytes} = PeerMessage.encode(message)
    :ok = :gen_tcp.send(sock, bytes)
  end

  defp serve_piece(sock, data) do
    {:ok, %Request{index: 0, begin: begin, length: length}, <<>>} = recv_frame(sock)
    send_message(sock, %Piece{index: 0, begin: begin, block: binary_part(data, begin, length)})
  end

  # -- tests ---------------------------------------------------------------

  test "require_mse completes a piece over the encrypted stream", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()
    serve_mse(listen, info_hash, ctx.data, parent, :rc4)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, encryption: :require_mse))

    assert_receive {:EXIT, ^pid, :normal}, 8_000
    assert_receive {:mse_proof, true}, 1_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "require_mse rejects a plaintext downgrade", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()
    serve_mse(listen, info_hash, ctx.data, parent, :plaintext, <<0, 1, 2, 3, 4, 5, 6>>)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, encryption: :require_mse))

    assert_receive {:EXIT, ^pid, {:mse_failed, :unacceptable_crypto}}, 8_000
  end

  test "prefer_mse falls back to plaintext on a fresh connection", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()
    serve_legacy(listen, info_hash, ctx.data, parent)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, encryption: :prefer_mse))

    assert_receive {:EXIT, ^pid, :normal}, 8_000
    assert_receive {:accepted, 1}, 1_000
    assert_receive {:accepted, 2}, 5_000
    assert_receive :legacy_done, 5_000
    assert Disk.read_piece(ctx.base, ctx.info, 0) == {:ok, ctx.data}
  end

  test "require_mse fails closed with no retry against a legacy peer", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    parent = self()
    {listen, port} = listen!()
    serve_legacy(listen, info_hash, ctx.data, parent)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, encryption: :require_mse))

    assert_receive {:EXIT, ^pid, {:mse_failed, _}}, 8_000
    assert_receive {:accepted, 1}, 1_000
    refute_receive {:accepted, 2}, 500
  end

  test "require_mse gives up when resync never lands", ctx do
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, _ya} = :gen_tcp.recv(sock, 96, 5_000)
      :ok = :gen_tcp.send(sock, :crypto.strong_rand_bytes(800))
      :timer.sleep(8_000)
    end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, :crypto.strong_rand_bytes(20), port, encryption: :require_mse)
      )

    assert_receive {:EXIT, ^pid, {:mse_failed, _}}, 8_000
  end

  test "require_mse fails closed when the peer goes quiet mid-handshake", ctx do
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, ya} = :gen_tcp.recv(sock, 96, 5_000)
      # Valid Yb gets the worker past DH, then silence: the resync
      # loop must fail on the closed stream, not hang or crash.
      :ok = :gen_tcp.send(sock, MSE.public_key(MSE.generate_private()))
      :ok = :gen_tcp.shutdown(sock, :write)
      {:ok, _step3} = :gen_tcp.recv(sock, 0, 8_000)
    end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(
        worker_opts(ctx, :crypto.strong_rand_bytes(20), port, encryption: :require_mse)
      )

    assert_receive {:EXIT, ^pid, {:mse_failed, _}}, 8_000
  end

  test "require_mse fails closed on a truncated negotiation", ctx do
    info_hash = :crypto.strong_rand_bytes(20)
    {listen, port} = listen!()

    spawn(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, 5_000)
      {:ok, ya} = :gen_tcp.recv(sock, 96, 5_000)
      priv = MSE.generate_private()
      {:ok, secret} = MSE.shared_secret(ya, priv)
      c4 = MSE.build_step4(secret, info_hash, :rc4)
      # Yb, PadB, then only a fragment of step 4 before going quiet:
      # the VC resync lands but the header never completes.
      :ok =
        :gen_tcp.send(
          sock,
          MSE.public_key(priv) <> :crypto.strong_rand_bytes(19) <> binary_part(c4, 0, 10)
        )

      :ok = :gen_tcp.shutdown(sock, :write)
      {:ok, _step3} = :gen_tcp.recv(sock, 0, 8_000)
    end)

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      PeerWorker.start_link(worker_opts(ctx, info_hash, port, encryption: :require_mse))

    assert_receive {:EXIT, ^pid, {:mse_failed, :peer_closed}}, 8_000
  end

  for {kind, reason} <- [error: :closed, raise: :badarg] do
    test "encrypted sends fail closed on transport #{kind}", ctx do
      info_hash = :crypto.strong_rand_bytes(20)
      parent = self()
      {listen, port} = listen!()
      serve_mse(listen, info_hash, ctx.data, parent, :rc4)
      {:ok, counter} = Agent.start_link(fn -> {0, 3, unquote(kind)} end)

      stub(TorrentClient.NetworkMock, :connect, fn %Peer{port: port} ->
        {:ok, real} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
        {:ok, {real, counter}}
      end)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        PeerWorker.start_link(
          worker_opts(ctx, info_hash, port,
            encryption: :require_mse,
            network: TorrentClient.NetworkMock,
            sock: CountingSock
          )
        )

      # Hello + step 3 go out; the first encrypted message does not.
      assert_receive {:EXIT, ^pid, {:send_failed, unquote(reason)}}, 8_000
    end
  end

  test "rejects an unknown encryption mode at start", ctx do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_encryption} =
             PeerWorker.start_link(
               worker_opts(
                 %{
                   info: %{:"piece length" => 1, name: "x", length: 1},
                   base: System.tmp_dir!(),
                   hash: :crypto.hash(:sha, "x")
                 },
                 :crypto.strong_rand_bytes(20),
                 1,
                 encryption: :bogus
               )
             )
  end
end
