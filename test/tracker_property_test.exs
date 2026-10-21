defmodule TrackerPropertyTest do
  @moduledoc """
  Mutation properties for dictionary-model tracker validation: a valid
  response stays accepted, and breaking one field (the port) rejects the
  whole response. Both generation sides stay inside usable addresses so the
  property can only disagree about ports.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  defp entry_gen(port_gen) do
    gen all(
          ip <- member_of(["1.2.3.4", "2001:db8::1"]),
          port <- port_gen
        ) do
      %{"ip" => ip, "port" => port}
    end
  end

  defp bad_port_gen do
    one_of([
      constant(0),
      integer(-1_000_000..0),
      integer(65_536..10_000_000),
      string(:alphanumeric, min_length: 1)
    ])
  end

  defp response(entries), do: Bento.encode!(%{"interval" => 900, "peers" => entries})

  property "valid ports are all accepted" do
    check all(entries <- list_of(entry_gen(integer(1..65_535)), min_length: 1)) do
      assert {:ok, %{peers: peers}} = Tracker.parse_peer_response(response(entries))
      assert length(peers) == length(entries)
      assert Enum.all?(peers, &(&1.port in 1..65_535))
    end
  end

  property "one broken port rejects the response" do
    check all(
            entries <- list_of(entry_gen(integer(1..65_535)), min_length: 1),
            bad_port <- bad_port_gen()
          ) do
      assert {:error, _} =
               Tracker.parse_peer_response(
                 response(entries ++ [%{"ip" => "1.2.3.4", "port" => bad_port}])
               )
    end
  end
end
