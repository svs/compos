defmodule Aimax.Core.SchemeAPI do
  @moduledoc """
  The complete primitive surface exposed to Scheme. Deliberately small: raw
  buffer/point mutations, window-tree mutations, minibuffer activation, keymap
  table entry, kill-ring access. Everything with *policy* — what C-k kills,
  what find-file prompts, what M-x lists — is Scheme (priv/editor.scm).

  Conventions (aimax docs/LISP.md): predicates `?`, mutators `!`.
  """

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Editor}

  @commands :aimax_commands

  def commands_table, do: @commands

  def primitives do
    Map.merge(buffer_primitives(), editor_primitives())
  end

  defp buffer_primitives do
    %{
      "buffer-create" => fn [name] ->
        Core.create_buffer(name)
        name
      end,
      "buffer-list" => fn [] -> Core.list_buffers() end,
      "buffer-list-mru" => fn [] -> Editor.buffer_mru() end,
      "buffer-exists?" => fn [name] -> Buffer.exists?(name) end,
      "buffer-text" => fn [name] -> Buffer.text(name) end,
      "buffer-size" => fn [name] -> Buffer.byte_size(name) end,
      "buffer-modified?" => fn [name] -> Buffer.modified?(name) end,
      "buffer-path" => fn [name] -> Buffer.path(name) || false end,
      # named buffer ops are programmatic (:editor source) — they bypass
      # read-only, like Emacs' inhibit-read-only
      "buffer-append!" => fn [name, text] ->
        :ok = Buffer.append(name, text, source: :editor)
        :void
      end,
      "buffer-insert!" => fn [name, pos, text] ->
        :ok = Buffer.insert_at(name, pos, text, source: :editor)
        :void
      end,
      "buffer-delete-range!" => fn [name, pos, len] ->
        :ok = Buffer.delete_range(name, pos, len, source: :editor)
        :void
      end,
      # overlays: (overlay-set! buf 'org (list (list s e "org-todo") ...))
      # replaces the tag's whole range set — the fontification model is
      # "mode recomputes"; positions auto-adjust between recomputes
      "overlay-set!" => fn [name, tag, ranges] ->
        :ok = Buffer.set_overlays(name, plain(tag), Enum.map(ranges, fn [s, e, f] -> {s, e, plain(f)} end))
        :void
      end,
      "overlay-clear!" => fn [name, tag] ->
        :ok = Buffer.clear_overlays(name, if(plain(tag) == "all", do: :all, else: plain(tag)))
        :void
      end,
      "buffer-overlays" => fn [name] ->
        Enum.map(Buffer.overlays(name), fn {s, e, f} -> [s, e, f] end)
      end,
      # folding: ranges is a list of (start end) byte ranges to hide
      "buffer-set-hidden!" => fn [name, ranges] ->
        :ok = Buffer.set_hidden(name, Enum.map(ranges, fn [s, e] -> {s, e} end))
        :void
      end,
      "buffer-hidden" => fn [name] ->
        Enum.map(Buffer.hidden(name), fn {s, e} -> [s, e] end)
      end,
      "buffer-set-read-only!" => fn [name, bool] ->
        Buffer.set_read_only(name, bool == true)
        :void
      end,
      "buffer-read-only?" => fn [name] -> Buffer.read_only?(name) end,
      "buffer-kill!" => fn [name] ->
        Core.kill_buffer(name)
        :void
      end,
      "find-file" => fn [path] ->
        case Core.open_file(path) do
          {:ok, name} -> name
          {:error, :already_exists} -> Path.expand(path)
        end
      end,
      # directory listing: names only, directories marked with trailing "/"
      "list-dir" => fn [dir] ->
        expanded = Path.expand(if dir == "", do: ".", else: dir)

        case File.ls(expanded) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.map(fn e ->
              if File.dir?(Path.join(expanded, e)), do: e <> "/", else: e
            end)

          {:error, _} ->
            []
        end
      end,
      "expand-path" => fn [p] -> Path.expand(p) end,
      # (file-stat path) -> (perms size date) strings, dired-style
      "file-stat" => fn [p] ->
        case File.stat(Path.expand(p), time: :posix) do
          {:ok, stat} ->
            [format_mode(stat), format_size(stat.size), format_mtime(stat.mtime)]

          {:error, _} ->
            ["----------", "?", "?"]
        end
      end,
      "file-exists?" => fn [p] -> File.exists?(Path.expand(p)) end,
      "file-directory?" => fn [p] -> File.dir?(Path.expand(p)) end,

      # processes (comint)
      "start-process!" => fn [buffer, cmd] ->
        case Aimax.Core.Proc.start(buffer, cmd) do
          {:ok, _} -> true
          {:error, {:already_started, _}} -> true
          _ -> false
        end
      end,
      "process-send!" => fn [buffer, text] ->
        Aimax.Core.Proc.send_text(buffer, text) == :ok
      end,
      "process-running?" => fn [buffer] -> Aimax.Core.Proc.running?(buffer) end,
      "process-mark" => fn [buffer] -> Aimax.Core.Proc.mark(buffer) end,
      "buffer-substring" => fn [s, e] ->
        text = Buffer.text(Editor.current_buffer())
        binary_part(text, s, min(e, Kernel.byte_size(text)) - s)
      end,
      "process-kill!" => fn [buffer] ->
        Aimax.Core.Proc.kill(buffer)
        :void
      end,
      # current line's text (policy-free helper for comint & friends)
      "line-text" => fn [] ->
        buf = Editor.current_buffer()
        text = Buffer.text(buf)
        p = Buffer.point(buf)
        before = binary_part(text, 0, p)

        bol =
          case :binary.matches(before, "\n") do
            [] -> 0
            m -> m |> List.last() |> elem(0) |> Kernel.+(1)
          end

        rest = binary_part(text, p, Kernel.byte_size(text) - p)

        eol =
          case :binary.match(rest, "\n") do
            :nomatch -> Kernel.byte_size(text)
            {off, _} -> p + off
          end

        binary_part(text, bol, eol - bol)
      end
    }
  end

  defp editor_primitives do
    %{
      # point & motion — operate on the current (active window's) buffer
      "current-buffer" => fn [] -> Editor.current_buffer() end,
      "point" => fn [] -> Buffer.point(Editor.current_buffer()) end,
      "goto-char!" => fn [pos] ->
        Buffer.goto(Editor.current_buffer(), pos)
        pos
      end,
      "forward-char!" => fn [] -> Buffer.forward_char(Editor.current_buffer()) end,
      "backward-char!" => fn [] -> Buffer.backward_char(Editor.current_buffer()) end,
      "forward-word!" => fn [] -> Buffer.forward_word(Editor.current_buffer()) end,
      "backward-word!" => fn [] -> Buffer.backward_word(Editor.current_buffer()) end,
      "next-line!" => fn [] -> Buffer.next_line(Editor.current_buffer()) end,
      "previous-line!" => fn [] -> Buffer.previous_line(Editor.current_buffer()) end,
      "beginning-of-line!" => fn [] -> Buffer.beginning_of_line(Editor.current_buffer()) end,
      "end-of-line!" => fn [] -> Buffer.end_of_line(Editor.current_buffer()) end,
      "beginning-of-buffer!" => fn [] -> Buffer.beginning_of_buffer(Editor.current_buffer()) end,
      "end-of-buffer!" => fn [] -> Buffer.end_of_buffer(Editor.current_buffer()) end,

      # editing (user-sourced: respects read-only)
      "insert!" => fn [text] ->
        case Buffer.insert(Editor.current_buffer(), text) do
          :ok -> :void
          {:error, :read_only} -> raise Aimax.Scheme.Eval.Error, message: "Buffer is read-only"
        end
      end,
      "delete-char!" => fn [n] ->
        case Buffer.delete_char(Editor.current_buffer(), n) do
          {:ok, deleted} -> deleted
          {:error, :read_only} -> raise Aimax.Scheme.Eval.Error, message: "Buffer is read-only"
        end
      end,
      "kill-line!" => fn [] ->
        case Buffer.kill_line(Editor.current_buffer()) do
          {:ok, killed} -> killed
          {:error, :read_only} -> raise Aimax.Scheme.Eval.Error, message: "Buffer is read-only"
        end
      end,
      "undo!" => fn [] ->
        Buffer.undo(Editor.current_buffer()) == :ok
      end,
      "buffer-save!" => fn [] ->
        case Buffer.save(Editor.current_buffer()) do
          {:ok, path} -> path
          {:error, :no_path} -> false
        end
      end,

      # kill ring
      "kill-push!" => fn [text] ->
        Editor.kill_push(text)
        :void
      end,
      "kill-top" => fn [] -> Editor.kill_top() end,
      "kill-nth" => fn [i] -> Editor.kill_nth(i) end,
      "kill-ring-size" => fn [] -> Editor.kill_size() end,

      # buffer-local variables
      "buffer-set-local!" => fn [buf, k, v] ->
        Buffer.set_local(buf, plain(k), v)
        :void
      end,
      "buffer-local" => fn [buf, k] -> Buffer.get_local(buf, plain(k)) || false end,

      # mark & region
      "set-mark!" => fn
        [false] ->
          Buffer.set_mark(Editor.current_buffer(), nil)
          :void

        [pos] ->
          Buffer.set_mark(Editor.current_buffer(), pos)
          :void
      end,
      "mark" => fn [] -> Buffer.mark(Editor.current_buffer()) || false end,
      "region-beginning" => fn [] -> region_bounds() |> elem(0) end,
      "region-end" => fn [] -> region_bounds() |> elem(1) end,
      "region-text" => fn [] ->
        {s, e} = region_bounds()
        buf = Editor.current_buffer()
        buf |> Buffer.text() |> binary_part(s, e - s)
      end,
      "delete-region!" => fn [] ->
        {s, e} = region_bounds()
        if e > s, do: Buffer.delete_range(Editor.current_buffer(), s, e - s)
        :void
      end,
      "exchange-point-and-mark!" => fn [] ->
        buf = Editor.current_buffer()

        case Buffer.mark(buf) do
          nil ->
            false

          m ->
            p = Buffer.point(buf)
            Buffer.set_mark(buf, p)
            Buffer.goto(buf, m)
            true
        end
      end,

      # tree-sitter: structural nav + queries on the current buffer.
      # Language comes from the buffer-local "ts-lang" (set by modes).
      "ts-nav" => fn [op] ->
        buf = Editor.current_buffer()

        case Buffer.get_local(buf, "ts-lang") do
          nil ->
            false

          lang ->
            case Aimax.Core.TS.ts_nav(lang, Buffer.text(buf), Buffer.point(buf), plain(op)) do
              nil -> false
              pos -> pos
            end
        end
      end,
      "ts-query" => fn [query] ->
        buf = Editor.current_buffer()

        case Buffer.get_local(buf, "ts-lang") do
          nil ->
            []

          lang ->
            lang
            |> Aimax.Core.TS.ts_query_nif(Buffer.text(buf), query)
            |> Enum.map(fn {cap, s, e} -> [cap, s, e] end)
        end
      end,
      "ts-langs" => fn [] -> Aimax.Core.TS.ts_langs() end,

      # search: returns (start end) byte range or #f
      "buffer-search" => fn [q, from] ->
        case Buffer.search(Editor.current_buffer(), q, from, :forward) do
          {s, e} -> [s, e]
          nil -> false
        end
      end,
      "buffer-search-backward" => fn [q, from] ->
        case Buffer.search(Editor.current_buffer(), q, from, :backward) do
          {s, e} -> [s, e]
          nil -> false
        end
      end,

      # faces: (set-face-attribute! 'modeline 'bg "#2f3140" 'fg "#fff" ...)
      "set-face-attribute!" => fn [face | kvs] ->
        attrs =
          kvs
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {plain(k), plain(v)} end)

        Editor.set_face(plain(face), attrs)
        :void
      end,

      # windows (tiling tree)
      "split-window!" => fn
        [dir] ->
          Editor.split(dir_atom(dir))
          :void

        [dir, ratio] ->
          Editor.split(dir_atom(dir), ratio / 1)
          :void
      end,
      "delete-window!" => fn [] -> Editor.delete_window() == :ok end,
      "delete-window-id!" => fn [id] -> Editor.delete_window_by_id(id) == :ok end,
      "window-list" => fn [] -> Enum.map(Editor.list_windows(), fn {id, b} -> [id, b] end) end,
      "select-window!" => fn [id] -> Editor.set_active(id) == :ok end,
      "active-window" => fn [] -> Editor.active_window() end,
      "scroll-window!" => fn [id, lines] ->
        Editor.scroll_window(id, lines) == :ok
      end,
      "delete-other-windows!" => fn [] ->
        Editor.delete_other_windows()
        :void
      end,
      "other-window!" => fn [] ->
        Editor.other_window()
        :void
      end,
      "switch-to-buffer!" => fn [name] ->
        Editor.set_window_buffer(name)
        name
      end,

      # minibuffer & keymap — 3-arity: (prompt candidates on-confirm);
      # 4-arity adds an on-complete fn: input -> (list new-input candidates)
      "minibuffer-read" => fn
        [prompt, candidates, callback] ->
          Editor.minibuffer_activate(prompt, candidates, callback)
          :void

        [prompt, candidates, on_complete, callback] ->
          Editor.minibuffer_activate(prompt, candidates, callback, on_complete)
          :void
      end,
      # full form: handlers is an alist of (list 'confirm f) (list 'change f)
      # (list 'complete f) (list 'cancel f) (list 'initial "text")
      "minibuffer-read*" => fn [prompt, candidates, handlers] ->
        map =
          Map.new(handlers, fn [k, v] ->
            case plain(k) do
              "initial" -> {:input, v}
              key -> {String.to_existing_atom("on_" <> key), v}
            end
          end)

        Editor.minibuffer_activate_full(prompt, candidates, map)
        :void
      end,
      "global-set-key" => fn [seq, command] ->
        Editor.bind_key(String.split(seq, " "), command)
        :void
      end,
      "local-set-key" => fn [seq, command] ->
        Editor.local_bind_key(Editor.current_buffer(), String.split(seq, " "), command)
        :void
      end,
      # explicit-buffer variant: bind without the buffer being current
      "local-set-key*" => fn [buf, seq, command] ->
        Editor.local_bind_key(buf, String.split(seq, " "), command)
        :void
      end,
      "key-for-command" => fn [name] -> Editor.key_for_command(name) end,
      "last-command" => fn [] -> Editor.last_command() end,
      "window-rows" => fn [] -> Editor.window_rows() end,
      "recenter!" => fn [] ->
        Editor.recenter()
        :void
      end,

      # completion popup: candidates = strings or (label hint) pairs
      "completion-show!" => fn [start, _end, candidates] ->
        Editor.completion_show(start, candidates)
        :void
      end,
      "completion-dismiss!" => fn [] ->
        Editor.completion_dismiss()
        :void
      end,
      # words in the current buffer with the given prefix (dabbrev fuel)
      "buffer-words" => fn [prefix] ->
        text = Buffer.text(Editor.current_buffer())

        ~r/[A-Za-z_][A-Za-z0-9_?!-]*/
        |> Regex.scan(text)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 != prefix))
        |> Enum.sort()
      end,
      "minibuffer-set-candidates!" => fn [candidates] ->
        Editor.minibuffer_set_candidates(candidates)
        :void
      end,

      # filesystem (dired's hands)
      "delete-file!" => fn [p] ->
        path = Path.expand(p)

        result = if File.dir?(path), do: File.rmdir(path), else: File.rm(path)

        case result do
          :ok -> true
          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error, message: "delete failed: #{reason} (#{path})"
        end
      end,
      "make-directory!" => fn [p] ->
        File.mkdir_p!(Path.expand(p))
        true
      end
    }
  end

  defp dir_atom({:sym, "h"}), do: :h
  defp dir_atom({:sym, "v"}), do: :v
  defp dir_atom("h"), do: :h
  defp dir_atom("v"), do: :v

  defp plain({:sym, s}), do: s
  defp plain(v), do: v

  defp format_mode(stat) do
    type = if stat.type == :directory, do: "d", else: "-"

    bits =
      [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
      |> Enum.zip(~w(r w x r w x r w x))
      |> Enum.map_join(fn {bit, ch} -> if Bitwise.band(stat.mode, bit) != 0, do: ch, else: "-" end)

    type <> bits
  end

  defp format_size(size) when size >= 1_048_576, do: "#{Float.round(size / 1_048_576, 1)}M"
  defp format_size(size) when size >= 1024, do: "#{Float.round(size / 1024, 1)}k"
  defp format_size(size), do: "#{size}"

  defp format_mtime(posix) do
    dt = DateTime.from_unix!(posix)
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), dt.month - 1)
    day = String.pad_leading("#{dt.day}", 2)
    hh = String.pad_leading("#{dt.hour}", 2, "0")
    mm = String.pad_leading("#{dt.minute}", 2, "0")
    "#{month} #{day} #{hh}:#{mm}"
  end

  defp region_bounds do
    buf = Editor.current_buffer()
    p = Buffer.point(buf)

    case Buffer.mark(buf) do
      nil -> {p, p}
      m -> {min(p, m), max(p, m)}
    end
  end
end

