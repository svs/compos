defmodule Aimax.Core.Editor do
  @moduledoc """
  Editor state holder: tiling window tree, keymap table, minibuffer state,
  kill ring, echo area. **Policy-free by design** — every command and default
  keybinding is Scheme (`priv/editor.scm`); this process only stores state and
  applies small mutations. Key routing lives in `Aimax.Core.KeyDispatch`,
  which runs in the caller's process so Scheme primitives can call back into
  this server without deadlock.

  Window tree: `%{type: :leaf, id, buffer}` | `%{type: :split, dir: :h | :v,
  children: [tree, tree]}`. Each leaf shows a buffer; `:h` = side-by-side.
  TODO: per-window points, ratios, window resizing.
  """

  use GenServer

  alias Aimax.Core.{Buffer, Events}

  @scratch "*scratch*"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # readers
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def current_buffer, do: GenServer.call(__MODULE__, :current_buffer)
  def lookup_key(seq), do: GenServer.call(__MODULE__, {:lookup_key, seq})
  def render_state, do: GenServer.call(__MODULE__, :render_state)

  # keymap
  def bind_key(seq, command), do: GenServer.call(__MODULE__, {:bind_key, seq, command})

  def local_bind_key(buffer, seq, command),
    do: GenServer.call(__MODULE__, {:local_bind_key, buffer, seq, command})

  # pending prefix + echo
  def set_pending(seq), do: GenServer.call(__MODULE__, {:set_pending, seq})
  def set_echo(msg), do: GenServer.call(__MODULE__, {:set_echo, msg})

  # minibuffer
  def minibuffer_activate(prompt, candidates, on_confirm, on_complete \\ nil) do
    minibuffer_activate_full(prompt, candidates, %{
      on_confirm: on_confirm,
      on_complete: on_complete
    })
  end

  @doc "Handlers: %{on_confirm:, on_complete:, on_change:, on_cancel:} (all optional closures)."
  def minibuffer_activate_full(prompt, candidates, handlers),
    do: GenServer.call(__MODULE__, {:mb_activate, prompt, candidates, handlers})

  def minibuffer_set_input(input), do: GenServer.call(__MODULE__, {:mb_input, input})

  def minibuffer_set_candidates(candidates),
    do: GenServer.call(__MODULE__, {:mb_candidates, candidates})

  def minibuffer_move_sel(delta), do: GenServer.call(__MODULE__, {:mb_move_sel, delta})

  @doc "Currently selected candidate label (after fuzzy filter), or nil."
  def minibuffer_selected, do: GenServer.call(__MODULE__, :mb_selected)

  def minibuffer_close, do: GenServer.call(__MODULE__, :mb_close)

  def key_for_command(command), do: GenServer.call(__MODULE__, {:key_for_command, command})

  @doc "Buffers in most-recently-displayed order (Emacs buffer list)."
  def buffer_mru, do: GenServer.call(__MODULE__, :buffer_mru)

  # Emacs last-command (yank-pop and friends dispatch on it)
  def set_last_command(name), do: GenServer.call(__MODULE__, {:set_last_command, name})
  def last_command, do: GenServer.call(__MODULE__, :last_command)

  # completion-at-point popup (anchored at a buffer position)
  def completion_show(start, candidates),
    do: GenServer.call(__MODULE__, {:completion_show, start, candidates})

  def completion_move(delta), do: GenServer.call(__MODULE__, {:completion_move, delta})

  @doc "Accept the selection: returns {start, label} and clears, or nil."
  def completion_accept, do: GenServer.call(__MODULE__, :completion_accept)

  def completion_dismiss, do: GenServer.call(__MODULE__, :completion_dismiss)

  # kill ring
  def kill_push(text), do: GenServer.call(__MODULE__, {:kill_push, text})
  def kill_top, do: GenServer.call(__MODULE__, :kill_top)
  def kill_nth(i), do: GenServer.call(__MODULE__, {:kill_nth, i})
  def kill_size, do: GenServer.call(__MODULE__, :kill_size)

  # faces: name -> attrs map, merged; frontends map them to CSS vars
  def set_face(name, attrs), do: GenServer.call(__MODULE__, {:set_face, name, attrs})

  # windows
  def split(dir, ratio \\ 0.5) when dir in [:h, :v],
    do: GenServer.call(__MODULE__, {:split, dir, ratio})

  def delete_window, do: GenServer.call(__MODULE__, :delete_window)
  def delete_window_by_id(id), do: GenServer.call(__MODULE__, {:delete_window_by_id, id})
  def list_windows, do: GenServer.call(__MODULE__, :list_windows)
  def set_active(id), do: GenServer.call(__MODULE__, {:set_active, id})
  def active_window, do: GenServer.call(__MODULE__, :active_window)
  def delete_other_windows, do: GenServer.call(__MODULE__, :delete_other_windows)
  def other_window, do: GenServer.call(__MODULE__, :other_window)
  def set_window_buffer(buffer), do: GenServer.call(__MODULE__, {:set_window_buffer, buffer})

  @doc "Replace the whole window tree from a {:leaf, name} | {:split, dir, a, b} spec."
  def restore_tree(spec, active_buffer),
    do: GenServer.call(__MODULE__, {:restore_tree, spec, active_buffer})

  # viewport: client reports how many text rows fit; wheel scrolls the
  # active window server-side; any key re-enables point auto-follow
  def set_total_rows(rows), do: GenServer.call(__MODULE__, {:set_total_rows, rows})
  def scroll_active(delta_lines), do: GenServer.call(__MODULE__, {:scroll_active, delta_lines})
  def scroll_window(id, delta_lines), do: GenServer.call(__MODULE__, {:scroll_window, id, delta_lines})
  def user_acted, do: GenServer.call(__MODULE__, :user_acted)
  def window_rows, do: GenServer.call(__MODULE__, :window_rows)
  def recenter, do: GenServer.call(__MODULE__, :recenter)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Aimax.Core.create_buffer(@scratch)

    {:ok,
     %{
       tree: %{type: :leaf, id: 1, buffer: @scratch, top: 0, manual: false},
       active: 1,
       next_win: 2,
       pending: [],
       minibuffer: nil,
       kill_ring: [],
       keymap: %{},
       echo: "",
       faces: %{},
       local_keymaps: %{},
       last_command: "",
       completion: nil,
       total_rows: 40,
       mru: [@scratch]
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:pending, :minibuffer, :echo, :active, :completion]), state}
  end

  def handle_call(:current_buffer, _from, state) do
    {:reply, find_leaf(state.tree, state.active).buffer, state}
  end

  def handle_call({:lookup_key, seq}, _from, state) do
    buffer = find_leaf(state.tree, state.active).buffer
    local = Map.get(state.local_keymaps, buffer, %{})

    reply =
      cond do
        Map.has_key?(local, seq) -> {:command, local[seq]}
        Map.has_key?(state.keymap, seq) -> {:command, state.keymap[seq]}
        Enum.any?(Map.keys(local), &List.starts_with?(&1, seq)) -> :prefix
        Enum.any?(Map.keys(state.keymap), &List.starts_with?(&1, seq)) -> :prefix
        true -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:local_bind_key, buffer, seq, command}, _from, state) do
    local_keymaps =
      Map.update(state.local_keymaps, buffer, %{seq => command}, &Map.put(&1, seq, command))

    {:reply, :ok, %{state | local_keymaps: local_keymaps}}
  end

  def handle_call(:render_state, _from, state) do
    {tree, rendered} = render_walk(state.tree, state.total_rows)
    state = %{state | tree: tree}

    {:reply,
     %{
       tree: rendered,
       active: state.active,
       pending: state.pending,
       minibuffer: state.minibuffer && render_minibuffer(state.minibuffer),
       which_key: which_key(state),
       completion: state.completion && render_completion(state.completion),
       echo: state.echo,
       faces: state.faces
     }, state}
  end

  def handle_call({:set_total_rows, rows}, _from, state),
    do: {:reply, :ok, %{state | total_rows: rows |> max(5) |> min(500)}}

  def handle_call({:scroll_active, delta}, _from, state) do
    leaf = find_leaf(state.tree, state.active)
    top = max(leaf.top + delta, 0)
    tree = replace_leaf(state.tree, state.active, %{leaf | top: top, manual: true})
    changed(:ok, %{state | tree: tree})
  end

  def handle_call({:scroll_window, id, delta}, _from, state) do
    case find_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      leaf ->
        top = max(leaf.top + delta, 0)
        tree = replace_leaf(state.tree, id, %{leaf | top: top, manual: true})
        changed(:ok, %{state | tree: tree})
    end
  end

  def handle_call(:user_acted, _from, state),
    do: {:reply, :ok, %{state | tree: clear_manual(state.tree)}}

  def handle_call(:window_rows, _from, state) do
    {:reply, rows_for(state.tree, state.active, state.total_rows) || state.total_rows, state}
  end

  def handle_call(:recenter, _from, state) do
    leaf = find_leaf(state.tree, state.active)
    rows = rows_for(state.tree, state.active, state.total_rows) || state.total_rows

    top =
      if Buffer.exists?(leaf.buffer) do
        text = Buffer.text(leaf.buffer)
        cl = cursor_line(text, Buffer.point(leaf.buffer))
        max(cl - div(rows, 2), 0)
      else
        0
      end

    tree = replace_leaf(state.tree, state.active, %{leaf | top: top, manual: false})
    changed(:ok, %{state | tree: tree})
  end

  def handle_call({:bind_key, seq, command}, _from, state),
    do: {:reply, :ok, %{state | keymap: Map.put(state.keymap, seq, command)}}

  # no-op writes must not broadcast — echo("")/pending([]) fire on every key
  def handle_call({:set_pending, seq}, _from, %{pending: seq} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_pending, seq}, _from, state), do: changed(:ok, %{state | pending: seq})

  def handle_call({:set_echo, msg}, _from, %{echo: msg} = state), do: {:reply, :ok, state}
  def handle_call({:set_echo, msg}, _from, state), do: changed(:ok, %{state | echo: msg})

  def handle_call({:mb_activate, prompt, candidates, handlers}, _from, state) do
    mb =
      %{on_confirm: nil, on_complete: nil, on_change: nil, on_cancel: nil, input: ""}
      |> Map.merge(handlers)
      |> Map.merge(%{
        prompt: prompt,
        candidates: normalize(candidates),
        sel: 0,
        sel_touched: false
      })

    changed(:ok, %{state | minibuffer: mb})
  end

  def handle_call({:mb_input, input}, _from, %{minibuffer: %{} = mb} = state),
    do: changed(:ok, %{state | minibuffer: %{mb | input: input, sel: 0, sel_touched: false}})

  def handle_call({:mb_input, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  def handle_call({:mb_candidates, candidates}, _from, %{minibuffer: %{} = mb} = state) do
    mb = %{mb | candidates: normalize(candidates), sel: 0, sel_touched: false}
    changed(:ok, %{state | minibuffer: mb})
  end

  def handle_call({:mb_candidates, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  def handle_call({:mb_move_sel, delta}, _from, %{minibuffer: %{} = mb} = state) do
    n = length(filtered(mb))
    sel = if n == 0, do: 0, else: mb.sel |> Kernel.+(delta) |> max(0) |> min(n - 1)
    changed(:ok, %{state | minibuffer: %{mb | sel: sel, sel_touched: true}})
  end

  def handle_call({:mb_move_sel, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  def handle_call(:mb_selected, _from, %{minibuffer: %{} = mb} = state),
    do: {:reply, selected_label(mb), state}

  def handle_call(:mb_selected, _from, state), do: {:reply, nil, state}

  # returns the full minibuffer map (with handlers, plus :selected) or nil
  def handle_call(:mb_close, _from, state) do
    reply = state.minibuffer && Map.put(state.minibuffer, :selected, selected_label(state.minibuffer))
    changed(reply, %{state | minibuffer: nil})
  end

  def handle_call(:buffer_mru, _from, state) do
    live = Enum.filter(state.mru, &Buffer.exists?/1)
    rest = Aimax.Core.list_buffers() -- live
    {:reply, live ++ Enum.sort(rest), state}
  end

  def handle_call({:set_last_command, name}, _from, state),
    do: {:reply, :ok, %{state | last_command: name}}

  def handle_call(:last_command, _from, state), do: {:reply, state.last_command, state}

  def handle_call({:completion_show, start, candidates}, _from, state) do
    case normalize(candidates) do
      [] ->
        changed(:ok, %{state | completion: nil})

      cands ->
        changed(:ok, %{state | completion: %{start: start, candidates: cands, sel: 0}})
    end
  end

  def handle_call({:completion_move, delta}, _from, %{completion: %{} = c} = state) do
    n = length(c.candidates)
    sel = c.sel |> Kernel.+(delta) |> max(0) |> min(n - 1)
    changed(:ok, %{state | completion: %{c | sel: sel}})
  end

  def handle_call({:completion_move, _}, _from, state), do: {:reply, :ok, state}

  def handle_call(:completion_accept, _from, %{completion: %{} = c} = state) do
    reply =
      case Enum.at(c.candidates, c.sel) do
        %{label: label} -> {c.start, label}
        nil -> nil
      end

    changed(reply, %{state | completion: nil})
  end

  def handle_call(:completion_accept, _from, state), do: {:reply, nil, state}

  def handle_call(:completion_dismiss, _from, state),
    do: changed(:ok, %{state | completion: nil})

  def handle_call({:key_for_command, command}, _from, state) do
    reply =
      state.keymap
      |> Enum.find(fn {_seq, cmd} -> cmd == command end)
      |> case do
        {seq, _} -> Enum.join(seq, " ")
        nil -> ""
      end

    {:reply, reply, state}
  end

  def handle_call({:kill_push, text}, _from, state),
    do: changed(:ok, %{state | kill_ring: Enum.take([text | state.kill_ring], 60)})

  def handle_call({:set_face, name, attrs}, _from, state) do
    faces = Map.update(state.faces, name, attrs, &Map.merge(&1, attrs))
    changed(:ok, %{state | faces: faces})
  end

  def handle_call(:kill_top, _from, state),
    do: {:reply, List.first(state.kill_ring, ""), state}

  def handle_call({:kill_nth, i}, _from, state),
    do: {:reply, Enum.at(state.kill_ring, i, ""), state}

  def handle_call(:kill_size, _from, state), do: {:reply, length(state.kill_ring), state}

  def handle_call({:split, dir, ratio}, _from, state) do
    old = find_leaf(state.tree, state.active)
    new_leaf = %{type: :leaf, id: state.next_win, buffer: old.buffer, top: old.top, manual: false}
    split = %{type: :split, dir: dir, ratio: ratio, children: [old, new_leaf]}
    tree = replace_leaf(state.tree, state.active, split)
    changed(:ok, %{state | tree: tree, next_win: state.next_win + 1})
  end

  def handle_call({:delete_window_by_id, id}, _from, state) do
    case remove_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :sole_window}, state}

      tree ->
        active = if state.active == id, do: first_leaf(tree).id, else: state.active
        changed(:ok, %{state | tree: tree, active: active})
    end
  end

  def handle_call(:list_windows, _from, state),
    do: {:reply, leaf_ids_buffers(state.tree), state}

  def handle_call({:set_active, id}, _from, state) do
    if find_leaf(state.tree, id),
      do: changed(:ok, %{state | active: id}),
      else: {:reply, {:error, :no_window}, state}
  end

  def handle_call(:active_window, _from, state), do: {:reply, state.active, state}

  def handle_call(:delete_window, _from, state) do
    case remove_leaf(state.tree, state.active) do
      nil ->
        {:reply, {:error, :sole_window}, state}

      tree ->
        changed(:ok, %{state | tree: tree, active: first_leaf(tree).id})
    end
  end

  def handle_call(:delete_other_windows, _from, state) do
    leaf = find_leaf(state.tree, state.active)
    changed(:ok, %{state | tree: leaf})
  end

  def handle_call(:other_window, _from, state) do
    ids = leaf_ids(state.tree)
    idx = Enum.find_index(ids, &(&1 == state.active)) || 0
    changed(:ok, %{state | active: Enum.at(ids, rem(idx + 1, length(ids)))})
  end

  def handle_call({:set_window_buffer, buffer}, _from, state) do
    unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    leaf = find_leaf(state.tree, state.active)
    tree = replace_leaf(state.tree, state.active, %{leaf | buffer: buffer, top: 0, manual: false})
    mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
    changed(:ok, %{state | tree: tree, mru: mru})
  end

  def handle_call({:restore_tree, spec, active_buffer}, _from, state) do
    {tree, next_win} = build_tree(spec, state.next_win)

    Enum.each(leaf_ids_buffers(tree), fn {_id, buffer} ->
      unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    end)

    active =
      Enum.find_value(leaf_ids_buffers(tree), fn {id, buffer} ->
        if buffer == active_buffer, do: id
      end) || first_leaf(tree).id

    changed(:ok, %{state | tree: tree, next_win: next_win, active: active})
  end

  defp changed(reply, state) do
    Events.broadcast_editor(:changed)
    {:reply, reply, state}
  end

  # --- minibuffer helpers (vertico-style: fuzzy filter + selection) ----------

  defp normalize(candidates) do
    Enum.map(candidates, fn
      [label, hint] when is_binary(label) -> %{label: label, hint: to_string(hint)}
      label when is_binary(label) -> %{label: label, hint: ""}
    end)
  end

  # orderless + flex matching, case-insensitive:
  # space-separated terms each match as substrings in any order;
  # a single term falls back to subsequence (flex) matching
  def fuzzy_match?(_label, ""), do: true

  def fuzzy_match?(label, query) do
    dl = String.downcase(label)

    case String.split(query, " ", trim: true) do
      [] -> true
      [single] -> do_fuzzy(dl, String.downcase(single))
      terms -> Enum.all?(terms, &String.contains?(dl, String.downcase(&1)))
    end
  end

  defp do_fuzzy(_label, ""), do: true

  defp do_fuzzy(label, <<c::utf8, rest::binary>>) do
    case :binary.match(label, <<c::utf8>>) do
      :nomatch -> false
      {i, l} -> do_fuzzy(binary_part(label, i + l, byte_size(label) - i - l), rest)
    end
  end

  # on_complete prompts (find-file): candidates are the current directory's
  # listing; narrow by prefix on the basename segment (cheap — the expensive
  # re-listing only happens in Scheme when the directory part changes)
  defp filtered(%{on_complete: oc} = mb) when oc != nil and oc != false do
    frag = mb.input |> String.split("/") |> List.last()
    Enum.filter(mb.candidates, &String.starts_with?(&1.label, frag))
  end

  defp filtered(%{input: ""} = mb), do: mb.candidates

  # exact match outranks prefix outranks subsequence — "paper" must select
  # paper, not paper-night
  defp filtered(mb) do
    mb.candidates
    |> Enum.filter(&fuzzy_match?(&1.label, mb.input))
    |> Enum.sort_by(&match_rank(&1.label, mb.input))
  end

  defp match_rank(label, input) do
    dl = String.downcase(label)
    di = String.downcase(input)

    cond do
      dl == di -> 0
      String.starts_with?(dl, di) -> 1
      String.contains?(dl, di) -> 2
      true -> 3
    end
  end

  defp selected_label(mb) do
    case Enum.at(filtered(mb), mb.sel) do
      %{label: label} -> label
      nil -> nil
    end
  end

  defp render_minibuffer(mb) do
    list = filtered(mb)
    sel = min(mb.sel, max(length(list) - 1, 0))
    # keep the selection visible in an 8-row window
    offset = max(0, sel - 7)

    rows =
      list
      |> Enum.slice(offset, 8)
      |> Enum.with_index(offset)
      |> Enum.map(fn {c, i} -> Map.put(c, :selected, i == sel and list != []) end)

    %{
      prompt: mb.prompt,
      input: mb.input,
      candidates: rows,
      sel: sel,
      total: length(list),
      completing: mb.on_complete not in [nil, false]
    }
  end

  defp render_completion(c) do
    sel = min(c.sel, length(c.candidates) - 1)
    offset = max(0, sel - 7)

    rows =
      c.candidates
      |> Enum.slice(offset, 8)
      |> Enum.with_index(offset)
      |> Enum.map(fn {cand, i} -> Map.put(cand, :selected, i == sel) end)

    %{start: c.start, candidates: rows, sel: sel, total: length(c.candidates)}
  end

  defp which_key(%{pending: []}), do: nil

  defp which_key(state) do
    buffer = find_leaf(state.tree, state.active).buffer
    local = Map.get(state.local_keymaps, buffer, %{})

    [local, state.keymap]
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {seq, _} -> List.starts_with?(seq, state.pending) and seq != state.pending end)
    |> Enum.map(fn {seq, cmd} -> %{key: Enum.join(Enum.drop(seq, length(state.pending)), " "), command: cmd} end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(& &1.key)
  end

  # --- tree helpers ----------------------------------------------------------

  defp find_leaf(%{type: :leaf} = leaf, id), do: if(leaf.id == id, do: leaf, else: nil)

  defp find_leaf(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &find_leaf(&1, id))

  defp replace_leaf(%{type: :leaf} = leaf, id, new),
    do: if(leaf.id == id, do: new, else: leaf)

  defp replace_leaf(%{type: :split} = split, id, new),
    do: %{split | children: Enum.map(split.children, &replace_leaf(&1, id, new))}

  # returns the tree with the leaf removed, or nil if the tree IS that leaf
  defp remove_leaf(%{type: :leaf, id: id}, id), do: nil
  defp remove_leaf(%{type: :leaf} = leaf, _id), do: leaf

  defp remove_leaf(%{type: :split, children: [a, b]} = split, id) do
    case {remove_leaf(a, id), remove_leaf(b, id)} do
      {nil, b2} -> b2
      {a2, nil} -> a2
      {a2, b2} -> %{split | children: [a2, b2]}
    end
  end

  defp first_leaf(%{type: :leaf} = leaf), do: leaf
  defp first_leaf(%{type: :split, children: [a | _]}), do: first_leaf(a)

  defp build_tree({:leaf, buffer}, n),
    do: {%{type: :leaf, id: n, buffer: buffer, top: 0, manual: false}, n + 1}

  defp build_tree({:split, dir, a, b}, n), do: build_tree({:split, dir, 0.5, a, b}, n)

  defp build_tree({:split, dir, ratio, a, b}, n) do
    {ta, n} = build_tree(a, n)
    {tb, n} = build_tree(b, n)
    {%{type: :split, dir: dir, ratio: ratio, children: [ta, tb]}, n}
  end

  defp leaf_ids_buffers(%{type: :leaf, id: id, buffer: b}), do: [{id, b}]

  defp leaf_ids_buffers(%{type: :split, children: c}),
    do: Enum.flat_map(c, &leaf_ids_buffers/1)

  defp leaf_ids(%{type: :leaf, id: id}), do: [id]
  defp leaf_ids(%{type: :split, children: children}), do: Enum.flat_map(children, &leaf_ids/1)

  # render walk: computes per-window rows (v-splits divide), clamps and
  # auto-follows the viewport top (unless manually scrolled), and returns
  # both the updated tree (tops persist) and the render payload
  defp render_walk(%{type: :split, dir: dir, children: [a, b]} = split, rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    {a2, ra} = render_walk(a, rows_a)
    {b2, rb} = render_walk(b, rows_b)

    {%{split | children: [a2, b2]},
     %{type: :split, dir: dir, ratio: ratio, children: [ra, rb]}}
  end

  defp split_rows(:h, rows, _ratio), do: {rows, rows}

  defp split_rows(:v, rows, ratio) do
    a = max(round(rows * ratio), 3)
    {a, max(rows - a, 3)}
  end

  defp render_walk(%{type: :leaf, id: id, buffer: buffer} = leaf, rows) do
    exists = Buffer.exists?(buffer)
    text = if exists, do: Buffer.text(buffer), else: ""
    point = if exists, do: Buffer.point(buffer), else: 0

    total_lines = length(:binary.matches(text, "\n")) + 1
    cl = cursor_line(text, point)

    top = leaf.top |> min(max(total_lines - 1, 0)) |> max(0)

    top =
      cond do
        leaf.manual -> top
        cl < top -> cl
        cl >= top + rows -> cl - rows + 1
        true -> top
      end

    rendered = %{
      type: :leaf,
      id: id,
      buffer: buffer,
      text: text,
      point: point,
      mark: if(exists, do: Buffer.mark(buffer), else: nil),
      version: if(exists, do: Buffer.version(buffer), else: 0),
      modified: exists && Buffer.modified?(buffer),
      mode: (exists && Buffer.get_local(buffer, "mode-name")) || "Fundamental",
      ts_lang: exists && Buffer.get_local(buffer, "ts-lang"),
      render_mode: exists && Buffer.get_local(buffer, "render-mode"),
      top: top,
      rows: rows,
      total_lines: total_lines,
      line_numbers: !(exists && Buffer.get_local(buffer, "line-numbers") == "off")
    }

    {%{leaf | top: top}, rendered}
  end

  defp cursor_line(text, point),
    do: length(:binary.matches(binary_part(text, 0, point), "\n"))

  defp clear_manual(%{type: :leaf} = leaf), do: %{leaf | manual: false}

  defp clear_manual(%{type: :split} = split),
    do: %{split | children: Enum.map(split.children, &clear_manual/1)}

  defp rows_for(%{type: :leaf, id: id}, id, rows), do: rows
  defp rows_for(%{type: :leaf}, _id, _rows), do: nil

  defp rows_for(%{type: :split, dir: dir, children: [a, b]} = split, id, rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    rows_for(a, id, rows_a) || rows_for(b, id, rows_b)
  end
end
