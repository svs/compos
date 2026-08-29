defmodule Compos.Core.Plist do
  @moduledoc """
  Flat Scheme plists — `(key value key value ...)` with `{:sym, _}` keys —
  to and from JSON.

  A Scheme list is ambiguous: it might be a record or a sequence. The house
  convention decides, and it has to be decided the SAME way everywhere,
  because the two shapes are different things on the wire. `(settingSources
  ())` is a one-key object; `("user" "local")` is an array. An adapter that
  reads one as the other silently ignores the config it was handed.

  This existed three times — the session's browser bridge, the session's
  general converter, and the ACP backend's `_meta` encoder — with three
  slightly different ideas of what counted as a plist.
  """

  @doc "Is this list a record? Even length, and every key slot a symbol."
  def plist?([]), do: false

  def plist?(list) when is_list(list) do
    n = length(list)

    n > 0 and rem(n, 2) == 0 and
      list |> Enum.take_every(2) |> Enum.all?(&match?({:sym, _}, &1))
  end

  def plist?(_), do: false

  @doc """
  Scheme value -> JSON-ready term. `nil_for` says what `false` becomes:
  `:false` keeps it a boolean (the default), `:null` turns it into nil —
  which is what an omitted argument means to a JSON API.
  """
  def to_json(value, nil_for \\ :false)

  def to_json(false, :null), do: nil
  def to_json(false, _), do: false
  def to_json(true, _), do: true
  def to_json({:sym, name}, _), do: name
  def to_json(:void, _), do: nil

  def to_json(list, nil_for) when is_list(list) do
    if plist?(list) do
      # A plist can hold the same key twice: Scheme code shadows a value by
      # consing a new pair on the front, and plist-get answers with the
      # first one it meets. Map.new would keep the LAST pair, so a shadowed
      # value crossed into Elixir as the value Scheme had replaced. Keep the
      # first pair, so both sides read one plist the same way.
      list
      |> Enum.chunk_every(2)
      |> Enum.reduce(%{}, fn [{:sym, k}, v], acc ->
        if Map.has_key?(acc, k), do: acc, else: Map.put(acc, k, to_json(v, nil_for))
      end)
    else
      Enum.map(list, &to_json(&1, nil_for))
    end
  end

  def to_json(other, _), do: other
end
