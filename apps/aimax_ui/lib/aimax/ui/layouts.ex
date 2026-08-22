defmodule Aimax.Ui.Layouts do
  use Phoenix.Component

  def root(assigns) do
    assigns = assign_new(assigns, :page_title, fn -> "ai-max.el" end)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={:persistent_term.get(:aimax_boot_id, "dev")} />
        <title>{@page_title}</title>
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" type="image/png" href="/icons/aimax-192.png" />
        <link rel="apple-touch-icon" href="/icons/aimax-192.png" />
        <meta name="theme-color" content="#e6e0d2" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
        <style>
          /* default palette = the Modern Emacs design's "paper" tokens;
             themes override via CSS custom properties from Scheme */
          :root {
            /* Plex draws the text; the Nerd Font draws the mode icons, which
               live in the private-use area Plex leaves empty. Both are
               monospace, so one icon still spends one cell. */
            --font-mono: 'IBM Plex Mono', 'Symbols Nerd Font Mono',
                         'JetBrainsMonoNL Nerd Font Mono', 'JetBrainsMono Nerd Font Mono',
                         'Hack Nerd Font Mono', ui-monospace, Menlo, monospace;
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
          .workspace-bar {
            flex: 0 0 auto; display: flex; align-items: center; gap: 10px;
            min-height: 38px; padding: 7px 14px;
            border-bottom: 2px solid color-mix(in srgb, var(--error-fg, #d13b32) 72%, #111);
            background:
              linear-gradient(90deg,
                color-mix(in srgb, var(--error-fg, #d13b32) 22%, #171312),
                #171312 62%);
            color: #fff8ee; font: 600 11px/1.25 var(--font-mono);
            letter-spacing: 0.015em;
            box-shadow: 0 4px 18px color-mix(in srgb, var(--error-fg, #d13b32) 24%, transparent);
            z-index: 40;
          }
          .workspace-bar-kind, .workspace-bar-port {
            padding: 4px 8px; border-radius: 999px;
            background: var(--error-fg, #d13b32); color: white;
            font-weight: 750; letter-spacing: 0.08em;
          }
          .workspace-bar-root {
            min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            color: #f1d8c8;
          }
          .workspace-bar-help { margin-left: auto; white-space: nowrap; color: #cdbfb6; }
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
          /* THE modal floats, and ONLY visibly: it stays an ordinary
             window in the tree, so every window command still reaches
             it. Taking its split out of the flow is what makes it float
             — the window it covers keeps its full height underneath. */
          .split-child:has(> .window.popup-center) {
            flex: 0 0 0 !important; overflow: visible; transition: none;
          }
          /* Tiling only: a side popup is an ordinary split — its share
             comes from the split ratio like every window's. ONE surface
             floats: the centered modal. Its sibling takes the whole
             split, or the modal would float over a strip of nothing.
             The daemon writes each child's share inline, and inline
             styles only yield to !important. */
          .split:has(> .split-child > .window.popup-center)
            > .split-child:not(:has(> .window.popup-center)) {
            flex-grow: 1 !important;
          }
          .window.popup-center {
            position: absolute; z-index: 20;
            box-shadow: 0 0 30px rgba(0, 0, 0, 0.30);
            border: var(--chrome-border, none);
            border-radius: var(--chrome-radius, 0);
            animation: popup-rise var(--chrome-anim, 140ms) ease-out;
            top: 50%; left: 50%; transform: translate(-50%, -50%);
            width: var(--popup-size, 56%); max-width: 1100px;
            min-width: min(520px, 100%);
            height: 62%;
          }
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
          .window.workspace-pending {
            position: relative;
            box-shadow:
              inset 0 0 0 2px var(--error-fg, #d13b32),
              inset 0 0 22px color-mix(in srgb, var(--error-fg, #d13b32) 18%, transparent),
              0 0 18px color-mix(in srgb, var(--error-fg, #d13b32) 24%, transparent);
          }
          .window.workspace-pending::before {
            content: "UNMERGED WORKTREE";
            position: absolute; z-index: 18; top: 8px; right: 10px;
            padding: 4px 10px;
            border: 1px solid color-mix(in srgb, var(--error-fg, #d13b32) 72%, white);
            border-radius: 999px;
            background: var(--error-fg, #d13b32);
            color: white;
            font: 700 10px/1.2 var(--font-mono);
            letter-spacing: 0.09em;
            box-shadow: 0 3px 14px color-mix(in srgb, var(--error-fg, #d13b32) 42%, transparent);
            pointer-events: none;
          }
          .buffer-header {
            flex: 0 0 auto;
            padding: 7px 14px;
            border-bottom: 1px solid var(--border, #cbc4b1);
            background: var(--modeline-active-bg, #e7e9f1);
            color: var(--modeline-active-fg, #1b1a17);
            font: 650 11px/1.3 var(--font-mono);
            letter-spacing: 0.015em;
          }
          .buffer-footer {
            flex: 0 0 auto;
            padding: 6px 14px;
            border-top: 1px solid var(--border, #cbc4b1);
            background: var(--modeline-inactive-bg, var(--window-inactive-bg, #f4f0e6));
            color: var(--dim-fg, #6b6a66);
            font: 550 11px/1.3 var(--font-mono);
            letter-spacing: 0.015em;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .window.workspace-pending .buffer-header {
            border-bottom-color: color-mix(in srgb, var(--error-fg, #d13b32) 68%, transparent);
            background: color-mix(in srgb, var(--error-fg, #d13b32) 12%, var(--window-bg, #fdfcf8));
            color: var(--error-fg, #a8342a);
          }
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
            visibility: hidden; animation: none;
          }
          /* A cursor means keyboard focus. No focused frame, no cursor. */
          body.unfocused .cursor {
            visibility: hidden !important; animation: none !important;
          }
          .no-nums .linenum { display: none; }
          /* an img-embed seg: the picture, in the text's place */
          .line img.img-embed {
            display: inline-block; max-width: min(100%, 640px); height: auto;
            border-radius: 4px; margin: 6px 8px 6px 0; vertical-align: middle;
          }
          .line-content:has(> img.img-avatar) {
            display: inline-flex; align-items: flex-end;
          }
          .line img.img-avatar {
            width: 36px; height: 36px; flex: 0 0 36px; object-fit: cover;
            border-radius: 50%; margin: 0 8px 0 0; vertical-align: bottom;
          }
          .line-content:has(> .f-web-separator) {
            display: flex; justify-content: center;
          }
          .line .f-web-separator {
            display: block; width: 50%; height: 1px; margin: 16px 0;
            color: transparent; font-size: 0;
            background: linear-gradient(90deg, transparent, var(--dim-fg), transparent);
          }
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
          /* A link takes the theme's link face. The browser default paints
             it #0000EE and marks a visited link purple, which no theme can
             read. The underline stays, because a link says it is a link,
             but it is thin, offset from the descenders, and fainter than
             the text until the pointer is on it. */
          .ag-prose a, .ag-prose a:visited {
            color: var(--link-fg, var(--accent-fg, #7aa2f7));
            text-decoration: underline;
            text-decoration-thickness: 1px;
            text-underline-offset: 2px;
            text-decoration-color: color-mix(in srgb, currentColor 45%, transparent);
          }
          .ag-prose a:hover { text-decoration-color: currentColor; }
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
            margin: 5px 0; border: 1px solid var(--agent-card-border, rgba(0,0,0,0.10));
            border-radius: 7px; font-family: var(--font-mono); font-size: 12px;
            background: color-mix(in srgb, var(--window-bg, #fdfcf8) 96%, var(--agent-tool-fg, #26356b));
          }
          .ag-tool summary, .ag-thought summary {
            display: flex; align-items: center; gap: 7px; min-height: 32px;
            padding: 4px 9px 4px 7px; cursor: pointer; list-style: none; user-select: none;
          }
          .ag-tool summary::-webkit-details-marker { display: none; }
          .ag-tool.running summary { position: relative; overflow: hidden; }
          .ag-tool.running summary::after {
            content: ""; position: absolute; inset: 0; pointer-events: none;
            background: linear-gradient(
              105deg,
              transparent 20%,
              color-mix(in srgb, var(--agent-tool-fg, #26356b) 13%, transparent) 46%,
              transparent 72%
            );
            transform: translateX(-120%); animation: ag-shimmer 1.8s ease-in-out infinite;
          }
          .ag-tool[open] {
            margin: 8px 0;
            border-color: color-mix(in srgb, var(--agent-tool-fg, #26356b) 35%, transparent);
          }
          .ag-chevron {
            width: 11px; flex: 0 0 11px; color: var(--agent-meta-fg, #8a8577);
            font-family: var(--font-sans); font-size: 17px; line-height: 1;
            transform: rotate(0deg); transition: transform 100ms ease;
          }
          .ag-tool[open] .ag-chevron { transform: rotate(90deg); }
          .ag-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--agent-meta-fg, #999); }
          .ag-dot.running { background: var(--warn-fg, #e0af68); animation: ag-pulse 1.2s ease-in-out infinite; }
          .ag-dot.done { background: var(--string-fg, #4a7a4a); }
          .ag-dot.failed { background: var(--error-fg, #a8342a); }
          .ag-kind {
            padding: 1px 5px; border-radius: 4px; color: var(--agent-tool-fg, #26356b);
            background: color-mix(in srgb, var(--agent-tool-fg, #26356b) 10%, transparent);
            font-family: var(--font-sans); font-size: 9px; font-weight: 700;
            letter-spacing: 0.05em; text-transform: uppercase;
          }
          .ag-summary-copy {
            display: flex; flex: 1; min-width: 0; flex-direction: column;
            justify-content: center; gap: 1px;
          }
          .ag-title {
            display: block; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--window-fg, inherit); font-size: 11.5px;
          }
          /* the argument is the interesting part: the tool name steps back,
             the argument carries the accent. A card with no argument keeps
             its name in the normal color. */
          .ag-tool-name { color: var(--agent-meta-fg, #8a8577); }
          .ag-title .ag-tool-name:only-child { color: var(--window-fg, inherit); }
          .ag-arg { margin-left: 7px; color: var(--agent-tool-fg, #26356b); font-weight: 600; }
          .ag-preview {
            display: block; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--agent-meta-fg, #8a8577);
            font-family: var(--font-mono); font-size: 10px; line-height: 1.25;
          }
          .ag-preview::before { content: "↳ "; color: var(--agent-tool-fg, #26356b); }
          .ag-tstatus {
            color: var(--agent-meta-fg, #8a8577); font-family: var(--font-sans);
            font-size: 9.5px; letter-spacing: 0.02em;
          }
          .ag-tstatus.done::before { content: "✓ "; color: var(--string-fg, #4a7a4a); }
          .ag-tstatus.failed { color: var(--error-fg, #a8342a); }
          .ag-body {
            border-top: 1px solid var(--agent-card-border, rgba(0,0,0,0.08));
            margin: 0; padding: 10px 12px; overflow-x: auto; max-height: 320px; overflow-y: auto;
            white-space: pre-wrap; overflow-wrap: anywhere; color: var(--agent-thought-fg, #6a675e);
            background: color-mix(in srgb, var(--agent-code-bg, rgba(0,0,0,0.06)) 60%, transparent);
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
          .ag-question {
            margin: 10px 0; padding: 11px 12px;
            border: 1px solid var(--agent-tool-fg, #26356b); border-radius: 8px;
            background: color-mix(in srgb, var(--agent-tool-fg, #26356b) 6%, transparent);
            font-family: var(--font-mono);
          }
          .ag-question-title { color: var(--agent-tool-fg, #26356b); font-weight: 650; }
          .ag-question-answers { display: flex; flex-wrap: wrap; gap: 7px; margin-top: 10px; }
          .ag-question .ag-btn.answer {
            border-color: color-mix(in srgb, var(--agent-tool-fg, #26356b) 55%, transparent);
            color: var(--agent-tool-fg, #26356b);
          }
          .ag-question .ag-btn.answer:hover {
            background: var(--agent-tool-fg, #26356b);
            color: var(--window-bg, #fdfcf8);
          }
          .ag-question-hint {
            margin-top: 9px; color: var(--agent-meta-fg, #8a8577); font-size: 10px;
          }
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
          /* the turn pulse under the transcript: outside .ag-scroll, so it
             aligns with the input row, not the padded scroll area */
          .ag-activity { margin: 2px 18px 4px; flex-shrink: 0; }
          @keyframes ag-shimmer {
            0%, 18% { transform: translateX(-120%); }
            82%, 100% { transform: translateX(120%); }
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
          /* queued rows under the transcript: outside .ag-scroll, so they
             align with the input row, not the padded scroll area */
          .ag-queued-row { margin: 2px 18px; flex-shrink: 0; }
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
          .dash-live {
            display: flex; gap: 16px; padding: 6px 16px;
            font-family: var(--font-mono); font-size: 10.5px;
            color: var(--dim-fg, #8a857a);
            border-bottom: 1px solid var(--border, #e2dbc9);
          }
          .dash-live-mod { color: var(--warn-fg, #7a5a1a); }
          .dash-top {
            flex: 0 0 auto; max-height: 46%; overflow-y: auto;
            background: var(--window-inactive-bg, #f4f0e6);
            border-bottom: 1px solid var(--border, #e2dbc9);
          }
          .ml-caret {
            font-family: var(--font-mono); font-size: 9px; cursor: pointer;
            color: var(--accent-fg, #26356b); flex: 0 0 auto; opacity: 0.7;
          }
          .ml-caret:hover { opacity: 1; }
          .ml-dot {
            width: 6px; height: 6px; border-radius: 50%;
            background: var(--linenum-fg, #c3bcac); flex: 0 0 auto;
          }
          .ml-dot.modified { background: var(--warn-fg, #7a5a1a); }
          .modeline .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .ml-pos { font-family: var(--font-mono); font-size: 10.5px; opacity: 0.75; }
          .ml-mode { font-family: var(--font-mono); font-size: 10.5px; opacity: 0.6; white-space: nowrap; }
          .ml-toggle { cursor: pointer; }
          .ml-toggle:hover { opacity: 1; text-decoration: underline; }
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
          /* vertico-style minibuffer: transient, keyboard-only. A plain
             prompt is a BOTTOM bar, like Emacs: the candidates sit above
             the input, the input sits on the last row, and the eye goes
             to one place for every prompt. Only the palette floats. */
          .mb-panel {
            flex-shrink: 0;
            background: var(--window-bg, #fdfcf8);
            border-top: 2px solid var(--accent-fg, #26356b);
            animation: rise 110ms ease-out;
          }
          /* palette style: the prompt floats centered over the windows,
             input on top, candidates below — the buffer switcher asks
             for this shape. The echo bar keeps the bottom row, so the
             window tree does not reflow while the palette is open. */
          .mb-panel.palette {
            position: fixed; left: 50%; top: 14dvh;
            transform: translateX(-50%);
            /* FIXED geometry: the box never changes size while you type —
               fewer candidates leave empty rows, never a smaller panel */
            width: min(1100px, 96vw);
            height: 62dvh;
            display: flex; flex-direction: column;
            border: 1px solid var(--border, #e2dbc9);
            border-top: 2px solid var(--accent-fg, #26356b);
            border-radius: 10px;
            box-shadow: 0 24px 60px rgba(0, 0, 0, 0.28);
            overflow: hidden;
            z-index: 40;
            animation: none;
            /* NO entry animation: a patched node's animation can stall
               at its first frame and leave the palette painted at
               opacity 0 — an open, working, invisible prompt */
          }
          .mb-panel.palette .mb-input-row {
            order: -1;
            border-top: none;
            border-bottom: 1px solid var(--border, #e2dbc9);
            flex: 0 0 auto;
          }
          .mb-panel.palette .mb-label-row { order: -2; flex: 0 0 auto; }
          .mb-panel.palette .mb-cands {
            max-height: none; flex: 1;
            /* rows keep their natural height — no stretching to fill */
            align-content: start;
          }
          /* the name is the point: give it the room, ellipsize later */
          .mb-panel.palette .mb-cand { font-size: 13.5px; }
          .mb-panel.palette .mb-label { max-width: 80ch; }
          .mb-panel.palette.transient-panel { height: auto; max-height: 62dvh; }
          .transient-title {
            padding: 13px 16px 11px; border-bottom: 1px solid var(--border, #e2dbc9);
            font-size: 14px; font-weight: 650; color: var(--accent-fg, #26356b);
          }
          .transient-groups {
            display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 18px 28px; padding: 16px; overflow: auto;
          }
          .transient-group-title {
            margin-bottom: 7px; font-size: 10px; letter-spacing: .13em;
            text-transform: uppercase; color: var(--dim-fg, #8a857a);
          }
          .transient-item {
            display: grid; grid-template-columns: 7ch minmax(0, 1fr) auto;
            gap: 10px; align-items: baseline; min-height: 26px; padding: 4px 7px;
            border-radius: 5px; font-family: var(--font-mono); font-size: 12.5px;
          }
          .transient-item.selected { background: var(--select-bg, #e7e9f1); }
          .transient-key { color: var(--accent-fg, #26356b); font-weight: 650; }
          .transient-item.stay .transient-key { color: var(--ok-fg, #2e6b45); }
          .transient-description { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .transient-value { color: var(--dim-fg, #8a857a); white-space: nowrap; }
          .transient-help {
            padding: 9px 16px 10px; border-top: 1px solid var(--border, #e2dbc9);
            color: var(--dim-fg, #8a857a); font-family: var(--font-mono); font-size: 10.5px;
          }
          /* the palette body: candidates left, the facts panel right */
          .mb-body { display: flex; flex: 1; min-height: 0; }
          .mb-body .mb-cands { flex: 1; min-width: 0; }
          .mb-preview {
            flex: 0 0 172px;
            /* min-width:auto would let the long title win over the
               basis and swallow half the palette */
            min-width: 0; overflow: hidden;
            border-left: 1px solid var(--border, #e2dbc9);
            background: var(--default-bg, #efeadf);
            padding: 11px 12px 12px;
            display: flex; flex-direction: column; gap: 6px;
            font-family: var(--font-mono); font-size: 10.5px;
          }
          .mb-preview-title {
            font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a); margin-bottom: 3px;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .mb-preview-fact { display: flex; gap: 8px; align-items: baseline; }
          .mb-preview-k { flex: 0 0 44px; color: var(--dim-fg, #8a857a); }
          .mb-preview-v { flex: 1; min-width: 0; overflow-wrap: anywhere; }
          .mb-preview-note {
            margin-top: auto; padding-top: 8px;
            color: var(--dim-fg, #8a857a); font-size: 10.5px; line-height: 1.5;
          }
          /* a container: one group as one row, its members as chips */
          .mb-container {
            grid-column: 1 / -1;
            margin: 2px 8px 3px;
            border: 1px solid var(--border, #e2dbc9); border-radius: 10px;
            background: var(--default-bg, #efeadf);
            overflow: hidden;
          }
          .mb-container.selected {
            border-color: var(--accent-fg, #26356b);
            background: var(--select-bg, #e7e9f1);
          }
          .mb-container-head {
            display: flex; align-items: baseline; gap: 10px;
            padding: 7px 12px; font-family: var(--font-mono);
          }
          .mb-container-dot {
            width: 7px; height: 7px; border-radius: 2px; align-self: center;
            background: var(--accent-fg, #26356b); flex: 0 0 auto;
          }
          .mb-container-name { font-size: 13.5px; font-weight: 600; flex: 0 0 auto; }
          .mb-container.selected .mb-container-name { color: var(--accent-fg, #26356b); }
          .mb-container-action {
            font-size: 10.5px; color: var(--accent-fg, #26356b); flex: 0 0 auto;
          }
          .mb-container-meta {
            flex: 1; min-width: 0; font-size: 10.5px; color: var(--dim-fg, #8a857a);
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .mb-chips {
            display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
            padding: 0 12px 8px 29px; font-family: var(--font-mono);
          }
          .mb-chips-key {
            font-size: 9.5px; letter-spacing: 0.1em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a);
          }
          .mb-chip {
            font-size: 10.5px; padding: 1px 8px; border-radius: 20px;
            border: 1px solid var(--border, #e2dbc9);
            background: var(--window-bg, #fdfcf8);
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
            "Enter": "RET", "Backspace": "DEL", "Delete": "<delete>", "Tab": "TAB", " ": "SPC",
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
          // paste event) — except the arrows, claimed for window motion,
          // and cmd-p, claimed for the command palette
          // ...and the text-scale chords (cmd-+/-/0), claimed from the
          // browser's whole-page zoom: the scale belongs to ONE buffer
          const CMD_KEYS = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                            "a", "p", "+", "=", "-", "0", "Enter"];

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

          // The column a visual-line move keeps while it walks rows, and the
          // row it last aimed at. A click sets a new column, and the click
          // arrives in the preview hook, so the two hooks share one holder.
          //
          // The row matters because the cursor marker does not always draw
          // on the row it belongs to: a point right after a line break in
          // the source draws at the END of the previous rendered row, where
          // the browser collapses the break. Reading the next row from the
          // marker would then read the same row twice and the cursor would
          // stop moving. So remember the row this move aimed at, in page
          // coordinates, and step from there.
          const visualGoal = { x: null, y: null };

          // the row a preview move works from: the marker's own row, unless
          // the row we aimed at last time says the marker drew somewhere else
          function visualBaseRow(d, rect, line) {
            const mid = rect.top + Math.max(1, Math.min(rect.height / 2, line / 2));
            if (visualGoal.y == null) return mid;
            const top = (d.scrollingElement || d.documentElement).scrollTop;
            const remembered = visualGoal.y - top;
            return Math.abs(remembered - mid) > line * 0.65 ? remembered : mid;
          }

          function rememberRow(d, y) {
            visualGoal.y = y + (d.scrollingElement || d.documentElement).scrollTop;
          }

          // The page carries one .ln marker per source line that draws text.
          // The marker above a caret names that line's byte offset, and the
          // rendered text between the two says how far along the line the
          // caret sits. Point then follows the source, and rows the source
          // does not own — a code block's head, an embed — carry
          // data-chrome and are skipped instead.
          function sourceSpot(d, node, off) {
            const marks = d.querySelectorAll("span.ln");
            if (!marks.length) return null;
            const caret = d.createRange();
            caret.setStart(node, off);
            caret.collapse(true);
            let found = null;
            for (const m of marks) {
              const at = d.createRange();
              at.selectNode(m);
              if (caret.compareBoundaryPoints(Range.START_TO_START, at) < 0) break;
              found = m;
            }
            if (!found) return null;
            const span = d.createRange();
            span.setStartAfter(found);
            span.setEnd(node, off);
            const p = parseInt(found.dataset.p, 10);
            if (!Number.isFinite(p)) return null;
            return { p: p, off: span.toString().length };
          }

          function isChrome(node) {
            const el = node && (node.nodeType === 1 ? node : node.parentElement);
            return !!(el && el.closest && el.closest("[data-chrome], .code-block-head, .tweet"));
          }

          // One rendered fragment names many source positions: the code span
          // `-b` sits in the file ten times. So say which one this is —
          // count the same text on the page before this occurrence — and
          // let Scheme pick that occurrence in the source.
          function previewSpot(d, node, off, dir) {
            const t = node.textContent;
            const before = t.slice(0, off);
            const after = t.slice(off);
            const wb = (before.match(/[\w-]*$/) || [""])[0];
            const wa = (after.match(/^[\w-]*/) || [""])[0];
            let page = "";
            try {
              const r = d.createRange();
              r.setStart(d.body, 0);
              r.setEnd(node, off);
              page = r.toString();
            } catch (_) { page = ""; }
            // the occurrence starts one BEFORE-length back from the caret
            const count = (needle, back) => {
              if (!needle) return 0;
              const upto = page.length - back;
              let n = 0;
              for (let i = page.indexOf(needle); i >= 0 && i < upto;
                   i = page.indexOf(needle, i + 1)) n++;
              return n;
            };
            return {
              before: before, after: after, wb: wb, wa: wa,
              nth: count(before + after, before.length),
              wn: count(wb + wa, wb.length),
              dir: dir
            };
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
                this.lastDoc = null;
                this.onLoad = () => {
                  this.lastDoc = null;
                  this.syncDoc();
                  this.attach();
                };
                this.el.addEventListener("load", this.onLoad);
                this.syncDoc();
                this.attach();
              },
              updated() {
                this.syncDoc();
                this.attach();
                this.apply();
                this.selectRegion();
              },
              destroyed() {
                this.el.removeEventListener("load", this.onLoad);
                clearTimeout(this.timer);
              },
              // same-origin, but the document is absent until it loads
              doc() {
                try { return this.el.contentDocument; } catch (e) { return null; }
              },
              // Assigning iframe.srcdoc navigates the frame, even when its
              // LiveView id is stable. Markdown includes the point marker,
              // so that used to reload and visibly blank the writing surface
              // on every cursor move. Ship the document as inert base64 and
              // replace the existing document tree synchronously instead.
              syncDoc() {
                const encoded = this.el.dataset.doc || "";
                if (encoded === this.lastDoc) return;
                const d = this.doc();
                if (!d) return;
                let html;
                try {
                  const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
                  html = new TextDecoder().decode(bytes);
                } catch (_) { return; }
                const next = new DOMParser().parseFromString(html, "text/html");
                d.documentElement.innerHTML = next.documentElement.innerHTML;
                this.lastDoc = encoded;
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
                this.selectRegion();
              },
              selectRegion() {
                const d = this.doc();
                const w = this.el.contentWindow;
                const pt = d && d.querySelector(".pt");
                const mk = d && d.querySelector(".mk");
                if (!pt || !mk) {
                  if (w && w.CSS && w.CSS.highlights) w.CSS.highlights.delete("region");
                  return;
                }
                const range = d.createRange();
                const markFirst = !!(mk.compareDocumentPosition(pt) & Node.DOCUMENT_POSITION_FOLLOWING);
                if (markFirst) {
                  range.setStartAfter(mk);
                  range.setEndBefore(pt);
                } else {
                  range.setStartAfter(pt);
                  range.setEndBefore(mk);
                }
                // the iframe never has keyboard focus, and Chrome does not
                // paint a selection in an unfocused document — an isearch
                // match was invisible until RET. The highlight API paints
                // regardless of focus; the selection stays as the fallback.
                if (w && w.CSS && w.CSS.highlights && w.Highlight) {
                  w.CSS.highlights.set("region", new w.Highlight(range));
                } else {
                  const selection = d.getSelection();
                  selection.removeAllRanges();
                  selection.addRange(range);
                }
              },
              attach() {
                const d = this.doc();
                if (!d) return;
                const pt = d.querySelector(".pt");
                if (pt) {
                  const active = this.el.closest(".window")?.classList.contains("active");
                  pt.style.visibility = document.hasFocus() && active ? "visible" : "hidden";
                }
                this.apply();
                this.selectRegion();
                // syncDoc keeps the same Document object, so document-level
                // listeners survive its tree replacement and must not stack.
                if (this.wired === d) return;
                this.wired = d;
                // a markdown preview shows point and takes edits, so a
                // click must move point. The caret API names the clicked
                // text node; the daemon finds that text in the source.
                if (this.el.dataset.rm === "markdown") {
                  // Text the renderer added — a code block's head, an embed
                  // card — names no source position. A caret there matches
                  // its short label text anywhere in the file, so it must
                  // not move point.
                  const chromeNode = (node) => isChrome(node);
                  // A link is the page's own button: the frame must not
                  // navigate to it (the document here is a render, not a
                  // site). The href goes to the daemon, which decides what
                  // the link means. An in-page anchor keeps the browser's
                  // own scroll.
                  const linkAt = (e) => {
                    const t = e.target;
                    const a = t && t.closest && t.closest("a[href]");
                    if (!a) return null;
                    const href = a.getAttribute("href") || "";
                    return (href === "" || href.startsWith("#")) ? null : href;
                  };
                  // the click only cancels the navigation: the mousedown
                  // below already sent the link, because moving point
                  // re-renders the document and the anchor dies with it
                  d.addEventListener("click", (e) => {
                    if (linkAt(e)) e.preventDefault();
                  }, true);
                  d.addEventListener("mousedown", (e) => {
                    // Only the left button moves point. A right click keeps
                    // the region for the copy that follows it.
                    if (e.button !== 0) return;
                    // a link answers the click itself: it must not also
                    // move point, or the re-render kills the anchor first
                    const href = linkAt(e);
                    if (href) {
                      e.preventDefault();
                      this.pushEvent("preview_link", {
                        win: parseInt(this.el.dataset.win, 10),
                        href: href
                      });
                      return;
                    }
                    // A generated response is atomic to the editor cursor,
                    // but its prose remains ordinary browser-selectable text.
                    // Do not patch the iframe on mousedown or a drag would
                    // lose its native selection halfway through.
                    if (e.target.closest && e.target.closest(".llm-response")) return;
                    const c = d.caretRangeFromPoint
                      ? d.caretRangeFromPoint(e.clientX, e.clientY)
                      : d.caretPositionFromPoint && d.caretPositionFromPoint(e.clientX, e.clientY);
                    if (!c) return;
                    const node = c.startContainer || c.offsetNode;
                    if (!node || node.nodeType !== 3) return;
                    if (chromeNode(node)) return;
                    const off = c.startOffset !== undefined ? c.startOffset : c.offset;
                    visualGoal.x = null;
                    visualGoal.y = null;
                    this.dragFrom = { x: e.clientX, y: e.clientY };
                    const src = sourceSpot(d, node, off);
                    if (src) {
                      this.pushEvent("preview_goto_src", {
                        win: parseInt(this.el.dataset.win, 10),
                        p: src.p, off: src.off, dir: 0, extend: false
                      });
                      return;
                    }
                    this.pushEvent("preview_goto", Object.assign(
                      { win: parseInt(this.el.dataset.win, 10) },
                      previewSpot(d, node, off, 0)));
                  }, true);
                  // A drag cannot keep its native selection: the goto above
                  // re-renders the document and the anchor node dies. So a
                  // drag extends the editor region to the caret under the
                  // pointer instead — the same mirror mouse_sel gives a line
                  // window, which a preview's events never reach.
                  const dragSpot = (e) => {
                    if (!this.dragFrom) return null;
                    if (Math.abs(e.clientX - this.dragFrom.x) < 4 &&
                        Math.abs(e.clientY - this.dragFrom.y) < 4) return null;
                    const c = d.caretRangeFromPoint
                      ? d.caretRangeFromPoint(e.clientX, e.clientY)
                      : d.caretPositionFromPoint && d.caretPositionFromPoint(e.clientX, e.clientY);
                    if (!c) return null;
                    const node = c.startContainer || c.offsetNode;
                    if (!node || node.nodeType !== 3) return null;
                    if (chromeNode(node)) return null;
                    const off = c.startOffset !== undefined ? c.startOffset : c.offset;
                    return previewSpot(d, node, off, 0);
                  };
                  const dragExtend = (spot) => {
                    this.pushEvent("preview_goto", Object.assign(
                      { win: parseInt(this.el.dataset.win, 10), extend: true }, spot));
                  };
                  d.addEventListener("mousemove", (e) => {
                    if (!this.dragFrom || !(e.buttons & 1)) return;
                    const now = Date.now();
                    if (this.dragAt && now - this.dragAt < 100) return;
                    const spot = dragSpot(e);
                    if (!spot) return;
                    this.dragAt = now;
                    dragExtend(spot);
                  }, true);
                  d.addEventListener("mouseup", (e) => {
                    const spot = dragSpot(e);
                    this.dragFrom = null;
                    this.dragAt = null;
                    if (spot) dragExtend(spot);
                  }, true);
                }
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
              // a page from an older daemon boot is stale: its JS and CSS
              // no longer match the server. A restart REJOINS the socket
              // without re-mounting hooks, so the check must run on every
              // path — mount, rejoin, and each patch (the patch writes the
              // new boot id into data-boot).
              bootCheck() {
                if (this.el.dataset.boot && this.el.dataset.boot !== PAGE_BOOT) {
                  window.location.reload();
                  return true;
                }
                return false;
              },
              reconnected() { this.bootCheck(); },
              updated() {
                if (this.bootCheck()) return;
                // A server patch acknowledges the last visual move. Keyup
                // may land inside the iframe, so it cannot be the only reset.
                this.visualLinePending = false;
                if (this.syncCursorFocus) this.syncCursorFocus();
              },
              mounted() {
                if (this.bootCheck()) return;
                this.handleEvent("navigate", ({url}) => window.location.assign(url));
                this.visualLinePending = false;
                this.syncCursorFocus = () => {
                  const focused = document.hasFocus() && !document.body.classList.contains("unfocused");
                  document.querySelectorAll(".window iframe[data-rm='markdown']").forEach((frame) => {
                    let d;
                    try { d = frame.contentDocument; } catch (_) { return; }
                    const pt = d && d.querySelector(".pt");
                    if (pt) {
                      const active = frame.closest(".window")?.classList.contains("active");
                      pt.style.visibility = focused && active ? "visible" : "hidden";
                    }
                  });
                };
                // visual-line-mode belongs to the buffer, but only the
                // browser knows where proportional rendered prose wraps.
                // Resolve the screen line here, then send the same semantic
                // preview position a mouse click sends; Scheme remains the
                // owner of the resulting point move.
                this.visualLineMove = (dir, extend) => {
                  if (document.querySelector(".mb-panel")) return false;
                  // A browser key-repeat can outrun the LiveView patch that
                  // moves the cursor. Do not send another move from stale DOM.
                  if (this.visualLinePending) return true;

                  // A raw line window already knows how to map a browser caret
                  // to its logical line and character offset. Use that same
                  // geometry for wrapped visual rows.
                  const raw = document.querySelector(
                    ".window.active .buf[data-visual-lines='true']"
                  );
                  if (raw) {
                    const cursor = raw.querySelector(".cursor");
                    if (!cursor || extend) return false;
                    const r = cursor.getBoundingClientRect();
                    const content = cursor.closest(".line-content") || cursor.parentElement;
                    const css = getComputedStyle(content);
                    const line = parseFloat(css.lineHeight) ||
                      (parseFloat(css.fontSize) || 16) * 1.2;
                    const x = visualGoal.x == null ? r.left : visualGoal.x;
                    visualGoal.x = x;
                    const y =
                      r.top + Math.max(1, Math.min(r.height / 2, line / 2)) + dir * line;
                    const box = raw.getBoundingClientRect();
                    const caretAt = (px) => document.caretPositionFromPoint
                      ? document.caretPositionFromPoint(px, y)
                      : document.caretRangeFromPoint && document.caretRangeFromPoint(px, y);
                    let pos = null;
                    for (let dx = 0; !pos && dx <= box.width; dx += 4) {
                      const xs = dx === 0 ? [x] : [x - dx, x + dx];
                      for (const px of xs) {
                        if (px < box.left || px > box.right) continue;
                        const c = caretAt(px);
                        if (!c) continue;
                        const node = c.offsetNode || c.startContainer;
                        const off = c.offset !== undefined ? c.offset : c.startOffset;
                        pos = posIn(node, off);
                        if (pos) break;
                      }
                    }
                    if (!pos) return false;
                    const winEl = raw.closest(".window[data-win-id]");
                    if (!winEl) return false;
                    this.visualLinePending = true;
                    this.pushEvent("mouse", {
                      win: parseInt(winEl.dataset.winId, 10),
                      line: pos.line,
                      col: pos.col
                    });
                    return true;
                  }

                  const frame = document.querySelector(
                    ".window.active iframe[data-rm='markdown'][data-visual-lines='true']"
                  );
                  if (!frame) return false;
                  let d;
                  try { d = frame.contentDocument; } catch (_) { return false; }
                  const pt = d && d.querySelector(".pt");
                  if (!pt) return false;
                  const r = pt.getBoundingClientRect();
                  const parent = pt.parentElement || d.body;
                  const css = d.defaultView.getComputedStyle(parent);
                  const line = parseFloat(css.lineHeight) ||
                    (parseFloat(css.fontSize) || 16) * 1.2;
                  const x = visualGoal.x == null ? r.left : visualGoal.x;
                  visualGoal.x = x;
                  const caretAt = (y) => d.caretRangeFromPoint
                    ? d.caretRangeFromPoint(x, y)
                    : d.caretPositionFromPoint && d.caretPositionFromPoint(x, y);
                  // Margins between Markdown blocks are not caret positions.
                  // Walk a little farther in the requested direction until
                  // the browser gives us text on the neighboring screen line.
                  const rowMid = visualBaseRow(d, r, line);
                  for (let step = line; step <= line * 3; step += Math.max(2, line / 4)) {
                    // Probe the middle of the target row. Its top edge can
                    // resolve to the previous row or to an element container.
                    const c = caretAt(rowMid + dir * step);
                    if (!c) continue;
                    const node = c.startContainer || c.offsetNode;
                    if (!node || node.nodeType !== 3) continue;
                    const response = node.parentElement && node.parentElement.closest(".llm-response");
                    if (response) {
                      const start = parseInt(response.dataset.start, 10);
                      const end = parseInt(response.dataset.end, 10);
                      if (!Number.isFinite(start) || !Number.isFinite(end)) continue;
                      this.visualLinePending = true;
                      this.pushEvent("preview_goto_pos", {
                        win: parseInt(frame.dataset.win, 10),
                        pos: dir > 0 ? end + 1 : Math.max(0, start - 1),
                        extend: extend
                      });
                      return true;
                    }
                    // a row the source does not own: keep walking
                    if (isChrome(node)) continue;
                    const off = c.startOffset !== undefined ? c.startOffset : c.offset;
                    this.visualLinePending = true;
                    rememberRow(d, rowMid + dir * step);
                    const src = sourceSpot(d, node, off);
                    if (src) {
                      this.pushEvent("preview_goto_src", {
                        win: parseInt(frame.dataset.win, 10),
                        p: src.p, off: src.off, dir: dir, extend: extend
                      });
                      return true;
                    }
                    this.pushEvent("preview_goto", Object.assign(
                      { win: parseInt(frame.dataset.win, 10), extend: extend },
                      previewSpot(d, node, off, dir)));
                    return true;
                  }
                  return false;
                };
                // Home/End and Cmd-Left/Right mean the edge of the rendered
                // row in a writing preview, not the source Markdown line.
                // Scan inward from the viewport edge at the cursor's y until
                // the browser supplies a caret on this visual row.
                this.visualLineEdge = (dir, extend) => {
                  if (document.querySelector(".mb-panel")) return false;
                  const frame = document.querySelector(
                    ".window.active iframe[data-rm='markdown'][data-visual-lines='true']"
                  );
                  if (!frame) return false;
                  let d;
                  try { d = frame.contentDocument; } catch (_) { return false; }
                  const pt = d && d.querySelector(".pt");
                  if (!pt || this.visualLinePending) return !!pt;
                  const r = pt.getBoundingClientRect();
                  const parent = pt.parentElement || d.body;
                  const css = d.defaultView.getComputedStyle(parent);
                  const line = parseFloat(css.lineHeight) ||
                    (parseFloat(css.fontSize) || 16) * 1.2;
                  const y = visualBaseRow(d, r, line);
                  const width = d.documentElement.clientWidth;
                  const caretAt = (x) => d.caretRangeFromPoint
                    ? d.caretRangeFromPoint(x, y)
                    : d.caretPositionFromPoint && d.caretPositionFromPoint(x, y);
                  for (let x = dir < 0 ? 0 : width - 1;
                       dir < 0 ? x < width : x >= 0;
                       x += dir < 0 ? 3 : -3) {
                    const c = caretAt(x);
                    if (!c) continue;
                    const node = c.startContainer || c.offsetNode;
                    if (!node || node.nodeType !== 3) continue;
                    const off = c.startOffset !== undefined ? c.startOffset : c.offset;
                    const probe = d.createRange();
                    probe.setStart(node, off);
                    probe.collapse(true);
                    const cr = probe.getBoundingClientRect();
                    if (Math.abs(cr.top - r.top) > line * 0.65) continue;
                    if (isChrome(node)) continue;
                    this.visualLinePending = true;
                    const src = sourceSpot(d, node, off);
                    if (src) {
                      this.pushEvent("preview_goto_src", {
                        win: parseInt(frame.dataset.win, 10),
                        p: src.p, off: src.off, dir: 0, extend: extend
                      });
                      return true;
                    }
                    // the edge of the row this cursor already sits on, so
                    // the move names no direction
                    this.pushEvent("preview_goto", Object.assign(
                      { win: parseInt(frame.dataset.win, 10), extend: extend },
                      previewSpot(d, node, off, 0)));
                    return true;
                  }
                  return false;
                };
                // a selection can live inside a same-origin preview iframe
                // (an .llm-response drag), where the focused parent's own
                // copy never sees it
                const previewSelection = () => {
                  for (const f of document.querySelectorAll(".window iframe")) {
                    try {
                      const s = f.contentDocument && f.contentDocument.getSelection();
                      if (s && !s.isCollapsed) return s.toString();
                    } catch (_) { /* cross-origin app frame */ }
                  }
                  return "";
                };
                this.handler = (e) => {
                  // Cmd-C with no native selection: copy the editor region
                  // (with one, the browser's own copy handles it)
                  if (e.metaKey && !e.ctrlKey && !e.altKey && e.key === "c" &&
                      window.getSelection().isCollapsed) {
                    e.preventDefault();
                    const text = previewSelection();
                    if (text) navigator.clipboard.writeText(text);
                    else this.pushEvent("copy", {});
                    return;
                  }
                  const spec = keySpec(e);
                  if (spec === null) return;
                  e.preventDefault();
                  const edgeDir = ["<home>", "S-<home>", "s-<left>", "s-S-<left>"].includes(spec)
                    ? -1
                    : ["<end>", "S-<end>", "s-<right>", "s-S-<right>"].includes(spec)
                      ? 1 : 0;
                  const edgeExtend = spec === "S-<home>" || spec === "S-<end>" ||
                    spec === "s-S-<left>" || spec === "s-S-<right>";
                  if (edgeDir !== 0 && this.visualLineEdge(edgeDir, edgeExtend)) return;
                  const visualDir = spec === "<down>" || spec === "C-n" ? 1
                    : spec === "<up>" || spec === "C-p" ? -1
                    : spec === "S-<down>" ? 1 : spec === "S-<up>" ? -1 : 0;
                  const visualExtend = spec === "S-<down>" || spec === "S-<up>";
                  if (visualDir !== 0 && this.visualLineMove(visualDir, visualExtend)) return;
                  visualGoal.x = null;
                  visualGoal.y = null;
                  this.pushEvent("key", { k: spec });
                };
                window.addEventListener("keydown", this.handler);
                this.keyupH = (e) => {
                  if (e.key === "ArrowUp" || e.key === "ArrowDown" ||
                      (e.ctrlKey && (e.key === "n" || e.key === "p"))) {
                    this.visualLinePending = false;
                  }
                };
                window.addEventListener("keyup", this.keyupH);

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
                this.lastWinCols = "";
                this.sendViewport = () => {
                  const line = document.querySelector(".line");
                  if (line) this.lineHeight = line.getBoundingClientRect().height || 22;
                  const area = document.querySelector(".windows");
                  if (area) this.pushEvent("viewport", { rows: Math.max(5, Math.floor(area.clientHeight / this.lineHeight)) });
                  this.sendWinRows();
                };
                this.sendWinRows = () => {
                  const rows = {};
                  const cols = {};
                  document.querySelectorAll(".window[data-win-id]").forEach((win) => {
                    const buf = win.querySelector(".buf");
                    if (!buf) return; // preview windows have no line grid
                    const ln = buf.querySelector(".line");
                    const h = ln ? ln.getBoundingClientRect().height : this.lineHeight;
                    if (h > 0) rows[win.dataset.winId] = Math.max(3, Math.floor(buf.clientHeight / h));
                    // how many characters fit on one line: the probe wears
                    // the line's own font, and the gutter is not text
                    const content = ln && ln.querySelector(".line-content");
                    if (content) {
                      const probe = document.createElement("span");
                      probe.textContent = "0".repeat(80);
                      probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
                      content.appendChild(probe);
                      const cw = probe.getBoundingClientRect().width / 80;
                      probe.remove();
                      // .line-content is the flex child that holds the text:
                      // its box is the width the text actually has, after the
                      // gutter, the gap and the line padding
                      const avail = content.getBoundingClientRect().width;
                      if (cw > 0 && avail > 0) {
                        cols[win.dataset.winId] = Math.max(20, Math.floor(avail / cw));
                      }
                    }
                  });
                  const key = JSON.stringify(rows);
                  if (key !== this.lastWinRows && Object.keys(rows).length > 0) {
                    this.lastWinRows = key;
                    this.pushEvent("win_rows", { rows });
                  }
                  const ckey = JSON.stringify(cols);
                  if (ckey !== this.lastWinCols && Object.keys(cols).length > 0) {
                    this.lastWinCols = ckey;
                    this.pushEvent("win_cols", { cols });
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

                this.focusH = () => {
                  document.body.classList.remove("unfocused");
                  this.syncCursorFocus();
                };
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
                  this.visualLinePending = false;
                  this.syncCursorFocus();
                };
                window.addEventListener("focus", this.focusH);
                window.addEventListener("blur", this.blurH);
                if (!document.hasFocus()) document.body.classList.add("unfocused");
                this.syncCursorFocus();
              },
              updated() {
                if (this.bootCheck()) return;
                this.visualLinePending = false;
                this.syncCursorFocus();
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
                window.removeEventListener("keyup", this.keyupH);
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
