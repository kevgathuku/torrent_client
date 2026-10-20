defmodule DomainPurityTest do
  @moduledoc """
  Tripwire: domain files must stay pure. This is a lexical check for obvious
  effectful calls, not a proof of purity — semantic impurity (e.g. randomness)
  remains a review judgement.
  """
  use ExUnit.Case, async: true

  @domain_files ~w(lib/peer.ex lib/torrent.ex lib/handshake.ex lib/tracker.ex)
  @banned [
    ~r/\bGenServer\b/,
    ~r/:gen_tcp\b/,
    ~r/\bSocket\./,
    ~r/\bFile\./,
    ~r/\bTesla\b/,
    ~r/\bSystem\./,
    ~r/\bProcess\./,
    ~r/:timer\b/,
    ~r/\bDateTime\b/,
    ~r/\bIO\./,
    ~r/:ssl\b/,
    ~r/\bRequests\./
  ]

  test "domain modules make no effectful calls" do
    violations =
      for file <- @domain_files,
          regex <- @banned,
          Regex.match?(regex, File.read!(file)),
          do: "#{file} matches #{inspect(regex.source)}"

    assert violations == []
  end
end
