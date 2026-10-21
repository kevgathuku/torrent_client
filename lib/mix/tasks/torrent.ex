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

  Addressing is exact hex id first, unique id prefix second, torrent
  path third. `remove` prompts before deleting data, defaulting to keep
  a complete torrent's files and delete an incomplete one's; `--yes`
  skips the prompt, `--dry-run` only lists what would go.

  The session's listen port and config file are `Session.start_link`
  opts (releases: `config :torrent_client, session: [...]`).
  """

  use Mix.Task

  alias TorrentClient.Session

  @impl true
  def run([]),
    do: Mix.raise("usage: mix torrent (parse|download|status|pause|resume|forget|remove) ...")

  def run(["parse" | args]), do: parse(args)
  def run(["download" | args]), do: download(args)
  def run(["status" | args]), do: status(args)
  def run(["pause" | args]), do: control(:pause, args)
  def run(["resume" | args]), do: control(:resume, args)
  def run(["forget" | args]), do: control(:forget, args)
  def run(["remove" | args]), do: remove(args)
  def run([verb | _]), do: Mix.raise("unknown torrent command: #{verb}")

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
        {:ok, ^id, _} = Session.remove(id_or_path)
        Mix.shell().info("removed #{id} (#{length(files)} file(s))")

      true ->
        Mix.shell().info("kept #{id} (still tracked)")
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
