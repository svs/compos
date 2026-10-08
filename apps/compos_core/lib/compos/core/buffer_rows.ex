defmodule Compos.Core.BufferRows do
  @moduledoc """
  The rows of every buffer listing: ibuffer, the mode lists, the buffer
  and group switchers.

  The data is the buffer read model itself (`BufferView`): one row per
  known buffer, live or dormant, with the editor's use of it beside it.
  Nothing here is cached, so nothing goes stale. A query projects the few
  fields it needs inside ETS, then filters, sorts and pages in the calling
  process: one pass, however many buffers there are.
  """

  alias Compos.Core.BufferView

  @doc "The fields a row can carry. Any other name is read as a buffer local."
  def fields, do: ~w(name path size modified live mode title group used windows)

  @doc """
  `{TOTAL, ROWS}` for OPTS, a map with string keys:

    * `names` - only these buffers
    * `modes`, `exclude-modes` - by `mode-name`
    * `has` - locals: a row holding any of them is kept beside the `modes`
      rows, whatever its mode
    * `exclude-names` - leave these out
    * `groups` - only the buffers whose group key is one of these
    * `dirs` - only the buffers with no path or a path under one of these
    * `hidden` - keep the names that start with a space
    * `context-only` - keep the context-only buffers
    * `match` - a case-blind substring of the name, title, path or mode
    * `sort` - `recent` (default), `name` or `size`
    * `group-by` - `group` or `mode`: the rows come section by section,
      each section in the sort order
    * `offset`, `limit` - the page
    * `fields` - what each row carries after its name
    * `bucket` - a field: the rows come back as buckets, `[KEY | NAMES]`,
      each bucket in the sort order, the buckets in the order of their
      first row; a row with no value for the field is in none

  TOTAL counts the rows before the page. A row is `[NAME | VALUES]`.
  """
  def query(opts) do
    fields = List.wrap(opts["fields"] || []) ++ List.wrap(opts["bucket"] || [])
    extra = Enum.uniq(Enum.reject(fields, &(&1 in fields())) ++ List.wrap(opts["has"] || []))

    rows =
      scan(extra)
      |> keep(opts)
      |> in_groups(opts)
      |> match(opts["match"])
      |> sort(opts["sort"] || "recent", opts["group-by"])

    total = length(rows)
    page = Enum.slice(rows, opts["offset"] || 0, opts["limit"] || total)

    case opts["bucket"] do
      key when is_binary(key) -> {total, buckets(page, key)}
      _ -> {total, Enum.map(page, &row_out(&1, fields))}
    end
  end

  defp buckets(rows, key) do
    {order, by_key} =
      Enum.reduce(rows, {[], %{}}, fn r, {order, acc} ->
        case Map.get(r, key, r["extra"][key]) do
          v when v in [nil, false] -> {order, acc}
          v when is_map_key(acc, v) -> {order, Map.update!(acc, v, &[r["name"] | &1])}
          v -> {[v | order], Map.put(acc, v, [r["name"]])}
        end
      end)

    order |> Enum.reverse() |> Enum.map(fn k -> [k | Enum.reverse(by_key[k])] end)
  end

  # One select over the read model. A dormant row from before a field
  # existed lacks it: every read is guarded, so it answers false.
  defp scan(extra) do
    m = :"$2"
    get = fn key -> {:andalso, {:is_map_key, key, m}, {:map_get, key, m}} end
    locals = {:map_get, :locals, m}

    local = fn key ->
      {:andalso, {:is_map_key, :locals, m},
       {:andalso, {:is_map_key, key, locals}, {:map_get, key, locals}}}
    end

    live =
      {:orelse, {:andalso, {:is_map_key, :live, m}, {:map_get, :live, m}},
       {:andalso, {:not, {:is_map_key, :live, m}}, {:is_map_key, :rope, m}}}

    body =
      [:"$1", get.(:path), get.(:size), get.(:modified), live,
       local.("mode-name"), local.("context-only"), local.("list-title"),
       local.("chat-title"), local.("last-seen"), local.("group-id"), local.("group-ids"),
       local.("group"), local.("companion-of")] ++ Enum.map(extra, local)

    uses =
      BufferView.table()
      |> :ets.select([{{{:use, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Map.new()

    BufferView.table()
    |> :ets.select([{{:"$1", m}, [{:is_binary, :"$1"}], [body]}])
    |> Enum.map(fn [name, path, size, modified, live, mode, ctx, title, chat_title, seen, gid, gids,
                    legacy, companion | rest] ->
      use = Map.get(uses, name, %{})

      %{
        "name" => name,
        "path" => path,
        "size" => size,
        "modified" => modified,
        "live" => live,
        "mode" => mode,
        "context-only" => ctx == true,
        "title" => title_of(name, title, chat_title),
        "used" => Map.get(use, :used) || (is_number(seen) && round(seen * 1000)) || 0,
        "windows" => Map.get(use, :windows, []),
        "group" => group_key(mode, gid, gids, legacy, companion),
        "extra" => extra |> Enum.zip(Enum.map(rest, &BufferView.big_value/1)) |> Map.new()
      }
    end)
  rescue
    # no read model yet: the table is gone between a crash and a restart
    ArgumentError -> []
  end

  # The group a buffer's locals name: a chat by its `group-id`, any other
  # buffer by its one `group-ids` entry. A row only Scheme can settle
  # (several ids, a legacy `group` or `companion-of`) is "slow".
  defp group_key(mode, gid, gids, legacy, companion) do
    cond do
      set?(legacy) or set?(companion) -> "slow"
      mode == "chat-mode" -> if is_binary(gid), do: gid
      is_list(gids) and length(gids) > 1 -> "slow"
      match?([id] when is_binary(id), gids) -> hd(gids)
      true -> nil
    end
  end

  # a Scheme value is set unless it is #f: the empty list is set
  defp set?(v), do: v not in [nil, false]

  # a list names a row by its `list-title`, a chat by its `chat-title`,
  # anything else by its buffer name
  defp title_of(name, title, chat_title) do
    Enum.find([title, chat_title], name, &(is_binary(&1) and &1 != ""))
  end

  defp keep(rows, opts) do
    names = set(opts["names"])
    excluded = set(opts["exclude-names"])
    modes = set(opts["modes"])
    has = List.wrap(opts["has"] || [])
    no_modes = set(opts["exclude-modes"])
    dirs = List.wrap(opts["dirs"] || [])
    hidden = opts["hidden"] == true
    ctx = opts["context-only"] == true

    Enum.filter(rows, fn r ->
      name = r["name"]

      (names == nil or MapSet.member?(names, name)) and
        (excluded == nil or not MapSet.member?(excluded, name)) and
        mode_ok?(r, modes, has) and
        (no_modes == nil or not MapSet.member?(no_modes, r["mode"])) and
        (hidden or not String.starts_with?(name, " ")) and
        (ctx or not r["context-only"]) and
        under?(r["path"], dirs)
    end)
  end

  defp mode_ok?(_r, nil, []), do: true

  defp mode_ok?(r, modes, has) do
    (modes != nil and MapSet.member?(modes, r["mode"])) or
      Enum.any?(has, &(r["extra"][&1] not in [nil, false]))
  end

  defp under?(_path, []), do: true
  defp under?(path, _dirs) when not is_binary(path), do: true
  defp under?(path, dirs), do: Enum.any?(dirs, &String.starts_with?(path, &1))

  defp set(v) when v in [nil, false], do: nil
  defp set(list), do: MapSet.new(List.wrap(list))

  defp in_groups(rows, opts) do
    case set(opts["groups"]) do
      nil -> rows
      groups -> Enum.filter(rows, &MapSet.member?(groups, &1["group"]))
    end
  end

  defp match(rows, q) when is_binary(q) and q != "" do
    q = String.downcase(q)

    Enum.filter(rows, fn r ->
      Enum.any?([r["name"], r["title"], r["path"], r["mode"]], fn s ->
        is_binary(s) and String.contains?(String.downcase(s), q)
      end)
    end)
  end

  defp match(rows, _), do: rows

  # recent is the editor's own ring first, the way buffer-list-mru gives
  # it, and the use times after it: a time is exact only for a use since
  # the editor started, the ring holds every use before
  defp sort(rows, by, section) do
    rank = if by in ["name", "size"], do: %{}, else: mru_rank()
    Enum.sort_by(rows, fn r -> {section_key(r, section), sort_key(r, by, rank)} end)
  end

  defp mru_rank do
    Compos.Core.Editor.buffer_mru() |> Enum.with_index() |> Map.new()
  catch
    :exit, _ -> %{}
  end

  defp section_key(r, "group"), do: r["group"] || ""
  defp section_key(r, "mode"), do: r["mode"] || ""
  defp section_key(_r, _), do: ""

  defp sort_key(r, "name", _), do: {String.downcase(r["title"]), r["name"]}
  defp sort_key(r, "size", _), do: {-(r["size"] || 0), r["name"]}

  defp sort_key(r, _recent, rank) do
    case Map.get(rank, r["name"]) do
      nil -> {1, -r["used"], r["name"]}
      i -> {0, i, r["name"]}
    end
  end

  defp row_out(r, fields),
    do: [r["name"] | Enum.map(fields, &out(Map.get(r, &1, r["extra"][&1])))]

  defp out(nil), do: false
  defp out(v), do: v
end
