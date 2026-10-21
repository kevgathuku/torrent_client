defmodule TorrentClient.Log do
  @moduledoc """
  File logging for post-mortems. Installs a `:logger_std_h` handler that
  writes debug-and-up with a level tag on every line; the console keeps
  its own level. Standard library only — no file-backend dependency.
  """

  @doc "Install the file handler (idempotent). Parent dirs are created."
  @spec setup(Path.t()) :: :ok | {:error, term()}
  def setup(path) when is_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      remove()

      :logger.add_handler(__MODULE__, :logger_std_h, %{
        config: %{file: String.to_charlist(path)},
        level: :debug,
        formatter: {:logger_formatter, %{template: [:time, " [", :level, "] ", :msg, "\n"]}}
      })
    end
  end

  @doc "Remove the file handler (no-op when absent)."
  @spec remove() :: :ok
  def remove do
    case :logger.remove_handler(__MODULE__) do
      :ok -> :ok
      {:error, {:not_found, _}} -> :ok
    end
  end
end
