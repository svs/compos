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
    |> Map.merge(telemetry_primitives())
  end

  @doc "One-line doc for every primitive: signature, then an em dash, then one sentence."
  def docs do
    %{
      "buffer-create" => "(buffer-create NAME) — create an empty buffer NAME and return NAME.",
      "buffer-list" => "(buffer-list) — return the names of all buffers.",
      "buffer-list-mru" =>
        "(buffer-list-mru) — return buffer names in most-recently-used order, without internal buffers.",
      "mru-list" =>
        "(mru-list) — return (\"buffer\" NAME) and (\"group\" NAME) rows: the whole history in recency order.",
      "mru-note-group!" => "(mru-note-group! NAME) — record a group switch as a history entry.",
      "buffer-exists?" => "(buffer-exists? NAME) — return #t if the buffer NAME exists.",
      "buffer-known?" =>
        "(buffer-known? NAME) — return #t if the buffer NAME is live OR dormant in the store; a dormant buffer wakes when you visit or edit it.",
      "buffer-text" => "(buffer-text BUF) — return the buffer's whole text as a string.",
      "buffer-size" => "(buffer-size BUF) — return the buffer's size in bytes.",
      "buffer-modified?" =>
        "(buffer-modified? BUF) — return #t if the buffer changed after its last save.",
      "buffer-path" => "(buffer-path BUF) — return the buffer's file path, or #f if it has none.",
      "buffer-append!" =>
        "(buffer-append! BUF TEXT) — append TEXT to the buffer's end; ignores read-only.",
      "buffer-insert!" =>
        "(buffer-insert! BUF POS TEXT) — insert TEXT at byte POS; ignores read-only.",
      "buffer-delete-range!" =>
        "(buffer-delete-range! BUF POS LEN) — delete LEN bytes at byte POS; ignores read-only.",
      "buffer-replace-range!" =>
        "(buffer-replace-range! BUF POS LEN TEXT) — replace LEN bytes at byte POS with TEXT as one undo step; ignores read-only.",
      "buffer-version-token" =>
        "(buffer-version-token BUF) — what this replica knows, as an opaque token to hand a peer; #f if the buffer records no history.",
      "buffer-updates-since" =>
        "(buffer-updates-since BUF TOKEN) — every change a replica at TOKEN has not seen, base64. Pass #f for a replica that knows nothing.",
      "buffer-merge!" =>
        "(buffer-merge! BUF UPDATES) — take base64 changes another replica made; the rope follows and the point stays put. #t when the text changed.",
      "peer-eval" =>
        "(peer-eval SOCKET CODE) — evaluate CODE on the daemon listening at SOCKET, a local path or host:/path over ssh. Returns its printed result, or raises when it cannot be reached.",
      "buffer-anchor" =>
        "(buffer-anchor BUF POS) — an opaque anchor on byte POS that keeps naming the same place while the text around it changes; #f if the buffer records no history.",
      "buffer-anchor-pos" =>
        "(buffer-anchor-pos BUF ANCHOR) — where an anchor from buffer-anchor points now, or #f if it cannot be resolved. Read a position now, edit at it later, and the edit still lands where you meant.",
      "buffer-authors" =>
        "(buffer-authors BUF) — return (START END AUTHOR) attribution spans for the current text.",
      "buffer-author-lines" =>
        "(buffer-author-lines BUF) — return (LINE AUTHOR BYTES) attribution rows, 1-based, in line order; a line two actors touched appears once per actor.",
      "buffer-edit-log" =>
        "(buffer-edit-log BUF) — return (VERSION AUTHOR POS INS DEL) edit records, newest first.",
      "buffer-provenance-status" =>
        "(buffer-provenance-status BUF) — return the durable recording state and accepted head.",
      "buffer-history" =>
        "(buffer-history BUF) — return every change to the buffer, oldest first: who made it, what it did, and when. A delete reports how many bytes it removed, not the text.",
      "buffer-provenance-start!" =>
        "(buffer-provenance-start! BUF [ACTOR REASON POLICY]) — start or resume recording; bridges any gap.",
      "buffer-provenance-stop!" =>
        "(buffer-provenance-stop! BUF [ACTOR REASON POLICY]) — stop recording; keeps all history.",
      "buffer-provenance-checkpoint!" =>
        "(buffer-provenance-checkpoint! BUF) — close the current changeset.",
      "overlay-set!" =>
        "(overlay-set! BUF TAG RANGES) — replace TAG's overlays with (START END FACE) byte ranges.",
      "overlay-clear!" =>
        "(overlay-clear! BUF TAG) — remove TAG's overlays; the tag 'all removes every overlay.",
      "buffer-overlays" =>
        "(buffer-overlays BUF) — return all overlays as (START END FACE) byte ranges.",
      "buffer-set-hidden!" =>
        "(buffer-set-hidden! BUF RANGES) — hide (fold) the given (START END) byte ranges.",
      "fold-set!" =>
        "(fold-set! BUF TAG RANGES) — replace TAG's hidden (START END) byte ranges; the display hides the union of all tags.",
      "fold-get" =>
        "(fold-get BUF [TAG]) — return TAG's hidden ranges; no TAG, or 'all, returns the union.",
      "fold-clear!" =>
        "(fold-clear! BUF [TAG]) — drop TAG's folds; no TAG, or 'all, drops every tag's.",
      "buffer-goto!" => "(buffer-goto! BUF POS) — move the named buffer's point to byte POS.",
      "file-mtime" =>
        "(file-mtime PATH) — return the file's mtime in posix seconds, or 0 if it is gone.",
      "git-root" =>
        "(git-root DIR [CB]) — return the absolute work-tree root of DIR, or (error MSG).",
      "git-prefix" =>
        "(git-prefix DIR [CB]) — return DIR's path inside its work tree with a trailing slash, or \"\" at the root.",
      "git-status" =>
        "(git-status DIR [PATHSPEC] [CB]) — return (path P orig-path P2 index X worktree Y) plists; a pathspec scopes the read.",
      "git-diff" =>
        "(git-diff DIR [OPTS] [CB]) — return parsed file plists; OPTS is (base REF path P staged BOOL).",
      "git-log" =>
        "(git-log DIR N [PATHSPEC] [CB]) — return the last N commits as (sha short-sha author date subject) plists.",
      "git-show" => "(git-show DIR REF [CB]) — return the raw text of one commit.",
      "diff-parse" =>
        "(diff-parse TEXT) — parse unified-diff TEXT into the same file plists git-diff returns.",
      "diff-word-range" =>
        "(diff-word-range OLD NEW) — return ((OS OE) (NS NE)) byte ranges of the differing span, or #f.",
      "watch-path!" =>
        "(watch-path! DIR) — watch DIR for changes, refcounted; return the watched root or (error MSG).",
      "unwatch-path!" =>
        "(unwatch-path! DIR) — drop one watch reference; the subscription stops at zero.",
      "watched-paths" => "(watched-paths) — return the watched roots.",
      "fs-on-change!" =>
        "(fs-on-change! FN) — register the ONE handler that gets a root when a watched tree changes.",
      "telemetry-snapshot" =>
        "(telemetry-snapshot [LIMIT]) — return recent Scheme lane and task events, newest first.",
      "telemetry-clear!" => "(telemetry-clear!) — discard retained Scheme telemetry events.",
      "block-on-click!" =>
        "(block-on-click! FN) — register the ONE handler that gets (BUF ID) when a block with a click id is clicked.",
      "define-style!" =>
        "(define-style! NAME CSS) — register a stylesheet the page renders; modes ship their own CSS with this.",
      "buffer-hidden" =>
        "(buffer-hidden BUF) — return the hidden (folded) byte ranges as (START END) pairs.",
      "buffer-set-read-only!" =>
        "(buffer-set-read-only! BUF BOOL) — set the buffer's read-only flag.",
      "buffer-read-only?" => "(buffer-read-only? BUF) — return #t if the buffer is read-only.",
      "buffer-kill!" => "(buffer-kill! BUF) — kill the buffer and release its windows.",
      "ssh-command" => "(ssh-command) — return the configured ssh command string.",
      "remote-read" =>
        "(remote-read HOST PATH [CALLBACK]) — read a remote file; return text, 'directory, 'absent, or (error MSG). With CALLBACK, run in a Task and hand it the value.",
      "remote-list-dir" =>
        "(remote-list-dir HOST DIR [CALLBACK]) — list a remote directory; return entries or (error MSG). With CALLBACK, run in a Task and hand it the value.",
      "remote-sh" =>
        "(remote-sh HOST CMD [CALLBACK]) — run CMD on HOST over ssh; return #t or (error MSG). With CALLBACK, run in a Task and hand it the value.",
      "remote-write" =>
        "(remote-write HOST PATH TEXT [CALLBACK]) — write TEXT to a remote file; return #t or (error MSG). With CALLBACK, run in a Task and hand it the value.",
      "buffer-mark-saved!" => "(buffer-mark-saved! BUF) — clear the buffer's modified flag.",
      "find-file" =>
        "(find-file PATH) — open the file PATH in a buffer and return the buffer name.",
      "list-dir" =>
        "(list-dir DIR) — return sorted entry names; directories carry a trailing slash.",
      "directory-entries" =>
        "(directory-entries DIR) — return sorted entry plists with name, type, exact bytes, mtime, size, date, and perms; return (error MSG) when DIR cannot be read.",
      "expand-path" => "(expand-path PATH) — expand PATH to an absolute path.",
      "file-stat" => "(file-stat PATH) — return (PERMS SIZE DATE) strings in dired style.",
      "url-encode" => "(url-encode S) — percent-encode S as one URL path segment.",
      "url-decode" => "(url-decode S) — decode a percent-encoded URL segment.",
      "file-exists?" => "(file-exists? PATH) — return #t if PATH exists.",
      "file-directory?" => "(file-directory? PATH) — return #t if PATH is a directory.",
      "read-file" => "(read-file PATH) — return the file's contents, or #f if unreadable.",
      "shell-command->string" =>
        "(shell-command->string CMD [DIR] [CALLBACK]) — run CMD in a shell; stderr merges into the output. With CALLBACK, run in a Task and return :void at once; CALLBACK gets the output. Without CALLBACK, block up to the shell time limit, then kill CMD and return what it wrote.",
      "scheme-read" =>
        "(scheme-read STR) — read STR as Scheme data; return the list of top-level forms, or #f when STR does not parse.",
      "getenv" =>
        "(getenv NAME) — return the environment variable NAME, or #f if it is unset or empty.",
      "json-parse" =>
        "(json-parse STR) — parse JSON; objects become plists with symbol keys; #f on failure.",
      "json-encode" =>
        "(json-encode V [PRETTY]) — encode a Scheme value as a JSON string; a plist becomes an object. A truthy PRETTY indents the output.",
      "write-file!" =>
        "(write-file! PATH TEXT) — write TEXT to PATH, create parent directories; return #t.",
      "start-process!" =>
        "(start-process! BUF CMD) — start a shell process attached to BUF; return #t on success.",
      "start-terminal!" =>
        "(start-terminal! BUF CMD) — start a raw PTY whose bounded plain transcript stays in BUF; return #t on success.",
      "process-send!" =>
        "(process-send! BUF TEXT) — send TEXT to the buffer's process; return #t on success.",
      "process-running?" => "(process-running? BUF) — return #t if the buffer's process runs.",
      "process-mark" =>
        "(process-mark BUF) — return the byte position just after the last process output.",
      "buffer-substring" =>
        "(buffer-substring START END) — return the current buffer's text between byte START and END.",
      "process-kill!" => "(process-kill! BUF) — kill the buffer's process.",
      "process-list" =>
        "(process-list) — return ((BUF CMD) ...) for every running process buffer.",
      "process-restart!" =>
        "(process-restart! BUF) — kill the buffer's process and run its command again; return #t on success.",
      "line-text" => "(line-text) — return the current line's text, without the newline.",
      "current-buffer" => "(current-buffer) — return the name of the current buffer.",
      "point" => "(point) — return point in the current buffer as a byte offset.",
      "buffer-point" => "(buffer-point BUF) — return the buffer's point as a byte offset.",
      "aimax-home" => "(aimax-home) — return the aimax home directory path (~/.aimax).",
      "aimax-priv-dir" =>
        "(aimax-priv-dir) — return the bundled Scheme directory (the editor's priv dir).",
      "aimax-config-dir" =>
        "(aimax-config-dir) — where user config reads from (AIMAX_CONFIG, else the home).",
      "aimax-socket-path" =>
        "(aimax-socket-path) — return the path of this daemon's JSON-RPC socket.",
      "socket-listeners" =>
        "(socket-listeners) — return ((NAME STATUS ADDRESS) ...) for the daemon's listen sockets.",
      "listener-restart!" =>
        "(listener-restart! NAME) — stop and start the named listen socket; return #t.",
      "daemon-restart!" =>
        "(daemon-restart!) — save the desktop, restart the daemon, and reload Scheme; return #t.",
      "reload-files!" =>
        "(reload-files! PATHS) — evaluate the changed top-level forms of each .scm and refresh the modes they redefine; return (FILES FORMS).",
      "window-list-all" =>
        "(window-list-all) — return ((WINDOW-ID BUFFER FRAME-ID) ...) for every window on every frame.",
      "redraw!" =>
        "(redraw!) — tell every connected client to re-render every frame; return #t.",
      "daemon-provision-workspace!" =>
        "(daemon-provision-workspace! PATH NAME) — start or reuse a daemon from PATH; return (URL HOME PORT).",
      "goto-char!" => "(goto-char! POS) — move point to byte POS; return POS.",
      "forward-char!" =>
        "(forward-char!) — move point one character forward; return the new point.",
      "backward-char!" =>
        "(backward-char!) — move point one character backward; return the new point.",
      "forward-word!" =>
        "(forward-word!) — move point to the end of the next word; return the new point.",
      "backward-word!" =>
        "(backward-word!) — move point to the start of the previous word; return the new point.",
      "next-line!" =>
        "(next-line!) — move point one line down, keep the goal column; return the new point.",
      "previous-line!" =>
        "(previous-line!) — move point one line up, keep the goal column; return the new point.",
      "beginning-of-line!" =>
        "(beginning-of-line!) — move point to the line start; return the new point.",
      "end-of-line!" => "(end-of-line!) — move point to the line end; return the new point.",
      "beginning-of-buffer!" =>
        "(beginning-of-buffer!) — move point to byte 0; return the new point.",
      "end-of-buffer!" =>
        "(end-of-buffer!) — move point to the buffer's end; return the new point.",
      "line-start-position" =>
        "(line-start-position LINE) — return the start byte offset of 1-based LINE.",
      "line-number-at-pos" =>
        "(line-number-at-pos POS) — return the 1-based line byte offset POS is on.",
      "insert!" => "(insert! TEXT) — insert TEXT at point; errors if the buffer is read-only.",
      "delete-char!" =>
        "(delete-char! N) — delete N characters at point, backward if negative; return the text.",
      "kill-line!" =>
        "(kill-line!) — delete from point to the line end, or the newline; return the text.",
      "undo!" => "(undo!) — undo one step in the current buffer; return #t on success.",
      "break-undo-chain!" =>
        "(break-undo-chain!) — start a new undo group in the current buffer.",
      "undo-exempt!" =>
        "(undo-exempt! COMMAND) — exempt COMMAND from the automatic undo-chain break.",
      "buffer-save!" =>
        "(buffer-save! [PATH]) — save the current buffer to its path; return the path or #f. With PATH, save there and adopt PATH as the buffer's path.",
      "kill-push!" => "(kill-push! TEXT) — push TEXT onto the kill ring.",
      "kill-top" => "(kill-top) — return the newest kill-ring entry, or \"\" when empty.",
      "kill-nth" => "(kill-nth I) — return kill-ring entry I (0 is newest), or \"\" when absent.",
      "kill-ring-size" => "(kill-ring-size) — return the number of kill-ring entries.",
      "clipboard-put!" =>
        "(clipboard-put! TEXT) — put TEXT on the OS clipboard of this frame's client.",
      "editor-url" =>
        "(editor-url) — return the base URL this editor serves, e.g. http://localhost:4004.",
      "daemon-name" => "(daemon-name) — return this daemon's configured name.",
      "daemon-source-root" =>
        "(daemon-source-root) — return the checkout that supplies this daemon's code.",
      "daemon-workspace-root" =>
        "(daemon-workspace-root) — return this daemon's workspace root, or #f.",
      "daemon-set-workspace-label!" =>
        "(daemon-set-workspace-label! PROJECT NAME) — set this daemon's frame-wide workspace label.",
      "daemon-registry-path" =>
        "(daemon-registry-path) — return the shared daemon registry file path.",
      "navigate-url!" => "(navigate-url! URL) — navigate this frame's browser tab to URL.",
      "buffer-set-local!" => "(buffer-set-local! BUF KEY VALUE) — set a buffer-local variable.",
      "buffer-local" =>
        "(buffer-local BUF KEY) — return a buffer-local variable's value, or #f if unset.",
      "buffer-locals" =>
        "(buffer-locals BUF) — return ((KEY VALUE) ...) for every buffer-local, sorted by name.",
      "set-mark!" => "(set-mark! POS) — set the mark at byte POS; #f clears the mark.",
      "mark" => "(mark) — return the mark's byte offset, or #f if no mark is set.",
      "region-beginning" =>
        "(region-beginning) — return the smaller of point and mark as a byte offset.",
      "region-end" => "(region-end) — return the larger of point and mark as a byte offset.",
      "region-text" => "(region-text) — return the text between point and mark.",
      "delete-region!" => "(delete-region!) — delete the text between point and mark.",
      "exchange-point-and-mark!" =>
        "(exchange-point-and-mark!) — swap point and mark; return #f if no mark is set.",
      "ts-nav" =>
        "(ts-nav OP) — tree-sitter motion 'forward|'backward|'up|'down; return a byte pos or #f.",
      "ts-node" =>
        "(ts-node KIND START END OP) — the node KIND covers the range (\"\" for the smallest); return its 'at|'parent|'child|'next|'prev|'top as (KIND START END), or #f.",
      "ts-children" =>
        "(ts-children KIND START END) — the named children of that node as ((KIND START END) ...); the range 0..SIZE names the whole file.",
      "ts-query" =>
        "(ts-query QUERY) — run a tree-sitter query; return (CAPTURE START END) byte ranges.",
      "ts-query-string" =>
        "(ts-query-string LANG TEXT QUERY) — run a tree-sitter query on detached text; return (CAPTURE START END) byte ranges.",
      "ts-langs" => "(ts-langs) — return the names of the loaded tree-sitter languages.",
      "ts-highlight-string" =>
        "(ts-highlight-string LANG TEXT) — highlight TEXT as LANG; return (START END SCOPE) byte ranges, () for an unknown language.",
      "buffer-search" =>
        "(buffer-search Q FROM) — search forward from byte FROM; return (START END) or #f.",
      "buffer-search-backward" =>
        "(buffer-search-backward Q FROM) — search backward from byte FROM; return (START END) or #f.",
      "set-face-attribute!" =>
        "(set-face-attribute! FACE KEY VALUE ...) — set the face's attributes from key-value pairs.",
      "split-window!" =>
        "(split-window! DIR [RATIO]) — split the active window 'h or 'v at RATIO (default 0.5).",
      "delete-window!" => "(delete-window!) — delete the active window; return #t on success.",
      "delete-window-id!" => "(delete-window-id! WIN) — delete window WIN; return #t on success.",
      "window-list" =>
        "(window-list) — return (WIN BUFFER) pairs for the selected frame's windows.",
      "window-tree" =>
        "(window-tree) — return the frame's window layout as an opaque value for window-tree-set!.",
      "window-tree-set!" =>
        "(window-tree-set! LAYOUT) — replace the frame's windows with a layout from window-tree.",
      "window-tree-buffers" =>
        "(window-tree-buffers LAYOUT) — return the buffer names a layout from window-tree holds.",
      "window-rects" =>
        "(window-rects) — return (WIN BUFFER X Y W H) rows with fractional rectangles.",
      "select-window!" =>
        "(select-window! WIN) — make WIN and its frame active; return #t on success.",
      "active-window" => "(active-window) — return the active window's id.",
      "scroll-window!" =>
        "(scroll-window! WIN LINES) — scroll window WIN by LINES; return #t on success.",
      "delete-other-windows!" =>
        "(delete-other-windows!) — delete every window in the frame except the active one.",
      "other-window!" => "(other-window!) — select the next window in the frame.",
      "switch-to-buffer!" =>
        "(switch-to-buffer! BUF) — show BUF in the active window; return BUF.",
      "window-switch-buffer!" =>
        "(window-switch-buffer! BUF) — raw switch that restores a dormant BUF inline; return BUF.",
      "frame-list" => "(frame-list) — return frame ids in most-recently-used order.",
      "selected-frame" => "(selected-frame) — return the current frame's id.",
      "select-frame!" => "(select-frame! FRAME) — make FRAME current; return #t on success.",
      "make-frame!" => "(make-frame!) — create a frame and return its id.",
      "window-list-all" =>
        "(window-list-all) — return (WIN BUFFER FRAME) rows for every window in every frame.",
      "window-set-buffer!" =>
        "(window-set-buffer! WIN BUF) — show BUF in window WIN without selection; return #t.",
      "frame-of-window" => "(frame-of-window WIN) — return the id of the window's frame, or #f.",
      "minibuffer-read" =>
        "(minibuffer-read PROMPT CANDIDATES [ON-COMPLETE] ON-CONFIRM) — activate the minibuffer.",
      "minibuffer-read*" =>
        "(minibuffer-read* PROMPT CANDIDATES HANDLERS) — activate the minibuffer with a handler alist, including an optional collect handler.",
      "global-set-key" =>
        "(global-set-key SEQ COMMAND) — bind the key sequence SEQ to COMMAND globally.",
      "local-set-key" =>
        "(local-set-key SEQ COMMAND) — bind SEQ to COMMAND in the current buffer.",
      "local-set-key*" => "(local-set-key* BUF SEQ COMMAND) — bind SEQ to COMMAND in buffer BUF.",
      "local-unset-key*" => "(local-unset-key* BUF SEQ) — drop BUF's own binding for SEQ.",
      "transient-show!" =>
        "(transient-show! MENU) — show this frame's Transient modal; #f clears it.",
      "local-remap!" =>
        "(local-remap! FROM TO) — in the current buffer, every key bound to FROM runs TO.",
      "local-remap*!" =>
        "(local-remap*! BUF FROM TO) — in buffer BUF, every key bound to FROM runs TO.",
      "key-for-command" =>
        "(key-for-command COMMAND) — return the tersest key sequence bound to COMMAND, or \"\".",
      "key-binding" =>
        "(key-binding SEQ) — the command SEQ runs in this buffer: a name, 'prefix, or #f. SEQ is a list of keys.",
      "capture-key!" =>
        "(capture-key! COMMAND) — the next key sequence runs COMMAND instead of its own binding; COMMAND reads it with (last-keys). #f disarms.",
      "last-command" => "(last-command) — return the name of the last command that ran.",
      "last-keys" =>
        "(last-keys) — return the key sequence whose keymap lookup ran the current command.",
      "current-prefix-arg" =>
        "(current-prefix-arg) — return this frame's raw one-shot prefix argument, or #f.",
      "set-prefix-arg!" =>
        "(set-prefix-arg! VALUE) — set this frame's raw one-shot prefix argument; #f clears it.",
      "window-rows" => "(window-rows) — return the number of text rows in the active window.",
      "window-cols" =>
        "(window-cols [WIN]) — return the number of text columns in WIN, or in the active window.",
      "frame-cols" => "(frame-cols) — estimate the usable text columns across the current frame.",
      "buffer-cols" =>
        "(buffer-cols BUF) — return the text columns of a window showing BUF, else the active window's.",
      "recenter!" => "(recenter!) — center the active window on the cursor line.",
      "completion-show!" =>
        "(completion-show! START END CANDIDATES) — show the completion popup for byte START.",
      "completion-dismiss!" => "(completion-dismiss!) — dismiss the completion popup.",
      "completion-move!" => "(completion-move! DELTA) — move the popup selection by DELTA rows.",
      "completion-accept!" =>
        "(completion-accept!) — close the popup; return (START LABEL) of the selection, or #f.",
      "buffer-words" =>
        "(buffer-words PREFIX) — return the buffer's words with PREFIX, sorted, without PREFIX itself.",
      "count-words" => "(count-words BUF) — return the buffer's whitespace-separated word count.",
      "minibuffer-selected" =>
        "(minibuffer-selected) — return the highlighted minibuffer candidate.",
      "set-mb-redirect!" =>
        "(set-mb-redirect! BOOL) — toggle redirection of current-buffer to the minibuffer's text.",
      "window-preview-buffer!" =>
        "(window-preview-buffer! BUF [WIN]) — show BUF in WIN (default: the active window) without MRU changes.",
      "buffer-sleep!" =>
        "(buffer-sleep! NAME) — checkpoint NAME and stop its process; the buffer stays known. #f when NAME is on screen, busy, or pinned.",
      "minibuffer-set-candidates!" =>
        "(minibuffer-set-candidates! CANDIDATES) — replace the minibuffer's candidate list.",
      "set-frame-group-label!" =>
        "(set-frame-group-label! NAME [FRAME]) — record a frame's group context; #f clears it. FRAME defaults to the selected one.",
      "delete-file!" =>
        "(delete-file! PATH) — delete a file or empty directory; return #t or error.",
      "trash-file!" =>
        "(trash-file! PATH) — move one file or directory to the user trash; return its new path.",
      "copy-file!" =>
        "(copy-file! SOURCE DESTINATION) — copy one file or directory without overwriting; return DESTINATION.",
      "set-file-mode!" => "(set-file-mode! PATH MODE) — set octal MODE such as 755 on PATH.",
      "touch-file!" => "(touch-file! PATH) — update PATH's mtime or create an empty file.",
      "make-symlink!" =>
        "(make-symlink! TARGET LINK) — create LINK as a symbolic link to TARGET without overwriting.",
      "buffer-rename!" =>
        "(buffer-rename! OLD NEW) — rename a buffer in place, keeping its text, point, locals and undo; return NEW, or #f if the name is taken. Policy lives in rename-buffer!.",
      "rename-file!" =>
        "(rename-file! SOURCE DESTINATION) — move a file or directory and carry an open buffer with it.",
      "make-directory!" =>
        "(make-directory! PATH) — create the directory and its parents; return #t."
    }
  end

  defp telemetry_primitives do
    %{
      "telemetry-snapshot" => fn
        [] -> telemetry_events(200)
        [limit] -> telemetry_events(trunc(limit))
      end,
      "telemetry-clear!" => fn [] ->
        :ok = Aimax.Core.Telemetry.clear()
        :void
      end
    }
  end

  defp telemetry_events(limit) do
    limit = max(0, min(limit, 1_000))

    Aimax.Core.Telemetry.events(limit)
    |> Enum.map(fn event ->
      [
        {:sym, "kind"},
        event.kind,
        {:sym, "time-ms"},
        event.time_ms,
        {:sym, "duration-ms"},
        event.duration_ms,
        {:sym, "queue-ms"},
        event.queue_ms,
        {:sym, "backlog"},
        event.backlog,
        {:sym, "owner"},
        event.owner,
        {:sym, "label"},
        event.label,
        {:sym, "status"},
        event.status
      ]
    end)
  end

  defp buffer_primitives do
    %{
      "buffer-create" => fn [name] ->
        Core.create_buffer(name)
        name
      end,
      "buffer-list" => fn [] -> Core.list_buffers() end,
      "buffer-list-mru" => fn [] -> Editor.buffer_mru() end,
      # the whole history: ("buffer" NAME) and ("group" NAME) rows in
      # recency order — a group switch is an entry like a buffer visit
      "mru-list" => fn [] -> Editor.mru_all() end,
      "mru-note-group!" => fn [g] ->
        Editor.mru_note_group(g)
        :void
      end,
      "buffer-exists?" => fn [name] -> Buffer.exists?(name) end,
      # the buffer list names dormant buffers too: they hold a checkpoint
      # and no process. A verb asks this, not exists?, or it refuses to act
      # on the rows it shows.
      "buffer-known?" => fn [name] ->
        Buffer.exists?(name) or Aimax.Core.BufferStore.known?(name)
      end,
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
      "buffer-replace-range!" => fn [name, pos, len, text] ->
        :ok = Buffer.replace_range(name, pos, len, text, source: :editor)
        :void
      end,
      "buffer-version-token" => fn [name] ->
        case Buffer.version_token(name) do
          token when is_binary(token) -> Base.url_encode64(token, padding: false)
          _ -> false
        end
      end,
      "buffer-updates-since" => fn [name, token] ->
        from =
          case token do
            t when is_binary(t) -> Base.url_decode64!(t, padding: false)
            _ -> nil
          end

        case Buffer.updates_since(name, from) do
          bytes when is_binary(bytes) -> Base.url_encode64(bytes, padding: false)
          {:error, reason} -> raise Aimax.Scheme.Eval.Error, message: inspect(reason)
        end
      end,
      "buffer-merge!" => fn [name, updates] ->
        bytes = Base.url_decode64!(updates, padding: false)

        case Buffer.merge(name, bytes) do
          {:ok, changed?} -> changed?
          {:error, reason} -> raise Aimax.Scheme.Eval.Error, message: inspect(reason)
        end
      end,
      "peer-eval" => fn [socket, code] ->
        case Aimax.Core.Peer.eval(socket, code) do
          {:ok, printed} -> printed
          {:error, reason} -> raise Aimax.Scheme.Eval.Error, message: inspect(reason)
        end
      end,
      "buffer-anchor" => fn [name, pos] ->
        Buffer.anchor(name, pos) || false
      end,
      "buffer-anchor-pos" => fn [name, anchor] ->
        Buffer.anchor_pos(name, anchor) || false
      end,
      "buffer-authors" => fn [name] ->
        for {s, e, a} <- Buffer.authors(name), do: [s, e, a]
      end,
      "buffer-author-lines" => fn [name] ->
        for {line, author, bytes} <- Buffer.author_lines(name), do: [line, author, bytes]
      end,
      "buffer-edit-log" => fn [name] ->
        for {v, a, pos, ins, del} <- Buffer.edit_log(name), do: [v, a || false, pos, ins, del]
      end,
      "buffer-provenance-status" => fn [name] ->
        Buffer.provenance(name) |> json_to_scheme_value()
      end,
      "buffer-history" => fn [name] ->
        Buffer.change_log(name) |> json_to_scheme_value()
      end,
      "buffer-provenance-start!" => fn
        [name] ->
          :ok = Buffer.provenance_start(name, source: :editor)
          :void

        [name, actor, reason, policy_source] ->
          :ok =
            Buffer.provenance_start(
              name,
              source: :editor,
              author: plain(actor),
              reason: plain(reason),
              policy_source: plain(policy_source)
            )

          :void
      end,
      "buffer-provenance-stop!" => fn
        [name] ->
          :ok = Buffer.provenance_stop(name, source: :editor)
          :void

        [name, actor, reason, policy_source] ->
          :ok =
            Buffer.provenance_stop(
              name,
              source: :editor,
              author: plain(actor),
              reason: plain(reason),
              policy_source: plain(policy_source)
            )

          :void
      end,
      "buffer-provenance-checkpoint!" => fn [name] ->
        case Buffer.provenance_checkpoint(name, source: :editor) do
          :ok -> :void
          {:error, reason} -> [{:sym, "error"}, Atom.to_string(reason)]
        end
      end,
      # overlays: (overlay-set! buf 'org (list (list s e "org-todo") ...))
      # replaces the tag's whole range set — the fontification model is
      # "mode recomputes"; positions auto-adjust between recomputes
      "overlay-set!" => fn [name, tag, ranges] ->
        :ok =
          Buffer.set_overlays(
            name,
            plain(tag),
            Enum.map(ranges, fn [s, e, f] -> {s, e, plain(f)} end)
          )

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
      "remote-read" => fn [host, path | rest] ->
        work = fn ->
          case Aimax.Core.Remote.read(host, path) do
            {:ok, text} -> text
            :directory -> {:sym, "directory"}
            :absent -> {:sym, "absent"}
            {:error, msg} -> [{:sym, "error"}, msg]
          end
        end

        case rest do
          [] -> work.()
          [callback] -> async_dispatch(callback, work)
        end
      end,
      "remote-list-dir" => fn [host, dir | rest] ->
        work = fn ->
          case Aimax.Core.Remote.list_dir(host, dir) do
            {:ok, entries} -> entries
            {:error, msg} -> [{:sym, "error"}, msg]
          end
        end

        case rest do
          [] -> work.()
          [callback] -> async_dispatch(callback, work)
        end
      end,
      "remote-sh" => fn [host, cmd | rest] ->
        work = fn ->
          case Aimax.Core.Remote.sh(host, cmd) do
            :ok -> true
            {:error, msg} -> [{:sym, "error"}, msg]
          end
        end

        case rest do
          [] -> work.()
          [callback] -> async_dispatch(callback, work)
        end
      end,
      "remote-write" => fn [host, path, text | rest] ->
        work = fn ->
          case Aimax.Core.Remote.write(host, path, text) do
            :ok -> true
            {:error, msg} -> [{:sym, "error"}, msg]
          end
        end

        case rest do
          [] -> work.()
          [callback] -> async_dispatch(callback, work)
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
      # One read supplies Dired's row data. File.lstat/2 preserves links,
      # and exact bytes stay separate from the formatted display value.
      "directory-entries" => fn [dir] ->
        expanded = Path.expand(if dir == "", do: ".", else: dir)

        case File.ls(expanded) do
          {:ok, names} ->
            names
            |> Enum.sort()
            |> Enum.map(&directory_entry(expanded, &1))

          {:error, reason} ->
            [{:sym, "error"}, file_error(reason, expanded)]
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
      # one segment, so a file buffer's slashes survive the round trip
      "url-encode" => fn [s] -> URI.encode(s, &URI.char_unreserved?/1) end,
      "url-decode" => fn [s] -> URI.decode(s) end,
      "file-exists?" => fn [p] -> File.exists?(Path.expand(p)) end,
      "file-directory?" => fn [p] -> File.dir?(Path.expand(p)) end,
      # (read-file PATH) -> contents, or #f if unreadable
      "read-file" => fn [p] ->
        case File.read(Path.expand(p)) do
          {:ok, text} -> text
          {:error, _} -> false
        end
      end,
      # (getenv NAME) — an unset OR empty variable is #f: a caller asking for
      # a key wants the next source in the chain, not the empty string
      "getenv" => fn [name] ->
        case System.get_env(name) do
          v when v in [nil, ""] -> false
          v -> v
        end
      end,
      # This is mechanism, including for agent-attributed evals. Scheme's
      # permission policy is an overridable convenience, not an OS sandbox.
      "shell-command->string" => fn
        [cmd] ->
          shell_to_string(cmd, File.cwd!())

        [cmd, dir_or_cb | rest] ->
          {dir, callback} =
            case {dir_or_cb, rest} do
              {cb, []} when not is_binary(cb) -> {File.cwd!(), cb}
              {dir, []} -> {Path.expand(dir), nil}
              {dir, [cb]} -> {Path.expand(dir), cb}
            end

          if callback do
            async_dispatch(callback, fn -> shell_to_string(cmd, dir, shell_async_limit()) end)
          else
            shell_to_string(cmd, dir)
          end
      end,
      "scheme-read" => fn [src] ->
        try do
          Aimax.Scheme.Reader.read_all(src)
        rescue
          _ -> false
        end
      end,
      # (json-parse STR) — objects become flat plists with symbol keys,
      # null becomes #f; #f on parse failure
      "json-parse" => fn [s] ->
        case Jason.decode(s) do
          {:ok, v} -> Aimax.Core.LLM.json_to_scheme(v)
          {:error, _} -> false
        end
      end,
      # (json-encode V [PRETTY]) — the inverse: a plist becomes an object,
      # any other list an array. Escaping is the encoder's job, so a value
      # survives a round trip through a file that the printer's own escapes
      # do not. A truthy PRETTY indents the output.
      "json-encode" => fn
        [v] -> Jason.encode!(Aimax.Core.Session.scheme_to_json(v))
        [v, false] -> Jason.encode!(Aimax.Core.Session.scheme_to_json(v))
        [v, _pretty] -> Jason.encode!(Aimax.Core.Session.scheme_to_json(v), pretty: true)
      end,
      "write-file!" => fn [p, text] ->
        path = Path.expand(p)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, text)
        true
      end,
      "start-process!" => fn [buffer, cmd] ->
        case Aimax.Core.Proc.start(buffer, cmd) do
          {:ok, _} -> true
          {:error, {:already_started, _}} -> true
          _ -> false
        end
      end,
      "start-terminal!" => fn [buffer, cmd] ->
        case Aimax.Core.Terminal.start(buffer, cmd) do
          {:ok, _} -> true
          {:error, {:already_started, _}} -> true
          _ -> false
        end
      end,
      "process-send!" => fn [buffer, text] ->
        result =
          if Aimax.Core.Terminal.running?(buffer),
            do: Aimax.Core.Terminal.send_text(buffer, text),
            else: Aimax.Core.Proc.send_text(buffer, text)

        result == :ok
      end,
      "process-running?" => fn [buffer] ->
        Aimax.Core.Terminal.running?(buffer) or Aimax.Core.Proc.running?(buffer)
      end,
      "process-mark" => fn [buffer] -> Aimax.Core.Proc.mark(buffer) end,
      "buffer-substring" => fn [s, e] ->
        text = Buffer.text(Editor.current_buffer())
        binary_part(text, s, min(e, Kernel.byte_size(text)) - s)
      end,
      "process-kill!" => fn [buffer] ->
        if Aimax.Core.Terminal.running?(buffer),
          do: Aimax.Core.Terminal.kill(buffer),
          else: Aimax.Core.Proc.kill(buffer)

        :void
      end,
      "process-list" => fn [] ->
        for {name, cmd} <- Enum.sort(Aimax.Core.Proc.list() ++ Aimax.Core.Terminal.list()),
            do: [name, cmd]
      end,
      "process-restart!" => fn [buffer] ->
        result =
          if Aimax.Core.Terminal.running?(buffer),
            do: Aimax.Core.Terminal.restart(buffer),
            else: Aimax.Core.Proc.restart(buffer)

        case result do
          {:ok, _} -> true
          _ -> false
        end
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
      "aimax-priv-dir" => fn [] -> Application.app_dir(:aimax_core, "priv") end,
      "aimax-config-dir" => fn [] -> Aimax.Core.config_dir() end,
      # The socket THIS daemon listens on. A second daemon (AIMAX_HOME, or the
      # verify config) listens elsewhere, and anything it spawns must come back
      # to it rather than to the default path.
      "aimax-socket-path" => fn [] ->
        Application.get_env(:aimax_rpc, :socket_path, Path.join(Aimax.Core.home(), "sock"))
        |> Path.expand()
      end,
      "socket-listeners" => fn [] ->
        for l <- Aimax.Core.Daemon.listeners(), do: [l.name, l.status, l.address]
      end,
      "listener-restart!" => fn [name] ->
        case Aimax.Core.Daemon.restart_listener(name) do
          :ok ->
            true

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message: "listener-restart!: #{name}: #{inspect(reason)}"
        end
      end,
      "daemon-restart!" => fn [] ->
        case Aimax.Core.Daemon.restart() do
          :ok ->
            true

          {:error, :desktop_save_failed} ->
            raise Aimax.Scheme.Eval.Error, message: "desktop save failed; refusing to restart"

          {:error, {:spawn_failed, _code, out}} ->
            raise Aimax.Scheme.Eval.Error,
              message: "could not respawn the daemon: #{inspect(out)}"

          {:error, {:compile_failed, out}} ->
            raise Aimax.Scheme.Eval.Error,
              message: "the tree does not compile; staying up: #{out}"
        end
      end,
      "window-list-all" => fn [] ->
        Enum.map(Editor.list_windows_all(), fn {id, buffer, fid} -> [id, buffer, fid] end)
      end,
      # A reload changes what a render would produce, but nothing asks for
      # one: the client repaints on an editor event, and evaluating a
      # definition is not an event. Without this a reloaded modeline, face,
      # or fringe stays on screen exactly as it was until the next keystroke,
      # which reads as "the reload did nothing".
      "redraw!" => fn [] ->
        Aimax.Core.Events.broadcast_editor(:redraw)
        Enum.each(Editor.frame_list(), &Aimax.Core.Events.broadcast_frame/1)
        true
      end,
      # The incremental form reloader, which lives in the Session. Scheme
      # cannot reach it otherwise: the diff is over read forms, and the
      # manifest of what each file last held is the Session's state.
      "reload-files!" => fn [paths] ->
        case Aimax.Core.Session.reload_files(List.wrap(paths)) do
          {:ok, %{files: files, forms: forms}} ->
            [files, forms]

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error, message: "reload failed: #{inspect(reason)}"
        end
      end,
      "daemon-provision-workspace!" => fn [workspace, name] ->
        case Aimax.Core.Daemon.provision_workspace(workspace, name) do
          {:ok, %{url: url, home: home, port: port}} ->
            [url, home, port]

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message: "workspace daemon failed: #{inspect(reason)}"
        end
      end,
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
      "line-number-at-pos" => fn [pos] ->
        Buffer.line_of(Editor.current_buffer(), trunc(pos))
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
      "buffer-save!" => fn
        [] ->
          case Buffer.save(Editor.current_buffer()) do
            {:ok, path} -> path
            {:error, :no_path} -> false
          end

        [path] ->
          {:ok, path} = Buffer.save(Editor.current_buffer(), path)
          path
      end,

      # kill ring
      "kill-push!" => fn [text] ->
        Editor.kill_push(text)
        :void
      end,
      "kill-top" => fn [] -> Editor.kill_top() end,
      "kill-nth" => fn [i] -> Editor.kill_nth(i) end,
      "kill-ring-size" => fn [] -> Editor.kill_size() end,
      "clipboard-put!" => fn [text] ->
        Editor.put_clipboard(text)
        :void
      end,

      # the LiveView app puts its own base URL at boot; a headless daemon
      # (tests, RPC with no web app) still answers with the default
      "editor-url" => fn [] ->
        :persistent_term.get(:aimax_editor_url, "http://localhost:4004")
      end,
      "daemon-name" => fn [] -> Application.get_env(:aimax_core, :name, "aimax") end,
      "daemon-source-root" => fn [] -> File.cwd!() end,
      "daemon-workspace-root" => fn [] ->
        Application.get_env(:aimax_core, :workspace_root, false)
      end,
      "daemon-set-workspace-label!" => fn [project, name] ->
        Application.put_env(:aimax_core, :workspace_project, to_string(project))
        Application.put_env(:aimax_core, :workspace_name, to_string(name))
        Aimax.Core.Events.broadcast_editor(:workspace_label)
        :void
      end,
      "daemon-registry-path" => fn [] ->
        Application.get_env(
          :aimax_core,
          :daemon_registry_path,
          Path.expand("~/.aimax/daemons.json")
        )
      end,
      "navigate-url!" => fn [url] ->
        Editor.navigate(url)
        :void
      end,

      # buffer-local variables
      "buffer-set-local!" => fn [buf, k, v] ->
        Buffer.set_local(buf, plain(k), v)
        :void
      end,
      "buffer-local" => fn [buf, k] -> Buffer.get_local(buf, plain(k)) || false end,
      # every local at once, so a help page can show a buffer's own state.
      # The name comes back as a symbol, the way the setter takes it.
      "buffer-locals" => fn [buf] ->
        buf
        |> Buffer.locals()
        |> Enum.map(fn {k, v} -> {to_string(k), v} end)
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {k, v} -> [{:sym, k}, v || false] end)
      end,

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
      "ts-node" => fn [kind, start, stop, op] ->
        buf = Editor.current_buffer()
        kind = if is_binary(kind), do: kind, else: ""

        case Buffer.ts_node(buf, kind, start, stop, plain(op)) do
          nil -> false
          {kind, s, e} -> [kind, s, e]
        end
      end,
      "ts-children" => fn [kind, start, stop] ->
        kind = if is_binary(kind), do: kind, else: ""

        Editor.current_buffer()
        |> Buffer.ts_children(kind, start, stop)
        |> Enum.map(fn {k, s, e} -> [k, s, e] end)
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
      # Detached text has no buffer parser state. Search commands use this
      # mechanism for a file or an explicit language without changing a
      # buffer's mode or its incremental parser.
      "ts-query-string" => fn [lang, text, query] ->
        if is_binary(lang) and is_binary(text) and is_binary(query) do
          lang
          |> Aimax.Core.TS.ts_query_nif(text, query)
          |> Enum.map(fn {cap, s, e} -> [cap, s, e] end)
        else
          []
        end
      end,
      "ts-langs" => fn [] -> Aimax.Core.TS.ts_langs() end,
      # one-shot highlight of detached text (embedded code blocks in
      # prose modes); the buffer's own language never enters into it
      "ts-highlight-string" => fn [lang, text] ->
        if is_binary(lang) and is_binary(text) do
          lang
          |> Aimax.Core.TS.ts_highlight(text)
          |> Enum.map(fn {s, e, scope} -> [s, e, scope] end)
        else
          []
        end
      end,

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
      # the layout round-trips as one opaque value: Scheme stores it in a
      # buffer-local and hands it back; only Elixir reads its insides.
      # The tree travels as the same tuple spec the desktop file uses,
      # which is what restore_tree accepts.
      "window-tree" => fn [] ->
        v = Editor.desktop_view()
        %{tree: tree_spec(v.tree), active: v.active_buffer}
      end,
      "window-tree-set!" => fn [%{tree: tree, active: active}]
                               when elem(tree, 0) in [:leaf, :split] ->
        Editor.restore_tree(tree, active)
        :void
      end,
      # A saved layout names buffers, and a name can outlive its buffer.
      # Scheme decides what to do about that — visit the file, drop the
      # window — so it must be able to read the names back out.
      "window-tree-buffers" => fn [%{tree: tree}] -> tree_buffers(tree) end,
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
        if Aimax.Core.Frame.buffer_context() do
          unless Buffer.exists?(name), do: Core.create_buffer(name)
          Aimax.Core.Frame.put_buffer(name)
        else
          # A forgotten name gets a fresh buffer here too — C-x b creates.
          # A dormant name goes to set_window_buffer, which wakes it.
          unless Buffer.exists?(name) or Aimax.Core.BufferStore.known?(name),
            do: Core.create_buffer(name)

          Editor.set_window_buffer(name)
        end

        name
      end,
      # editor.scm wraps this raw primitive so a dormant buffer's mode setup
      # completes in the current interpreter before switch-to-buffer! returns.
      "window-switch-buffer!" => fn [name] ->
        previous = Process.get(:aimax_inline_runtime_restore)
        Process.put(:aimax_inline_runtime_restore, true)

        try do
          if Aimax.Core.Frame.buffer_context() do
            unless Buffer.exists?(name), do: Core.create_buffer(name)
            Aimax.Core.Frame.put_buffer(name)
          else
            # A forgotten name gets a fresh buffer here too — C-x b creates.
            # A dormant name goes to set_window_buffer, which wakes it.
            unless Buffer.exists?(name) or Aimax.Core.BufferStore.known?(name),
              do: Core.create_buffer(name)

            Editor.set_window_buffer(name)
          end
        after
          if previous,
            do: Process.put(:aimax_inline_runtime_restore, previous),
            else: Process.delete(:aimax_inline_runtime_restore)
        end

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
      # (list 'complete f) (list 'cancel f) (list 'collect f) (list 'initial "text")
      # (list 'match-hint #t) — the last one widens the filter to the
      # annotation, so a prompt matches what a candidate MEANS. #t means
      # the first field; an integer N means the first N fields.
      "minibuffer-read*" => fn [prompt, candidates, handlers] ->
        map =
          Map.new(handlers, fn [k, v] ->
            case plain(k) do
              "initial" -> {:input, v}
              # A dynamic provider has already filtered/ranked its results.
              "filter" -> {:filter, v}
              "match-hint" -> {:match_hint, v}
              # A prompt can reuse a domain list when its filtered result is
              # collected. Scheme decides the target and receives the rows.
              "collect" -> {:on_collect, v}
              # "palette" renders the prompt as a centered panel
              "style" -> {:style, v}
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
      "transient-show!" => fn
        [false] ->
          Editor.set_transient(nil)
          :void

        [[title, groups]] ->
          menu = %{
            title: title,
            groups:
              Enum.map(groups, fn [heading, rows] ->
                %{
                  title: heading,
                  items:
                    Enum.map(rows, fn [key, description, value, kind, behavior, selected] ->
                      %{
                        key: key,
                        description: description,
                        value: value,
                        kind: plain(kind),
                        behavior: plain(behavior),
                        selected: selected
                      }
                    end)
                }
              end)
          }

          Editor.set_transient(menu)
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
      # what a key sequence means here, without pressing it
      "key-binding" => fn [seq] ->
        case Editor.lookup_key(key_seq(seq)) do
          {:command, name} -> name
          :prefix -> {:sym, "prefix"}
          _ -> false
        end
      end,
      # describe-key arms this, then reads the sequence back with (last-keys)
      "capture-key!" => fn [command] ->
        Editor.set_key_capture(command)
        :void
      end,
      # a mode's own stylesheet, rendered into the page beside the face
      # variables. Modes are trusted code — they can eval anything — so the
      # CSS ships raw.
      "define-style!" => fn [name, css] ->
        Editor.set_style(plain(name), css)
        :void
      end,
      "last-command" => fn [] -> Editor.last_command() end,
      "last-keys" => fn [] -> Editor.last_keys() end,
      "current-prefix-arg" => fn [] -> Editor.prefix_arg() || false end,
      "set-prefix-arg!" => fn [arg] ->
        Editor.set_prefix_arg(arg)
        :void
      end,
      "window-rows" => fn [] -> Editor.window_rows() end,
      # the client measures its own font and reports it; a window nobody
      # measured is worth the default
      "buffer-cols" => fn [name] -> Editor.buffer_cols(name) end,
      "window-cols" => fn
        [] -> Editor.window_cols()
        [win] when is_integer(win) -> Editor.window_cols(win)
        _ -> Editor.window_cols()
      end,
      "frame-cols" => fn [] -> Editor.frame_cols() end,
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
      # show a buffer in a window without MRU bookkeeping — candidate
      # preview must not reorder the buffer ring. The optional WIN is the
      # modal switcher's home window; default is the active window.
      "window-preview-buffer!" => fn
        [name] -> Editor.preview_buffer(name) == :ok
        [name, win] -> Editor.preview_buffer(name, nil, win) == :ok
      end,
      # the way back to dormancy: preview wakes candidates, the prompt's
      # close puts the ones nobody picked back to sleep
      "buffer-sleep!" => fn [name] ->
        Aimax.Core.sleep_buffer(name) == :ok
      end,
      "minibuffer-set-candidates!" => fn [candidates] ->
        Editor.minibuffer_set_candidates(candidates)
        :void
      end,
      "set-frame-group-label!" => fn
        [label] ->
          Editor.set_frame_group_label(if(is_binary(label), do: label, else: nil))
          :void

        [label, fid] ->
          Editor.set_frame_group_label(
            if(is_binary(label), do: label, else: nil),
            if(is_binary(fid), do: fid, else: nil)
          )

          :void
      end,

      # filesystem (dired's hands)
      "delete-file!" => fn [p] ->
        path = Path.expand(p)

        result =
          case File.lstat(path) do
            {:ok, %{type: :directory}} -> File.rmdir(path)
            {:ok, _} -> File.rm(path)
            {:error, reason} -> {:error, reason}
          end

        case result do
          :ok ->
            true

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error, message: "delete failed: #{reason} (#{path})"
        end
      end,
      "trash-file!" => fn [p] ->
        path = Path.expand(p)
        trash = user_trash_dir()
        :ok = File.mkdir_p(trash)
        target = unused_path(Path.join(trash, Path.basename(path)))

        case File.rename(path, target) do
          :ok ->
            target

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message: "trash failed: #{reason} (#{path} -> #{target})"
        end
      end,
      "copy-file!" => fn [source, destination] ->
        source = Path.expand(source)
        destination = Path.expand(destination)

        cond do
          path_present?(destination) ->
            raise Aimax.Scheme.Eval.Error,
              message: "copy failed: destination exists (#{destination})"

          true ->
            :ok = File.mkdir_p(Path.dirname(destination))

            case File.cp_r(source, destination) do
              {:ok, _paths} ->
                destination

              {:error, reason, failed} ->
                raise Aimax.Scheme.Eval.Error,
                  message: "copy failed: #{reason} (#{failed})"
            end
        end
      end,
      "set-file-mode!" => fn [p, mode] ->
        path = Path.expand(p)

        with {value, ""} <- Integer.parse(to_string(mode), 8),
             :ok <- File.chmod(path, value) do
          true
        else
          :error ->
            raise Aimax.Scheme.Eval.Error, message: "invalid octal mode: #{mode}"

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message: "chmod failed: #{reason} (#{path})"

          {_value, _rest} ->
            raise Aimax.Scheme.Eval.Error, message: "invalid octal mode: #{mode}"
        end
      end,
      "touch-file!" => fn [p] ->
        path = Path.expand(p)
        :ok = File.mkdir_p(Path.dirname(path))

        case File.touch(path) do
          :ok ->
            true

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message: "touch failed: #{reason} (#{path})"
        end
      end,
      "make-symlink!" => fn [target, link] ->
        link = Path.expand(link)

        if path_present?(link) do
          raise Aimax.Scheme.Eval.Error,
            message: "link failed: destination exists (#{link})"
        else
          :ok = File.mkdir_p(Path.dirname(link))

          case File.ln_s(target, link) do
            :ok ->
              link

            {:error, reason} ->
              raise Aimax.Scheme.Eval.Error,
                message: "link failed: #{reason} (#{link})"
          end
        end
      end,
      # the buffer keeps its process, so nothing in it moves. A name that is
      # taken (live or in history) answers false: the caller picks another.
      "buffer-rename!" => fn [old, new] ->
        case Aimax.Core.rename_buffer(old, new) do
          {:ok, name} -> name
          {:error, _reason} -> false
        end
      end,
      "rename-file!" => fn [source, destination] ->
        case Aimax.Core.rename_file(source, destination) do
          {:ok, path} ->
            path

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error,
              message:
                "rename failed: #{reason} (#{Path.expand(source)} -> #{Path.expand(destination)})"
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
            {:sym, "file-a"},
            f.file_a || false,
            {:sym, "file-b"},
            f.file_b || false,
            {:sym, "binary?"},
            f.binary?,
            {:sym, "hunks"},
            for h <- f.hunks do
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
                for({tag, t} <- h.lines, do: [{:sym, Atom.to_string(tag)}, t])
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

        git_dispatch(
          rest,
          fn -> Git.status(dir, path) end,
          &Enum.map(&1, fn e -> status_plist(e) end)
        )
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

        git_dispatch(
          rest,
          fn -> Git.log(dir, n, path) end,
          &Enum.map(&1, fn c -> log_plist(c) end)
        )
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

    s =
      common_suffix_len(
        binary_part(old, p, byte_size(old) - p),
        binary_part(new, p, byte_size(new) - p)
      )

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

  defp git_dispatch([callback | _], work, shape),
    do: async_dispatch(callback, fn -> git_value(work.(), shape) end)

  # run WORK in a Task and hand its value to CALLBACK through the Session —
  # the single writer of the interpreter store. The closure stays rooted in
  # @escaped until the callback fires, which protects it from the GC.
  defp async_dispatch(callback, work) do
    key = {:async_call, make_ref()}
    rooted? = root_closure(key, callback)

    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
      value = work.()

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

  defp json_to_scheme_value(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
    |> Aimax.Core.LLM.json_to_scheme()
  end

  defp plain({:sym, s}), do: s
  defp plain(v), do: v

  # the desktop's tuple spec for a window tree — what restore_tree accepts
  defp tree_buffers({:leaf, b, _, _, _, _}), do: [b]
  defp tree_buffers({:split, _, _, a, b}), do: tree_buffers(a) ++ tree_buffers(b)
  defp tree_buffers(_), do: []

  defp tree_spec(%{type: :leaf, buffer: b} = leaf) do
    {:leaf, b, Map.get(leaf, :top, 0), Map.get(leaf, :point, 0), Map.get(leaf, :manual, false),
     Map.get(leaf, :ctop, 0)}
  end

  defp tree_spec(%{type: :split, dir: dir, children: [a, b]} = s),
    do: {:split, dir, Map.get(s, :ratio, 0.5), tree_spec(a), tree_spec(b)}

  # (fold-get BUF 'all) reads the union, the same word overlay-clear! uses
  defp fold_tag(tag), do: if(plain(tag) == "all", do: :all, else: plain(tag))

  # A key sequence is a list of keys. Scheme writes one the way a person
  # says it — "C-x b" — and the keymaps hold ["C-x", "b"]. Take either.
  # A bare string reaching the keymap walk raises inside the Editor call,
  # and an Editor that dies loses every buffer's local keymap.
  defp key_seq(seq) when is_list(seq), do: Enum.map(seq, &plain/1)
  defp key_seq(seq) when is_binary(seq), do: String.split(seq, " ", trim: true)
  defp key_seq(seq), do: [plain(seq)]

  # System.cmd has no time limit, so a hung command would hold the caller —
  # and in the inline form the caller is the Session — forever. Run through
  # a port, kill the OS process at the limit, and return what it wrote.
  defp shell_to_string(cmd, dir, limit \\ nil) do
    limit = limit || shell_inline_limit()

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", cmd],
        cd: dir
      ])

    deadline = System.monotonic_time(:millisecond) + limit
    t0 = System.monotonic_time(:millisecond)
    out = collect_port(port, deadline, [])
    report_slow_shell(cmd, dir, System.monotonic_time(:millisecond) - t0)
    out
  rescue
    _ -> ""
  end

  # The inline form holds its lane for as long as the command runs, so a
  # slow command is a frozen editor. The lane log names the job "eval" and
  # stops there; without the command text, a slow shell is invisible. Name
  # it here, at the same threshold the lane uses.
  @slow_shell_ms 250

  defp report_slow_shell(cmd, dir, ms) when ms > @slow_shell_ms do
    require Logger
    Logger.warning("shell: #{ms}ms in #{dir}: #{String.slice(cmd, 0, 160)}")
  end

  defp report_slow_shell(_cmd, _dir, _ms), do: :ok

  defp collect_port(port, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, chunk}} ->
        collect_port(port, deadline, [acc | chunk])

      {^port, {:exit_status, _}} ->
        IO.iodata_to_binary(acc)
    after
      max(left, 0) ->
        kill_port(port)
        IO.iodata_to_binary(acc)
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)])
      _ -> :ok
    end

    Port.close(port)
    flush_port(port)
  catch
    _, _ -> flush_port(port)
  end

  # a port message left in the mailbox would reach handle_info and crash
  # the Session — drain every message the closed port already sent
  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp shell_inline_limit, do: Application.get_env(:aimax_core, :shell_timeout_ms, 15_000)

  defp shell_async_limit,
    do: Application.get_env(:aimax_core, :shell_async_timeout_ms, 600_000)

  defp directory_entry(dir, base) do
    path = Path.join(dir, base)

    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        name = if stat.type == :directory, do: base <> "/", else: base

        [
          {:sym, "name"},
          name,
          {:sym, "type"},
          Atom.to_string(stat.type),
          {:sym, "bytes"},
          stat.size,
          {:sym, "mtime"},
          stat.mtime,
          {:sym, "size"},
          format_size(stat.size),
          {:sym, "date"},
          format_mtime(stat.mtime),
          {:sym, "perms"},
          format_mode(stat)
        ]

      {:error, reason} ->
        [
          {:sym, "name"},
          base,
          {:sym, "type"},
          "missing",
          {:sym, "bytes"},
          0,
          {:sym, "mtime"},
          0,
          {:sym, "size"},
          "?",
          {:sym, "date"},
          "?",
          {:sym, "perms"},
          "??????????",
          {:sym, "error"},
          file_error(reason, path)
        ]
    end
  end

  defp file_error(reason, path) do
    detail = reason |> :file.format_error() |> List.to_string()
    "#{detail}: #{path}"
  end

  defp path_present?(path) do
    case File.lstat(path) do
      {:ok, _} -> true
      {:error, :enoent} -> false
      {:error, _} -> true
    end
  end

  defp user_trash_dir do
    case Application.get_env(:aimax_core, :trash_dir) do
      nil ->
        home = System.user_home!()

        case :os.type() do
          {:unix, :darwin} ->
            Path.join(home, ".Trash")

          _ ->
            Path.join([
              System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share"),
              "Trash",
              "files"
            ])
        end

      dir ->
        Path.expand(dir)
    end
  end

  defp unused_path(path, suffix \\ 0) do
    candidate = if suffix == 0, do: path, else: path <> ".#{suffix}"
    if path_present?(candidate), do: unused_path(path, suffix + 1), else: candidate
  end

  defp format_mode(stat) do
    type =
      case stat.type do
        :directory -> "d"
        :symlink -> "l"
        :regular -> "-"
        :device -> "b"
        _ -> "?"
      end

    bits =
      [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
      |> Enum.zip(~w(r w x r w x r w x))
      |> Enum.map_join(fn {bit, ch} ->
        if Bitwise.band(stat.mode, bit) != 0, do: ch, else: "-"
      end)

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
