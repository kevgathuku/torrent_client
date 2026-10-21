defmodule UtilsTest do
  @moduledoc """
  Smoke for the shared helpers: peer ids and free-port selection.
  """
  use ExUnit.Case, async: true

  test "get_port returns a bindable port" do
    port = Utils.get_port()

    assert port in 1..65_535
    {:ok, socket} = :gen_tcp.listen(port, [])
    :gen_tcp.close(socket)
  end
end
