defmodule Compos.Ui.Layouts do
  use Phoenix.Component

  def root(assigns) do
    assigns = assign_new(assigns, :page_title, fn -> "compos.el" end)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={:persistent_term.get(:compos_boot_id, "dev")} />
        <title>{@page_title}</title>
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" type="image/png" href="/icons/compos-192.png" />
        <link rel="apple-touch-icon" href="/icons/compos-192.png" />
        <link
          rel="stylesheet"
          href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css"
        />
        <meta name="theme-color" content="#e6e0d2" />
        <script>
          // the browser chrome follows the theme's default background;
          // the faces arrive with the LiveView, so read them after each load
          window.addEventListener("phx:page-loading-stop", () => {
            const bg = getComputedStyle(document.documentElement).getPropertyValue("--default-bg").trim();
            const meta = document.querySelector('meta[name="theme-color"]');
            if (bg && meta) meta.setAttribute("content", bg);
          });
        </script>
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
          .editor-root {
            display: flex; flex-direction: column; position: relative;
            overflow: hidden;
            /* the application text scale (appearance.scm ui-scale): the
               'ui face's zoom is a root variable, and the whole page
               grows by it, rendered pages included. A viewport unit does
               not shrink under zoom, so the height divides by it, or the
               modeline lands below the fold. */
            zoom: var(--ui-zoom, 1);
            height: 100dvh;
          }
          /* Engines disagree on viewport units inside CSS zoom. A boot
             probe measures this engine and stamps html with the class
             its math needs; naming engines would age badly. */
          html.zoom-divides .editor-root { height: calc(100dvh / var(--ui-zoom, 1)); }
          html.zoom-multiplies .editor-root { height: calc(100dvh * var(--ui-zoom, 1)); }
          .editor-root.instance-identified::before {
            content: attr(data-instance);
            position: absolute; top: 0; right: 14px; z-index: 70;
            padding: 4px 10px 5px;
            border-radius: 0 0 6px 6px;
            background: var(--instance-accent);
            color: #fff; font: 700 11px/1 var(--font-mono);
            letter-spacing: 0.06em; text-transform: uppercase;
            pointer-events: none;
          }
          .editor-root.instance-identified::after {
            content: "";
            position: absolute; inset: 0; z-index: 69;
            border: 4px solid var(--instance-accent);
            pointer-events: none;
          }
          .workspace-bar {
            flex: 0 0 auto; display: flex; align-items: center; gap: 10px;
            min-height: 38px; padding: 7px 14px;
            border-bottom: 2px solid color-mix(in srgb, var(--alert-fg, #d13b32) 72%, #111);
            background:
              linear-gradient(90deg,
                color-mix(in srgb, var(--alert-fg, #d13b32) 22%, #171312),
                #171312 62%);
            color: #fff8ee; font: 600 11px/1.25 var(--font-mono);
            letter-spacing: 0.015em;
            box-shadow: none;
            z-index: 40;
          }
          .workspace-bar-kind, .workspace-bar-port {
            padding: 4px 8px; border-radius: 999px;
            background: var(--alert-fg, #d13b32); color: white;
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
          /* A popup stays in the window tree, so editor commands can reach it.
             Its split leaves the visual flow. The sibling then fills that split.
             The popup measures itself against .windows, which is the frame. */
          .split-child:has(> .window.popup) {
            flex: 0 0 0 !important; overflow: visible; transition: none;
          }
          .split:has(> .split-child > .window.popup)
            > .split-child:not(:has(> .window.popup)) {
            flex-grow: 1 !important;
          }
          .window.popup-right,
          .window.popup-left,
          .window.popup-top,
          .window.popup-bottom,
          .window.popup-center {
            position: absolute; z-index: 20;
            box-shadow: 0 0 30px rgba(0, 0, 0, 0.30);
            border: var(--chrome-border, none);
            border-radius: var(--chrome-radius, 0);
            animation: popup-rise var(--chrome-anim, 140ms) ease-out;
          }
          .window.popup-right,
          .window.popup-left {
            top: 0; bottom: 0;
            width: var(--popup-size, 33.333%);
          }
          .window.popup-right { right: 0; }
          .window.popup-left { left: 0; }
          .window.popup-top,
          .window.popup-bottom {
            left: 0; right: 0;
            height: var(--popup-size, 33.333%);
          }
          .window.popup-top { top: 0; }
          .window.popup-bottom { bottom: 0; }
          .window.popup-center {
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
            box-shadow: var(--chrome-shadow, inset -1px -1px 0 0 var(--border-bg, #d5cdb9));
            overflow: hidden;
            min-width: 0; min-height: 0;
            animation: win-in var(--chrome-anim, 140ms) ease-out;
          }
          .window.active { background: var(--window-bg, #fdfcf8); }
          .window.workspace-pending {
            position: relative;
            box-shadow:
              inset 0 0 0 2px var(--alert-fg, #d13b32),
              inset 0 0 22px color-mix(in srgb, var(--alert-fg, #d13b32) 18%, transparent),
              0 0 18px color-mix(in srgb, var(--alert-fg, #d13b32) 24%, transparent);
          }
          .window.workspace-pending::before {
            content: "UNMERGED WORKTREE";
            position: absolute; z-index: 18; top: 8px; right: 10px;
            padding: 4px 10px;
            border: 1px solid color-mix(in srgb, var(--alert-fg, #d13b32) 72%, white);
            border-radius: 999px;
            background: var(--alert-fg, #d13b32);
            color: white;
            font: 700 10px/1.2 var(--font-mono);
            letter-spacing: 0.09em;
            box-shadow: 0 3px 14px color-mix(in srgb, var(--alert-fg, #d13b32) 42%, transparent);
            pointer-events: none;
          }
          .buffer-header {
            flex: 0 0 auto;
            padding: 7px 14px;
            border-bottom: 1px solid var(--border-bg, #cbc4b1);
            background: var(--modeline-active-bg, #e7e9f1);
            color: var(--modeline-active-fg, #1b1a17);
            font: 650 11px/1.3 var(--font-mono);
            letter-spacing: 0.015em;
          }
          .buffer-footer {
            flex: 0 0 auto;
            padding: 6px 14px;
            border-top: 1px solid var(--border-bg, #cbc4b1);
            background: var(--modeline-inactive-bg, var(--window-inactive-bg, #f4f0e6));
            color: var(--dim-fg, #6b6a66);
            font: 550 11px/1.3 var(--font-mono);
            letter-spacing: 0.015em;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .window.workspace-pending .buffer-header {
            border-bottom-color: color-mix(in srgb, var(--alert-fg, #d13b32) 68%, transparent);
            background: color-mix(in srgb, var(--alert-fg, #d13b32) 12%, var(--window-bg, #fdfcf8));
            color: var(--alert-fg, #a8342a);
          }
          .buf {
            flex: 1;
            /* the server owns vertical scrolling (viewport windowing); a row
               wider than the window (a CSV table) scrolls right */
            overflow: auto hidden;
            padding: 12px 0 22px;
            /* default face drives the text font; themes/customize set the
               vars, buffer-face! overrides them per window via inline style */
            font-family: var(--default-family, var(--font-mono));
            /* the buffer text scale (text-scale-increase) is a factor in
               the same inline style; the size a remap names still holds */
            font-size: calc(var(--default-size, 13px) * var(--text-scale-factor, 1));
            line-height: var(--default-line-height, 1.7);
            font-variant-ligatures: common-ligatures;
            letter-spacing: -0.1px;
          }
          .terminal-view {
            flex: 1; min-width: 0; min-height: 0; overflow: hidden;
            padding: 7px 8px;
            background: var(--window-bg, #111318);
          }
          .terminal-view .xterm { height: 100%; }
          .terminal-view .xterm-viewport { overflow-y: auto !important; }
          .terminal-view .xterm-screen { margin: 0; }
          /* buffers under the ship-all threshold get every line at once
             (editor_live.ex) — the browser owns scroll position natively
             here, no server round-trip per scroll tick */
          .buf.client-scroll { overflow: auto auto; }
          .line { display: flex; align-items: flex-start; gap: 12px; padding: 0 16px 0 8px;
                  /* empty lines must keep their height even with .linenum hidden (no-nums, writing-mode) */
                  min-height: 1lh; }
          .window.active .line.hl-line { background: var(--hl-line-bg, #f5f1e6); }
          /* A select overlay names complete logical rows. Paint each touched
             display line across the window, including its line-number area. */
          .window .line.selected-line,
          .window.active .line.selected-line {
            background: var(--select-bg, #e7e9f1);
          }
          .linenum {
            flex: 0 0 30px; text-align: right;
            font-size: 11px; color: var(--linenum-fg, #b3ac9c);
            user-select: none;
          }
          .line-content { flex: 1; min-width: 0; white-space: pre-wrap; word-break: break-word; position: relative; }
          /* the editable surface: the browser's text pipeline feeds
             beforeinput intents; the server still draws the caret */
          .buf[contenteditable] { outline: none; caret-color: transparent; position: relative; }
          /* the ghost caret: where point stands while the page does not own
             the keyboard (a hollow box, as Emacs draws for an inactive frame) */
          .buf[contenteditable] .caret-ghost {
            display: none; position: absolute; width: 2px; pointer-events: none;
            box-shadow: inset 0 0 0 1px var(--cursor-bg, #26356b);
          }
          body.unfocused .window.active .buf[contenteditable] .caret-ghost { display: block; }
          .buf[contenteditable] .linenum { user-select: none; }
          /* while the surface owns the keyboard the browser draws the caret
             and the selection; the server's cursor block and region fall
             silent. Away from the keyboard the server's drawing returns,
             so a reader still sees where point stands. */
          .buf[contenteditable]:focus { caret-color: var(--cursor-bg, #26356b); }
          .buf[contenteditable]:focus .cursor {
            background: transparent; color: inherit; animation: none;
          }
          .buf[contenteditable]:focus .region { background: transparent; }
          .buf[contenteditable] ::selection { background: var(--region-bg, #e7e9f1); }
          /* Preview keeps markup hidden. Morg owns source editing. */
          .f-md-marker { display: none; }
          /* chrome: text the buffer does not hold, drawn beside the text;
             a zero-length island the caret walks over */
          .chrome-seg { user-select: none; white-space: nowrap; }
          .chrome-seg[phx-click] { cursor: pointer; }

          /* the block shapes of a drawn page: the marker stepped back, the
             row takes the shape */
          .line.row-li .line-content { padding-left: 1.4em; }
          .line.row-li .line-content::before {
            content: "\2022"; display: inline-block; width: 1.4em; margin-left: -1.4em;
            text-align: center; color: var(--dim-fg, #8a857a);
          }
          .line.row-oli .line-content { padding-left: 1.4em; text-indent: -1.4em; }
          .line.row-quote .line-content {
            border-left: 3px solid var(--border-bg, #cfc8b6); padding-left: 12px;
            color: var(--dim-fg, #57534a); font-style: italic;
          }
          .line.row-hr .line-content { position: relative; }
          .line.row-hr .line-content::after {
            content: ""; position: absolute; left: 0; right: 0; top: 50%;
            border-top: 1px solid var(--border-bg, #cfc8b6);
          }
          /* a block reads as one shape: its rows share a background and a
             left edge that hold in any theme (translucent grey) */
          .line.row-code .line-content, .line.row-fence .line-content {
            font-family: var(--font-mono);
            background: var(--window-inactive-bg, rgba(127, 127, 127, 0.09));
            border-left: 3px solid rgba(127, 127, 127, 0.28);
            padding-left: 10px; padding-right: 10px;
          }
          .line.row-code .line-content { font-size: .88em; }
          /* a picture's caption (markdown-mode md--caption): centred and
             small under the picture, as the page draws its figcaption */
          .line.row-caption .line-content { text-align: center; font-size: .9em; }
          /* a line that is one picture (row-picture): centred, as the
             page centres a figure's image */
          .line.row-picture .line-content { text-align: center; }
          .line.row-picture img.img-embed { margin: 6px 0; }
          .line.row-fence .line-content { font-size: .72em; color: var(--dim-fg, #8a857a); }
          /* hl-line-mode off: the current line draws like any other */
          .buf[data-hl-line="false"] .line.hl-line { background: transparent; }
          /* a table (markdown-mode md--table-row-spans): each source row is
             its own table box, so the columns divide the width evenly and
             line up down the run. Every bar is a cell of its own, which is
             what puts the text between two bars in a column of its own —
             a cell holding inline markup is several spans, and no one of
             them could carry the column. */
          .line.row-table .line-content {
            display: table; width: 100%; table-layout: fixed;
          }
          .line.row-table .f-md-table-bar {
            display: table-cell; width: 0; padding: 0 8px;
            overflow: hidden; color: transparent;
          }
          .line.row-table-head .line-content { font-weight: 600; }
          /* a CSV row keeps its columns at their width: the sheet scrolls
             right instead of folding into the window */
          .line.row-csv .line-content {
            width: max-content; min-width: 100%; table-layout: auto; white-space: nowrap;
          }
          .line.row-csv .f-md-table-bar { width: auto; padding: 0 12px; }
          /* the rule row draws the line under the head, as row-hr does */
          .line.row-table-rule .line-content { position: relative; }
          .line.row-table-rule .line-content::after {
            content: ""; position: absolute; left: 0; right: 0; top: 50%;
            border-top: 1px solid var(--border-bg, #cfc8b6);
          }
          /* visual-line-mode off: continuation lines, wrapped wherever the
             window ends (Emacs's default); on: wrapped at words */
          .buf[data-visual-lines="false"] .line-content { word-break: break-all; }
          /* whitespace-mode: a dot per space, a mark per tab, a pilcrow
             at the newline; every mark is paint, the text keeps its bytes */
          .f-ws-space {
            background-image: radial-gradient(circle, var(--dim-fg, #8a857a) 0.9px, transparent 1px);
            background-size: .5em 100%; background-position: center; background-repeat: repeat-x;
          }
          .f-ws-tab { position: relative; }
          .f-ws-tab::before {
            content: "»"; position: absolute; left: 0; color: var(--dim-fg, #8a857a);
            opacity: .6; pointer-events: none;
          }
          .buf[data-ws="true"] .line-content::after {
            content: "¶"; color: var(--dim-fg, #8a857a); opacity: .45;
            font-size: .85em; user-select: none; pointer-events: none;
          }
          /* an empty line carries a <br> to hold the caret. An inline mark
             after that <br> starts a second line box and makes the row twice
             as tall. Take the mark out of the flow and paint it at column 0. */
          .buf[data-ws="true"] .line-content:has(> .empty-row) { position: relative; }
          .buf[data-ws="true"] .line-content:has(> .empty-row)::after {
            position: absolute; left: 0; top: 0;
          }
          /* an X post island: the card in the URL's place */
          /* inline-level on purpose: the browser's caret motion walks a line
             of inline boxes; a block inside the row throws it off by lines */
          .x-card {
            display: inline-block; width: 100%; max-width: 480px; margin: 6px 0; padding: 12px 14px;
            vertical-align: top;
            border: 1px solid var(--border-bg, #e2dbc9); border-radius: 12px;
            font-family: var(--font-sans); font-size: 14px; line-height: 1.4;
            user-select: all;
          }
          .x-card .tw-head { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
          .x-card .tw-avatar { width: 36px; height: 36px; border-radius: 50%; }
          .x-card .tw-name { font-weight: 700; }
          .x-card .tw-handle { color: var(--dim-fg, #8a857a); margin-left: 6px; text-decoration: none; }
          .x-card .tw-text { margin: 0 0 8px; }
          .x-card .tw-media { max-width: 100%; border-radius: 8px; margin-top: 8px; }
          .x-card .tw-date { color: var(--dim-fg, #8a857a); font-size: 12px; text-decoration: none; }
          .x-card .x-pending { color: var(--dim-fg, #8a857a); font-family: var(--font-mono); font-size: 12px; }
          /* a YouTube island: an inert thumbnail that opens the video */
          .youtube-card {
            position: relative; display: inline-block; width: 100%; max-width: 640px;
            margin: 6px 0; overflow: hidden; vertical-align: top;
            border-radius: 8px; background: #111; color: white; text-decoration: none;
          }
          .youtube-card img { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; }
          .youtube-play {
            position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
            display: grid; place-items: center; width: 64px; height: 44px;
            border-radius: 12px; background: #f00; color: white;
            font: 24px/1 sans-serif; box-shadow: 0 2px 10px #0008;
          }
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
            border-bottom: 1px solid var(--border-bg, #e2dbc9);
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
            background: transparent;
            color: inherit;
            box-shadow: inset 0 0 0 1px var(--cursor-bg, #26356b);
            animation: none;
          }
          /* The frame does not own the keyboard, so the cursor stops
             blinking and goes hollow. It does NOT go away: a reader who
             looks at the editor from a terminal must still see where point
             stands, and Emacs draws a hollow box for the same reason. */
          body.unfocused .window.active .cursor {
            background: transparent !important;
            color: inherit !important;
            box-shadow: inset 0 0 0 1px var(--cursor-bg, #26356b);
            animation: none !important;
          }
          .no-nums .linenum { display: none; }
          /* an img-embed seg: the picture, in the text's place */
          /* a drawn link says it can be followed */
          .buf [data-href] { cursor: pointer; }
          .buf [data-href]:hover { text-decoration: underline; }

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
          .window.writing .modeline { opacity: 1; }
          /* HTML preview: sandboxed (no scripts), styles/images allowed */
          .html-preview {
            flex: 1; width: 100%; border: 0;
            background: var(--window-inactive-bg, #f4f0e6);
            /* a rendered page is its own document and reads no variable
               of ours; the buffer text scale zooms the frame instead */
            zoom: var(--text-scale-factor, 1);
          }
          .window.active .html-preview { background: var(--window-bg, #fdfcf8); }
          .file-preview {
            flex: 1; width: 100%; min-height: 0; border: 0;
            background: var(--window-bg, #fdfcf8);
          }
          /* an app paints its own background — the editor supplies none */
          .app-preview {
            flex: 1; width: 100%; min-height: 0; border: 0; background: #fff;
          }
          .region { background: var(--region-bg, #e7e9f1); }
          /* native drag-selection matches the editor region it becomes */
          ::selection { background: var(--region-bg, #e7e9f1); }
          /* --- block views -------------------------------------------------- */
          /* only the container: a mode composes blocks and ships its own
             stylesheet via define-style! (diff-mode.scm is the precedent) */
          .blocks-view { flex: 1; display: flex; flex-direction: column; min-height: 0; }
          .blocks-scroll { flex: 1; overflow-y: auto; padding: 10px 12px 8px; }
          /* --- agent transcript (the Modern Emacs agent-chat design) ------- */
          .agent-view {
            flex: 1; display: flex; flex-direction: column; min-height: 0;
            font-size: calc(var(--default-size, 13px) * var(--text-scale-factor, 1));
          }
          .ag-scroll { flex: 1; overflow-y: auto; padding: 14px 18px 6px; }
          .ag-label {
            font-family: var(--font-mono); font-size: calc(10px * var(--text-scale-factor, 1)); letter-spacing: 0.12em;
            color: var(--agent-meta-fg, #8a8577); flex-shrink: 0; padding-top: 3px;
          }
          .ag-user {
            display: flex; gap: 12px; margin: 10px 0;
            background: var(--agent-you-bg, rgba(99, 110, 200, 0.10));
            border-radius: 8px; padding: 8px 12px;
          }
          .ag-user-text {
            min-width: 0; font-family: var(--font-mono); font-size: calc(12.5px * var(--text-scale-factor, 1));
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
            font-family: var(--font-serif); font-size: calc(15px * var(--text-scale-factor, 1)); line-height: 1.6;
            margin: 8px 0; overflow-wrap: break-word;
          }
          .ag-prose > * { max-width: 62ch; }
          .ag-prose > pre, .ag-prose > .ag-table, .ag-prose > .code-block { max-width: 100%; }
          .ag-prose .code-block pre { margin: 6px 0; }
          .ag-prose code, .ag-prose pre {
            font-family: var(--font-mono); font-size: calc(12px * var(--text-scale-factor, 1));
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
            font-family: var(--font-sans); font-size: calc(13px * var(--text-scale-factor, 1));
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
            border-radius: 7px; font-family: var(--font-mono); font-size: calc(12px * var(--text-scale-factor, 1));
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
            font-family: var(--font-sans); font-size: calc(17px * var(--text-scale-factor, 1)); line-height: 1;
            transform: rotate(0deg); transition: transform 100ms ease;
          }
          .ag-tool[open] .ag-chevron { transform: rotate(90deg); }
          .ag-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--agent-meta-fg, #999); }
          .ag-dot.running { background: var(--warn-fg, #e0af68); animation: ag-pulse 1.2s ease-in-out infinite; }
          .ag-dot.done { background: var(--ok-fg, #4a7a4a); }
          .ag-dot.failed { background: var(--alert-fg, #a8342a); }
          .ag-kind {
            padding: 1px 5px; border-radius: 4px; color: var(--agent-tool-fg, #26356b);
            background: color-mix(in srgb, var(--agent-tool-fg, #26356b) 10%, transparent);
            font-family: var(--font-sans); font-size: calc(9px * var(--text-scale-factor, 1)); font-weight: 700;
            letter-spacing: 0.05em; text-transform: uppercase;
          }
          .ag-summary-copy {
            display: flex; flex: 1; min-width: 0; flex-direction: column;
            justify-content: center; gap: 1px;
          }
          .ag-title {
            display: block; min-width: 0; overflow: hidden; text-overflow: ellipsis;
            white-space: nowrap; color: var(--window-fg, inherit); font-size: calc(11.5px * var(--text-scale-factor, 1));
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
            font-family: var(--font-mono); font-size: calc(10px * var(--text-scale-factor, 1)); line-height: 1.25;
          }
          .ag-preview::before { content: "↳ "; color: var(--agent-tool-fg, #26356b); }
          .ag-tstatus {
            color: var(--agent-meta-fg, #8a8577); font-family: var(--font-sans);
            font-size: calc(9.5px * var(--text-scale-factor, 1)); letter-spacing: 0.02em;
          }
          .ag-tstatus.done::before { content: "✓ "; color: var(--ok-fg, #4a7a4a); }
          .ag-tstatus.failed { color: var(--alert-fg, #a8342a); }
          .ag-duration {
            color: var(--agent-meta-fg, #8a8577); font-family: var(--font-sans);
            font-size: calc(9.5px * var(--text-scale-factor, 1)); letter-spacing: 0.02em;
            white-space: nowrap;
          }
          .ag-body {
            border-top: 1px solid var(--agent-card-border, rgba(0,0,0,0.08));
            margin: 0; padding: 10px 12px; overflow-x: auto; max-height: 320px; overflow-y: auto;
            white-space: pre-wrap; overflow-wrap: anywhere; color: var(--agent-thought-fg, #6a675e);
            background: color-mix(in srgb, var(--agent-code-bg, rgba(0,0,0,0.06)) 60%, transparent);
          }
          .ag-thought summary { color: var(--agent-thought-fg, #8a8577); font-size: calc(10.5px * var(--text-scale-factor, 1)); }
          .ag-thought-text { padding: 6px 10px; white-space: pre-wrap; color: var(--agent-thought-fg, #8a8577); }
          .ag-plan {
            font-family: var(--font-mono); font-size: calc(12px * var(--text-scale-factor, 1)); margin: 8px 0;
            padding: 8px 12px; border-left: 2px solid var(--agent-card-border, rgba(0,0,0,0.15));
            white-space: pre-wrap;
          }
          .ag-perm {
            display: flex; align-items: center; gap: 10px; margin: 10px 0;
            border: 1px solid var(--agent-permission-fg, #e0af68); border-radius: 8px;
            padding: 8px 12px; font-family: var(--font-mono); font-size: calc(12px * var(--text-scale-factor, 1));
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
            margin-top: 9px; color: var(--agent-meta-fg, #8a8577); font-size: calc(10px * var(--text-scale-factor, 1));
          }
          .ag-btn {
            font-family: var(--font-mono); font-size: calc(11px * var(--text-scale-factor, 1)); padding: 3px 12px;
            border-radius: 6px; border: 1px solid var(--agent-card-border, rgba(0,0,0,0.2));
            background: transparent; color: inherit; cursor: pointer;
          }
          /* bb's hierarchy: affirmative filled, session-scope outlined, deny
             a quiet ghost that stays visible without competing */
          .ag-btn.allow {
            background: var(--ok-fg, #4a7a4a); border-color: var(--ok-fg, #4a7a4a);
            color: var(--window-bg, #fdfcf8); font-weight: 600;
          }
          .ag-btn.session { border-color: var(--ok-fg, #4a7a4a); color: var(--ok-fg, #4a7a4a); }
          .ag-btn.deny { border-color: transparent; color: var(--alert-fg, #a8342a); opacity: 0.8; }
          .ag-wait {
            font-family: var(--font-mono); font-size: calc(12px * var(--text-scale-factor, 1)); margin: 8px 0;
            color: var(--agent-thought-fg, #8a8577); animation: ag-pulse 1.4s ease-in-out infinite;
          }
          /* the turn pulse under the transcript: outside .ag-scroll, so it
             aligns with the input row, not the padded scroll area */
          .ag-activity { margin: 2px 18px 4px; flex-shrink: 0; }
          @keyframes ag-shimmer {
            0%, 18% { transform: translateX(-120%); }
            82%, 100% { transform: translateX(120%); }
          }
          .ag-meta { font-family: var(--font-mono); font-size: calc(11.5px * var(--text-scale-factor, 1)); color: var(--agent-meta-fg, #8a8577); margin: 6px 0; }
          @keyframes ag-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }
          .ag-inputrow {
            display: flex; align-items: baseline; gap: 12px; margin: 6px 14px 12px;
            border: 1px solid var(--agent-card-border, rgba(0,0,0,0.14));
            border-radius: 10px; padding: 9px 14px;
            background: var(--window-bg, rgba(255,255,255,0.5));
          }
          .ag-input {
            flex: 1; min-width: 0; font-family: var(--font-mono); font-size: calc(12.5px * var(--text-scale-factor, 1));
            white-space: pre-wrap; overflow-wrap: anywhere;
          }
          .ag-queued { color: var(--agent-queued-fg, #9a958a); }
          /* queued rows under the transcript: outside .ag-scroll, so they
             align with the input row, not the padded scroll area */
          .ag-queued-row { margin: 2px 18px; flex-shrink: 0; }
          .ag-hint { font-family: var(--font-mono); font-size: calc(10px * var(--text-scale-factor, 1)); color: var(--agent-meta-fg, #8a8577); flex-shrink: 0; }
          .ml-extra {
            display: flex; align-items: center; gap: 12px;
            font-family: var(--font-mono); font-size: 11px; padding: 0 8px;
            white-space: nowrap;
          }
          .ml-extra .ml-segment { color: var(--dim-fg, #8a857a); }
          .ml-extra .ml-attention { color: var(--agent-permission-fg, #a8741a); font-weight: 600; }
          /* font-lock scopes (tree-sitter): the .ts-SCOPE rules come from the
             ts-SCOPE faces, see Compos.Ui.FaceCSS. A theme or a defface! owns
             every syntax colour, weight and slant. */
          .modeline {
            display: flex; align-items: center; gap: 8px;
            min-height: 32px; padding: 0 12px;
            flex-shrink: 0;
            background: var(--modeline-bg, #ded9ca);
            color: var(--modeline-fg, #34322c);
            font-size: 12px;
          }
          .window.active .modeline {
            background: var(--modeline-active-bg, #e1e5f1);
            color: var(--modeline-active-fg, #18203f);
          }
          .window.buffer-selected .modeline {
            box-shadow: inset 3px 0 var(--accent-fg, #26356b);
          }
          .window.buffer-selected {
            outline: 2px solid var(--accent-fg, #26356b);
            outline-offset: -2px;
          }
          .window.buffer-selected .modeline {
            box-shadow: inset 3px 0 var(--accent-fg, #26356b);
          }
          .dash-live {
            display: flex; gap: 16px; padding: 6px 16px;
            font-family: var(--font-mono); font-size: 10.5px;
            color: var(--dim-fg, #8a857a);
            border-bottom: 1px solid var(--border-bg, #e2dbc9);
          }
          .dash-live-mod { color: var(--warn-fg, #7a5a1a); }
          .dash-top {
            flex: 0 0 auto; max-height: 46%; overflow-y: auto;
            background: var(--window-inactive-bg, #f4f0e6);
            border-bottom: 1px solid var(--border-bg, #e2dbc9);
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
          .modeline .name { font-weight: 700; color: var(--buffer-group-color, inherit); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
          .ml-icon { display: inline-block; min-width: 1.1em; color: var(--accent-fg, #26356b); font-weight: 700; text-align: center; }
          .ml-pos { font-family: var(--font-mono); font-size: 11px; opacity: 1; white-space: nowrap; }
          .ml-mode { font-family: var(--font-mono); font-size: 11px; opacity: 1; white-space: nowrap; }
          .ml-group-item { color: var(--buffer-group-color, var(--accent-fg, #26356b)); }
          .ml-state-modified { color: var(--warn-fg, #7a5a1a); font-weight: 600; }
          .ml-info { color: inherit; }
          .ml-toggle { cursor: pointer; }
          .ml-toggle:hover { opacity: 1; text-decoration: underline; }
          .ml-group {
            font-family: var(--font-mono); font-size: 10.5px;
            color: var(--buffer-group-color, var(--accent-fg, #26356b)); opacity: 0.85;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
            max-width: 16ch; flex: 0 1 auto;
          }
          .echo-bar {
            display: flex; align-items: baseline; gap: 14px;
            min-height: 30px; padding: 7px 14px 8px;
            flex-shrink: 0;
            background: var(--window-bg, #fdfcf8);
            border-bottom: 1px solid var(--border-bg, #cbc4b1);
            font-family: var(--font-mono); font-size: 12.5px;
          }
          .echo { color: var(--dim-fg, #57534a); white-space: pre; }
          .ml-frame-path {
            min-width: 0; max-width: 62vw; overflow: hidden; text-overflow: ellipsis;
            color: var(--dim-fg, #57534a); font-size: 11px; white-space: nowrap;
          }
          .ml-frame-group {
            color: var(--frame-group-color, var(--accent-fg, #26356b)); font-size: 11px;
            font-weight: 650; white-space: nowrap;
          }
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
            border: 1px solid var(--border-bg, #e2dbc9);
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
            border-bottom: 1px solid var(--border-bg, #e2dbc9);
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
            padding: 13px 16px 11px; border-bottom: 1px solid var(--border-bg, #e2dbc9);
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
            padding: 9px 16px 10px; border-top: 1px solid var(--border-bg, #e2dbc9);
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
            border-left: 1px solid var(--border-bg, #e2dbc9);
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
            border: 1px solid var(--border-bg, #e2dbc9); border-radius: 10px;
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
            border: 1px solid var(--border-bg, #e2dbc9);
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
          /* a section heading inside the candidate list: it labels the rows
             under it and never takes the selection */
          .mb-sep {
            grid-column: 1 / -1;
            display: flex; align-items: center; gap: 9px;
            padding: 9px 14px 4px;
          }
          .mb-sep-label {
            font-family: var(--font-mono); font-size: 9.5px;
            letter-spacing: 0.15em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a); white-space: nowrap;
          }
          .mb-sep::after {
            content: ""; flex: 1; height: 1px;
            background: var(--border-bg, #e2dbc9);
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
          .mb-cand.selected .mb-label:not([class*="f-group-color-"]) { color: var(--accent-fg, #26356b); }
          .mb-cand.selected .mb-label { font-weight: 600; }
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
            border-top: 1px solid var(--border-bg, #e2dbc9);
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
            max-height: 44vh;
            overflow-y: auto;
            animation: rise 120ms ease-out;
          }
          .wk-title {
            display: flex; justify-content: space-between; gap: 18px;
            font-family: var(--font-mono); font-size: 10px;
            letter-spacing: 0.14em; text-transform: uppercase;
            color: var(--dim-fg, #8a857a); padding-bottom: 8px;
          }
          .wk-filter { letter-spacing: 0.04em; text-transform: none; }
          .wk-groups { display: flex; flex-direction: column; gap: 10px; }
          .wk-group[hidden] { display: none; }
          .wk-item[hidden] { display: none; }
          .wk-empty {
            padding: 10px 0 3px;
            color: var(--dim-fg, #8a857a);
            font-family: var(--font-mono); font-size: 12px;
          }
          .wk-group-title {
            display: flex; align-items: baseline; gap: 7px;
            margin: 0 0 4px; padding-bottom: 3px;
            border-bottom: 1px solid var(--border-bg, #e2dbc9);
            color: var(--accent-fg, #26356b);
            font-family: var(--font-mono); font-size: 11px;
            letter-spacing: 0.08em; text-transform: uppercase;
          }
          .wk-group-title span {
            color: var(--dim-fg, #8a857a); font-size: 9px; font-weight: 400;
          }
          .wk-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
            gap: 3px 22px;
          }
          .wk-item {
            display: grid; grid-template-columns: minmax(8ch, auto) 1fr;
            align-items: baseline; gap: 8px;
            min-width: 0; font-family: var(--font-mono); font-size: 12px;
          }
          .wk-key {
            justify-self: start;
            min-width: 3ch; padding: 1px 5px;
            border: 1px solid var(--border-bg, #d8d0c0); border-radius: 3px;
            background: var(--select-bg, #e7e9f1);
            color: var(--accent-fg, #26356b); font-weight: 700;
          }
          .wk-cmd {
            min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
            color: var(--dim-fg, #57534a);
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script src="/phx/phoenix.min.js"></script>
        <script src="/lv/phoenix_live_view.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-webgl@0.18.0/lib/addon-webgl.min.js"></script>
        <script>
          // Which zoom math keeps the root exactly one viewport tall?
          // Chrome leaves 100dvh unzoomed (the height must divide by the
          // zoom); the observed WebKit shrinks it by the zoom (the height
          // must multiply); a compensating engine needs neither. Measure a
          // probe element once and stamp the class the CSS reads.
          (() => {
            const d = document.createElement("div");
            d.style.cssText = "position:absolute;visibility:hidden;zoom:2;height:100dvh;";
            document.body.appendChild(d);
            const f = d.getBoundingClientRect().height / innerHeight;
            d.remove();
            if (f > 1.5) document.documentElement.classList.add("zoom-divides");
            else if (f < 0.75) document.documentElement.classList.add("zoom-multiplies");
          })();

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

          const SHIFTED_DIGITS = ")!@#$%^&*(";

          function baseKey(e) {
            if (e.altKey) {
              if (e.code.startsWith("Key")) return e.code.slice(3).toLowerCase();
              if (e.code.startsWith("Digit")) return e.code.slice(5);
              if (CODE_CHARS[e.code]) return CODE_CHARS[e.code][e.shiftKey ? 1 : 0];
            }
            // macOS reports a Cmd chord with the unshifted character:
            // Cmd-Shift-= arrives as key "=" with shiftKey set, and the
            // buffer scale on s-+ never fires. The physical key says
            // which character shift makes, so a shifted Cmd chord reads
            // its character from e.code, the way an Alt chord does.
            if (e.metaKey && e.shiftKey) {
              if (e.code.startsWith("Key")) return e.code.slice(3).toUpperCase();
              if (e.code.startsWith("Digit")) return SHIFTED_DIGITS[Number(e.code.slice(5))];
              if (CODE_CHARS[e.code]) return CODE_CHARS[e.code][1];
            }
            if (NAMED[e.key]) return NAMED[e.key];
            if (e.key.length === 1) return e.key;
            return null;
          }

          // cmd combos belong to the browser (cmd-c/v/q, and cmd-v's native
          // paste event) — except the arrows, claimed for window motion,
          // and cmd-p, claimed for the command palette
          // ...and the text-scale chords, claimed from the browser's
          // whole-page zoom: cmd-=/-/0 scale the application (appearance.scm
          // ui-scale), and their shifted shapes cmd-+/_/) scale ONE buffer.
          // The list names the BASE the key travels as (baseKey), so a
          // named key appears in its Emacs spelling: "<up>", not "ArrowUp".
          const CMD_KEYS = ["<left>", "<right>", "<up>", "<down>",
                            "a", "p", "+", "=", "-", "0", "_", ")", "RET"];

          function keySpec(e) {
            if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return null;
            const base = baseKey(e);
            if (base === null) return null;
            // the claim reads the base, not e.key: Cmd-Shift-= is "+"
            if (e.metaKey && !CMD_KEYS.includes(base)) return null;
            let spec = base;
            // S- only for named keys (TAB, arrows, RET...): printable chars
            // already encode shift in the character itself, Emacs-style
            if (e.shiftKey && base.length > 1) spec = "S-" + spec;
            if (e.altKey) spec = "M-" + spec;
            if (e.ctrlKey) spec = "C-" + spec;
            if (e.metaKey) spec = "s-" + spec; // s- = super = Cmd
            return spec;
          }

          // A key the browser's text pipeline should keep, because an
          // editable buffer surface has focus: a printable character, a
          // dead key or input-method key, and plain Enter, Backspace and
          // Delete. Everything with a modifier, TAB, ESC, and the motion
          // keys still travel as keys (keySpec).
          // The browser also owns caret motion on that surface: the arrows,
          // Home and End, with or without Shift. It moves by its own layout,
          // keeps the goal column across short lines, and the selection it
          // leaves is reported as bytes (selectionchange).
          // The page keys are NOT its. Chrome scrolls the editable box and
          // leaves the caret where it was, so a page key that stayed native
          // moved point nowhere and reported no selection. They travel as
          // <prior> and <next>, and Scheme pages by visual rows.
          const NATIVE_MOTION = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
                                 "Home", "End"];
          function nativeTextKey(e) {
            const a = document.activeElement;
            if (!a || !a.closest || !a.closest(".buf[contenteditable]")) return false;
            // Cmd-Left/Right are the platform's line start and end; a server
            // round trip for them read as lag. Cmd-Up/Down stay keys: they
            // are window motion outside prose. Window motion left and right
            // from an editable buffer is the command, windmove-left and
            // windmove-right, on a chord a keymap picks
            // (windmove-default-keybindings).
            if (e.metaKey && !e.ctrlKey && !e.altKey &&
                (e.key === "ArrowLeft" || e.key === "ArrowRight")) return true;
            if (e.ctrlKey || e.altKey || e.metaKey) return false;
            if (e.key === "Dead" || e.key === "Process" || e.key === "Unidentified") return true;
            if (e.key.length === 1) return true;
            if (NATIVE_MOTION.includes(e.key)) return true;
            return !e.shiftKey && (e.key === "Enter" || e.key === "Backspace" || e.key === "Delete");
          }

          const WHICH_KEY_MODIFIERS = {
            "Control": "C", "Alt": "M", "Shift": "S", "Meta": "s"
          };
          const WHICH_KEY_MODIFIER_LABELS = {
            "C": "Control", "M": "Meta", "S": "Shift", "s": "Super"
          };

          function heldWhichKeyModifiers(e) {
            const held = [];
            if (e.ctrlKey) held.push("C");
            if (e.altKey) held.push("M");
            if (e.shiftKey) held.push("S");
            if (e.metaKey) held.push("s");
            return held;
          }

          // The page carries one .ln marker per source line that draws text.
          // The marker above a caret names that line's byte offset, and the
          // rendered text between the two says how far along the line the
          // caret sits. Point then follows the source, and rows the source
          // does not own — a code block's head, an embed — carry
          // data-chrome and are skipped instead.
          // The exact answer, when the page carries one. Every run of drawn
          // text says the source byte it began at, and a run is the source's
          // own bytes, so the caret's byte is that offset plus the bytes of
          // the text before it. No counting back to a line mark, and nothing
          // to be wrong by: markup the renderer took out is not in the run.
          const utf8 = new TextEncoder();
          const PREVIEW_UTF8 = utf8;
          const CARET_RE = /<span class="pt"><\/span>/g;

          // The caret at a soft wrap. Point is the first byte of the lower
          // row, and the wrap map says so, because the map measures
          // characters. The caret is an empty box, and Chrome draws an
          // empty box at a wrap at the end of the row ABOVE. So
          // beginning-of-line drew the caret at the end of the row before,
          // and the next press could move nothing. The caret stays where
          // it is in the document and is shifted to the box of the
          // character after it; relative position moves nothing else.
          function settleCaret(d) {
            const pt = d.querySelector(".pt");
            if (!pt) return;
            pt.style.position = "";
            pt.style.left = "";
            pt.style.top = "";
            // the first drawn character after the caret. The renderer cuts
            // the run at the caret, so that character usually begins the
            // next run, not the next text node.
            const walker = d.createTreeWalker(d.body, NodeFilter.SHOW_TEXT);
            walker.currentNode = pt;
            let next = walker.nextNode();
            while (next && !next.textContent.length) next = walker.nextNode();
            if (!next) return;
            // a caret before a space is at a row's end, never its start: a
            // hanging space reports a box on the row below, and that box
            // is not where the caret belongs
            if (/\s/.test(next.textContent[0])) return;
            const r = d.createRange();
            r.setStart(next, 0);
            r.setEnd(next, 1);
            const cr = r.getClientRects()[0];
            const pr = pt.getBoundingClientRect();
            if (!cr || cr.top <= pr.top + Math.max(2, pr.height * 0.5)) return;
            pt.style.position = "relative";
            pt.style.left = (cr.left - pr.left) + "px";
            pt.style.top = (cr.top - pr.top) + "px";
          }

          // take the caret out, leaving the text it split as one node
          function removeCaret(d) {
            const old = d.querySelector(".pt");
            if (!old) return;
            const host = old.parentNode;
            old.remove();
            if (host) host.normalize();
          }

          function exactSpot(d, node, off) {
            const el = node.nodeType === 1 ? node : node.parentElement;
            const run = el && el.closest && el.closest("span.s[data-s]");
            if (!run) return null;
            const at = parseInt(run.dataset.s, 10);
            if (!Number.isFinite(at)) return null;

            const upto = d.createRange();
            upto.setStart(run, 0);
            upto.setEnd(node, off);

            // whitespace-mode paints its marks with CSS, so the text in the
            // range is the source's own bytes and nothing has to be taken
            // back out of the count
            return at + utf8.encode(upto.toString()).length;
          }

          // Raw HTML has no renderer-owned source spans. Use the clicked
          // text fragment and its page occurrence to find the same text in
          // the source. This keeps HTML editing on the normal buffer path.
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

          // The image a probe landed on, and the source byte it names. A
          // probe over a picture answers with the element that holds it and
          // the index of the picture inside it, not with a text node.
          function imageAt(node, off) {
            let el = null;
            if (node.nodeType === 1) {
              el = node.tagName === "IMG"
                ? node
                : (node.children && node.children[off]) || null;
            } else if (node.nodeType === 3) {
              return null;
            }
            if (!el || el.tagName !== "IMG") return null;
            const at = parseInt(el.dataset.s, 10);
            return Number.isFinite(at) ? at : null;
          }

          function isChrome(node) {
            const el = node && (node.nodeType === 1 ? node : node.parentElement);
            return !!(el && el.closest && el.closest("[data-chrome], .code-block-head, .tweet"));
          }

          const PAGE_BOOT = document.querySelector("meta[name='boot-id']").getAttribute("content");

          // Telemetry, the browser's layer. Every key and intent push carries
          // a trace id, and this measures what the server cannot see: the
          // round trip of the push, the DOM patch after the reply, the paint
          // of an input event (Event Timing), and long tasks. The rows go to
          // the daemon once a second and land in M-x telemetry beside the
          // Scheme lanes and the LiveView events of the same trace id.
          // Every step is guarded: a failure here must never cost a key.
          const Telem = {
            boot: Math.random().toString(36).slice(2, 6),
            seq: 0,
            rows: [],
            open: {},
            capture: null,
            lastRaw: { at: 0, bytes: 0 },
            hook: null,
            wrapped: false,
            tid() { return this.boot + ":" + (++this.seq); },
            now() { return performance.now(); },
            epoch(at) { return Math.round(performance.timeOrigin + at); },
            row(kind, label, ms, wait, tid, detail, at) {
              this.rows.push({
                k: kind, l: label, ms: Math.round(ms), wait: Math.round(wait || 0),
                tid: tid || null, d: detail || "", t: this.epoch(at == null ? this.now() : at)
              });
              if (this.rows.length > 500) this.rows.splice(0, this.rows.length - 500);
            },
            // the socket ref of the push is made inside pushEvent, so a
            // wrapper on makeRef pairs the next ref with the open trace
            wrap() {
              if (this.wrapped) return;
              try {
                const sock = liveSocket.getSocket();
                const makeRef = sock.makeRef.bind(sock);
                sock.makeRef = () => {
                  const ref = makeRef();
                  if (Telem.capture) { Telem.open[Telem.capture].ref = ref; Telem.capture = null; }
                  return ref;
                };
                const onConn = sock.onConnMessage.bind(sock);
                sock.onConnMessage = (raw) => {
                  Telem.lastRaw = { at: Telem.now(), bytes: raw && raw.data ? raw.data.length : 0 };
                  // the biggest reply since the last look, for a person who
                  // asks what a patch carried: composTelemetry.sample()
                  if (Telem.lastRaw.bytes > (Telem.big ? Telem.big.length : 0)) Telem.big = raw.data;
                  return onConn(raw);
                };
                sock.onMessage((msg) => {
                  if (!msg || !msg.ref) return;
                  for (const tid in Telem.open) {
                    const o = Telem.open[tid];
                    if (o.ref === msg.ref) { o.recv = Telem.lastRaw.at; o.bytes = Telem.lastRaw.bytes; }
                  }
                });
                this.wrapped = true;
              } catch (err) {}
            },
            // a traced push: the label is the key or the intent type, the
            // wait is the server round trip, the detail is the patch and
            // the reply size
            push(hook, event, payload) {
              let tid = null;
              try {
                this.wrap();
                tid = this.tid();
                payload.tid = tid;
                const t0 = this.now();
                this.open[tid] = { t0, ref: null, recv: null, bytes: 0 };
                this.capture = tid;
                const label = event === "key" ? "key " + payload.k : "intent " + payload.type;
                hook.pushEvent(event, payload, () => {
                  try {
                    const done = this.now();
                    const o = this.open[tid] || { t0, recv: null, bytes: 0 };
                    delete this.open[tid];
                    const recv = o.recv == null ? done : o.recv;
                    this.row("push", label, done - t0, recv - t0, tid,
                      "patch " + Math.round(done - recv) + "ms " + o.bytes + "b", t0);
                  } catch (err) {}
                });
              } catch (err) {
                this.capture = null;
                if (tid) delete this.open[tid];
                hook.pushEvent(event, payload);
              }
            },
            observe() {
              try {
                new PerformanceObserver((list) => {
                  for (const e of list.getEntries()) {
                    if (!/^(keydown|keypress|keyup|beforeinput|input|compositionupdate)$/.test(e.name)) continue;
                    const delay = e.processingStart - e.startTime;
                    const handlers = e.processingEnd - e.processingStart;
                    const present = e.startTime + e.duration - e.processingEnd;
                    Telem.row("paint", "paint " + e.name, e.duration, delay, null,
                      "delay " + Math.round(delay) + "ms handlers " + Math.round(handlers) +
                      "ms present " + Math.round(present) + "ms", e.startTime);
                  }
                }).observe({ type: "event", durationThreshold: 16 });
              } catch (err) {}
              try {
                new PerformanceObserver((list) => {
                  for (const e of list.getEntries()) {
                    // which document ran it: the page itself, or an iframe
                    // (a preview, an app, a PDF) named by its src or id
                    const a = (e.attribution && e.attribution[0]) || {};
                    const who = [a.containerType, a.containerName, a.containerId,
                      a.containerSrc ? String(a.containerSrc).slice(0, 60) : ""]
                      .filter((x) => x).join(" ");
                    Telem.row("longtask", "longtask", e.duration, 0, null, who, e.startTime);
                  }
                }).observe({ type: "longtask" });
              } catch (err) {}
            },
            // one piece of the client's own work, by name: the row says
            // what ran after a patch and how long it held the main thread.
            // Under 4ms is noise and is not reported.
            time(label, fn) {
              const t0 = this.now();
              try { return fn(); }
              finally {
                const ms = this.now() - t0;
                if (ms >= 4) this.row("client", "client " + label, ms, 0, null, "", t0);
              }
            },
            // the report itself is not traced: the server records it and
            // renders nothing
            flush() {
              if (!this.hook || this.rows.length === 0) return;
              const rows = this.rows;
              this.rows = [];
              try { this.hook.pushEvent("telemetry", { rows }); } catch (err) {}
            },
            sample() { const b = this.big || ""; this.big = null; return b; },
            attach(hook) {
              this.hook = hook;
              if (!this.timer) {
                this.observe();
                this.timer = setInterval(() => this.flush(), 1000);
              }
            },
            detach(hook) {
              if (this.hook === hook) this.hook = null;
            }
          };
          window.composTelemetry = Telem;

          const Hooks = {
            Terminal: {
              mounted() {
                if (!window.Terminal || !window.FitAddon) {
                  this.el.textContent = "Terminal assets did not load.";
                  return;
                }

                const styles = getComputedStyle(this.el.closest(".window"));
                const color = (name, fallback) => styles.getPropertyValue(name).trim() || fallback;
                this.term = new window.Terminal({
                  cursorBlink: true,
                  scrollback: 10000,
                  fontFamily: color("--font-mono", "ui-monospace, Menlo, monospace"),
                  fontSize: 13,
                  lineHeight: 1.15,
                  theme: {
                    background: color("--window-bg", "#111318"),
                    foreground: color("--default-fg", "#e6e1d8"),
                    cursor: color("--cursor-bg", "#d6b95e"),
                    selectionBackground: color("--select-bg", "#36405a")
                  }
                });
                this.fitAddon = new window.FitAddon.FitAddon();
                this.term.loadAddon(this.fitAddon);
                this.term.open(this.el);
                if (window.WebglAddon) {
                  try {
                    this.webglAddon = new window.WebglAddon.WebglAddon();
                    this.webglAddon.onContextLoss(() => this.webglAddon.dispose());
                    this.term.loadAddon(this.webglAddon);
                  } catch (_) { this.webglAddon = null; }
                }

                this.socket = new Phoenix.Socket("/terminal", {});
                this.socket.connect();
                this.channel = this.socket.channel("terminal", { buffer: this.el.dataset.buffer });
                const write64 = (encoded) => {
                  if (!encoded || !this.term) return;
                  const raw = atob(encoded);
                  const bytes = Uint8Array.from(raw, c => c.charCodeAt(0));
                  this.term.write(bytes);
                };
                this.channel.on("output", ({ data }) => write64(data));
                this.channel.on("exit", ({ status }) => {
                  this.term.write(`\r\n\x1b[90m[process exited: ${status}]\x1b[0m\r\n`);
                });
                this.channel.join()
                  .receive("ok", ({ history }) => write64(history))
                  .receive("error", ({ reason }) => {
                    this.term.write(`\r\n[terminal unavailable: ${reason}]\r\n`);
                  });

                this.dataSub = this.term.onData(data => this.channel.push("input", { data }));
                this.editorSequence = false;
                this.keyboardOwnerH = (event) => {
                  const owner = event.detail && event.detail.terminal;
                  const owns = owner === this.el.id;
                  this.editorSequence = !owns;
                  if (owns && document.hasFocus()) this.term.focus();
                };
                window.addEventListener("compos:keyboard-owner", this.keyboardOwnerH);
                this.term.attachCustomKeyEventHandler((e) => {
                  if (e.metaKey && e.key.toLowerCase() === "c" && this.term.hasSelection()) {
                    navigator.clipboard.writeText(this.term.getSelection());
                    return false;
                  }

                  const spec = keySpec(e);
                  // Browser commands remain browser commands. Returning false
                  // without preventing the event lets Cmd-R/L/T/W and native
                  // clipboard handling continue outside xterm.
                  if (spec === null && e.metaKey) return false;
                  const editorOpen = !!document.querySelector(
                    ".mb-panel, .which-key, .transient-panel"
                  );
                  const editorEntry = ["C-x", "M-x", "C-g", "C-`", "C-M-`", "s-p"].includes(spec);
                  if (spec && (this.editorSequence || editorOpen || editorEntry)) {
                    e.preventDefault();
                    this.editorSequence = true;
                    Telem.push(this, "key", { k: spec });
                    return false;
                  }
                  return true;
                });

                this.fit = () => {
                  if (!this.term || !this.fitAddon) return;
                  this.fitAddon.fit();
                  this.channel.push("resize", { cols: this.term.cols, rows: this.term.rows });
                };
                this.observer = new ResizeObserver(() => {
                  cancelAnimationFrame(this.fitFrame);
                  this.fitFrame = requestAnimationFrame(this.fit);
                });
                this.observer.observe(this.el);
                requestAnimationFrame(() => {
                  this.fit();
                  const active = this.el.closest(".window")?.classList.contains("active");
                  const editorOpen = document.querySelector(
                    ".mb-panel, .which-key, .transient-panel"
                  );
                  if (active && !editorOpen && document.hasFocus()) this.term.focus();
                });
              },
              destroyed() {
                if (this.observer) this.observer.disconnect();
                if (this.dataSub) this.dataSub.dispose();
                window.removeEventListener("compos:keyboard-owner", this.keyboardOwnerH);
                if (this.channel) this.channel.leave();
                if (this.socket) this.socket.disconnect();
                if (this.term) this.term.dispose();
                cancelAnimationFrame(this.fitFrame);
              }
            },
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
                  // the document is only now scrollable: put the reader's
                  // saved offset back, the same as a line window does
                  this.apply();
                  if (window.composRemeasure) window.composRemeasure();
                };
                this.el.addEventListener("load", this.onLoad);
                this.syncDoc();
                this.attach();
                this.apply();
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

                // Moving the caret used to rebuild the document: DOMParser
                // read 235kB, innerHTML read it again, and 5000 elements
                // laid out afresh - on every keystroke, and that was the
                // judder. When the page differs only in where the caret is,
                // move the caret. Every run of text says the source byte it
                // began at, so the caret's new home is a lookup.
                const caretOnly =
                  this.lastHtml &&
                  html.replace(CARET_RE, "") === this.lastHtml.replace(CARET_RE, "");

                if (caretOnly && this.placeCaret(d, this.el.dataset.pt)) {
                  settleCaret(d);
                  this.lastDoc = encoded;
                  this.lastHtml = html;
                  return;
                }

                const next = new DOMParser().parseFromString(html, "text/html");
                d.documentElement.innerHTML = next.documentElement.innerHTML;
                settleCaret(d);
                this.lastDoc = encoded;
                this.lastHtml = html;
              },

              // Put the caret at source byte POINT, in the run that owns it.
              // Answers false when the page cannot say where that is, and
              // the caller rebuilds instead.
              placeCaret(d, point) {
                const at = parseInt(point, 10);
                if (!Number.isFinite(at)) return false;

                // the old caret first, so the run it split is one text node
                removeCaret(d);

                let target = null;
                let within = 0;
                for (const run of d.querySelectorAll("span.s[data-s]")) {
                  const start = parseInt(run.dataset.s, 10);
                  if (!Number.isFinite(start) || start > at) continue;
                  const len = PREVIEW_UTF8.encode(run.textContent).length;
                  if (at <= start + len) { target = run; within = at - start; }
                }
                if (!target) return false;

                const node = target.firstChild;
                if (!node || node.nodeType !== 3) return false;

                // bytes to characters: the split has to fall on a character
                let chars = 0;
                let bytes = 0;
                const text = node.textContent;
                while (chars < text.length && bytes < within) {
                  bytes += PREVIEW_UTF8.encode(text[chars]).length;
                  chars += 1;
                }
                if (bytes !== within) return false;

                const caret = d.createElement("span");
                caret.className = "pt";
                const rest = node.splitText(chars);
                rest.parentNode.insertBefore(caret, rest);
                return true;
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
                const s = this.scroller();
                if (el && s) {
                  // The new document tree may not have layout yet. Defer the
                  // measurement until the frame paints, then center point in
                  // the iframe's own scrollport.
                  // While point is on the page, do not scroll at all: a
                  // reader who moves down one line expects the page to hold
                  // still, and centring on every move threw the document
                  // half a page at a time. When point leaves the page, put
                  // it back in the MIDDLE, so there is a screenful of what
                  // comes next rather than one line of it.
                  //
                  // That is what Emacs does by default, and it is the one
                  // rule: the motion handler used to make its own room by a
                  // different measure, and which of the two you got depended
                  // on the numbers.
                  const reveal = () => {
                    const current = this.doc();
                    const marker = current && current.querySelector(".pt");
                    const scroll = this.scroller();
                    if (!marker || !scroll) return;
                    const r = marker.getBoundingClientRect();
                    const h = this.el.clientHeight;
                    const edge = Math.min(48, h / 8);

                    if (r.top >= edge && r.bottom <= h - edge) return;

                    scroll.scrollTop = Math.max(
                      0,
                      scroll.scrollTop + r.top - h / 2 + r.height / 2
                    );
                  };
                  requestAnimationFrame(() => requestAnimationFrame(reveal));
                }
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
                  // a window that does not own the keyboard draws the caret
                  // idle, never nothing: point is still somewhere, and the
                  // reader still has to see where
                  pt.style.visibility = "visible";
                  pt.classList.toggle("idle", !(document.hasFocus() && active));
                }
                this.apply();
                this.selectRegion();
                // syncDoc keeps the same Document object, so document-level
                // listeners survive its tree replacement and must not stack.
                if (this.wired === d) return;
                this.wired = d;
                // Markdown carries exact source offsets. HTML falls back to
                // matching the clicked text. Both use the normal editor input
                // path, so read-only remains the only edit permission.
                if (["markdown", "html"].includes(this.el.dataset.rm)) {
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
                      this.pushEvent(e.shiftKey ? "preview_link_to_group" : "preview_link", {
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
                    this.dragFrom = { x: e.clientX, y: e.clientY };
                    // a click lands only where the page names the byte; a
                    // spot with no run under it selects the window and
                    // nothing more
                    const exact = exactSpot(d, node, off);
                    if (exact !== null) {
                      this.pushEvent("preview_goto_pos", {
                        win: parseInt(this.el.dataset.win, 10),
                        pos: exact, extend: false
                      });
                    } else {
                      this.pushEvent("preview_goto", Object.assign(
                        { win: parseInt(this.el.dataset.win, 10) },
                        previewSpot(d, node, off, 0)));
                    }
                  }, true);
                  // Clicking the preview gives keyboard focus to the iframe.
                  // Keyboard events do not cross that browsing-context boundary,
                  // so forward them to the editor's existing dispatcher.
                  const forwardKey = (type, e) => {
                    // The iframe is the focused browsing context after a
                    // click. Always forward keydown: the browser may already
                    // have marked the iframe event handled (notably Space
                    // and Enter), even though the editor still needs it.
                    if (type === "keydown") e.preventDefault();
                    window.dispatchEvent(new KeyboardEvent(type, {
                      key: e.key,
                      code: e.code,
                      location: e.location,
                      ctrlKey: e.ctrlKey,
                      altKey: e.altKey,
                      shiftKey: e.shiftKey,
                      metaKey: e.metaKey,
                      repeat: e.repeat,
                      bubbles: true,
                      cancelable: true
                    }));
                  };
                  d.addEventListener("keydown", forwardKey.bind(null, "keydown"), true);
                  d.addEventListener("keyup", forwardKey.bind(null, "keyup"), true);
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
                    const exact = exactSpot(d, node, off);
                    return exact !== null ? exact : previewSpot(d, node, off, 0);
                  };
                  const dragExtend = (pos) => {
                    if (typeof pos === "number") {
                      this.pushEvent("preview_goto_pos", {
                        win: parseInt(this.el.dataset.win, 10), pos: pos, extend: true
                      });
                    } else {
                      this.pushEvent("preview_goto", Object.assign(
                        { win: parseInt(this.el.dataset.win, 10), extend: true }, pos));
                    }
                  };
                  d.addEventListener("mousemove", (e) => {
                    if (!this.dragFrom || !(e.buttons & 1)) return;
                    const now = Date.now();
                    if (this.dragAt && now - this.dragAt < 100) return;
                    const spot = dragSpot(e);
                    if (spot === null) return;
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
                    if (window.composRemeasure) window.composRemeasure();
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
                  if (!m || !m.compos) return;
                  if (m.compos === "scroll") {
                    clearTimeout(this.timer);
                    this.timer = setTimeout(() => {
                      this.pushEvent("cscroll", {
                        win: parseInt(this.el.dataset.win, 10),
                        top: Math.round(m.top)
                      });
                    }, 250);
                  } else if (m.compos === "release") {
                    // C-g inside the app gives the keyboard back to the editor
                    const sink = document.getElementById("kb-sink");
                    if (sink) sink.focus();
                  } else if (m.compos === "request-focus") {
                    // A cross-origin app cannot focus its own iframe element.
                    // The parent grants focus only to the selected app window.
                    const active = this.el.closest(".window")?.classList.contains("active");
                    const editorOpen = document.querySelector(
                      ".mb-panel, .which-key, .transient-panel"
                    );
                    if (active && !editorOpen && document.hasFocus()) {
                      this.el.focus({ preventScroll: true });
                      this.el.contentWindow?.postMessage({ compos: "focus-granted" }, "*");
                    }
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
                if (!w) return;
                w.postMessage({ compos: "scroll", top: top }, "*");
              }
            },
            // transcript follows output unless the reader scrolled up.
            // The flag and position mirror into daemon state (runtime
            // locals), so a refresh keeps the reader's place and a
            // daemon restart resets to following.
            AgentScroll: {
              mounted() {
                // The hook lives on the transcript LiveComponent itself.
                // Its lifecycle therefore runs after the child patch has
                // supplied the transcript's final scrollHeight.
                this.scroller = this.el;
                this.buf = this.el.dataset.buf;
                this.stick = this.el.dataset.stick !== "false";
                this.report = null;
                this.linkH = (e) => {
                  const link = e.target.closest && e.target.closest("a[href]");
                  if (!link || !this.el.contains(link)) return;
                  const href = link.getAttribute("href") || "";
                  if (href === "" || href.startsWith("#")) return;
                  e.preventDefault();
                  this.pushEvent(e.shiftKey ? "preview_link_to_group" : "preview_link", {
                    win: parseInt(this.el.dataset.win, 10),
                    href: href
                  });
                };
                this.el.addEventListener("click", this.linkH);
                this.scrollH = () => {
                  const s = this.scroller;
                  // hiding the window forces scrollTop to 0 and fires this
                  // event; only a scroll the reader can see may move the
                  // saved place, or a long chat comes back at the top
                  if (!s.isConnected || s.clientHeight === 0) return;
                  this.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
                  clearTimeout(this.report);
                  this.report = setTimeout(() => {
                    this.pushEvent("ag_stick", {
                      buf: this.el.dataset.buf,
                      stick: this.stick,
                      top: Math.round(s.scrollTop)
                    });
                  }, 250);
                };
                this.scroller.addEventListener("scroll", this.scrollH);
                if (this.stick) this.scroller.scrollTop = this.scroller.scrollHeight;
                else this.scroller.scrollTop = parseInt(this.el.dataset.scrollTop || "0", 10);
              },
              updated() {
                // A window may show another chat without replacing the DOM
                // id. Adopt that buffer's saved position once; within one
                // chat the local flag wins over a lagging server patch.
                const buf = this.el.dataset.buf;
                if (buf !== this.buf) {
                  this.buf = buf;
                  this.stick = this.el.dataset.stick !== "false";
                  if (this.stick) this.scroller.scrollTop = this.scroller.scrollHeight;
                  else this.scroller.scrollTop = parseInt(this.el.dataset.scrollTop || "0", 10);
                } else if (this.stick) {
                  this.scroller.scrollTop = this.scroller.scrollHeight;
                }
              },
              destroyed() {
                this.el.removeEventListener("click", this.linkH);
                this.scroller.removeEventListener("scroll", this.scrollH);
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
                if (this.syncCursorFocus) this.syncCursorFocus();
              },
              mounted() {
                if (this.bootCheck()) return;
                Telem.attach(this);
                this.handleEvent("navigate", ({url}) => window.location.assign(url));
                this.whichKeyHeld = new Set();
                this.whichKeyQuery = "";
                this.whichKeyFiltering = false;
                this.applyWhichKeyFilter = () => {
                  const panel = document.querySelector(".which-key");
                  if (!panel) {
                    this.whichKeyQuery = "";
                    this.whichKeyFiltering = false;
                    return;
                  }
                  const held = Array.from(this.whichKeyHeld);
                  const terms = this.whichKeyQuery.trim().toLowerCase().split(/\s+/).filter(Boolean);
                  let visible = 0;
                  panel.querySelectorAll(".wk-group").forEach((group) => {
                    const groupModifiers = (group.dataset.modifiers || "").split(" ").filter(Boolean);
                    const modifierMatch = held.length === 0 ||
                      held.every((modifier) => groupModifiers.includes(modifier));
                    let groupVisible = 0;
                    group.querySelectorAll(".wk-item").forEach((item) => {
                      const command = item.dataset.command || "";
                      item.hidden = !terms.every((term) => command.includes(term));
                      if (!item.hidden) groupVisible++;
                    });
                    group.hidden = !modifierMatch || groupVisible === 0;
                    if (modifierMatch) visible += groupVisible;
                  });
                  const hint = panel.querySelector(".wk-filter");
                  if (hint) {
                    const query = this.whichKeyQuery;
                    hint.textContent = this.whichKeyFiltering
                      ? "/ " + query + "▏ · RET applies · ESC clears"
                      : query
                        ? "Command: " + query + " · / edits · ESC clears"
                        : held.length === 0
                          ? "Hold a modifier · / filters commands"
                          : "Showing " + held.map((modifier) =>
                              WHICH_KEY_MODIFIER_LABELS[modifier]).join(" + ");
                  }
                  const count = panel.querySelector(".wk-count");
                  const total = count ? parseInt(count.dataset.total, 10) : 0;
                  const filtered = terms.length > 0 || held.length > 0;
                  if (count) count.textContent = filtered ? visible + " / " + total + " bindings"
                    : total + " bindings";
                  const empty = panel.querySelector(".wk-empty");
                  if (empty) empty.hidden = visible > 0;
                };
                this.syncCursorFocus = () => {
                  const focused = document.hasFocus() && !document.body.classList.contains("unfocused");
                  document.querySelectorAll(".window iframe[data-rm='markdown']").forEach((frame) => {
                    let d;
                    try { d = frame.contentDocument; } catch (_) { return; }
                    const pt = d && d.querySelector(".pt");
                    if (pt) {
                      const active = frame.closest(".window")?.classList.contains("active");
                      pt.style.visibility = "visible";
                      pt.classList.toggle("idle", !(focused && active));
                    }
                  });
                };
                this.syncKeyboardOwner = () => {
                  const editorOpen = document.querySelector(
                    ".mb-panel, .which-key, .transient-panel"
                  );
                  const terminal = editorOpen
                    ? null
                    : document.querySelector(".window.active .terminal-view");
                  window.dispatchEvent(new CustomEvent("compos:keyboard-owner", {
                    detail: { terminal: terminal ? terminal.id : null }
                  }));

                  const focusedTerminal = document.activeElement?.closest?.(".terminal-view");
                  if (document.hasFocus() && (editorOpen || (!terminal && focusedTerminal))) {
                    this.sink?.focus();
                  }
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
                  if (e.target.closest && e.target.closest(".terminal-view")) return;
                  const panel = document.querySelector(".which-key");
                  const modifier = WHICH_KEY_MODIFIERS[e.key];
                  if (modifier && panel && !this.whichKeyFiltering) {
                    e.preventDefault();
                    this.whichKeyHeld.add(modifier);
                    this.applyWhichKeyFilter();
                    return;
                  }
                  if (modifier && panel && this.whichKeyFiltering) {
                    e.preventDefault();
                    return;
                  }
                  if (panel && e.key === "/" && !e.ctrlKey && !e.altKey && !e.metaKey) {
                    e.preventDefault();
                    this.whichKeyFiltering = true;
                    this.whichKeyHeld.clear();
                    this.applyWhichKeyFilter();
                    return;
                  }
                  if (panel && this.whichKeyFiltering) {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      this.whichKeyFiltering = false;
                      this.applyWhichKeyFilter();
                      return;
                    }
                    if (e.key === "Escape") {
                      e.preventDefault();
                      this.whichKeyQuery = "";
                      this.whichKeyFiltering = false;
                      this.applyWhichKeyFilter();
                      return;
                    }
                    if (e.key === "Backspace") {
                      e.preventDefault();
                      this.whichKeyQuery = this.whichKeyQuery.slice(0, -1);
                      this.applyWhichKeyFilter();
                      return;
                    }
                    if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
                      e.preventDefault();
                      this.whichKeyQuery += e.key.toLowerCase();
                      this.applyWhichKeyFilter();
                      return;
                    }
                  }
                  if (panel && this.whichKeyQuery && e.key === "Escape") {
                    e.preventDefault();
                    this.whichKeyQuery = "";
                    this.applyWhichKeyFilter();
                    return;
                  }
                  // C-g from an app lands on the keyboard sink. RET returns
                  // focus to the selected app when no editor panel owns RET.
                  if (e.key === "Enter" && !e.ctrlKey && !e.altKey && !e.metaKey &&
                      !e.shiftKey &&
                      !document.querySelector(".mb-panel, .which-key, .transient-panel")) {
                    const app = document.querySelector(".window.active .app-preview");
                    if (app) {
                      e.preventDefault();
                      app.focus({ preventScroll: true });
                      app.contentWindow?.postMessage({ compos: "focus-granted" }, "*");
                      return;
                    }
                  }
                  this.whichKeyHeld = new Set(heldWhichKeyModifiers(e));
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
                  // An editable surface has focus: the browser's own text
                  // pipeline turns this key into a beforeinput intent
                  // (accents, input methods, dictation, autocorrect).
                  // Chords, motion keys, and TAB still travel as keys.
                  if (NATIVE_MOTION.includes(e.key)) {
                    // the cause of the next selection report (wrapAffinity);
                    // Cmd-Left/Right are Home and End
                    this._lastMotion = e.metaKey && e.key === "ArrowLeft" ? "Home"
                      : e.metaKey && e.key === "ArrowRight" ? "End" : e.key;
                    this._caretTopBefore = caretTopNow();
                    // The mark is the user's. In Emacs a keyboard motion
                    // extends the region from it, so the selection report
                    // this key is about to cause must not clear it. The
                    // arrows never reach the server on an editable surface,
                    // so this timestamp is the only thing that can tell a
                    // caret move from a click down there.
                    this._motionAt = performance.now();
                  }
                  if (nativeTextKey(e)) return;
                  const spec = keySpec(e);
                  if (spec === null) return;
                  e.preventDefault();
                  if (e.altKey) this._chordAt = performance.now();
                  // every key goes to the editor as the key it is. A visual
                  // row move is Scheme reading the wrap map this client
                  // measured after the last paint; nothing is decided here.
                  Telem.push(this, "key", { k: spec });
                };
                window.addEventListener("keydown", this.handler);
                this.keyupH = (e) => {
                  if (e.target.closest && e.target.closest(".terminal-view")) return;
                  const modifier = WHICH_KEY_MODIFIERS[e.key];
                  if (modifier) {
                    this.whichKeyHeld.delete(modifier);
                    this.applyWhichKeyFilter();
                  }
                };
                window.addEventListener("keyup", this.keyupH);

                // system clipboard: Cmd-V fires a native paste event (cmd
                // keys pass through keySpec untouched)
                this.pasteH = (e) => {
                  if (e.target.closest && e.target.closest(".terminal-view")) return;
                  const items = e.clipboardData && Array.from(e.clipboardData.items || []);
                  const files = e.clipboardData && Array.from(e.clipboardData.files || []);
                  const image = items && items.find((item) => item.type.startsWith("image/"));
                  const imageFile = image ? image.getAsFile() :
                    (files && files.find((file) => file.type.startsWith("image/")));
                  if (imageFile) {
                    e.preventDefault();
                    const blob = imageFile;
                    const reader = new FileReader();
                    reader.onload = () => {
                      const comma = reader.result.indexOf(",");
                      if (comma >= 0) {
                        const data = reader.result.slice(comma + 1);
                        this.pushEvent("paste_image", { data, mime: blob.type });
                      }
                    };
                    reader.readAsDataURL(blob);
                    return;
                  }
                  const text = e.clipboardData && e.clipboardData.getData("text/plain");
                  if (!text) return;
                  e.preventDefault();
                  this.pushEvent("paste", { text });
                };
                window.addEventListener("paste", this.pasteH);

                // --- the editable surface --------------------------------
                // A DOM position inside a line, as the source byte it names:
                // the line's start plus the UTF-8 length of the drawn text
                // before it. The caret placeholder (an nbsp the server drew
                // at the end of a line) and the completion popup draw no
                // source bytes.
                const editableOf = (node) => {
                  const el = node && (node.nodeType === 1 ? node : node.parentElement);
                  return el && el.closest ? el.closest(".buf[contenteditable]") : null;
                };
                const winIdOf = (el) => {
                  const win = el && el.closest(".window[data-win-id]");
                  return win ? parseInt(win.dataset.winId, 10) : null;
                };
                const countsBytes = (t) => {
                  const p = t.parentElement;
                  if (!p || p.closest(".cap-pop")) return false;
                  // text inside an island (data-len) is display, not source
                  if (p.closest("[data-len]")) return false;
                  return !(p.classList.contains("cursor") && t.textContent === " ");
                };
                const domByte = (node, offset) => {
                  const el = node.nodeType === 1 ? node : node.parentElement;
                  const line = el && el.closest(".line");
                  if (!line) return null;
                  const start = parseInt(line.dataset.s, 10);
                  if (isNaN(start)) return null;
                  const content = line.querySelector(".line-content");
                  if (!content) return start;
                  // an element position names the text before its child
                  let target = node, at = offset, after = false;
                  if (node.nodeType === 1) {
                    const child = node.childNodes[offset];
                    if (child) { target = child; at = 0; }
                    else { target = node.lastChild; after = true; }
                  }
                  let bytes = 0;
                  // an island (data-len) stands for its source bytes as one
                  // unit; the text inside a card is not source
                  const walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                  let t;
                  while ((t = walker.nextNode())) {
                    const island = t.nodeType === 1 ? (t.dataset && t.dataset.len !== undefined ? t : null)
                                                    : null;
                    if (t.nodeType === 1 && !island) continue;
                    if (t.nodeType === 3 && t.parentElement && t.parentElement.closest("[data-len]")) continue;
                    const inside = target && (t === target || (t.contains && t.contains(target)) || (target.contains && target.contains(t)));
                    if (island) {
                      const len = parseInt(island.dataset.len, 10) || 0;
                      if (inside) return start + bytes + (after || (target !== island && at > 0) ? len : 0);
                      bytes += len;
                      continue;
                    }
                    if (inside && !after) {
                      if (countsBytes(t) && t === target) bytes += utf8.encode(t.textContent.slice(0, at)).length;
                      return start + bytes;
                    }
                    if (countsBytes(t)) bytes += utf8.encode(t.textContent).length;
                    if (inside && after && t === target) return start + bytes;
                  }
                  return start + bytes;
                };
                // the text node before NODE inside the same row content, or null
                const prevTextNode = (node) => {
                  const content = (node.nodeType === 1 ? node : node.parentElement).closest(".line-content");
                  if (!content) return null;
                  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
                  let prev = null, n;
                  while ((n = walker.nextNode())) {
                    if (n === node) return prev;
                    if (n.textContent.length > 0 && countsBytes(n)) prev = n;
                  }
                  return null;
                };
                // the box of the character before (NODE, OFF), crossing into
                // the previous text node at a node start; null at a row start
                const rectBefore = (node, off) => {
                  try {
                    let n = node, o = off;
                    if (o === 0) { n = prevTextNode(node); if (!n) return null; o = n.textContent.length; }
                    const r = document.createRange();
                    r.setStart(n, o - 1); r.setEnd(n, o);
                    const b = r.getBoundingClientRect();
                    return b.height > 0 ? b : null;
                  } catch (_) { return null; }
                };
                // the box of the character at (NODE, OFF), crossing into the
                // next text node at a node end; null at a row end
                const rectAfter = (node, off) => {
                  try {
                    let n = node, o = off;
                    if (o >= n.textContent.length) {
                      const content = n.parentElement.closest(".line-content");
                      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
                      let seen = false, m, next = null;
                      while ((m = walker.nextNode())) {
                        if (seen && m.textContent.length > 0 && countsBytes(m)) { next = m; break; }
                        if (m === n) seen = true;
                      }
                      if (!next) return null;
                      n = next; o = 0;
                    }
                    const r = document.createRange();
                    r.setStart(n, o); r.setEnd(n, o + 1);
                    const b = r.getBoundingClientRect();
                    return b.height > 0 ? b : null;
                  } catch (_) { return null; }
                };
                // Which row a caret at a soft wrap belongs to. A Range has no
                // affinity and its box cannot say, so the cause says: End and
                // a leftward step stay on the upper row, Home and a rightward
                // step take the lower one, a vertical step or a click takes
                // the row it aimed at.
                const wrapAffinity = (sel) => {
                  const f = sel.focusNode;
                  if (!f || f.nodeType !== 3) return "down";
                  const before = rectBefore(f, sel.focusOffset), after = rectAfter(f, sel.focusOffset);
                  if (!before || !after) return "down";
                  const h = before.height;
                  if (Math.abs(before.top - after.top) < h / 2) return "down";
                  const nearest = (y) => Math.abs(before.top - y) <= Math.abs(after.top - y) ? "up" : "down";
                  switch (this._lastMotion) {
                    case "End": case "ArrowLeft": return "up";
                    case "Home": case "ArrowRight": return "down";
                    case "ArrowDown": return nearest(this._caretTopBefore + h);
                    case "ArrowUp": return nearest(this._caretTopBefore - h);
                    case "Click": return nearest(this._clickY - h / 2);
                    default: return "down";
                  }
                };
                const caretTopNow = () => {
                  try { return window.getSelection().getRangeAt(0).getBoundingClientRect().top; }
                  catch (_) { return 0; }
                };
                // byte -> DOM position inside BUF: the row whose start is at
                // or before the byte, then the text node that holds it; an
                // island is one unit, so a byte inside it lands after it
                const domPos = (buf, byte) => {
                  const lines = Array.from(buf.querySelectorAll(":scope > .line"));
                  let line = null;
                  for (const l of lines) {
                    const st = parseInt(l.dataset.s, 10);
                    if (isNaN(st) || st > byte) break;
                    line = l;
                  }
                  if (!line) return null;
                  const content = line.querySelector(".line-content");
                  if (!content) return null;
                  let rem = byte - parseInt(line.dataset.s, 10);
                  const walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                  let t, last = null;
                  while ((t = walker.nextNode())) {
                    if (t.nodeType === 1) {
                      if (!t.dataset || t.dataset.len === undefined) continue;
                      const len = parseInt(t.dataset.len, 10) || 0;
                      if (rem <= 0) return { node: t.parentNode, offset: Array.from(t.parentNode.childNodes).indexOf(t) };
                      if (rem < len) return { node: t.parentNode, offset: Array.from(t.parentNode.childNodes).indexOf(t) + 1 };
                      rem -= len; last = t;
                      continue;
                    }
                    if (t.parentElement && t.parentElement.closest("[data-len]")) continue;
                    if (!countsBytes(t)) continue;
                    const bytes = utf8.encode(t.textContent).length;
                    if (rem <= bytes) {
                      // the character offset for REM bytes into this node
                      let chars = 0, used = 0;
                      for (const ch of t.textContent) {
                        const b = utf8.encode(ch).length;
                        if (used + b > rem) break;
                        used += b; chars += ch.length;
                      }
                      return { node: t, offset: chars };
                    }
                    rem -= bytes; last = t;
                  }
                  if (last && last.nodeType === 3) return { node: last, offset: last.textContent.length };
                  return { node: content, offset: content.childNodes.length };
                };
                // the ghost caret: a box at point, shown only while the page
                // does not own the keyboard (the native caret is gone then)
                const placeGhost = (buf, pos) => {
                  let g = buf.querySelector(":scope > .caret-ghost");
                  if (!g) { g = document.createElement("span"); g.className = "caret-ghost"; buf.appendChild(g); }
                  try {
                    const r = document.createRange(); r.setStart(pos.node, pos.offset); r.collapse(true);
                    const b = r.getBoundingClientRect(), bb = buf.getBoundingClientRect();
                    if (b.height > 0) {
                      g.style.top = (b.top - bb.top + buf.scrollTop) + "px";
                      g.style.left = (b.left - bb.left + buf.scrollLeft) + "px";
                      g.style.height = b.height + "px";
                    }
                  } catch (_) { /* nothing to draw */ }
                };
                // the current row is the client's mark on an editable
                // surface: the server sends no line for a caret move, so the
                // highlight follows the caret here, at once and after a patch
                const markCurrentRow = (buf) => {
                  const sel = window.getSelection();
                  const f = sel && sel.focusNode;
                  const el = f ? (f.nodeType === 1 ? f : f.parentElement) : null;
                  const row = el && buf.contains(el) ? el.closest(".line") : null;
                  buf.querySelectorAll(":scope > .line.hl-line").forEach((l) => { if (l !== row) l.classList.remove("hl-line"); });
                  if (row) row.classList.add("hl-line");
                };
                this.beforeInputH = (e) => {
                  const buf = editableOf(e.target);
                  if (!buf) return;
                  // an input method owns the DOM of its run until it ends
                  if (e.isComposing || e.inputType === "insertCompositionText") {
                    buf.setAttribute("phx-update", "ignore");
                    return;
                  }
                  e.preventDefault();
                  // With no selection, the intent acts at the server's point,
                  // whatever the DOM caret says: the DOM caret is one patch
                  // behind while you type, and a Backspace measured from it
                  // deletes the wrong character. A real selection is a range.
                  const domSel = window.getSelection();
                  const collapsedDelete = e.inputType.startsWith("delete") &&
                    domSel && domSel.isCollapsed;
                  const range = !collapsedDelete && e.getTargetRanges ? e.getTargetRanges()[0] : null;
                  const from = range ? domByte(range.startContainer, range.startOffset) : null;
                  const to = range ? domByte(range.endContainer, range.endOffset) : null;
                  let text = e.data;
                  if (text == null && e.dataTransfer) text = e.dataTransfer.getData("text/plain");
                  Telem.push(this, "intent", {
                    win: winIdOf(buf), type: e.inputType,
                    from: from == null ? -1 : from, to: to == null ? -1 : to,
                    text: text || ""
                  });
                };
                window.addEventListener("beforeinput", this.beforeInputH, true);
                // A chord with Option starts a macOS dead-key composition
                // even when its keydown was prevented: M-x opened the prompt,
                // and the composition then ended with a character, which
                // went into the prompt as text. A composition that begins
                // right after a chord we sent is the chord's, not text.
                this.compStartH = (e) => {
                  const buf = editableOf(e.target);
                  this._chordComp = performance.now() - (this._chordAt || 0) < 300;
                  if (buf && !this._chordComp) buf.setAttribute("phx-update", "ignore");
                };
                this.compEndH = (e) => {
                  const buf = editableOf(e.target);
                  if (!buf) return;
                  buf.removeAttribute("phx-update");
                  if (this._chordComp) { this._chordComp = false; return; }
                  Telem.push(this, "intent", {
                    win: winIdOf(buf), type: "insertCompositionText",
                    from: -1, to: -1, text: e.data || ""
                  });
                };
                window.addEventListener("compositionstart", this.compStartH, true);
                window.addEventListener("compositionend", this.compEndH, true);
                // After a patch the active editable takes focus and the DOM
                // caret stands on the server's cursor, so the next intent
                // targets the byte the server means. A prompt, a panel, or
                // a terminal keeps the keyboard it has.
                this.syncEditable = () => {
                  if (document.querySelector(".mb-panel, .which-key, .transient-panel")) return;
                  const buf = document.querySelector(".window.active .buf[contenteditable]");
                  if (!buf) return;
                  const a = document.activeElement;
                  if (a && a.closest && a.closest(".terminal-view, iframe, input, textarea")) return;
                  if (a !== buf && !buf.contains(a)) buf.focus({ preventScroll: true });
                  if (buf.hasAttribute("phx-update")) return;
                  const pt = parseInt(buf.dataset.pt, 10);
                  if (isNaN(pt)) return;
                  const markAttr = buf.dataset.mark;
                  const mark = markAttr === undefined || markAttr === "" ? null : parseInt(markAttr, 10);
                  const sel = window.getSelection();
                  if (!sel) return;
                  const ptPos = domPos(buf, pt);
                  if (!ptPos) return;
                  // the ghost is drawn only while the page has no keyboard;
                  // measuring it on every patch is a forced layout
                  if (document.body.classList.contains("unfocused")) placeGhost(buf, ptPos);
                  // the selection the page already has, as bytes; the same
                  // bytes are left alone so the browser keeps its goal column
                  // and its side of a soft wrap
                  const focusByte = sel.focusNode && buf.contains(sel.focusNode) ? domByte(sel.focusNode, sel.focusOffset) : null;
                  const anchorByte = sel.anchorNode && buf.contains(sel.anchorNode) ? domByte(sel.anchorNode, sel.anchorOffset) : null;
                  const wantAnchor = mark === null || mark === pt ? pt : mark;
                  if (focusByte === pt && anchorByte === wantAnchor) { markCurrentRow(buf); return; }
                  this._settingSel = true;
                  try {
                    if (wantAnchor !== pt) {
                      const mPos = domPos(buf, wantAnchor);
                      if (mPos) sel.setBaseAndExtent(mPos.node, mPos.offset, ptPos.node, ptPos.offset);
                      else sel.collapse(ptPos.node, ptPos.offset);
                      return;
                    }
                    sel.collapse(ptPos.node, ptPos.offset);
                    // At a soft wrap the byte is drawn at the head of the
                    // lower row by default. The caret came from the upper
                    // row: the Selection API sets no affinity, so ask the
                    // browser's own motion for it (one step back, then to
                    // the row's end), which lands on the same byte.
                    if (this._affinity === "up" && ptPos.node.nodeType === 3) {
                      const before = rectBefore(ptPos.node, ptPos.offset);
                      const here = sel.getRangeAt(0).getBoundingClientRect();
                      if (before && here.top > before.top + before.height / 2) {
                        sel.modify("move", "backward", "character");
                        sel.modify("move", "forward", "lineboundary");
                        if (domByte(sel.focusNode, sel.focusOffset) !== pt) sel.collapse(ptPos.node, ptPos.offset);
                      }
                    }
                  } catch (_) { /* detached mid-patch */ }
                  finally { this._settingSel = false; markCurrentRow(buf); }
                };
                // The browser moved the caret (an arrow, Home, a Shift
                // selection): report it as bytes. Our own placements and a
                // composition in progress are not reports.
                this.selChangeH = () => {
                  if (this._settingSel) return;
                  const a = document.activeElement;
                  const buf = a && a.closest ? a.closest(".buf[contenteditable]") : null;
                  if (!buf || buf.hasAttribute("phx-update")) return;
                  // only the selected window's caret is news: a click
                  // selects a window through "mouse" first, and a patch
                  // that nudges the selection in another window is not a
                  // move anyone made
                  const win = buf.closest(".window");
                  if (!win || !win.classList.contains("active")) return;
                  markCurrentRow(buf);
                  // report when the caret comes to rest: a held arrow moves
                  // it thirty times a second, and a server redraw per step
                  // starves the paint of the caret itself
                  clearTimeout(this._selt);
                  this._selt = setTimeout(() => {
                    if (this._settingSel) return;
                    const sel = window.getSelection();
                    const pt = parseInt(buf.dataset.pt, 10);
                    // a collapsed caret still on the server's point is no news
                    if (sel && sel.isCollapsed && !isNaN(pt) && sel.focusNode && buf.contains(sel.focusNode) &&
                        domByte(sel.focusNode, sel.focusOffset) === pt) return;
                    // keep the mark when a motion key caused this report;
                    // a click, which sets no timestamp, still clears it
                    this.sendSelection(buf,
                      performance.now() - (this._motionAt || 0) < 1200);
                  }, 150);
                };
                document.addEventListener("selectionchange", this.selChangeH);
                this.syncEditable();
                // the selection of the active editable surface, as bytes
                // KEEP: a keyboard motion leaves the mark alone (Emacs: the
                // region follows point); a click clears it
                this.sendSelection = (buf, keep) => {
                  const sel = window.getSelection();
                  if (!sel || !sel.rangeCount || !buf.contains(sel.focusNode)) return false;
                  const point = domByte(sel.focusNode, sel.focusOffset);
                  const mark = sel.isCollapsed ? null : domByte(sel.anchorNode, sel.anchorOffset);
                  if (point == null) return false;
                  // At a soft wrap the end of one row and the start of the
                  // next are one byte. A caret at the end of its text node
                  // sits on the upper row; remember that, so the redraw puts
                  // it back there and not at the head of the row below.
                  // upstream = the caret is drawn on the row of the character
                  // before it; at a soft wrap that row is the upper one
                  this._affinity = wrapAffinity(sel);
                  this.pushEvent("sel", { win: winIdOf(buf), point, mark, keep: !!keep });
                  return true;
                };
                // a motion command asks the browser's layout to move the
                // selection; the answer is the selection, as bytes
                this.handleEvent("select", ({ alter, dir, granularity, count }) => {
                  const buf = document.querySelector(".window.active .buf[contenteditable]");
                  const sel = window.getSelection();
                  if (!buf || !sel) return;
                  if (!buf.contains(sel.focusNode)) this.syncEditable();
                  // A page is one request carrying many line moves. The
                  // browser answers each from where the last one landed,
                  // and only the caret it ends on travels back. The daemon
                  // holds one pending request per frame, so N requests
                  // would collapse to one row.
                  const n = Math.max(1, Math.min(parseInt(count, 10) || 1, 1000));
                  try {
                    for (let i = 0; i < n; i++) sel.modify(alter, dir, granularity);
                  } catch (_) { return; }
                  this.sendSelection(buf, true);
                });

                this.handleEvent("clipboard", ({ text }) => {
                  if (text) navigator.clipboard.writeText(text);
                });

                // this TAB's frame rides the payload as data-frame (S5,
                // S13): sessionStorage carries it across reloads, per tab —
                // two tabs are two frames and stop fighting over win_rows
                if (this.el.dataset.frame) {
                  sessionStorage.setItem("compos-frame", this.el.dataset.frame);
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
                  // an editable surface: the browser placed the caret or the
                  // selection, and it names bytes exactly. The server accepts
                  // a caret report only for the active window, so a click
                  // into another window selects that window first.
                  const editable = winEl.querySelector(".buf[contenteditable]");
                  if (editable && sel && sel.rangeCount && editable.contains(sel.focusNode)) {
                    if (!winEl.classList.contains("active")) this.pushEvent("mouse", { win });
                    if (this.sendSelection(editable)) return;
                  }
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
                  if (window.composRemeasure) window.composRemeasure();
                };
                // The wrap map. The browser is the only party that knows
                // where proportional text wraps, so it measures where each
                // visual row begins and reports the source byte offsets, per
                // window, tagged with the buffer version the page shows.
                // What a key means on those rows is Scheme's decision. The
                // measure runs after paint, never on the key path, and is
                // sent only when it changed, like win_rows.
                this.lastWrapMaps = "";
                const wrapUtf8 = new TextEncoder();
                // the text nodes that are the source's own bytes. The cursor
                // placeholder and the completion popup are chrome.
                const sourceTextNodes = (root, doc) => {
                  const out = [];
                  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                  let t;
                  while ((t = walker.nextNode())) {
                    const parent = t.parentElement;
                    if (parent && parent.closest(".cap-pop")) continue;
                    if (parent && parent.classList.contains("cursor") &&
                        t.textContent === "\u00a0") continue;
                    out.push(t);
                  }
                  return out;
                };
                // The UTF-16 indices at which a new row begins inside NODES,
                // and the top of the last row. PREVTOP is the row the text
                // before these nodes ended on, or null for a fresh block.
                // Every probe is a one-character range: a collapsed range at
                // a wrap boundary measures zero height and reports the NEXT
                // row. Rows are monotonic in the index, so each row start is
                // found by a binary search rather than a probe per character.
                const rowBreaks = (doc, nodes, prevTop) => {
                  const spans = [];
                  let total = 0;
                  for (const n of nodes) {
                    spans.push({ n, at: total });
                    total += n.textContent.length;
                  }
                  const locate = (i) => {
                    let lo = 0, hi = spans.length - 1;
                    while (lo < hi) {
                      const mid = (lo + hi + 1) >> 1;
                      if (spans[mid].at <= i) lo = mid; else hi = mid - 1;
                    }
                    return spans[lo];
                  };
                  const rectAt = (i) => {
                    const sp = locate(i);
                    const len = sp.n.textContent.length;
                    const r = doc.createRange();
                    r.setStart(sp.n, i - sp.at);
                    r.setEnd(sp.n, Math.min(len, i - sp.at + 1));
                    const rects = r.getClientRects();
                    return rects.length ? rects[0] : null;
                  };
                  const starts = [];
                  let top = prevTop;
                  let i = 0;
                  while (i < total) {
                    const rect = rectAt(i);
                    // collapsed whitespace draws no box: it belongs to the
                    // row before it. A space hanging at a wrap, when it
                    // begins a text node, reports a zero-width box on the
                    // row BELOW; it is the same space, and it is not where
                    // the reader sees that row begin.
                    if (!rect || rect.width === 0) { i++; continue; }
                    const tol = Math.max(2, rect.height * 0.5);
                    if (top === null || rect.top > top + tol) starts.push(i);
                    top = rect.top;
                    // the last index still on this row
                    let lo = i, hi = total - 1;
                    while (lo < hi) {
                      const mid = (lo + hi + 1) >> 1;
                      const m = rectAt(mid);
                      if (!m || m.top <= top + tol) lo = mid; else hi = mid - 1;
                    }
                    i = lo + 1;
                  }
                  return { starts, top };
                };
                const byteAt = (text, i) => wrapUtf8.encode(text.slice(0, i)).length;
                // one screen of margin above and below what is visible: a
                // move at the edge still has rows to land on, and the scroll
                // that follows brings a fresh measure
                const firstFrom = (els, lo) => {
                  let a = 0, b = els.length - 1;
                  while (a < b) {
                    const m = (a + b) >> 1;
                    if (els[m].getBoundingClientRect().bottom < lo) a = m + 1; else b = m;
                  }
                  return a;
                };
                // a line window: each .line names its start byte, and the
                // rows inside it are where its own text wraps
                const measureRaw = (buf) => {
                  const rows = [];
                  const lines = buf.querySelectorAll(":scope > .line");
                  if (!lines.length) return rows;
                  const box = buf.getBoundingClientRect();
                  const lo = box.top - box.height, hi = box.bottom + box.height;
                  for (let k = firstFrom(lines, lo); k < lines.length; k++) {
                    const ln = lines[k];
                    if (ln.getBoundingClientRect().top > hi) break;
                    const start = parseInt(ln.dataset.s, 10);
                    if (!Number.isFinite(start)) continue;
                    const content = ln.querySelector(".line-content");
                    if (!content) continue;
                    const nodes = sourceTextNodes(content, document);
                    const text = nodes.map((n) => n.textContent).join("");
                    if (!text.length) { rows.push(start); continue; }
                    for (const i of rowBreaks(document, nodes, null).starts) {
                      rows.push(start + byteAt(text, i));
                    }
                  }
                  return rows;
                };
                // a rendered page: the rows are runs of drawn text, each
                // naming the source byte it began at. A run continues the
                // row of the run before it unless the browser moved it down.
                const measurePreview = (frame) => {
                  const rows = [];
                  let d;
                  try { d = frame.contentDocument; } catch (_) { return null; }
                  if (!d || !d.body) return null;
                  const runs = d.querySelectorAll("span.s[data-s]");
                  if (!runs.length) return rows;
                  const h = frame.clientHeight;
                  const lo = -h, hi = 2 * h;
                  let top = null;
                  for (let k = firstFrom(runs, lo); k < runs.length; k++) {
                    const run = runs[k];
                    if (run.getBoundingClientRect().top > hi) break;
                    const at = parseInt(run.dataset.s, 10);
                    if (!Number.isFinite(at)) continue;
                    const nodes = sourceTextNodes(run, d);
                    const text = nodes.map((n) => n.textContent).join("");
                    if (!text.length) continue;
                    const br = rowBreaks(d, nodes, top);
                    for (const i of br.starts) rows.push(at + byteAt(text, i));
                    top = br.top;
                  }
                  return rows;
                };
                this.sendWrapMaps = () => {
                  // a paint can move a wrap under a caret that did not
                  // move: settle it again before the rows are read
                  document.querySelectorAll("iframe[data-rm='markdown']").forEach((f) => {
                    try { if (f.contentDocument) settleCaret(f.contentDocument); } catch (_) {}
                  });
                  const maps = {};
                  document.querySelectorAll(".window[data-win-id]").forEach((win) => {
                    // a preview window keeps its buffer element in the page
                    // while the iframe draws: the iframe is what the reader
                    // sees, so it is the one to measure
                    const frame = win.querySelector(
                      "iframe[data-rm='markdown'][data-visual-lines='true']");
                    const buf = win.querySelector(".buf[data-visual-lines='true']");
                    const el = frame || buf;
                    if (!el) return;
                    // an editable surface moves by the browser's own layout
                    // (Selection.modify); no map is measured for it
                    if (!frame && buf.hasAttribute("contenteditable")) return;
                    const v = parseInt(el.dataset.v, 10);
                    if (!Number.isFinite(v)) return;
                    const rows = frame ? measurePreview(frame) : measureRaw(buf);
                    if (!rows) return;
                    maps[win.dataset.winId] = { v, r: rows };
                  });
                  const key = JSON.stringify(maps);
                  if (key !== this.lastWrapMaps) {
                    this.lastWrapMaps = key;
                    this.pushEvent("wrap_map", { maps });
                  }
                };
                // the preview hook scrolls and reloads its own document, so
                // it asks for a measure through this one door
                window.composRemeasure = () => {
                  clearTimeout(this._wmt);
                  this._wmt = setTimeout(() => Telem.time("wrap-maps", this.sendWrapMaps), 40);
                };
                this.sendWinRows = () => {
                  // a which-key panel takes rows from every window while it
                  // is up and gives them back when it goes. Reporting that
                  // re-rendered every window twice per prefix key; the
                  // measurement before the panel still holds after it.
                  if (document.querySelector(".which-key")) return;
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

                // Any client's JS failure lands in *Messages*: a webview
                // has no extension and often no open inspector, and an
                // unreported error reads as "the editor ignored me".
                this.jsErrH = (e) => {
                  const m = e.message || (e.reason && (e.reason.stack || e.reason.message)) || "unknown";
                  const at = e.filename ? ` @${e.filename}:${e.lineno}` : "";
                  this.pushEvent("client_error", { m: `${m}${at}`.slice(0, 500) });
                };
                window.addEventListener("error", this.jsErrH);
                window.addEventListener("unhandledrejection", this.jsErrH);

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
                    e.target.closest(".ag-scroll, .blocks-scroll, .buf.client-scroll, .terminal-view")
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
                  // a window being hidden scrolls itself to 0; that is not
                  // the reader (see AgentScroll.scrollH)
                  if (!el.isConnected || el.clientHeight === 0) return;
                  const winEl = el.closest(".window[data-win-id]");
                  if (!winEl) return;
                  const win = parseInt(winEl.dataset.winId, 10);
                  clearTimeout(this.cscrollTimers.get(win));
                  this.cscrollTimers.set(win, setTimeout(() => {
                    this.pushEvent("cscroll", { win, top: Math.round(el.scrollTop) });
                    window.composRemeasure();
                  }, 250));
                };
                window.addEventListener("scroll", this.cscrollH, true);
                this.restoreClientScroll();

                this.focusH = () => {
                  document.body.classList.remove("unfocused");
                  this.syncCursorFocus();
                  this.syncKeyboardOwner();
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
                  this.whichKeyHeld.clear();
                  this.applyWhichKeyFilter();
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
                  this.syncCursorFocus();
                };
                window.addEventListener("focus", this.focusH);
                window.addEventListener("blur", this.blurH);

                // "unfocused" hides every cursor, and only the focus event
                // above clears it. The line below sets it from a poll, and a
                // browser answers that poll with false while it is still
                // settling a new document — a reconnect, a boot-id reload.
                // The window never lost the focus, so no focus event ever
                // comes to undo it, and the editor sits there with no cursor
                // until the reader alt-tabs away and back. A key or a
                // pointer proves the window has the focus, whatever the poll
                // said, so let either one heal the state.
                this.proveFocusH = () => {
                  if (document.hasFocus() && document.body.classList.contains("unfocused")) {
                    this.focusH();
                  }
                };
                window.addEventListener("pointerdown", this.proveFocusH, true);
                window.addEventListener("keydown", this.proveFocusH, true);

                // a click is the one thing that says the mark is gone: it
                // ends the run of keyboard motion the report above keeps
                this.pointerMarkH = () => { this._motionAt = 0; };
                window.addEventListener("pointerdown", this.pointerMarkH, true);

                // A drawn Markdown link carries its target. Clicking the
                // text follows the link instead of putting the caret inside
                // it. The mousedown does it, not the click: following
                // re-renders the document, and the span dies with it.
                // Shift opens the target in the group, as it does in a
                // rendered page.
                this.linkDownH = (e) => {
                  if (e.button !== 0) return;
                  const el = e.target.closest && e.target.closest("[data-href]");
                  if (!el || !el.closest(".buf")) return;
                  const win = el.closest(".window");
                  if (!win) return;
                  e.preventDefault();
                  this.pushEvent(e.shiftKey ? "preview_link_to_group" : "preview_link", {
                    win: parseInt(win.dataset.winId, 10),
                    href: el.dataset.href
                  });
                };
                window.addEventListener("mousedown", this.linkDownH, true);
                // a tab that comes back to the front re-reads the poll, and
                // by then the answer is the true one
                this.visibilityH = () => {
                  if (document.visibilityState === "visible") this.proveFocusH();
                };
                document.addEventListener("visibilitychange", this.visibilityH);

                if (!document.hasFocus()) document.body.classList.add("unfocused");
                this.syncCursorFocus();
                this.syncKeyboardOwner();
              },
              updated() {
                if (this.bootCheck()) return;
                Telem.time("updated", () => this.afterPatch());
              },
              // A window the reader scrolled comes back from a layout
              // restore as a NEW element, so its scrollTop is 0 and the
              // saved offset (S1) has to go back on. Once per element:
              // a later patch must not fight a live scroll. The expando
              // lives exactly as long as the element does.
              restoreClientScroll() {
                document.querySelectorAll(".buf.client-scroll").forEach((el) => {
                  if (el._composCtop) return;
                  el._composCtop = true;
                  // the first sight of an element records the server's
                  // scroll request without applying it: a reload must
                  // not replay a scroll from before
                  el._composScrollSeen = el.dataset.scroll || "";
                  if (el.dataset.manual !== "true") return;
                  const want = parseInt(el.dataset.ctop || "0", 10);
                  if (want > 0) el.scrollTop = want;
                });
              },
              // The server scrolls a client-scrolled window in lines
              // (scroll-other-window, scroll-window!): the leaf carries
              // data-scroll="GEN:LINES", and a new generation moves the
              // container by that many of its own line heights. The scroll
              // event then mirrors the pixel offset back (cscroll).
              applyScrollRequests() {
                document.querySelectorAll(".buf.client-scroll[data-scroll]").forEach((el) => {
                  const req = el.dataset.scroll;
                  if (el._composScrollSeen === undefined) { el._composScrollSeen = req; return; }
                  if (req === el._composScrollSeen) return;
                  el._composScrollSeen = req;
                  const lines = parseInt(req.split(":")[1] || "0", 10);
                  if (!lines) return;
                  const line = el.querySelector(".line");
                  const h = line ? line.getBoundingClientRect().height : 18;
                  el.scrollTop = Math.max(0, el.scrollTop + lines * h);
                });
              },
              afterPatch() {
                this.applyWhichKeyFilter();
                this.restoreClientScroll();
                this.applyScrollRequests();
                this.syncCursorFocus();
                this.syncKeyboardOwner();
                this.syncEditable();
                // re-measure after every patch: splits, buffer switches and
                // per-buffer styles all change how many rows fit where
                clearTimeout(this._wrt);
                this._wrt = setTimeout(() => Telem.time("win-rows", this.sendWinRows), 30);
                window.composRemeasure();

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
                Telem.detach(this);
                window.removeEventListener("keydown", this.handler);
                window.removeEventListener("keyup", this.keyupH);
                window.removeEventListener("resize", this.resizeH);
                window.removeEventListener("wheel", this.wheelH);
                window.removeEventListener("scroll", this.cscrollH, true);
                window.removeEventListener("focus", this.focusH);
                window.removeEventListener("blur", this.blurH);
                window.removeEventListener("pointerdown", this.proveFocusH, true);
                window.removeEventListener("pointerdown", this.pointerMarkH, true);
                window.removeEventListener("keydown", this.proveFocusH, true);
                window.removeEventListener("mousedown", this.linkDownH, true);
                document.removeEventListener("visibilitychange", this.visibilityH);
                window.removeEventListener("paste", this.pasteH);
                window.removeEventListener("beforeinput", this.beforeInputH, true);
                window.removeEventListener("compositionstart", this.compStartH, true);
                window.removeEventListener("compositionend", this.compEndH, true);
                document.removeEventListener("selectionchange", this.selChangeH);
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
                sessionStorage.getItem("compos-frame") ||
                (() => {
                  const old = localStorage.getItem("compos-frame");
                  if (old) {
                    localStorage.removeItem("compos-frame");
                    sessionStorage.setItem("compos-frame", old);
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
