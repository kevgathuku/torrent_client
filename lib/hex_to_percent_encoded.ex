defmodule HexToPercentEncoded do
  def hex_to_percent_encoded(hex_string) do
    binary = Base.decode16!(hex_string)
    bytes = build_charlist(binary)
    encoded = URI.encode_query(bytes)
    Enum.join(encoded, "")
  end

  defp build_charlist(<<head::utf8, tail::binary>>) do
    [head | build_charlist(tail)]
  end

  defp build_charlist(<<>>), do: []
end
