defmodule TorrentClient.DiskBehaviour do
  @moduledoc """
  Disk edge for piece storage and resume state. The real implementation uses
  `File`; tests substitute `TorrentClient.DiskMock`. Workers receive the
  impl via start opts.
  """

  @doc "Read the file at path."
  @callback read(path :: Path.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Write data to the file at path."
  @callback write(path :: Path.t(), data :: iodata()) :: :ok | {:error, term()}

  @doc "Atomically publish a staged file (resume temp-file + rename)."
  @callback rename(from :: Path.t(), to :: Path.t()) :: :ok | {:error, term()}

  @doc "Delete a single file (torrent removal; directories are never wiped)."
  @callback delete(path :: Path.t()) :: :ok | {:error, term()}

  @doc "Create parent dirs and size every file in the torrent layout."
  @callback init_layout(base_dir :: Path.t(), info :: map()) :: :ok | {:error, term()}

  @doc "Read a whole piece, gathering spans that cross file boundaries."
  @callback read_piece(base_dir :: Path.t(), info :: map(), index :: non_neg_integer()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Write a whole piece, scattering spans that cross file boundaries."
  @callback write_piece(
              base_dir :: Path.t(),
              info :: map(),
              index :: non_neg_integer(),
              data :: binary()
            ) :: :ok | {:error, term()}
end
