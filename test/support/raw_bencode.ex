defmodule RawBencode do
  @moduledoc """
  Test-only minimal bdecoder that tracks byte consumption, so tests can
  extract the exact as-found bytes of a value. Bento doesn't expose ranges.
  """

  @doc "Decode one bencode value, returning {value, rest}."
  def decode(<<"i", rest::binary>>) do
    [digits, rest] = String.split(rest, "e", parts: 2)
    {String.to_integer(digits), rest}
  end

  def decode(<<"l", rest::binary>>), do: decode_list(rest, [])
  def decode(<<"d", rest::binary>>), do: decode_dict(rest, [])

  def decode(bin) do
    [len, rest] = String.split(bin, ":", parts: 2)
    len = String.to_integer(len)
    {binary_part(rest, 0, len), binary_part(rest, len, byte_size(rest) - len)}
  end

  @doc "The exact as-found bytes of the info dict in a .torrent file."
  def info_bytes(file_bytes) do
    with [_head, after_info] <- :binary.split(file_bytes, "4:info"),
         {_value, rest} <- decode(after_info) do
      {:ok, :binary.part(after_info, 0, byte_size(after_info) - byte_size(rest))}
    else
      _ -> {:error, :info_not_found}
    end
  end

  defp decode_list("e" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp decode_list(bin, acc) do
    {value, rest} = decode(bin)
    decode_list(rest, [value | acc])
  end

  defp decode_dict("e" <> rest, acc), do: {Map.new(acc), rest}

  defp decode_dict(bin, acc) do
    {key, rest} = decode(bin)
    {value, rest} = decode(rest)
    decode_dict(rest, [{key, value} | acc])
  end
end
