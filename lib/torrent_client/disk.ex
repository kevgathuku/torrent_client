defmodule TorrentClient.Disk do
  @moduledoc """
  Real disk implementation. Effectful by design — everything in here stays
  out of the domain layer.
  """

  @behaviour TorrentClient.DiskBehaviour

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, data), do: File.write(path, data)
end
