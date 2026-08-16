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

  `match_hint` widens the filter to the KINDS the annotation begins with, so
  a prompt finds a buffer or a file by its mode. It is a field count: `true`
  means 1 (the first field), an integer N means the first N fields — the
  buffer prompt passes 3 so mode, group and project all match. The prompt
  asks for it; the default stays off, because a doc-string annotation
  matches almost anything, and a size or date field must never match.
  """

  @window 8

  defstruct items: [], query: "", sel: 0, touched: false, filtered: [], match_hint: 0

  @doc "Build from raw candidates: strings or [label, hint] pairs."
  def new(candidates, opts \\ []) do
    refilter(%__MODULE__{
      items: normalize(candidates),
      query: Keyword.get(opts, :query, ""),
      sel: 0,
      touched: false,
      match_hint: hint_fields(Keyword.get(opts, :match_hint, false))
    })
  end

  defp hint_fields(true), do: 1
  defp hint_fields(n) when is_integer(n) and n > 0, do: n
  defp hint_fields(_), do: 0

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
      |> Enum.filter(&matches?(&1.label, list.query, hint_of(list, &1)))
      |> Enum.sort_by(&rank(&1.label, list.query))

    %{list | filtered: filtered}
  end

  # the annotation joins the match text only when the prompt asked for it;
  # rank still reads the label alone, so a kind match sorts last
  defp hint_of(%{match_hint: n}, %{hint: hint}) when n > 0, do: kinds(hint, n)
  defp hint_of(_list, _item), do: []

  # One 268-character chat buffer name set the name column for all 110
  # candidates and pushed every annotation off the right of the panel. A
  # name past this width truncates instead; the annotation always shows.
  @max_label_width 64

  @doc "Widest label in the full set, in characters (0 when empty), capped."
  def label_width(list) do
    list.items
    |> Enum.map(&String.length(&1.label))
    |> Enum.max(fn -> 0 end)
    |> min(@max_label_width)
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

  KINDS are the annotation fields a term may also match from the start —
  `elixir-mode`, `chat-mode`, a group, a project. A prompt that does not
  widen the filter passes [].
  """
  def matches?(label, query, kinds \\ [])

  def matches?(_label, "", _kinds), do: true

  def matches?(label, query, kinds) do
    dl = String.downcase(label)
    ks = List.wrap(kinds)

    case String.split(query, " ", trim: true) do
      [] -> true
      [single] -> subsequence?(dl, String.downcase(single)) or kind?(ks, single)
      terms -> Enum.all?(terms, &(String.contains?(dl, String.downcase(&1)) or kind?(ks, &1)))
    end
  end

  # The first N annotation fields, which the annotator writes as the kinds
  # of the thing: the mode a buffer is in, its group, its project. Padding
  # builds the columns, so 2+ spaces separate the fields. The later fields
  # are a size and a date, and a term must not match those — a filename
  # beginning "a" would find every file dated in August.
  defp kinds(hint, n) do
    hint
    |> String.split(~r/\s{2,}/, trim: true)
    |> Enum.take(n)
    |> Enum.map(&String.downcase/1)
  end

  # from the start of a kind, never inside it: "chat" finds the chats, and
  # "mo" still means the name alone, though every mode name ends in "-mode"
  defp kind?(kinds, term) do
    t = String.downcase(term)
    Enum.any?(kinds, &String.starts_with?(&1, t))
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
