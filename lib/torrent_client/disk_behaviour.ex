defmodule TorrentClient.DiskBehaviour do
  @moduledoc """
  Disk edge for piece storage and resume state. The real implementation uses
  `File`; tests substitute `TorrentClient.DiskMock`. Workers receive the
  impl via start opts. (First real caller lands in kog.7.)
  """

  @doc "Read the file at path."
  @callback read(path :: Path.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Write data to the file at path."
  @callback write(path :: Path.t(), data :: iodata()) :: :ok | {:error, term()}
end
