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
          .windows { flex: 1; display: flex; min-height: 0; background: var(--default-bg, #d5cdb9); }
          .windows > * { flex: 1; min-width: 0; min-height: 0; }
          .split { flex: 1; display: flex; min-width: 0; min-height: 0; }
          .split.h { flex-direction: row; }
          .split.v { flex-direction: column; }
          .split-child { display: flex; min-width: 0; min-height: 0; }
          .split-child > * { flex: 1; min-width: 0; min-height: 0; }
          .window {
            display: flex; flex-direction: column;
            background: var(--window-inactive-bg, #f4f0e6);
            box-shadow: inset -1px -1px 0 0 var(--border, #d5cdb9);
            min-width: 0; min-height: 0;
          }
          .window.active { background: var(--window-bg, #fdfcf8); }
          .buf {
            flex: 1;
            overflow: hidden; /* the server owns scrolling (viewport windowing) */
            padding: 12px 0 22px;
            font-family: var(--font-mono);
            font-size: 13px;
            line-height: 1.7;
            font-variant-ligatures: common-ligatures;
            letter-spacing: -0.1px;
          }
          .line { display: flex; align-items: flex-start; gap: 12px; padding: 0 16px 0 8px; }
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
          .region { background: var(--region-bg, #e7e9f1); }
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
          .mb-cands { max-height: 40dvh; overflow-y: auto; }
          .mb-cand {
            display: flex; align-items: baseline; gap: 12px;
            padding: 3px 14px;
            border-left: 2px solid transparent;
            font-family: var(--font-mono); font-size: 12.5px;
          }
          .mb-cand.selected {
            background: var(--select-bg, #e7e9f1);
            border-left-color: var(--accent-fg, #26356b);
          }
          .mb-cand.selected .mb-label { color: var(--accent-fg, #26356b); font-weight: 600; }
          .mb-label { white-space: nowrap; }
          .mb-hint {
            color: var(--dim-fg, #8a857a); font-size: 11px;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
          }
          .mb-input-row {
            display: flex; align-items: baseline;
            padding: 7px 14px 8px;
            border-top: 1px solid var(--border, #e2dbc9);
            background: var(--default-bg, #efeadf);
          }
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

          function keySpec(e) {
            if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return null;
            if (e.metaKey) return null; // let cmd-c/v/q etc. through to the browser
            const base = baseKey(e);
            if (base === null) return null;
            let spec = base;
            if (e.altKey) spec = "M-" + spec;
            if (e.ctrlKey) spec = "C-" + spec;
            return spec;
          }

          const PAGE_BOOT = document.querySelector("meta[name='boot-id']").getAttribute("content");
          const Hooks = {
            Keys: {
              mounted() {
                // remounted against a restarted server: this page's CSS/JS is
                // stale relative to the markup — hard reload
                if (this.el.dataset.boot && this.el.dataset.boot !== PAGE_BOOT) {
                  window.location.reload();
                  return;
                }
                this.handler = (e) => {
                  const spec = keySpec(e);
                  if (spec === null) return;
                  e.preventDefault();
                  this.pushEvent("key", { k: spec });
                };
                window.addEventListener("keydown", this.handler);

                // viewport geometry: tell the server how many rows fit
                this.lineHeight = 22;
                this.sendViewport = () => {
                  const line = document.querySelector(".line");
                  if (line) this.lineHeight = line.getBoundingClientRect().height || 22;
                  const area = document.querySelector(".windows");
                  if (area) this.pushEvent("viewport", { rows: Math.max(5, Math.floor(area.clientHeight / this.lineHeight)) });
                };
                requestAnimationFrame(this.sendViewport);
                this.resizeH = () => {
                  clearTimeout(this._rt);
                  this._rt = setTimeout(this.sendViewport, 150);
                };
                window.addEventListener("resize", this.resizeH);

                // wheel scrolls the server-side viewport of the active window
                this.wheelAcc = 0;
                this.wheelH = (e) => {
                  e.preventDefault();
                  this.wheelAcc += e.deltaY;
                  const lines = Math.trunc(this.wheelAcc / this.lineHeight);
                  if (lines !== 0) {
                    this.wheelAcc -= lines * this.lineHeight;
                    this.pushEvent("scroll", { lines });
                  }
                };
                window.addEventListener("wheel", this.wheelH, { passive: false });

                // hollow, non-blinking cursor when the OS window is unfocused
                this.focusH = () => document.body.classList.remove("unfocused");
                this.blurH = () => document.body.classList.add("unfocused");
                window.addEventListener("focus", this.focusH);
                window.addEventListener("blur", this.blurH);
                if (!document.hasFocus()) document.body.classList.add("unfocused");
              },
              destroyed() {
                window.removeEventListener("keydown", this.handler);
                window.removeEventListener("resize", this.resizeH);
                window.removeEventListener("wheel", this.wheelH);
                window.removeEventListener("focus", this.focusH);
                window.removeEventListener("blur", this.blurH);
              }
            }
          };

          const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            hooks: Hooks, params: { _csrf_token: csrf }
          });
          liveSocket.connect();
          if (liveSocket.disableDebug) liveSocket.disableDebug();
        </script>
      </body>
    </html>
    """
  end
end
