defmodule Aimax.Core.CatalogBackfill do
  @moduledoc """
  Frozen Luna classifications for bundled Scheme declarations.

  This module never calls an LLM. Regenerate the reviewed artifact with
  `mix aimax.catalog.backfill`; runtime lookup is a plain in-memory map.
  """

  @artifact Path.expand("../../../priv/catalog-backfill.json", __DIR__)
  @external_resource @artifact
  @entries @artifact |> File.read!() |> Jason.decode!()
  @by_id Map.new(@entries, &{&1["id"], &1})

  @spec lookup(String.t(), String.t()) :: map() | nil
  def lookup(kind, qualified_name) when is_binary(kind) and is_binary(qualified_name) do
    @by_id["#{kind}:#{qualified_name}"]
  end

  @spec count() :: non_neg_integer()
  def count, do: map_size(@by_id)
end
