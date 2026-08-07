defmodule Aimax.Core.Candidates do
  @moduledoc """
  The one candidate-list engine: normalize → filter → rank → select → window.

  Both completion surfaces use it — the minibuffer panel (M-x, find-file,
  switch-buffer: vertico-shaped) and the at-point popup (completion-at-point:
  corfu-shaped). Two presentations, one behaviour; when they had separate
  filtering, find-file silently lost orderless matching.

  A list is `%{items: [%{label:, hint:}], query: "", sel: 0, touched: false}`.
  `query` is whatever the surface decides to match on — the minibuffer passes
  its input, file prompts pass the segment after the last "/", the popup
  passes the typed prefix.
  """

  @window 8

  defstruct items: [], query: "", sel: 0, touched: false, filtered: []

  @doc "Build from raw candidates: strings or [label, hint] pairs."
  def new(candidates, opts \\ []) do
    refilter(%__MODULE__{
      items: normalize(candidates),
      query: Keyword.get(opts, :query, ""),
      sel: 0,
      touched: false
    })
  end

  def normalize(candidates) do
    Enum.map(candidates, fn
      [label, hint] when is_binary(label) -> %{label: label, hint: to_string(hint)}
      %{label: _} = c -> c
      label when is_binary(label) -> %{label: label, hint: ""}
    end)
  end

  def put_items(list, candidates),
    do: refilter(%{list | items: normalize(candidates), sel: 0, touched: false})

  def put_query(list, query),
    do: refilter(%{list | query: query, sel: 0, touched: false})

  @doc "Move the selection; marks the list as explicitly touched by the user."
  def move(list, delta) do
    n = length(list.filtered)
    sel = if n == 0, do: 0, else: list.sel |> Kernel.+(delta) |> max(0) |> min(n - 1)
    %{list | sel: sel, touched: true}
  end

  @doc "Candidates surviving the query, best match first (memoized)."
  def filtered(list), do: list.filtered

  # filter + rank once, when items/query change — not on every read (a single
  # minibuffer render reads this several times)
  defp refilter(%{query: ""} = list), do: %{list | filtered: list.items}

  defp refilter(list) do
    filtered =
      list.items
      |> Enum.filter(&matches?(&1.label, list.query))
      |> Enum.sort_by(&rank(&1.label, list.query))

    %{list | filtered: filtered}
  end

  @doc "Widest label in the full set, in characters (0 when empty)."
  def label_width(list) do
    list.items |> Enum.map(&String.length(&1.label)) |> Enum.max(fn -> 0 end)
  end

  def selected(list) do
    case Enum.at(filtered(list), list.sel) do
      %{label: label} -> label
      nil -> nil
    end
  end

  def total(list), do: length(filtered(list))

  @doc "Rows for display: an 8-row window around the selection, marked."
  def rows(list) do
    all = filtered(list)
    sel = min(list.sel, max(length(all) - 1, 0))
    offset = max(0, sel - (@window - 1))

    all
    |> Enum.slice(offset, @window)
    |> Enum.with_index(offset)
    |> Enum.map(fn {c, i} -> Map.put(c, :selected, i == sel and all != []) end)
  end

  # --- matching --------------------------------------------------------------

  @doc """
  Orderless + flex, case-insensitive: space-separated terms each match as
  substrings in any order; a single term also matches as a subsequence.
  """
  def matches?(_label, ""), do: true

  def matches?(label, query) do
    dl = String.downcase(label)

    case String.split(query, " ", trim: true) do
      [] -> true
      [single] -> subsequence?(dl, String.downcase(single))
      terms -> Enum.all?(terms, &String.contains?(dl, String.downcase(&1)))
    end
  end

  defp subsequence?(_label, ""), do: true

  defp subsequence?(label, <<c::utf8, rest::binary>>) do
    case :binary.match(label, <<c::utf8>>) do
      :nomatch -> false
      {i, l} -> subsequence?(binary_part(label, i + l, byte_size(label) - i - l), rest)
    end
  end

  @doc "exact < prefix < substring < subsequence — so `paper` beats `paper-night`."
  def rank(label, query) do
    dl = String.downcase(label)
    dq = String.downcase(query)

    cond do
      dl == dq -> 0
      String.starts_with?(dl, dq) -> 1
      String.contains?(dl, dq) -> 2
      true -> 3
    end
  end
end
