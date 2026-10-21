defmodule TorrentClient.TierState do
  @moduledoc """
  Pure BEP-12 tier walk: tiers tried in order, success moves the tracker to
  the front of its tier and restarts the order, failure advances. Shuffling
  within tiers happens at the worker edge (randomness stays out of here).
  """

  defstruct tiers: [], tier: 0, pos: 0

  @doc "Start walking the given (already shuffled) tiers."
  def new(tiers) when is_list(tiers) do
    %__MODULE__{tiers: Enum.reject(tiers, &(&1 == []))}
  end

  @doc "The next tracker URL, or exhausted when every tier failed."
  def next(%{tiers: tiers, tier: tier, pos: pos} = state) do
    case Enum.at(tiers, tier) do
      nil -> {:error, :exhausted}
      urls -> {:ok, Enum.at(urls, pos), state}
    end
  end

  @doc "Record success: tracker to the front of its tier, order restarts."
  def report(%{tiers: tiers, tier: tier} = state, :ok, url) do
    current = Enum.at(tiers, tier, [])
    moved = [url | Enum.reject(current, &(&1 == url))]
    {:ok, %{state | tiers: List.replace_at(tiers, tier, moved), tier: 0, pos: 0}}
  end

  @doc "Record failure: advance past the tracker."
  def report(%{tiers: tiers, tier: tier, pos: pos} = state, :error, _url) do
    if pos + 1 < length(Enum.at(tiers, tier)) do
      {:ok, %{state | pos: pos + 1}}
    else
      {:ok, %{state | tier: tier + 1, pos: 0}}
    end
  end
end
