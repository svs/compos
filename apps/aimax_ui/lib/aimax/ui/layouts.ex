defmodule Aimax.Ui.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={:persistent_term.get(:aimax_boot_id, "dev")} />
        <title>ai-max.el</title>
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
        <style>
          /* default palette = the Modern Emacs design's "paper" tokens;
             themes override via CSS custom properties from Scheme */
          :root {
            --font-mono: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
            --font-sans: 'IBM Plex Sans', system-ui, sans-serif;
            --font-serif: Spectral, Georgia, serif;
          }
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { height: 100%; }
          body {
            background: var(--default-bg, #e6e0d2);
            color: var(--default-fg, #1b1a17);
            font-family: var(--font-sans);
            font-size: 13px;
            overflow: hidden;
            -webkit-font-smoothing: antialiased;
          }
          .editor-root { display: flex; flex-direction: column; height: 100dvh; overflow: hidden; }
          /* window chrome is themable: a 'chrome face maps to these vars
             (gap, radius, border, shadow, anim) — zero values reproduce the
             flat flush look */
          /* position: relative so a floating popup measures itself
             against the whole frame. Against its own split instead, a
             popup opened from a window in the middle of the layout would
             float in the middle of the layout — the frame edge is the
             only anchor that puts it in the same place every time. */
          .windows {
            flex: 1; display: flex; position: relative; min-height: 0;
            background: var(--default-bg, #d5cdb9);
            padding: var(--chrome-gap, 0);
          }
          .windows > * { flex: 1; min-width: 0; min-height: 0; }
          .split { flex: 1; display: flex; min-width: 0; min-height: 0; gap: var(--chrome-gap, 0); }
          .split.h { flex-direction: row; }
          .split.v { flex-direction: column; }
          .split-child {
            display: flex; min-width: 0; min-height: 0;
            transition: flex-grow var(--chrome-anim, 140ms) ease-out;
          }
          .split-child > * { flex: 1; min-width: 0; min-height: 0; }
          /* A popup floats, and ONLY visibly: it stays an ordinary window
             in the tree, so every window command still reaches it. Taking
             its split out of the flow is what makes it float — the window
             it covers keeps its full height underneath, instead of being
             squeezed into what is left. `C-M-`` drops the class and the
             popup settles back into the layout. */
          /* the popup's split keeps no space in the flow... */
          .split-child:has(> .window.popup) {
            flex: 0 0 0 !important; overflow: visible; transition: none;
          }
          /* ...its sibling takes the whole split, or the popup would
             float over a strip of nothing. The daemon writes each child's
             share inline, and inline styles only yield to !important. */
          .split:has(> .split-child > .window.popup)
            > .split-child:not(:has(> .window.popup)) {
            flex-grow: 1 !important;
          }
          /* ...and the popup floats against the FRAME, on the side its
             display rule chose. The rule's share arrives as --popup-size
             on this element, because a custom property set on a child
             never reaches its parent. */
          .window.popup {
            position: absolute; z-index: 20;
            box-shadow: 0 0 30px rgba(0, 0, 0, 0.30);
            border: var(--chrome-border, none);
            border-radius: var(--chrome-radius, 0);
            animation: popup-rise var(--chrome-anim, 140ms) ease-out;
          }
          .window.popup-right, .window.popup-left {
            top: 0; bottom: 0;
            width: var(--popup-size, 38%); min-width: min(380px, 100%);
          }
          .window.popup-right { right: 0; }
          .window.popup-left { left: 0; }
          .window.popup-top, .window.popup-bottom {
            left: 0; right: 0; height: var(--popup-size, 38%);
          }
          .window.popup-top { top: 0; }
          .window.popup-bottom { bottom: 0; }
          @keyframes popup-rise { from { opacity: 0; } to { opacity: 1; } }
          @keyframes win-in { from { opacity: 0; transform: scale(0.985); } to { opacity: 1; transform: none; } }
          .window {
            display: flex; flex-direction: column;
            background: var(--window-inactive-bg, #f4f0e6);
            border: var(--chrome-border, none);
            border-radius: var(--chrome-radius, 0);
            box-shadow: var(--chrome-shadow, inset -1px -1px 0 0 var(--border, #d5cdb9));
            overflow: hidden;
            min-width: 0; min-height: 0;
            animation: win-in var(--chrome-anim, 140ms) ease-out;
          }
          .window.active { background: var(--window-bg, #fdfcf8); }
          .buf {
            flex: 1;
            overflow: hidden; /* the server owns scrolling (viewport windowing) */
            padding: 12px 0 22px;
            /* default face drives the text font; themes/customize set the
               vars, buffer-face! overrides them per window via inline style */
            font-family: var(--default-family, var(--font-mono));
            font-size: var(--default-size, 13px);
            line-height: var(--default-line-height, 1.7);
            font-variant-ligatures: common-ligatures;
            letter-spacing: -0.1px;
          }
          /* buffers under the ship-all threshold get every line at once
             (editor_live.ex) — the browser owns scroll position natively
             here, no server round-trip per scroll tick */
          .buf.client-scroll { overflow: hidden auto; }
          .line { display: flex; align-items: flex-start; gap: 12px; padding: 0 16px 0 8px;
                  /* empty lines must keep their height even with .linenum hidden (no-nums, writing-mode) */
                  min-height: 1lh; }
          .window.active .line.hl-line { background: var(--hl-line-bg, #f5f1e6); }
          .linenum {
            flex: 0 0 30px; text-align: right;
            font-size: 11px; color: var(--linenum-fg, #b3ac9c);
            user-select: none;
          }
          .line-content { flex: 1; min-width: 0; white-space: pre-wrap; word-break: break-word; position: relative; }
          /* completion-at-point popup: inline card anchored under the prefix */
          .cap-pop {
            position: absolute; top: calc(100% + 3px); z-index: 15;
            display: block; min-width: 240px; max-width: 380px;
            background: var(--window-bg, #fdfcf8);
            border: 1px solid var(--default-fg, #1b1a17);
            box-shadow: 3px 3px 0 rgba(27, 26, 23, 0.18);
            animation: rise 90ms ease-out;
            white-space: nowrap;
          }
          .cap-title {
            display: flex; padding: 4px 10px 5px;
            border-bottom: 1px solid var(--border, #e2dbc9);
            font-size: 10px; letter-spacing: 0.13em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a);
          }
          .cap-row {
            display: flex; align-items: baseline; gap: 10px; padding: 3px 10px;
            border-left: 2px solid transparent; font-size: 12.5px;
          }
          .cap-row.selected {
            background: var(--select-bg, #e7e9f1);
            border-left-color: var(--accent-fg, #26356b);
          }
          .cap-row.selected .cap-label { color: var(--accent-fg, #26356b); font-weight: 600; }
          .cap-label { white-space: nowrap; }
          .cap-kind {
            margin-left: auto; font-size: 10px; letter-spacing: 0.1em;
            text-transform: uppercase; color: var(--dim-fg, #8a857a);
          }
          /* off-phase shows the glyph as normal text (Emacs GUI behavior) —
             never blink the character itself away */
          @keyframes blink { 50%, 100% { background-color: transparent; color: inherit; } }
          /* translate only — an opacity keyframe leaves panels invisible in
             backgrounded tabs where animations never run */
          @keyframes rise { from { transform: translateY(6px); } to { transform: none; } }
          .cursor {
            background: var(--cursor-bg, #26356b);
            color: var(--window-bg, #fdfcf8);
            border-radius: 1px;
          }
          .window.active .cursor { animation: blink 1.1s steps(1) infinite; }
          .window.inactive .cursor {
            background: transparent; color: inherit; animation: none;
            outline: 1px solid var(--linenum-fg, #b3ac9c);
          }
          /* OS window unfocused: hollow, no blink (Emacs frame behavior) */
          body.unfocused .cursor {
            background: transparent !important; color: inherit !important; animation: none !important;
            outline: 1px solid var(--linenum-fg, #b3ac9c);
          }
          .no-nums .linenum { display: none; }
          /* --- writing-mode: centered measure, quiet chrome ---------------- */
          .window.writing .buf { padding-top: clamp(20px, 6vh, 90px); }
          .window.writing .line {
            max-width: var(--writing-measure, 62ch);
            width: 100%; margin: 0 auto; box-sizing: border-box;
            padding: 0 16px;
          }
          .window.writing.active .line.hl-line { background: transparent; }
          .window.writing .modeline { opacity: 0.35; transition: opacity 0.2s ease; }
          .window.writing .modeline:hover { opacity: 1; }
          /* HTML preview: sandboxed (no scripts), styles/images allowed */
          .html-preview {
            flex: 1; width: 100%; border: 0;
            background: var(--window-inactive-bg, #f4f0e6);
          }
          .window.active .html-preview { background: var(--window-bg, #fdfcf8); }
          /* an app paints its own background — the editor supplies none */
          .app-preview { flex: 1; width: 100%; border: 0; background: #fff; }
          .region { background: var(--region-bg, #e7e9f1); }
          /* native drag-selection matches the editor region it becomes */
          ::selection { background: var(--region-bg, #e7e9f1); }
          /* --- block views -------------------------------------------------- */
          /* only the container: a mode composes blocks and ships its own
             stylesheet via define-style! (diff-mode.scm is the precedent) */
          .blocks-view { flex: 1; display: flex; flex-direction: column; min-height: 0; }
          .blocks-scroll { flex: 1; overflow-y: auto; padding: 10px 12px 8px; }
          /* --- agent transcript (the Modern Emacs agent-chat design) ------- */
          .agent-view { flex: 1; display: flex; flex-direction: column; min-height: 0; }
          .ag-scroll { flex: 1; overflow-y: auto; padding: 14px 18px 6px; }
          .ag-label {
            font-family: var(--font-mono); font-size: 10px; letter-spacing: 0.12em;
            color: var(--agent-meta-fg, #8a8577); flex-shrink: 0; padding-top: 3px;
          }
          .ag-user {
            display: flex; gap: 12px; margin: 10px 0;
            background: var(--agent-you-bg, rgba(99, 110, 200, 0.10));
            border-radius: 8px; padding: 8px 12px;
          }
          .ag-user-text {
            min-width: 0; font-family: var(--font-mono); font-size: 12.5px;
            white-space: pre-wrap; overflow-wrap: anywhere;
          }
          /* The measure belongs to the text, not to the block: five table
             columns do not fit in 62ch. `overflow-wrap: anywhere` made it
             worse. `anywhere` counts every character as a wrap opportunity
             when the browser computes a cell's minimum width, so the table
             algorithm shrank a "Rating" header to one letter per line.
             `break-word` still breaks a long URL, and it leaves the
             minimum width alone. */
          .ag-prose {
            font-family: var(--font-serif); font-size: 15px; line-height: 1.6;
            margin: 8px 0; overflow-wrap: break-word;
          }
          .ag-prose > * { max-width: 62ch; }
          .ag-prose > pre, .ag-prose > .ag-table { max-width: 100%; }
          .ag-prose code, .ag-prose pre {
            font-family: var(--font-mono); font-size: 12px;
            background: var(--agent-code-bg, rgba(0,0,0,0.06)); border-radius: 4px;
          }
          .ag-prose code { padding: 1px 4px; }
          .ag-prose pre { padding: 8px 10px; overflow-x: auto; margin: 6px 0; }
          .ag-prose pre code { background: none; padding: 0; }
          .ag-prose p { margin: 6px 0; }
          .ag-prose ul, .ag-prose ol { margin: 6px 0 6px 1.4em; }
          /* The wrapper scrolls, the table does not (see wrap_tables/1).
             The table takes the pane width and wraps its cells while that
             still fits. When even the longest word no longer fits, the
             table grows past the wrapper and the wrapper scrolls. */
          .ag-table { overflow-x: auto; margin: 10px 0; }
          .ag-prose table {
            width: auto; max-width: 100%; border-collapse: collapse;
            font-family: var(--font-sans); font-size: 13px;
            font-variant-numeric: tabular-nums;
          }
          .ag-prose th, .ag-prose td {
            border: 1px solid var(--agent-card-border, rgba(0,0,0,0.12));
            padding: 5px 9px; text-align: left; vertical-align: top;
          }
          /* a header names the column: it never reads better wrapped */
          .ag-prose th { font-weight: 600; white-space: nowrap; }
          .ag-tool, .ag-thought {
            margin: 8px 0; border: 1px solid var(--agent-card-border, rgba(0,0,0,0.10));
            border-radius: 8px; font-family: var(--font-mono); font-size: 12px;
          }
          .ag-tool summary, .ag-thought summary {
            display: flex; align-items: center; gap: 8px; padding: 6px 10px;
            cursor: pointer; list-style: none; user-select: none;
          }
          .ag-tool summary::-webkit-details-marker { display: none; }
          .ag-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--agent-meta-fg, #999); }
          .ag-dot.running { background: var(--warn-fg, #e0af68); animation: ag-pulse 1.2s ease-in-out infinite; }
          .ag-dot.done { background: var(--string-fg, #4a7a4a); }
          .ag-verb { color: var(--agent-tool-fg, #26356b); font-weight: 600; }
          .ag-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .ag-tstatus { color: var(--agent-meta-fg, #8a8577); font-size: 10px; }
          .ag-body {
            border-top: 1px solid var(--agent-card-border, rgba(0,0,0,0.08));
            padding: 8px 10px; overflow-x: auto; max-height: 260px; overflow-y: auto;
            white-space: pre-wrap; overflow-wrap: anywhere; color: var(--agent-thought-fg, #6a675e);
          }
          .ag-thought summary { color: var(--agent-thought-fg, #8a8577); font-size: 10.5px; }
          .ag-thought-text { padding: 6px 10px; white-space: pre-wrap; color: var(--agent-thought-fg, #8a8577); }
          .ag-plan {
            font-family: var(--font-mono); font-size: 12px; margin: 8px 0;
            padding: 8px 12px; border-left: 2px solid var(--agent-card-border, rgba(0,0,0,0.15));
            white-space: pre-wrap;
          }
          .ag-perm {
            display: flex; align-items: center; gap: 10px; margin: 10px 0;
            border: 1px solid var(--agent-permission-fg, #e0af68); border-radius: 8px;
            padding: 8px 12px; font-family: var(--font-mono); font-size: 12px;
          }
          .ag-perm-title { flex: 1; color: var(--agent-permission-fg, #a8741a); }
          .ag-btn {
            font-family: var(--font-mono); font-size: 11px; padding: 3px 12px;
            border-radius: 6px; border: 1px solid var(--agent-card-border, rgba(0,0,0,0.2));
            background: transparent; color: inherit; cursor: pointer;
          }
          /* bb's hierarchy: affirmative filled, session-scope outlined, deny
             a quiet ghost that stays visible without competing */
          .ag-btn.allow {
            background: var(--string-fg, #4a7a4a); border-color: var(--string-fg, #4a7a4a);
            color: var(--window-bg, #fdfcf8); font-weight: 600;
          }
          .ag-btn.session { border-color: var(--string-fg, #4a7a4a); color: var(--string-fg, #4a7a4a); }
          .ag-btn.deny { border-color: transparent; color: var(--error-fg, #a8342a); opacity: 0.8; }
          .ag-wait {
            font-family: var(--font-mono); font-size: 12px; margin: 8px 0;
            color: var(--agent-thought-fg, #8a8577); animation: ag-pulse 1.4s ease-in-out infinite;
          }
          .ag-meta { font-family: var(--font-mono); font-size: 11.5px; color: var(--agent-meta-fg, #8a8577); margin: 6px 0; }
          @keyframes ag-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }
          .ag-inputrow {
            display: flex; align-items: baseline; gap: 12px; margin: 6px 14px 12px;
            border: 1px solid var(--agent-card-border, rgba(0,0,0,0.14));
            border-radius: 10px; padding: 9px 14px;
            background: var(--window-bg, rgba(255,255,255,0.5));
          }
          .ag-input {
            flex: 1; min-width: 0; font-family: var(--font-mono); font-size: 12.5px;
            white-space: pre-wrap; overflow-wrap: anywhere;
          }
          .ag-queued { color: var(--agent-queued-fg, #9a958a); }
          .ag-hint { font-family: var(--font-mono); font-size: 10px; color: var(--agent-meta-fg, #8a8577); flex-shrink: 0; }
          .ml-extra {
            font-family: var(--font-mono); font-size: 11px; padding: 0 8px;
            color: var(--agent-permission-fg, #a8741a); font-weight: 600;
          }
          /* font-lock scopes (tree-sitter) — themeable via --ts-<scope>-fg */
          .ts-keyword { color: var(--ts-keyword-fg, #26356b); font-weight: 600; }
          .ts-function { color: var(--ts-function-fg, #1b1a17); font-weight: 500; }
          .ts-string { color: var(--ts-string-fg, #2e6b45); }
          .ts-comment { color: var(--ts-comment-fg, #8a857a); font-style: italic; }
          .ts-number { color: var(--ts-number-fg, #7a5a1a); }
          .ts-constant { color: var(--ts-constant-fg, #7a5a1a); }
          .ts-type { color: var(--ts-type-fg, #7a5a1a); font-weight: 500; }
          .ts-module { color: var(--ts-module-fg, #7a5a1a); font-weight: 500; }
          .ts-variable { color: var(--ts-variable-fg, inherit); }
          .ts-property { color: var(--ts-property-fg, #57534a); }
          .ts-attribute { color: var(--ts-attribute-fg, #7a5a1a); }
          .ts-tag { color: var(--ts-tag-fg, #26356b); font-weight: 600; }
          .ts-operator { color: var(--ts-operator-fg, #a09a8b); }
          .ts-punctuation { color: var(--ts-punctuation-fg, #a09a8b); }
          .ts-escape { color: var(--ts-escape-fg, #7a5a1a); }
          .ts-embedded { color: inherit; }
          .modeline {
            display: flex; align-items: center; gap: 8px;
            height: 26px; padding: 0 10px;
            flex-shrink: 0;
            background: var(--modeline-bg, #eae5da);
            color: var(--modeline-fg, #57534a);
            border-top: 1px solid var(--border, #cbc4b1);
            font-size: 11.5px;
          }
          .window.active .modeline {
            background: var(--modeline-active-bg, #e7e9f1);
            color: var(--modeline-active-fg, #1b1a17);
            border-top: 2px solid var(--accent-fg, #26356b);
          }
          .ml-dot {
            width: 6px; height: 6px; border-radius: 50%;
            background: var(--linenum-fg, #c3bcac); flex: 0 0 auto;
          }
          .ml-dot.modified { background: var(--warn-fg, #7a5a1a); }
          .modeline .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .ml-pos { font-family: var(--font-mono); font-size: 10.5px; opacity: 0.75; }
          .ml-mode { font-family: var(--font-mono); font-size: 10.5px; opacity: 0.6; white-space: nowrap; }
          .ml-group {
            font-family: var(--font-mono); font-size: 10.5px;
            color: var(--accent-fg, #26356b); opacity: 0.85;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
            max-width: 16ch; flex: 0 1 auto;
          }
          .echo-bar {
            display: flex; align-items: baseline; gap: 14px;
            min-height: 30px; padding: 7px 14px 8px;
            flex-shrink: 0;
            background: var(--window-bg, #fdfcf8);
            border-top: 1px solid var(--border, #cbc4b1);
            font-family: var(--font-mono); font-size: 12.5px;
          }
          .echo { color: var(--dim-fg, #57534a); white-space: pre; }
          .echo-hint {
            color: var(--dim-fg, #8a857a); opacity: 0.8; font-size: 11px;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .mb-spacer { flex: 1; }
          .prompt { color: var(--accent-fg, #26356b); font-weight: 600; white-space: pre; flex-shrink: 0; }
          .mb-input { white-space: pre; flex-shrink: 0; font-family: var(--font-mono); }
          .mb-input .cursor { background: var(--cursor-bg, #26356b); }
          /* vertico-style minibuffer: transient, keyboard-only */
          .mb-panel {
            flex-shrink: 0;
            background: var(--window-bg, #fdfcf8);
            border-top: 2px solid var(--accent-fg, #26356b);
            animation: rise 110ms ease-out;
          }
          .mb-label-row {
            padding: 6px 14px 5px;
            font-family: var(--font-mono); font-size: 10px;
            letter-spacing: 0.13em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a);
          }
          /* the names column expands to the longest name in the whole set
             (--mb-label-w, from the core) — marginalia sits immediately
             after it and the column never reflows while narrowing */
          .mb-cands {
            max-height: 40dvh; overflow-y: auto;
            display: grid;
            /* The column used to BE --mb-label-w. A row is a subgrid item
               with 14px of side padding, and that padding comes out of the
               tracks — so the column ran narrower than the width the core
               asked for, and the longest name ran into its annotation.
               max-content sizes the column to the labels themselves,
               padding included, and the floor below keeps the column from
               reflowing as narrowing shortens the longest visible name. */
            grid-template-columns: max-content minmax(0, auto);
            justify-content: start;
          }
          .mb-cand {
            display: grid; grid-template-columns: subgrid; grid-column: 1 / -1;
            align-items: baseline; column-gap: 12px;
            padding: 3px 14px;
            border-left: 2px solid transparent;
            font-family: var(--font-mono); font-size: 12.5px;
          }
          .mb-cand.selected {
            background: var(--select-bg, #e7e9f1);
            border-left-color: var(--accent-fg, #26356b);
          }
          .mb-cand.selected .mb-label { color: var(--accent-fg, #26356b); font-weight: 600; }
          /* the floor: the widest label in the WHOLE set, from the core.
             The ceiling matches the cap the core applies to that width —
             one very long name must not push the annotations off the
             panel, so past it a name truncates instead. */
          .mb-label {
            white-space: nowrap;
            min-width: var(--mb-label-w, 0); max-width: 64ch;
            overflow: hidden; text-overflow: ellipsis;
          }
          .mb-hint {
            color: var(--dim-fg, #8a857a); font-size: 11px;
            /* an annotation is COLUMNS, padded with spaces by the
               annotator — nowrap collapses a run of spaces to one and the
               columns fell apart. pre keeps them and still does not wrap. */
            white-space: pre; overflow: hidden; text-overflow: ellipsis;
          }
          .mb-input-row {
            display: flex; align-items: baseline;
            padding: 7px 14px 8px;
            border-top: 1px solid var(--border, #e2dbc9);
            background: var(--default-bg, #efeadf);
          }
          /* the prompt line holds the selection: the input names a directory */
          .mb-input-row.selected { background: var(--select-bg, #e7e9f1); }
          .mb-count { font-family: var(--font-mono); color: var(--dim-fg, #8a857a); font-size: 10.5px; }
          /* which-key: transient prefix panel */
          .which-key {
            flex-shrink: 0;
            background: var(--window-bg, #fdfcf8);
            border-top: 2px solid var(--accent-fg, #26356b);
            padding: 10px 14px 12px;
            animation: rise 120ms ease-out;
          }
          .wk-title {
            font-family: var(--font-mono); font-size: 10px;
            letter-spacing: 0.14em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a); padding-bottom: 8px;
          }
          .wk-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 4px 22px; }
          .wk-item { display: flex; align-items: baseline; gap: 8px; font-family: var(--font-mono); font-size: 12px; }
          .wk-key { color: var(--accent-fg, #26356b); font-weight: 600; min-width: 34px; }
          .wk-arrow { color: var(--linenum-fg, #b3ac9c); }
          .wk-cmd { color: var(--dim-fg, #57534a); }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/phx/phoenix.min.js"></script>
        <script src="/lv/phoenix_live_view.min.js"></script>
        <script>
          const NAMED = {
            "Enter": "RET", "Backspace": "DEL", "Tab": "TAB", " ": "SPC",
            "Escape": "ESC", "ArrowLeft": "<left>", "ArrowRight": "<right>",
            "ArrowUp": "<up>", "ArrowDown": "<down>", "Home": "<home>", "End": "<end>",
            "PageUp": "<prior>", "PageDown": "<next>"
          };
          // macOS Option-key produces transformed chars ("≈"); recover the
          // intended key from e.code for M- bindings.
          const CODE_CHARS = { "Comma": [",", "<"], "Period": [".", ">"], "Semicolon": [";", ":"],
            "Slash": ["/", "?"], "Minus": ["-", "_"], "Equal": ["=", "+"], "Backslash": ["\\", "|"],
            "Quote": ["'", "\""], "BracketLeft": ["[", "{"], "BracketRight": ["]", "}"],
            "Backquote": ["`", "~"] };

          function baseKey(e) {
            if (e.altKey) {
              if (e.code.startsWith("Key")) return e.code.slice(3).toLowerCase();
              if (e.code.startsWith("Digit")) return e.code.slice(5);
              if (CODE_CHARS[e.code]) return CODE_CHARS[e.code][e.shiftKey ? 1 : 0];
            }
            if (NAMED[e.key]) return NAMED[e.key];
            if (e.key.length === 1) return e.key;
            return null;
          }

          // cmd combos belong to the browser (cmd-c/v/q, and cmd-v's native
          // paste event) — except the arrows, claimed for window motion
          const CMD_KEYS = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];

          function keySpec(e) {
            if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return null;
            if (e.metaKey && !CMD_KEYS.includes(e.key)) return null;
            const base = baseKey(e);
            if (base === null) return null;
            let spec = base;
            // S- only for named keys (TAB, arrows, RET...): printable chars
            // already encode shift in the character itself, Emacs-style
            if (e.shiftKey && base.length > 1) spec = "S-" + spec;
            if (e.altKey) spec = "M-" + spec;
            if (e.ctrlKey) spec = "C-" + spec;
            if (e.metaKey) spec = "s-" + spec; // s- = super = Cmd
            return spec;
          }

          const PAGE_BOOT = document.querySelector("meta[name='boot-id']").getAttribute("content");
          const Hooks = {
            // A preview draws inside an iframe, so the keyboard cannot
            // reach it the way it reaches a line window: the daemon moves
            // the window's pixel offset and this hook applies it. The
            // wheel still works on its own, so report where the reader
            // left the page — the offset survives a refresh and a restart
            // the same way a line window's does.
            PreviewScroll: {
              mounted() {
                // seed lastPt so a restored offset wins on mount: the
                // cursor pulls the view only when point MOVES after that
                this.lastPt = this.el.dataset.pt;
                this.onLoad = () => this.attach();
                this.el.addEventListener("load", this.onLoad);
                this.attach();
              },
              updated() { this.apply(); },
              destroyed() {
                this.el.removeEventListener("load", this.onLoad);
                clearTimeout(this.timer);
              },
              // same-origin, but the document is absent until it loads
              doc() {
                try { return this.el.contentDocument; } catch (e) { return null; }
              },
              scroller() {
                const d = this.doc();
                return d && d.scrollingElement;
              },
              apply() {
                const s = this.scroller();
                if (!s) return;
                const want = parseInt(this.el.dataset.ctop || "0", 10);
                // a 2px slack stops the applied value from fighting the
                // wheel report that follows it
                if (Math.abs(s.scrollTop - want) > 2) s.scrollTop = want;
                this.follow();
              },
              // an edit in a markdown preview lands at point, and the
              // rendered page shows point as the .pt span. When point
              // moved, bring the span into view; a wheel scroll or a
              // restored offset stays where the reader put it.
              follow() {
                const pt = this.el.dataset.pt;
                if (pt === undefined || pt === this.lastPt) return;
                this.lastPt = pt;
                const d = this.doc();
                const el = d && d.querySelector(".pt");
                if (el) el.scrollIntoView({ block: "nearest" });
              },
              attach() {
                const d = this.doc();
                if (!d || this.wired === d) return;
                this.wired = d;
                this.apply();
                d.addEventListener("scroll", () => {
                  clearTimeout(this.timer);
                  this.timer = setTimeout(() => {
                    const s = this.scroller();
                    if (!s) return;
                    this.pushEvent("cscroll", {
                      win: parseInt(this.el.dataset.win, 10),
                      top: Math.round(s.scrollTop)
                    });
                  }, 250);
                }, true);
              }
            },
            // An app is in another origin, so contentDocument is closed to
            // us. Everything travels as messages, and the app's half of the
            // wire is the bridge script the app server injects.
            AppFrame: {
              mounted() {
                this.onMsg = (e) => {
                  if (e.source !== this.el.contentWindow) return;
                  const m = e.data;
                  if (!m || !m.aimax) return;
                  if (m.aimax === "scroll") {
                    clearTimeout(this.timer);
                    this.timer = setTimeout(() => {
                      this.pushEvent("cscroll", {
                        win: parseInt(this.el.dataset.win, 10),
                        top: Math.round(m.top)
                      });
                    }, 250);
                  } else if (m.aimax === "release") {
                    // C-g inside the app gives the keyboard back to the editor
                    const sink = document.getElementById("kb-sink");
                    if (sink) sink.focus();
                  }
                };
                window.addEventListener("message", this.onMsg);
                this.onLoad = () => this.apply();
                this.el.addEventListener("load", this.onLoad);
              },
              updated() { this.apply(); },
              destroyed() {
                window.removeEventListener("message", this.onMsg);
                this.el.removeEventListener("load", this.onLoad);
                clearTimeout(this.timer);
              },
              apply() {
                const top = parseInt(this.el.dataset.ctop || "0", 10);
                const w = this.el.contentWindow;
                if (w) w.postMessage({ aimax: "scroll", top: top }, "*");
              }
            },
            // transcript follows output unless the reader scrolled up.
            // The flag and position mirror into daemon state (runtime
            // locals), so a refresh keeps the reader's place and a
            // daemon restart resets to following.
            AgentScroll: {
              mounted() {
                this.scroller = this.el.querySelector(".ag-scroll");
                this.stick = this.el.dataset.stick !== "false";
                this.report = null;
                this.scroller.addEventListener("scroll", () => {
                  const s = this.scroller;
                  this.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
                  clearTimeout(this.report);
                  this.report = setTimeout(() => {
                    this.pushEvent("ag_stick", {
                      buf: this.el.dataset.buf,
                      stick: this.stick,
                      top: Math.round(s.scrollTop)
                    });
                  }, 250);
                });
                if (this.stick) this.scroller.scrollTop = this.scroller.scrollHeight;
                else this.scroller.scrollTop = parseInt(this.el.dataset.scrollTop || "0", 10);
              },
              updated() {
                if (this.stick) this.scroller.scrollTop = this.scroller.scrollHeight;
              },
              destroyed() {
                clearTimeout(this.report);
              }
            },
            // point moves in the buffer, so the mark moves in the block
            // view — and the reader has to be able to see where it went.
            // The renderer stamps data-current on marked, anchored blocks;
            // the LAST match in document order is the innermost. Only scroll
            // when it actually changed, or every unrelated re-render would
            // yank the view back.
            BlockScroll: {
              mounted() {
                this.scroller = this.el.querySelector(".blocks-scroll");
                this.last = null;
                this.follow();
              },
              updated() {
                this.follow();
              },
              follow() {
                if (!this.scroller) return;
                const marked = this.el.querySelectorAll("[data-current]");
                const cur = marked.length ? marked[marked.length - 1] : null;
                if (!cur) return;
                const key = cur.dataset.anchor || null;
                if (key !== null && key === this.last) return;
                this.last = key;
                cur.scrollIntoView({ block: "nearest" });
              }
            },
            Keys: {
              mounted() {
                // remounted against a restarted server: this page's CSS/JS is
                // stale relative to the markup — hard reload
                if (this.el.dataset.boot && this.el.dataset.boot !== PAGE_BOOT) {
                  window.location.reload();
                  return;
                }
                this.handler = (e) => {
                  // Cmd-C with no native selection: copy the editor region
                  // (with one, the browser's own copy handles it)
                  if (e.metaKey && !e.ctrlKey && !e.altKey && e.key === "c" &&
                      window.getSelection().isCollapsed) {
                    e.preventDefault();
                    this.pushEvent("copy", {});
                    return;
                  }
                  const spec = keySpec(e);
                  if (spec === null) return;
                  e.preventDefault();
                  this.pushEvent("key", { k: spec });
                };
                window.addEventListener("keydown", this.handler);

                // system clipboard: Cmd-V fires a native paste event (cmd
                // keys pass through keySpec untouched)
                this.pasteH = (e) => {
                  const text = e.clipboardData && e.clipboardData.getData("text/plain");
                  if (!text) return;
                  e.preventDefault();
                  this.pushEvent("paste", { text });
                };
                window.addEventListener("paste", this.pasteH);
                this.handleEvent("clipboard", ({ text }) => {
                  if (text) navigator.clipboard.writeText(text);
                });

                // this TAB's frame rides the payload as data-frame (S5,
                // S13): sessionStorage carries it across reloads, per tab —
                // two tabs are two frames and stop fighting over win_rows
                if (this.el.dataset.frame) {
                  sessionStorage.setItem("aimax-frame", this.el.dataset.frame);
                }

                // mouse: a click selects the window and places point; a drag
                // leaves a native selection, mirrored into mark + point.
                // Positions are (logical line, char offset) — the server maps
                // them to bytes via the rope.
                const posIn = (node, offset) => {
                  if (!node) return null;
                  const el = node.nodeType === 1 ? node : node.parentElement;
                  const lineEl = el && el.closest(".line");
                  if (!lineEl) return null;
                  const content = lineEl.querySelector(".line-content");
                  const numEl = lineEl.querySelector(".linenum");
                  if (!content || !numEl) return null;
                  let col = 0, found = false;
                  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
                  let t;
                  while ((t = walker.nextNode())) {
                    if (t === node) { col += offset; found = true; break; }
                    col += t.textContent.length;
                  }
                  if (!found && !content.contains(node)) col = 0;
                  return { line: parseInt(numEl.textContent, 10), col };
                };
                this.mouseH = (e) => {
                  if (e.button !== 0) return;
                  if (e.target.closest("button, [phx-click]")) return;
                  const winEl = e.target.closest(".window[data-win-id]");
                  if (!winEl) return;
                  const win = parseInt(winEl.dataset.winId, 10);
                  const sel = window.getSelection();
                  if (sel && !sel.isCollapsed &&
                      winEl.contains(sel.anchorNode) && winEl.contains(sel.focusNode)) {
                    const a = posIn(sel.anchorNode, sel.anchorOffset);
                    const f = posIn(sel.focusNode, sel.focusOffset);
                    if (a && f) {
                      this.pushEvent("mouse_sel", { win, al: a.line, ac: a.col, fl: f.line, fc: f.col });
                      return;
                    }
                  }
                  let pos = null;
                  if (document.caretPositionFromPoint) {
                    const cp = document.caretPositionFromPoint(e.clientX, e.clientY);
                    if (cp) pos = posIn(cp.offsetNode, cp.offset);
                  } else if (document.caretRangeFromPoint) {
                    const r = document.caretRangeFromPoint(e.clientX, e.clientY);
                    if (r) pos = posIn(r.startContainer, r.startOffset);
                  }
                  this.pushEvent("mouse", pos ? { win, line: pos.line, col: pos.col } : { win });
                };
                window.addEventListener("mouseup", this.mouseH);

                // viewport geometry: overall estimate for split math, plus
                // exact per-window rows (line height varies per buffer)
                this.lineHeight = 22;
                this.lastWinRows = "";
                this.sendViewport = () => {
                  const line = document.querySelector(".line");
                  if (line) this.lineHeight = line.getBoundingClientRect().height || 22;
                  const area = document.querySelector(".windows");
                  if (area) this.pushEvent("viewport", { rows: Math.max(5, Math.floor(area.clientHeight / this.lineHeight)) });
                  this.sendWinRows();
                };
                this.sendWinRows = () => {
                  const rows = {};
                  document.querySelectorAll(".window[data-win-id]").forEach((win) => {
                    const buf = win.querySelector(".buf");
                    if (!buf) return; // preview windows have no line grid
                    const ln = buf.querySelector(".line");
                    const h = ln ? ln.getBoundingClientRect().height : this.lineHeight;
                    if (h > 0) rows[win.dataset.winId] = Math.max(3, Math.floor(buf.clientHeight / h));
                  });
                  const key = JSON.stringify(rows);
                  if (key !== this.lastWinRows && Object.keys(rows).length > 0) {
                    this.lastWinRows = key;
                    this.pushEvent("win_rows", { rows });
                  }
                };
                requestAnimationFrame(this.sendViewport);
                this.resizeH = () => {
                  clearTimeout(this._rt);
                  this._rt = setTimeout(this.sendViewport, 150);
                };
                window.addEventListener("resize", this.resizeH);

                // wheel scrolls the server-side viewport of the hovered window
                // (falling back to the active one) — batched to one round-trip
                // per animation frame. Raw wheel events fire at native OS
                // resolution (60-100+/sec on a trackpad); sending every line
                // crossing as its own pushEvent means a full server diff/patch
                // cycle on nearly every tick of a fast scroll. Summing into one
                // flush per frame cuts round-trips without changing the line
                // math.
                //
                // Pending lines are kept PER WINDOW: one accumulator would
                // credit a scroll over window A to whichever window happened to
                // flush, which is wrong the moment a frame has more than one.
                this.wheelAcc = 0;
                this.wheelPending = new Map();
                this.wheelScheduled = false;
                this.flushWheel = () => {
                  this.wheelScheduled = false;
                  for (const [win, lines] of this.wheelPending) {
                    if (lines !== 0) {
                      this.pushEvent("scroll", win === null ? { lines } : { lines, win });
                    }
                  }
                  this.wheelPending.clear();
                };
                this.wheelH = (e) => {
                  // agent/chat transcripts (.ag-scroll), diff cards
                  // (.diff-scroll) and buffers under the ship-all threshold
                  // (.buf.client-scroll) own their scrolling natively — the
                  // server viewport only drives large line-grid buffers
                  // still using the windowed path
                  if (
                    e.target.closest &&
                    e.target.closest(".ag-scroll, .blocks-scroll, .buf.client-scroll")
                  )
                    return;
                  e.preventDefault();
                  this.wheelAcc += e.deltaY;
                  const lines = Math.trunc(this.wheelAcc / this.lineHeight);
                  if (lines !== 0) {
                    this.wheelAcc -= lines * this.lineHeight;
                    const winEl = e.target.closest && e.target.closest(".window[data-win-id]");
                    const win = winEl ? parseInt(winEl.dataset.winId, 10) : null;
                    this.wheelPending.set(win, (this.wheelPending.get(win) || 0) + lines);
                    if (!this.wheelScheduled) {
                      this.wheelScheduled = true;
                      requestAnimationFrame(this.flushWheel);
                    }
                  }
                };
                window.addEventListener("wheel", this.wheelH, { passive: false });

                // client-scrolled buffers mirror their position into the
                // daemon (S1): scroll doesn't bubble, so capture it, and
                // debounce per window. On mount, a pinned window gets its
                // saved offset back.
                this.cscrollTimers = new Map();
                this.cscrollH = (e) => {
                  const el = e.target;
                  if (!(el instanceof Element) || !el.matches(".buf.client-scroll")) return;
                  const winEl = el.closest(".window[data-win-id]");
                  if (!winEl) return;
                  const win = parseInt(winEl.dataset.winId, 10);
                  clearTimeout(this.cscrollTimers.get(win));
                  this.cscrollTimers.set(win, setTimeout(() => {
                    this.pushEvent("cscroll", { win, top: Math.round(el.scrollTop) });
                  }, 250));
                };
                window.addEventListener("scroll", this.cscrollH, true);
                document.querySelectorAll(".buf.client-scroll[data-manual='true']").forEach((el) => {
                  el.scrollTop = parseInt(el.dataset.ctop || "0", 10);
                });

                // hollow, non-blinking cursor when the OS window is unfocused
                this.focusH = () => document.body.classList.remove("unfocused");
                // the keyboard sink: one focusable element that is never a
                // preview. A click in a preview moves focus INTO its iframe,
                // and the keydown listener is on THIS window — from then on
                // every key goes to the sandboxed document instead: no
                // minibuffer, no motion, an editor that looks dead. blur()
                // on the iframe does NOT bring the focus home (the parent's
                // activeElement reads "BODY" while the browser still sends
                // the keys to the child), and neither does body.focus().
                // Focusing a real element of ours does.
                this.sink = document.createElement("div");
                this.sink.id = "kb-sink";
                this.sink.tabIndex = -1;
                this.sink.setAttribute("aria-hidden", "true");
                this.sink.style.cssText =
                  "position:fixed;left:0;top:0;width:1px;height:1px;outline:none";
                document.body.appendChild(this.sink);

                this.blurH = () => {
                  const el = document.activeElement;
                  // an app window is the one iframe that KEEPS the keyboard:
                  // its text fields and its keys are the point of it. C-g in
                  // the app posts "release" and the sink takes focus back.
                  if (el && el.classList && el.classList.contains("app-preview")) {
                    const appWin = el.closest(".window[data-win-id]");
                    if (appWin) {
                      this.pushEvent("mouse", { win: parseInt(appWin.dataset.winId, 10) });
                    }
                    return;
                  }
                  if (el && el.tagName === "IFRAME") {
                    // after the browser settles the focus, not during: a
                    // focus() inside the blur that announces the move is
                    // overwritten by the move itself
                    setTimeout(() => {
                      el.blur();
                      this.sink.focus();
                    }, 0);
                    // ...and select the window the reader clicked, the same
                    // thing a click on a line does. Events inside an iframe
                    // never reach our mouseup handler, so this is the only
                    // notice we get that the click happened.
                    const winEl = el.closest(".window[data-win-id]");
                    if (winEl) {
                      this.pushEvent("mouse", { win: parseInt(winEl.dataset.winId, 10) });
                    }
                    return;
                  }
                  document.body.classList.add("unfocused");
                };
                window.addEventListener("focus", this.focusH);
                window.addEventListener("blur", this.blurH);
                if (!document.hasFocus()) document.body.classList.add("unfocused");
              },
              updated() {
                // re-measure after every patch: splits, buffer switches and
                // per-buffer styles all change how many rows fit where
                clearTimeout(this._wrt);
                this._wrt = setTimeout(this.sendWinRows, 30);

                // client-scrolled buffers (.buf.client-scroll) ship every
                // line — the server no longer computes a windowing top to
                // keep point visible for them, so as point moves (edits,
                // cursor motion, goto-line/imenu jumps) the browser has to
                // do it instead. Only touch it when actually out of view —
                // routine typing shouldn't re-center on every keystroke —
                // but a deliberate jump to a distant line should land in
                // the middle of the window, not right at the edge.
                document.querySelectorAll(".buf.client-scroll .line.hl-line").forEach((el) => {
                  const container = el.closest(".buf.client-scroll");
                  if (!container) return;
                  // a pinned window (manual scroll, S1/S9) is the reader's:
                  // don't yank it to point. A keypress clears the pin and
                  // following resumes.
                  if (container.dataset.manual === "true") return;
                  const eb = el.getBoundingClientRect();
                  const cb = container.getBoundingClientRect();
                  if (eb.top < cb.top || eb.bottom > cb.bottom) {
                    el.scrollIntoView({ block: "center" });
                  }
                });
              },
              destroyed() {
                window.removeEventListener("keydown", this.handler);
                window.removeEventListener("resize", this.resizeH);
                window.removeEventListener("wheel", this.wheelH);
                window.removeEventListener("scroll", this.cscrollH, true);
                window.removeEventListener("focus", this.focusH);
                window.removeEventListener("blur", this.blurH);
                window.removeEventListener("paste", this.pasteH);
                window.removeEventListener("mouseup", this.mouseH);
                if (this.sink) this.sink.remove();
              }
            }
          };

          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            hooks: Hooks,
            params: () => ({
              _csrf_token: csrf,
              // per-tab frame id; one-shot migration claims the old
              // per-profile key for the first tab that connects
              frame:
                sessionStorage.getItem("aimax-frame") ||
                (() => {
                  const old = localStorage.getItem("aimax-frame");
                  if (old) {
                    localStorage.removeItem("aimax-frame");
                    sessionStorage.setItem("aimax-frame", old);
                  }
                  return old;
                })()
            })
          });
          liveSocket.connect();
          if (liveSocket.disableDebug) liveSocket.disableDebug();
        </script>
      </body>
    </html>
    """
  end
end
