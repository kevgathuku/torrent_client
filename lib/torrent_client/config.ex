defmodule TorrentClient.Config do
  @moduledoc """
  Tiny `key = value` config file. Today it carries only the listen port;
  unknown keys are ignored so older clients stay forward-compatible.
  Missing file is the caller's error (`File.read` failure passes through);
  a present-but-malformed file fails fast instead of booting deaf.
  """

  @type t :: %{port: pos_integer() | nil}

  @doc "Load and validate the config at `path`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- File.read(path) do
      parse(bytes)
    end
  end

  defp parse(bytes) do
    lines = String.split(bytes, "\n")

    Enum.reduce_while(lines, {:ok, %{port: nil}}, fn line, {:ok, config} ->
      case parse_line(String.trim(line)) do
        {:ok, parsed} -> {:cont, {:ok, Map.merge(config, parsed)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_line("" <> ""), do: {:ok, %{}}
  defp parse_line("#" <> _), do: {:ok, %{}}

  defp parse_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> parse_pair(String.trim(key), String.trim(value))
      _ -> {:error, {:invalid_config, line}}
    end
  end

  defp parse_pair("port", value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, %{port: port}}
      _ -> {:error, {:invalid_config, "port=#{value}"}}
    end
  end

  defp parse_pair(_unknown, _value), do: {:ok, %{}}
end
