defmodule Aimax.Core.SchemeAPI do
  @moduledoc """
  The complete primitive surface exposed to Scheme. Deliberately small: raw
  buffer/point mutations, window-tree mutations, minibuffer activation, keymap
  table entry, kill-ring access. Everything with *policy* — what C-k kills,
  what find-file prompts, what M-x lists — is Scheme (priv/editor.scm).

  Conventions (aimax docs/LISP.md): predicates `?`, mutators `!`.
  """

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Editor, Git}

  @commands :aimax_commands

  # closures that escape into a Task must stay rooted, or the Session GC
  # collects the frames they capture (see Session's @escaped)
  @escaped :aimax_escaped_closures

  def commands_table, do: @commands

  def primitives do
    buffer_primitives()
    |> Map.merge(editor_primitives())
    |> Map.merge(git_primitives())
    |> Map.merge(watch_primitives())
  end

  @doc "One-line doc for every primitive: signature, then an em dash, then one sentence."
  def docs do
    %{
      "buffer-create" => "(buffer-create NAME) — create an empty buffer NAME and return NAME.",
      "buffer-list" => "(buffer-list) — return the names of all buffers.",
      "buffer-list-mru" => "(buffer-list-mru) — return buffer names in most-recently-used order, without internal buffers.",
      "buffer-exists?" => "(buffer-exists? NAME) — return #t if the buffer NAME exists.",
      "buffer-text" => "(buffer-text BUF) — return the buffer's whole text as a string.",
      "buffer-size" => "(buffer-size BUF) — return the buffer's size in bytes.",
      "buffer-modified?" => "(buffer-modified? BUF) — return #t if the buffer changed after its last save.",
      "buffer-path" => "(buffer-path BUF) — return the buffer's file path, or #f if it has none.",
      "buffer-append!" => "(buffer-append! BUF TEXT) — append TEXT to the buffer's end; ignores read-only.",
      "buffer-insert!" => "(buffer-insert! BUF POS TEXT) — insert TEXT at byte POS; ignores read-only.",
      "buffer-delete-range!" => "(buffer-delete-range! BUF POS LEN) — delete LEN bytes at byte POS; ignores read-only.",
      "overlay-set!" => "(overlay-set! BUF TAG RANGES) — replace TAG's overlays with (START END FACE) byte ranges.",
      "overlay-clear!" => "(overlay-clear! BUF TAG) — remove TAG's overlays; the tag 'all removes every overlay.",
      "buffer-overlays" => "(buffer-overlays BUF) — return all overlays as (START END FACE) byte ranges.",
      "buffer-set-hidden!" => "(buffer-set-hidden! BUF RANGES) — hide (fold) the given (START END) byte ranges.",
      "fold-set!" => "(fold-set! BUF TAG RANGES) — replace TAG's hidden (START END) byte ranges; the display hides the union of all tags.",
      "fold-get" => "(fold-get BUF [TAG]) — return TAG's hidden ranges; no TAG, or 'all, returns the union.",
      "fold-clear!" => "(fold-clear! BUF [TAG]) — drop TAG's folds; no TAG, or 'all, drops every tag's.",
      "buffer-goto!" => "(buffer-goto! BUF POS) — move the named buffer's point to byte POS.",
      "file-mtime" => "(file-mtime PATH) — return the file's mtime in posix seconds, or 0 if it is gone.",
      "git-root" => "(git-root DIR [CB]) — return the absolute work-tree root of DIR, or (error MSG).",
      "git-prefix" => "(git-prefix DIR [CB]) — return DIR's path inside its work tree with a trailing slash, or \"\" at the root.",
      "git-status" => "(git-status DIR [PATHSPEC] [CB]) — return (path P orig-path P2 index X worktree Y) plists; a pathspec scopes the read.",
      "git-diff" => "(git-diff DIR [OPTS] [CB]) — return parsed file plists; OPTS is (base REF path P staged BOOL).",
      "git-log" => "(git-log DIR N [PATHSPEC] [CB]) — return the last N commits as (sha short-sha author date subject) plists.",
      "git-show" => "(git-show DIR REF [CB]) — return the raw text of one commit.",
      "diff-parse" => "(diff-parse TEXT) — parse unified-diff TEXT into the same file plists git-diff returns.",
      "diff-word-range" => "(diff-word-range OLD NEW) — return ((OS OE) (NS NE)) byte ranges of the differing span, or #f.",
      "watch-path!" => "(watch-path! DIR) — watch DIR for changes, refcounted; return the watched root or (error MSG).",
      "unwatch-path!" => "(unwatch-path! DIR) — drop one watch reference; the subscription stops at zero.",
      "watched-paths" => "(watched-paths) — return the watched roots.",
      "fs-on-change!" => "(fs-on-change! FN) — register the ONE handler that gets a root when a watched tree changes.",
      "block-on-click!" => "(block-on-click! FN) — register the ONE handler that gets (BUF ID) when a block with a click id is clicked.",
      "define-style!" => "(define-style! NAME CSS) — register a stylesheet the page renders; modes ship their own CSS with this.",
      "buffer-hidden" => "(buffer-hidden BUF) — return the hidden (folded) byte ranges as (START END) pairs.",
      "buffer-set-read-only!" => "(buffer-set-read-only! BUF BOOL) — set the buffer's read-only flag.",
      "buffer-read-only?" => "(buffer-read-only? BUF) — return #t if the buffer is read-only.",
      "buffer-kill!" => "(buffer-kill! BUF) — kill the buffer and release its windows.",
      "ssh-command" => "(ssh-command) — return the configured ssh command string.",
      "remote-read" => "(remote-read HOST PATH) — read a remote file; return text, 'directory, 'absent, or (error MSG).",
      "remote-list-dir" => "(remote-list-dir HOST DIR) — list a remote directory; return entries or (error MSG).",
      "remote-sh" => "(remote-sh HOST CMD) — run CMD on HOST over ssh; return #t or (error MSG).",
      "remote-write" => "(remote-write HOST PATH TEXT) — write TEXT to a remote file; return #t or (error MSG).",
      "buffer-mark-saved!" => "(buffer-mark-saved! BUF) — clear the buffer's modified flag.",
      "find-file" => "(find-file PATH) — open the file PATH in a buffer and return the buffer name.",
      "list-dir" => "(list-dir DIR) — return sorted entry names; directories carry a trailing slash.",
      "expand-path" => "(expand-path PATH) — expand PATH to an absolute path.",
      "file-stat" => "(file-stat PATH) — return (PERMS SIZE DATE) strings in dired style.",
      "file-exists?" => "(file-exists? PATH) — return #t if PATH exists.",
      "file-directory?" => "(file-directory? PATH) — return #t if PATH is a directory.",
      "read-file" => "(read-file PATH) — return the file's contents, or #f if unreadable.",
      "shell-command->string" => "(shell-command->string CMD [DIR]) — run CMD in a shell; return its output with stderr merged.",
      "json-parse" => "(json-parse STR) — parse JSON; objects become plists with symbol keys; #f on failure.",
      "json-encode" => "(json-encode V) — encode a Scheme value as a JSON string; a plist becomes an object.",
      "write-file!" => "(write-file! PATH TEXT) — write TEXT to PATH, create parent directories; return #t.",
      "start-process!" => "(start-process! BUF CMD) — start a shell process attached to BUF; return #t on success.",
      "process-send!" => "(process-send! BUF TEXT) — send TEXT to the buffer's process; return #t on success.",
      "process-running?" => "(process-running? BUF) — return #t if the buffer's process runs.",
      "process-mark" => "(process-mark BUF) — return the byte position just after the last process output.",
      "buffer-substring" => "(buffer-substring START END) — return the current buffer's text between byte START and END.",
      "process-kill!" => "(process-kill! BUF) — kill the buffer's process.",
      "line-text" => "(line-text) — return the current line's text, without the newline.",
      "current-buffer" => "(current-buffer) — return the name of the current buffer.",
      "point" => "(point) — return point in the current buffer as a byte offset.",
      "buffer-point" => "(buffer-point BUF) — return the buffer's point as a byte offset.",
      "aimax-home" => "(aimax-home) — return the aimax home directory path (~/.aimax).",
      "goto-char!" => "(goto-char! POS) — move point to byte POS; return POS.",
      "forward-char!" => "(forward-char!) — move point one character forward; return the new point.",
      "backward-char!" => "(backward-char!) — move point one character backward; return the new point.",
      "forward-word!" => "(forward-word!) — move point to the end of the next word; return the new point.",
      "backward-word!" => "(backward-word!) — move point to the start of the previous word; return the new point.",
      "next-line!" => "(next-line!) — move point one line down, keep the goal column; return the new point.",
      "previous-line!" => "(previous-line!) — move point one line up, keep the goal column; return the new point.",
      "beginning-of-line!" => "(beginning-of-line!) — move point to the line start; return the new point.",
      "end-of-line!" => "(end-of-line!) — move point to the line end; return the new point.",
      "beginning-of-buffer!" => "(beginning-of-buffer!) — move point to byte 0; return the new point.",
      "end-of-buffer!" => "(end-of-buffer!) — move point to the buffer's end; return the new point.",
      "line-start-position" => "(line-start-position LINE) — return the start byte offset of 1-based LINE.",
      "insert!" => "(insert! TEXT) — insert TEXT at point; errors if the buffer is read-only.",
      "delete-char!" => "(delete-char! N) — delete N characters at point, backward if negative; return the text.",
      "kill-line!" => "(kill-line!) — delete from point to the line end, or the newline; return the text.",
      "undo!" => "(undo!) — undo one step in the current buffer; return #t on success.",
      "break-undo-chain!" => "(break-undo-chain!) — start a new undo group in the current buffer.",
      "undo-exempt!" => "(undo-exempt! COMMAND) — exempt COMMAND from the automatic undo-chain break.",
      "buffer-save!" => "(buffer-save!) — save the current buffer to its path; return the path or #f.",
      "kill-push!" => "(kill-push! TEXT) — push TEXT onto the kill ring.",
      "kill-top" => "(kill-top) — return the newest kill-ring entry, or \"\" when empty.",
      "kill-nth" => "(kill-nth I) — return kill-ring entry I (0 is newest), or \"\" when absent.",
      "kill-ring-size" => "(kill-ring-size) — return the number of kill-ring entries.",
      "buffer-set-local!" => "(buffer-set-local! BUF KEY VALUE) — set a buffer-local variable.",
      "buffer-local" => "(buffer-local BUF KEY) — return a buffer-local variable's value, or #f if unset.",
      "set-mark!" => "(set-mark! POS) — set the mark at byte POS; #f clears the mark.",
      "mark" => "(mark) — return the mark's byte offset, or #f if no mark is set.",
      "region-beginning" => "(region-beginning) — return the smaller of point and mark as a byte offset.",
      "region-end" => "(region-end) — return the larger of point and mark as a byte offset.",
      "region-text" => "(region-text) — return the text between point and mark.",
      "delete-region!" => "(delete-region!) — delete the text between point and mark.",
      "exchange-point-and-mark!" => "(exchange-point-and-mark!) — swap point and mark; return #f if no mark is set.",
      "ts-nav" => "(ts-nav OP) — tree-sitter motion 'forward|'backward|'up|'down; return a byte pos or #f.",
      "ts-node" =>
        "(ts-node START END OP) — the node covering the range, or its 'at|'parent|'child|'next|'prev|'top; return (KIND START END) or #f.",
      "ts-query" => "(ts-query QUERY) — run a tree-sitter query; return (CAPTURE START END) byte ranges.",
      "ts-langs" => "(ts-langs) — return the names of the loaded tree-sitter languages.",
      "buffer-search" => "(buffer-search Q FROM) — search forward from byte FROM; return (START END) or #f.",
      "buffer-search-backward" => "(buffer-search-backward Q FROM) — search backward from byte FROM; return (START END) or #f.",
      "set-face-attribute!" => "(set-face-attribute! FACE KEY VALUE ...) — set the face's attributes from key-value pairs.",
      "split-window!" => "(split-window! DIR [RATIO]) — split the active window 'h or 'v at RATIO (default 0.5).",
      "delete-window!" => "(delete-window!) — delete the active window; return #t on success.",
      "delete-window-id!" => "(delete-window-id! WIN) — delete window WIN; return #t on success.",
      "window-list" => "(window-list) — return (WIN BUFFER) pairs for the selected frame's windows.",
      "window-rects" => "(window-rects) — return (WIN BUFFER X Y W H) rows with fractional rectangles.",
      "select-window!" => "(select-window! WIN) — make WIN and its frame active; return #t on success.",
      "active-window" => "(active-window) — return the active window's id.",
      "scroll-window!" => "(scroll-window! WIN LINES) — scroll window WIN by LINES; return #t on success.",
      "delete-other-windows!" => "(delete-other-windows!) — delete every window in the frame except the active one.",
      "other-window!" => "(other-window!) — select the next window in the frame.",
      "switch-to-buffer!" => "(switch-to-buffer! BUF) — show BUF in the active window; return BUF.",
      "frame-list" => "(frame-list) — return frame ids in most-recently-used order.",
      "selected-frame" => "(selected-frame) — return the current frame's id.",
      "select-frame!" => "(select-frame! FRAME) — make FRAME current; return #t on success.",
      "make-frame!" => "(make-frame!) — create a frame and return its id.",
      "window-list-all" => "(window-list-all) — return (WIN BUFFER FRAME) rows for every window in every frame.",
      "window-set-buffer!" => "(window-set-buffer! WIN BUF) — show BUF in window WIN without selection; return #t.",
      "frame-of-window" => "(frame-of-window WIN) — return the id of the window's frame, or #f.",
      "minibuffer-read" => "(minibuffer-read PROMPT CANDIDATES [ON-COMPLETE] ON-CONFIRM) — activate the minibuffer.",
      "minibuffer-read*" => "(minibuffer-read* PROMPT CANDIDATES HANDLERS) — activate the minibuffer with a handler alist.",
      "global-set-key" => "(global-set-key SEQ COMMAND) — bind the key sequence SEQ to COMMAND globally.",
      "local-set-key" => "(local-set-key SEQ COMMAND) — bind SEQ to COMMAND in the current buffer.",
      "local-set-key*" => "(local-set-key* BUF SEQ COMMAND) — bind SEQ to COMMAND in buffer BUF.",
      "local-unset-key*" => "(local-unset-key* BUF SEQ) — drop BUF's own binding for SEQ.",
      "local-remap!" => "(local-remap! FROM TO) — in the current buffer, every key bound to FROM runs TO.",
      "local-remap*!" => "(local-remap*! BUF FROM TO) — in buffer BUF, every key bound to FROM runs TO.",
      "key-for-command" => "(key-for-command COMMAND) — return the tersest key sequence bound to COMMAND, or \"\".",
      "last-command" => "(last-command) — return the name of the last command that ran.",
      "window-rows" => "(window-rows) — return the number of text rows in the active window.",
      "recenter!" => "(recenter!) — center the active window on the cursor line.",
      "completion-show!" => "(completion-show! START END CANDIDATES) — show the completion popup for byte START.",
      "completion-dismiss!" => "(completion-dismiss!) — dismiss the completion popup.",
      "completion-move!" => "(completion-move! DELTA) — move the popup selection by DELTA rows.",
      "completion-accept!" =>
        "(completion-accept!) — close the popup; return (START LABEL) of the selection, or #f.",
      "buffer-words" => "(buffer-words PREFIX) — return the buffer's words with PREFIX, sorted, without PREFIX itself.",
      "count-words" => "(count-words BUF) — return the buffer's whitespace-separated word count.",
      "minibuffer-selected" => "(minibuffer-selected) — return the highlighted minibuffer candidate.",
      "set-mb-redirect!" => "(set-mb-redirect! BOOL) — toggle redirection of current-buffer to the minibuffer's text.",
      "window-preview-buffer!" => "(window-preview-buffer! BUF) — show BUF in the active window without MRU changes.",
      "minibuffer-set-candidates!" => "(minibuffer-set-candidates! CANDIDATES) — replace the minibuffer's candidate list.",
      "delete-file!" => "(delete-file! PATH) — delete a file or empty directory; return #t or error.",
      "make-directory!" => "(make-directory! PATH) — create the directory and its parents; return #t."
    }
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
      # folding: ranges is a list of (start end) byte ranges to hide.
      # A buffer has several fold owners, so ranges are tagged and each
      # owner replaces only its own tag. The display hides the union.
      # The untagged pair below writes and reads the "default" tag.
      "buffer-set-hidden!" => fn [name, ranges] ->
        :ok = Buffer.set_hidden(name, Enum.map(ranges, fn [s, e] -> {s, e} end))
        :void
      end,
      "buffer-hidden" => fn [name] ->
        Enum.map(Buffer.hidden(name), fn {s, e} -> [s, e] end)
      end,
      "fold-set!" => fn [name, tag, ranges] ->
        :ok = Buffer.set_hidden(name, plain(tag), Enum.map(ranges, fn [s, e] -> {s, e} end))
        :void
      end,
      "fold-get" => fn
        [name] -> Enum.map(Buffer.hidden(name), fn {s, e} -> [s, e] end)
        [name, tag] -> Enum.map(Buffer.hidden(name, fold_tag(tag)), fn {s, e} -> [s, e] end)
      end,
      "fold-clear!" => fn
        [name] ->
          :ok = Buffer.clear_hidden(name)
          :void

        [name, tag] ->
          :ok = Buffer.clear_hidden(name, fold_tag(tag))
          :void
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
      # remote files: ssh transport only — /ssh: path syntax, remote buffers,
      # and save interception are Scheme (priv/editor.scm)
      "ssh-command" => fn [] -> Aimax.Core.Remote.ssh() end,
      "remote-read" => fn [host, path] ->
        case Aimax.Core.Remote.read(host, path) do
          {:ok, text} -> text
          :directory -> {:sym, "directory"}
          :absent -> {:sym, "absent"}
          {:error, msg} -> [{:sym, "error"}, msg]
        end
      end,
      "remote-list-dir" => fn [host, dir] ->
        case Aimax.Core.Remote.list_dir(host, dir) do
          {:ok, entries} -> entries
          {:error, msg} -> [{:sym, "error"}, msg]
        end
      end,
      "remote-sh" => fn [host, cmd] ->
        case Aimax.Core.Remote.sh(host, cmd) do
          :ok -> true
          {:error, msg} -> [{:sym, "error"}, msg]
        end
      end,
      "remote-write" => fn [host, path, text] ->
        case Aimax.Core.Remote.write(host, path, text) do
          :ok -> true
          {:error, msg} -> [{:sym, "error"}, msg]
        end
      end,
      "buffer-mark-saved!" => fn [name] ->
        Buffer.mark_saved(name)
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
      # a sortable mtime (posix seconds), 0 when the file is gone — file-stat
      # formats for display and cannot be ordered
      "file-mtime" => fn [p] ->
        case File.stat(Path.expand(p), time: :posix) do
          {:ok, stat} -> stat.mtime
          {:error, _} -> 0
        end
      end,
      "file-exists?" => fn [p] -> File.exists?(Path.expand(p)) end,
      "file-directory?" => fn [p] -> File.dir?(Path.expand(p)) end,
      # (read-file PATH) -> contents, or #f if unreadable
      "read-file" => fn [p] ->
        case File.read(Path.expand(p)) do
          {:ok, text} -> text
          {:error, _} -> false
        end
      end,
      # (shell-command->string CMD [DIR]) — sync, stderr folded in, "" on spawn failure
      "shell-command->string" => fn
        [cmd] -> shell_to_string(cmd, File.cwd!())
        [cmd, dir] -> shell_to_string(cmd, Path.expand(dir))
      end,
      # (json-parse STR) — objects become flat plists with symbol keys,
      # null becomes #f; #f on parse failure
      "json-parse" => fn [s] ->
        case Jason.decode(s) do
          {:ok, v} -> Aimax.Core.LLM.json_to_scheme(v)
          {:error, _} -> false
        end
      end,
      # (json-encode V) — the inverse: a plist becomes an object, any other
      # list an array. Escaping is the encoder's job, so a value survives a
      # round trip through a file that the printer's own escapes do not.
      "json-encode" => fn [v] -> Jason.encode!(Aimax.Core.Session.scheme_to_json(v)) end,
      "write-file!" => fn [p, text] ->
        path = Path.expand(p)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, text)
        true
      end,
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
        {bol, eol} = Aimax.Core.Text.line_bounds(text, Buffer.point(buf))
        binary_part(text, bol, eol - bol)
      end
    }
  end

  defp editor_primitives do
    %{
      # point & motion — operate on the current (active window's) buffer
      "current-buffer" => fn [] -> Editor.current_buffer() end,
      "point" => fn [] -> Buffer.point(Editor.current_buffer()) end,
      "buffer-point" => fn [name] -> Buffer.point(name) end,
      # ~/.aimax in real life, a tmp dir in tests — config and user packages
      "aimax-home" => fn [] -> Aimax.Core.home() end,
      "goto-char!" => fn [pos] ->
        Buffer.goto(Editor.current_buffer(), pos)
        pos
      end,
      # goto-char! in a named buffer: an async refresh restores point in the
      # buffer it rebuilt, which is not always the current one
      "buffer-goto!" => fn [name, pos] ->
        Buffer.goto(name, pos)
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
      # 1-based line -> its start byte offset, O(log n) via the rope's own
      # line index (same lookup mouse-click position resolution already
      # uses) — for goto-line, never walk next-line! in a loop for this
      "line-start-position" => fn [line] ->
        {start, _text} = Buffer.line_at(Editor.current_buffer(), trunc(line))
        start
      end,

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
      # undo boundary control (evil et al. group their own edits)
      "break-undo-chain!" => fn [] ->
        buf = Editor.current_buffer()
        if Buffer.exists?(buf), do: Buffer.break_undo_chain(buf)
        :void
      end,
      "undo-exempt!" => fn [name] ->
        Editor.add_undo_exempt(name)
        :void
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
      # node identity is a byte range, so the caller can walk from the node
      # it stands on instead of from the deepest node under point
      "ts-node" => fn [start, stop, op] ->
        buf = Editor.current_buffer()

        case Buffer.get_local(buf, "ts-lang") do
          nil ->
            false

          lang ->
            case Aimax.Core.TS.ts_node(lang, Buffer.text(buf), start, stop, plain(op)) do
              nil -> false
              {kind, s, e} -> [kind, s, e]
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
      "window-rects" => fn [] -> Editor.window_rects() end,
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

      # frames: one per attached client; window primitives above act on the
      # selected frame implicitly. delete-frame! lives in Session (it must
      # fire an active prompt's on_cancel in the current store).
      "frame-list" => fn [] -> Editor.frame_list() end,
      "selected-frame" => fn [] ->
        Aimax.Core.Frame.current() || Editor.last_active_frame()
      end,
      "select-frame!" => fn [id] ->
        # commands run with the dispatching frame stamped in the pdict —
        # retarget it too, or the next primitive undoes the selection
        ok = Editor.select_frame(id) == :ok
        if ok, do: Aimax.Core.Frame.put(id)
        ok
      end,
      "make-frame!" => fn [] ->
        {:ok, id} = Editor.attach_frame(nil)
        id
      end,
      # every window everywhere: ((id buffer frame-id) ...) — the cross-frame
      # walk for kill-buffer replacement, agent window release
      "window-list-all" => fn [] ->
        Enum.map(Editor.list_windows_all(), fn {id, b, fid} -> [id, b, fid] end)
      end,
      # set any window's buffer without selecting it (no frame/focus change)
      "window-set-buffer!" => fn [id, name] ->
        Editor.window_set_buffer(id, name) == :ok
      end,
      "frame-of-window" => fn [id] -> Editor.frame_of_window(id) || false end,

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
      # the inverse: a minor mode restores the map it borrowed
      "local-unset-key*" => fn [buf, seq] ->
        Editor.local_unbind_key(buf, String.split(seq, " "))
        :void
      end,
      # Emacs [remap COMMAND]: every key bound to FROM runs TO in this
      # buffer — arrows, C-n/C-p, and user rebindings all follow at once
      "local-remap!" => fn [from, to] ->
        Editor.local_remap(Editor.current_buffer(), from, to)
        :void
      end,
      "local-remap*!" => fn [buf, from, to] ->
        Editor.local_remap(buf, from, to)
        :void
      end,
      "key-for-command" => fn [name] -> Editor.key_for_command(name) end,
      # a mode's own stylesheet, rendered into the page beside the face
      # variables. Modes are trusted code — they can eval anything — so the
      # CSS ships raw.
      "define-style!" => fn [name, css] ->
        Editor.set_style(plain(name), css)
        :void
      end,
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
      "completion-move!" => fn [delta] ->
        Editor.completion_move(delta)
        :void
      end,
      "completion-accept!" => fn [] ->
        case Editor.completion_accept() do
          {start, label} -> [start, label]
          nil -> false
        end
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
      # whitespace-separated word count (writing-mode modeline, M-x count-words)
      "count-words" => fn [buf] ->
        ~r/\S+/ |> Regex.scan(Buffer.text(buf)) |> length()
      end,
      # the highlighted candidate (consult-style preview reads it on move)
      "minibuffer-selected" => fn [] -> Editor.minibuffer_selected() end,
      # escape hatch: current-buffer defaults to the minibuffer's OWN text
      # while one is active, so a preview hook that wants to act on the
      # invoking buffer (e.g. goto-char! for a same-buffer position
      # preview) must toggle this off around that call, then back on
      "set-mb-redirect!" => fn [bool] ->
        Editor.set_mb_redirect(bool)
        :void
      end,
      # show a buffer in the active window without MRU bookkeeping —
      # candidate preview must not reorder the buffer ring
      "window-preview-buffer!" => fn [name] ->
        Editor.preview_buffer(name) == :ok
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

  # --- git (Aimax.Core.Git; policy in packages/git.scm) ----------------------
  # Every primitive takes an optional trailing callback. With one, the git
  # command runs in a supervised Task and the callback gets the value — the
  # Session never blocks on git. Without one, the caller waits: an agent
  # through the RPC `eval` path needs an answer, not a promise.
  #
  # Values cross as plists — (key value ...) with symbol keys. An error is
  # the plist (error "message"), which `list?` tells apart from a string.
  defp git_primitives do
    %{
      "git-root" => fn [dir | rest] ->
        git_dispatch(rest, fn -> Git.root(dir) end, & &1)
      end,
      # (git-status DIR [PATHSPEC] [CALLBACK]) — a pathspec scopes the read
      # to one subtree, so the diff you get is the directory you are in
      # (diff-word-range OLD NEW) -> ((OS OE) (NS NE)), or #f when the two
      # lines differ at neither end. Byte scanning with UTF-8 boundaries is
      # mechanism; deciding what to emphasise with it is diff-mode's.
      "diff-word-range" => fn [old, new] ->
        case word_range(old, new) do
          nil -> false
          {{os, oe}, {ns, ne}} -> [[os, oe], [ns, ne]]
        end
      end,
      # (diff-parse TEXT) -> the same file plists git-diff returns. Text that
      # git handed us whole — a commit — has no structured form of its own.
      "diff-parse" => fn [text] ->
        for f <- Aimax.Core.Git.parse(text) do
          [
            {:sym, "file-a"}, f.file_a || false,
            {:sym, "file-b"}, f.file_b || false,
            {:sym, "binary?"}, f.binary?,
            {:sym, "hunks"},
            for h <- f.hunks do
              [
                {:sym, "header"}, h.header,
                {:sym, "old-start"}, h.old_start,
                {:sym, "old-count"}, h.old_count,
                {:sym, "new-start"}, h.new_start,
                {:sym, "new-count"}, h.new_count,
                {:sym, "lines"}, for({tag, t} <- h.lines, do: [{:sym, Atom.to_string(tag)}, t])
              ]
            end
          ]
        end
      end,
      "git-prefix" => fn [dir | rest] ->
        git_dispatch(rest, fn -> Git.prefix(dir) end, & &1)
      end,
      "git-status" => fn [dir | rest] ->
        {path, rest} = opt_path(rest)
        git_dispatch(rest, fn -> Git.status(dir, path) end,
          &Enum.map(&1, fn e -> status_plist(e) end))
      end,
      # (git-diff DIR) | (git-diff DIR OPTS) | (git-diff DIR OPTS CALLBACK)
      "git-diff" => fn
        [dir] ->
          git_dispatch([], fn -> Git.diff(dir, []) end, &diff_plist/1)

        [dir, opts] ->
          if callback?(opts) do
            git_dispatch([opts], fn -> Git.diff(dir, []) end, &diff_plist/1)
          else
            git_dispatch([], fn -> Git.diff(dir, diff_opts(opts)) end, &diff_plist/1)
          end

        [dir, opts | rest] ->
          git_dispatch(rest, fn -> Git.diff(dir, diff_opts(opts)) end, &diff_plist/1)
      end,
      "git-log" => fn [dir, n | rest] ->
        {path, rest} = opt_path(rest)
        git_dispatch(rest, fn -> Git.log(dir, n, path) end,
          &Enum.map(&1, fn c -> log_plist(c) end))
      end,
      "git-show" => fn [dir, ref | rest] ->
        git_dispatch(rest, fn -> Git.show(dir, plain(ref)) end, & &1)
      end
    }
  end

  # --- the file watcher (Aimax.Core.Watch) -----------------------------------
  # The event is content-free: it names the root and nothing else, so the
  # handler re-queries. `fs-on-change!` holds ONE handler, like
  # `mcp-on-change!`; editor.scm keeps the subscriber list, because a list of
  # subscribers is policy.
  defp watch_primitives do
    %{
      "watch-path!" => fn [dir] ->
        case Aimax.Core.Watch.watch(plain(dir)) do
          {:ok, root} -> root
          {:error, msg} -> [{:sym, "error"}, msg]
        end
      end,
      "unwatch-path!" => fn [dir] ->
        Aimax.Core.Watch.unwatch(plain(dir))
        :void
      end,
      "watched-paths" => fn [] -> Aimax.Core.Watch.watching() end,
      "fs-on-change!" => fn [handler] ->
        :ets.insert(@escaped, {{:fs_handler}, handler})
        :void
      end,
      # clicking a block in a rich view. The client holds a buffer and the
      # block's own id string, not a command, so it needs a closure to hand
      # them to — the same one-handler shape as mcp-on-change! and
      # fs-on-change!. What an id means is the mode's business.
      "block-on-click!" => fn [handler] ->
        :ets.insert(@escaped, {{:block_click_handler}, handler})
        :void
      end
    }
  end

  @doc """
  Run the registered block click handler. The UI calls this: it holds a
  buffer and an opaque block id, and the policy for what a click does is
  Scheme's.
  """
  def block_click(buffer, id) do
    with tid when tid != :undefined <- :ets.whereis(@escaped),
         [{_, handler}] <- :ets.lookup(tid, {:block_click_handler}) do
      Aimax.Core.Session.apply_callback(handler, [buffer, id])
    end

    :ok
  end

  # The intra-line diff: strip the common prefix and the common suffix and
  # report what is left on each side. Exact when one span changed, which is
  # what most edited lines are, and it never lies about the ends.
  defp word_range(old, new) do
    p = common_prefix_len(old, new)
    s = common_suffix_len(binary_part(old, p, byte_size(old) - p), binary_part(new, p, byte_size(new) - p))

    omid = byte_size(old) - p - s
    nmid = byte_size(new) - p - s

    if omid <= 0 and nmid <= 0,
      do: nil,
      else: {{p, p + omid}, {p, p + nmid}}
  end

  defp common_prefix_len(a, b), do: common_prefix_len(a, b, 0)

  defp common_prefix_len(a, b, i) do
    if i < byte_size(a) and i < byte_size(b) and :binary.at(a, i) == :binary.at(b, i),
      do: common_prefix_len(a, b, i + 1),
      else: utf8_floor(a, i)
  end

  defp common_suffix_len(a, b), do: common_suffix_len(a, b, 0)

  defp common_suffix_len(a, b, i) do
    sa = byte_size(a) - 1 - i
    sb = byte_size(b) - 1 - i

    if sa >= 0 and sb >= 0 and :binary.at(a, sa) == :binary.at(b, sb),
      do: common_suffix_len(a, b, i + 1),
      # the suffix STARTS at byte_size - i, and that index must be a
      # character boundary too, or the emphasis splits a codepoint
      else: byte_size(a) - utf8_floor(a, byte_size(a) - i)
  end

  # never split a multi-byte character: walk back off a continuation byte
  defp utf8_floor(_bin, 0), do: 0

  defp utf8_floor(bin, i) do
    if i < byte_size(bin) and Bitwise.band(:binary.at(bin, i), 0xC0) == 0x80,
      do: utf8_floor(bin, i - 1),
      else: i
  end

  # a leading string in the tail is a pathspec; a closure is the callback
  defp opt_path([p | rest]) when is_binary(p), do: {p, rest}
  defp opt_path(rest), do: {nil, rest}

  defp git_dispatch([], work, shape), do: git_value(work.(), shape)

  defp git_dispatch([callback | _], work, shape) do
    key = {:git_call, make_ref()}
    rooted? = root_closure(key, callback)

    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
      value = git_value(work.(), shape)

      try do
        Aimax.Core.Session.apply_callback(callback, [value])
      after
        if rooted?, do: :ets.delete(@escaped, key)
      end
    end)

    :void
  end

  # the table belongs to the Session; a primitive called without one (tests)
  # has no GC to defend against
  defp root_closure(key, callback) do
    case :ets.whereis(@escaped) do
      :undefined ->
        false

      _tid ->
        :ets.insert(@escaped, {key, callback})
        true
    end
  end

  defp git_value({:ok, value}, shape), do: shape.(value)
  defp git_value({:error, msg}, _shape), do: [{:sym, "error"}, msg]

  defp callback?({:closure, _, _, _}), do: true
  defp callback?({:builtin, _, _}), do: true
  defp callback?(_), do: false

  defp status_plist(e) do
    [
      {:sym, "path"},
      e.path,
      {:sym, "orig-path"},
      e.orig_path || false,
      {:sym, "index"},
      e.index,
      {:sym, "worktree"},
      e.worktree
    ]
  end

  defp diff_plist(files) do
    for f <- files do
      [
        {:sym, "file-a"},
        f.file_a || false,
        {:sym, "file-b"},
        f.file_b || false,
        {:sym, "binary?"},
        f.binary?,
        {:sym, "hunks"},
        Enum.map(f.hunks, &hunk_plist/1)
      ]
    end
  end

  defp hunk_plist(h) do
    [
      {:sym, "header"},
      h.header,
      {:sym, "old-start"},
      h.old_start,
      {:sym, "old-count"},
      h.old_count,
      {:sym, "new-start"},
      h.new_start,
      {:sym, "new-count"},
      h.new_count,
      {:sym, "lines"},
      for({tag, text} <- h.lines, do: [{:sym, Atom.to_string(tag)}, text])
    ]
  end

  defp log_plist(c) do
    [
      {:sym, "sha"},
      c.sha,
      {:sym, "short-sha"},
      c.short_sha,
      {:sym, "author"},
      c.author,
      {:sym, "date"},
      c.date,
      {:sym, "subject"},
      c.subject
    ]
  end

  # (base "HEAD" path "lib/x.ex" staged #t) — a #f base drops the ref and
  # diffs the work tree against the index
  defp diff_opts(plist) when is_list(plist), do: diff_opts(plist, [])
  defp diff_opts(_), do: []

  defp diff_opts([key, value | rest], acc) do
    acc =
      case plain(key) do
        "base" -> Keyword.put(acc, :base, opt_string(value))
        "path" -> Keyword.put(acc, :path, opt_string(value))
        "staged" -> Keyword.put(acc, :staged, value == true)
        _ -> acc
      end

    diff_opts(rest, acc)
  end

  defp diff_opts(_, acc), do: acc

  defp opt_string(false), do: nil
  defp opt_string(value), do: plain(value)

  defp dir_atom({:sym, "h"}), do: :h
  defp dir_atom({:sym, "v"}), do: :v
  defp dir_atom("h"), do: :h
  defp dir_atom("v"), do: :v

  defp plain({:sym, s}), do: s
  defp plain(v), do: v

  # (fold-get BUF 'all) reads the union, the same word overlay-clear! uses
  defp fold_tag(tag), do: if(plain(tag) == "all", do: :all, else: plain(tag))

  defp shell_to_string(cmd, dir) do
    {out, _status} = System.cmd("/bin/sh", ["-c", cmd], cd: dir, stderr_to_stdout: true)
    out
  rescue
    _ -> ""
  end

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

