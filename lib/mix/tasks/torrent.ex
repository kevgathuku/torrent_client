defmodule Mix.Tasks.Torrent do
  @shortdoc "Manage torrents: parse, download, pause, resume, status, forget, remove"

  @moduledoc """
  Thin entry points over `TorrentClient.Session` (remsh/rpc covers
  anything fancier — no custom control protocol here).

      mix torrent parse PATH
      mix torrent download PATH [--dir DIR] [--timeout MS]
      mix torrent status [ID_OR_PATH]
      mix torrent pause ID_OR_PATH
      mix torrent resume ID_OR_PATH
      mix torrent forget ID_OR_PATH
      mix torrent remove ID_OR_PATH [--yes] [--dry-run]

  Prepend `--log-level <debug|info|warning|error>` (or `--log-level=<lvl>`)
  to any command to set the console log level; it defaults to `info`.
  The file log always records debug-and-up regardless of the flag, e.g.
  `mix torrent --log-level debug download path/to/file.torrent` narrates
  per-tracker announce outcomes on the console too.

  Addressing is exact hex id first, unique id prefix second, torrent
  path third. `resume` of a torrent file the session never saw re-adds
  it, continuing from on-disk resume state. `remove` prompts before deleting data, defaulting to keep
  a complete torrent's files and delete an incomplete one's; `--yes`
  skips the prompt, `--dry-run` only lists what would go.

  The session's listen port and config file are `Session.start_link`
  opts (releases: `config :torrent_client, session: [...]`).
  """

  use Mix.Task

  alias TorrentClient.Session

  @log_levels ~w(debug info warning error)

  @impl true
  def run(argv) do
    {level, argv} = pop_log_level(argv)
    set_console_level(level)
    dispatch(argv)
  end

  defp dispatch([]),
    do: Mix.raise("usage: mix torrent (parse|download|status|pause|resume|forget|remove) ...")

  defp dispatch(["parse" | args]), do: parse(args)
  defp dispatch(["download" | args]), do: download(args)
  defp dispatch(["status" | args]), do: status(args)
  defp dispatch(["pause" | args]), do: control(:pause, args)
  defp dispatch(["resume" | args]), do: resume(args)
  defp dispatch(["forget" | args]), do: control(:forget, args)
  defp dispatch(["remove" | args]), do: remove(args)
  defp dispatch([verb | _]), do: Mix.raise("unknown torrent command: #{verb}")

  # Global flag, accepted anywhere in the argv: `--log-level LVL` or
  # `--log-level=LVL`. The console defaults to info; the file log is
  # always debug-and-up (see TorrentClient.Log).
  defp pop_log_level(argv) do
    idx =
      Enum.find_index(argv, &(&1 == "--log-level" or String.starts_with?(&1, "--log-level=")))

    case idx do
      nil ->
        {"info", argv}

      i ->
        case Enum.at(argv, i) do
          "--log-level" ->
            {Enum.at(argv, i + 1), argv |> List.delete_at(i) |> List.delete_at(i)}

          prefixed ->
            {String.replace_prefix(prefixed, "--log-level=", ""), List.delete_at(argv, i)}
        end
    end
  end

  defp set_console_level(level) when level in @log_levels do
    :ok = :logger.set_handler_config(:default, :level, String.to_existing_atom(level))
  end

  defp set_console_level(level) do
    Mix.raise(
      "--log-level must be one of #{Enum.join(@log_levels, ", ")}, got: #{inspect(level)}"
    )
  end

  # -- commands ----------------------------------------------------------

  defp parse([path | _]) do
    with {:ok, bytes} <- File.read(path),
         {:ok, bento, info} <- Torrent.parse_bytes(bytes),
         hashes when is_list(hashes) <- Torrent.get_piece_hashes(bento) do
      Mix.shell().info("info_hash: #{Torrent.info_hash(info)}")

      Mix.shell().info("pieces: #{length(hashes)} total: #{Torrent.remaining(bento)} bytes")
    else
      _ -> Mix.raise("cannot parse #{path}")
    end
  end

  defp parse([]), do: Mix.raise("usage: mix torrent parse PATH")

  defp download(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: [dir: :string, timeout: :integer])

    path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("usage: mix torrent download PATH [--dir DIR]")
      end

    ensure_session()

    add_opts =
      [base_dir: opts[:dir], announce_timeout: opts[:timeout] || 10_000]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    id =
      case Session.add_torrent(path, add_opts) do
        {:ok, id} -> id
        {:error, reason} -> Mix.raise("cannot add #{path}: #{inspect(reason)}")
      end

    Mix.shell().info("added #{id}")

    case await_terminal(id) do
      :complete -> Mix.shell().info("complete #{id}")
      terminal -> Mix.raise("#{path}: #{terminal}")
    end
  end

  defp status(args) do
    ensure_session()

    entries =
      case args do
        [] ->
          Session.status()

        [want | _] ->
          Enum.filter(Session.status(), fn entry ->
            entry.id == want or entry.path == want or String.starts_with?(entry.id, want)
          end)
      end

    Enum.each(entries, fn entry ->
      Mix.shell().info("#{entry.id}  #{entry.status}  #{entry.path}  -> #{entry.base_dir}")
    end)
  end

  # Resume restarts a known entry; for a torrent the session never saw
  # (fresh node after a kill, or a forgotten entry) it degrades to
  # adding it, which loads the on-disk resume state and continues.
  # Anything that is not a torrent file stays a not_found error.
  defp resume([]), do: Mix.raise("usage: mix torrent resume ID_OR_PATH")

  defp resume([id_or_path | _] = args) do
    ensure_session()

    case Session.resume(id_or_path) do
      {:ok, id} ->
        Mix.shell().info("resume #{id}")

      {:error, :not_found} ->
        if File.regular?(id_or_path) do
          download(args)
        else
          Mix.raise("resume #{id_or_path}: :not_found")
        end

      {:error, reason} ->
        Mix.raise("resume #{id_or_path}: #{inspect(reason)}")
    end
  end

  defp control(action, args) do
    id_or_path =
      case args do
        [id_or_path | _] -> id_or_path
        [] -> Mix.raise("usage: mix torrent #{action} ID_OR_PATH")
      end

    ensure_session()

    case apply(Session, action, [id_or_path]) do
      {:ok, id} -> Mix.shell().info("#{action} #{id}")
      {:error, reason} -> Mix.raise("#{action} #{id_or_path}: #{inspect(reason)}")
    end
  end

  defp remove(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: [yes: :boolean, dry_run: :boolean])

    id_or_path =
      case positional do
        [id_or_path | _] -> id_or_path
        [] -> Mix.raise("usage: mix torrent remove ID_OR_PATH [--yes] [--dry-run]")
      end

    ensure_session()

    # Dry-run first: it resolves prefixes through the session and reports
    # the canonical id for the prompt below.
    {id, files} =
      case Session.remove(id_or_path, dry_run: true) do
        {:ok, id, files} -> {id, files}
        {:error, reason} -> Mix.raise("remove #{id_or_path}: #{inspect(reason)}")
      end

    cond do
      opts[:dry_run] ->
        Mix.shell().info("would delete #{length(files)} file(s):")
        Enum.each(files, &Mix.shell().info("  #{&1}"))

      opts[:yes] || confirmed?(id, files) ->
        do_remove(id_or_path, id, files)

      true ->
        Mix.shell().info("kept #{id} (still tracked)")
    end
  end

  defp do_remove(id_or_path, id, files) do
    case Session.remove(id_or_path) do
      {:ok, ^id, _} -> Mix.shell().info("removed #{id} (#{length(files)} file(s))")
      {:error, reason} -> Mix.raise("remove #{id}: #{inspect(reason)}")
    end
  end

  # -- helpers -----------------------------------------------------------

  defp ensure_session do
    {:ok, _} = Application.ensure_all_started(:torrent_client)
    :ok
  end

  defp await_terminal(id) do
    case Enum.find(Session.status(), &(&1.id == id)) do
      %{status: status} when status in [:complete, :exhausted, :stalled] ->
        status

      nil ->
        Mix.raise("torrent gone: #{id}")

      _ ->
        Process.sleep(1_000)
        await_terminal(id)
    end
  end

  # A complete torrent probably keeps its files; an incomplete one
  # probably deletes them. The prompt defaults accordingly; IO.gets
  # (not the shell) so tests can feed stdin through ExUnit.CaptureIO.
  defp confirmed?(id, files) do
    complete? = match?(%{status: :complete}, Enum.find(Session.status(), &(&1.id == id)))
    hint = if complete?, do: "y/N", else: "Y/n"

    # to_string(nil) is "": EOF from a closed stdin takes the default.
    case IO.gets("delete #{length(files)} file(s) of #{id}? [#{hint}] ") |> to_string() do
      answer ->
        case answer |> String.trim() |> String.downcase() do
          "y" -> true
          "yes" -> true
          "" -> not complete?
          _ -> false
        end
    end
  end
end
