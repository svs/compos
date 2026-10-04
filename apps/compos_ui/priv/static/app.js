  // the browser chrome follows the theme's default background;
  // the faces arrive with the LiveView, so read them after each load
  window.addEventListener("phx:page-loading-stop", () => {
    const bg = getComputedStyle(document.documentElement).getPropertyValue("--default-bg").trim();
    const meta = document.querySelector('meta[name="theme-color"]');
    if (bg && meta) meta.setAttribute("content", bg);
  });
;

  // The viewport height in px, for the editor root's height under
  // the application zoom (see .editor-root). A px length scales by
  // the zoom the same way in every engine; a viewport unit does not.
  (() => {
    const set = () =>
      document.documentElement.style.setProperty("--viewport-h", innerHeight + "px");
    set();
    window.addEventListener("resize", set);
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
      // Option-Space arrives as a no-break space in some engines
      if (e.code === "Space") return "SPC";
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
    // already encode shift in the character itself, Emacs-style.
    // SPC is a printable character too -- Shift-Space still means
    // space, not a chord.
    if (e.shiftKey && base.length > 1 && base !== "SPC") spec = "S-" + spec;
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
  // An editable buffer has two states, and neither is a mode. The
  // user lands on it in the movement state: the Cmd-arrows travel
  // as keys, so the focus chords move past it. The
  // first key that is not ESC or C-g puts it in the editing state:
  // the Cmd-arrows are then the platform's line start and end and
  // document start and end, native, because a server round trip
  // for them read as lag.
  // ESC or C-g returns it to the movement state. A modifier alone
  // and a plain Cmd-arrow change nothing: they are the window
  // motion itself, or the shift before a chord.
  function editingAfterKey(e, editing) {
    if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return editing;
    if (e.key === "Escape") return false;
    if (e.ctrlKey && !e.altKey && !e.metaKey && e.key === "g") return false;
    if (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey &&
        NAMED[e.key] && e.key.startsWith("Arrow")) return editing;
    return true;
  }
  function nativeTextKey(e, editing) {
    const a = document.activeElement;
    // A pane switch can leave DOM focus in the old editable until
    // the next patch. Only the selected pane may handle keys natively.
    if (!a || !a.closest || !a.closest(".window.active .buf[contenteditable]")) return false;
    // The popup's keymap owns navigation and acceptance. Letting
    // the browser handle these keys also moves its native caret.
    if (document.querySelector(".window.active .cap-pop") &&
        (NATIVE_MOTION.includes(e.key) || e.key === "Enter")) return false;
    // Cmd-Up and Cmd-Down always walk the group, so they are keys.
    // Cmd-Left and Cmd-Right are keys until the buffer is in the
    // editing state (editingAfterKey); then the browser moves the caret.
    if (e.metaKey && (e.key === "ArrowUp" || e.key === "ArrowDown")) return false;
    if (e.metaKey && !e.ctrlKey && !e.altKey &&
        NATIVE_MOTION.includes(e.key) && e.key.startsWith("Arrow")) return editing === true;
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

  // the Keys hook owns the keyboard state of the page; the panel's own
  // hook reads its which-key filter from here
  let keysHook = null;

  const Hooks = {
    Terminal: {
      mounted() {
        if (!window.Terminal || !window.FitAddon) {
          this.el.textContent = "Terminal assets did not load.";
          return;
        }

        // The terminal wears the editor's theme. Every colour is a face:
        // `terminal', `terminal-cursor', `terminal-select' and the sixteen
        // `ansi-color-*' faces, read here as the pane's computed variables.
        // A theme names them; this hook only reads them.
        // The frame carries a CSS zoom (the `ui' face writes --ui-zoom, and a
        // buffer may scale its text again). xterm measures the cell in real
        // pixels and draws into a canvas it sizes itself, so under a zoom it
        // counts the wrong number of rows and the text sits below the top of
        // the pane. The pane cancels every zoom it sits under and puts the
        // same factor on the font size: the terminal reads at the editor's
        // scale and fits the pane exactly.
        this.zoom = () => {
          let z = 1;
          for (let n = this.el.parentElement; n; n = n.parentElement) {
            const v = parseFloat(getComputedStyle(n).zoom);
            if (v > 0 && v !== 1) z *= v;
          }
          return z;
        };
        this.look = () => {
          const zoom = this.zoom();
          this.el.style.zoom = 1 / zoom;
          const styles = getComputedStyle(this.el.closest(".window"));
          const v = (name, fallback) => styles.getPropertyValue(name).trim() || fallback;
          const ansi = (name, fallback) => v("--ansi-color-" + name + "-fg", fallback);
          const bg = v("--terminal-bg", "#111318");
          return {
            fontFamily: v("--terminal-family", "ui-monospace, Menlo, monospace"),
            fontSize: (parseFloat(v("--terminal-size", "13px")) || 13) * zoom,
            theme: {
              background: bg,
              foreground: v("--terminal-fg", "#e6e1d8"),
              cursor: v("--terminal-cursor-bg", "#d6b95e"),
              cursorAccent: bg,
              selectionBackground: v("--terminal-select-bg", "#36405a"),
              black: ansi("black", "#1c1c1c"),
              red: ansi("red", "#cd3131"),
              green: ansi("green", "#0dbc79"),
              yellow: ansi("yellow", "#e5e510"),
              blue: ansi("blue", "#2472c8"),
              magenta: ansi("magenta", "#bc3fbc"),
              cyan: ansi("cyan", "#11a8cd"),
              white: ansi("white", "#e5e5e5"),
              brightBlack: ansi("bright-black", "#666666"),
              brightRed: ansi("bright-red", "#f14c4c"),
              brightGreen: ansi("bright-green", "#23d18b"),
              brightYellow: ansi("bright-yellow", "#f5f543"),
              brightBlue: ansi("bright-blue", "#3b8eea"),
              brightMagenta: ansi("bright-magenta", "#d670d6"),
              brightCyan: ansi("bright-cyan", "#29b8db"),
              brightWhite: ansi("bright-white", "#e5e5e5")
            }
          };
        };
        this.term = new window.Terminal({
          cursorBlink: true,
          scrollback: 10000,
          lineHeight: 1.15,
          ...this.look()
        });
        // the pane carries its terminal, so a console session can read what
        // the PTY drew: document.querySelector(".terminal-view").__term
        this.el.__term = this.term;
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

        // The transcript replays into this terminal on every mount. It is raw
        // PTY bytes, wrapped at the width the PTY had when it wrote them, so
        // a terminal that is still 80 columns wide re-wraps every line and
        // leaves blank rows above the prompt. The pane is sized first, in
        // `connect' below, and only then does the channel join.
        this.connect = () => {
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
            .receive("ok", ({ history, cols, rows }) => {
              // wear the PTY's size, replay, then take the pane's size back
              if (cols > 0 && rows > 0) this.term.resize(cols, rows);
              write64(history);
              this.fit();
            })
            .receive("error", ({ reason }) => {
              this.term.write(`\r\n[terminal unavailable: ${reason}]\r\n`);
            });

          this.dataSub = this.term.onData(data => this.channel.push("input", { data }));
        };
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
          const editorEntry = ["C-x", "M-x", "C-g", "C-`", "M-`", "C-M-`", "s-p"].includes(spec);
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
          // a zoom change is a font change as well as a size change
          const z = this.zoom();
          if (z !== this.zoomWas) {
            this.zoomWas = z;
            this.retheme();
            return;
          }
          this.fitAddon.fit();
          if (this.channel) {
            this.channel.push("resize", { cols: this.term.cols, rows: this.term.rows });
          }
        };
        this.observer = new ResizeObserver(() => {
          cancelAnimationFrame(this.fitFrame);
          this.fitFrame = requestAnimationFrame(this.fit);
        });
        this.observer.observe(this.el);

        // A theme change rewrites the face stylesheet. Nothing else writes
        // a <style> element, so this observer fires once per theme change,
        // and the terminal reads its colours again.
        this.retheme = () => {
          if (!this.term) return;
          const look = this.look();
          this.term.options.fontFamily = look.fontFamily;
          this.term.options.fontSize = look.fontSize;
          this.term.options.theme = look.theme;
          this.fit();
        };
        this.themeObserver = new MutationObserver(() => {
          cancelAnimationFrame(this.themeFrame);
          this.themeFrame = requestAnimationFrame(this.retheme);
        });
        document.querySelectorAll("style").forEach((s) =>
          this.themeObserver.observe(s, {
            childList: true, characterData: true, subtree: true
          }));
        requestAnimationFrame(() => {
          // width first, transcript second
          this.fit();
          this.connect();
          const active = this.el.closest(".window")?.classList.contains("active");
          const editorOpen = document.querySelector(
            ".mb-panel, .which-key, .transient-panel"
          );
          if (active && !editorOpen && document.hasFocus()) this.term.focus();
        });
      },
      destroyed() {
        if (this.observer) this.observer.disconnect();
        if (this.themeObserver) this.themeObserver.disconnect();
        cancelAnimationFrame(this.themeFrame);
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
          } else if (m.compos === "key") {
            // An editor key the app does not keep (Cmd-arrows): take the
            // keyboard back and run it through the editor's dispatcher.
            const sink = document.getElementById("kb-sink");
            if (sink) sink.focus();
            window.dispatchEvent(new KeyboardEvent("keydown", {
              key: m.key, code: m.code,
              shiftKey: !!m.shiftKey, altKey: !!m.altKey,
              metaKey: !!m.metaKey, ctrlKey: !!m.ctrlKey,
              bubbles: true, cancelable: true
            }));
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
        // the page loads the buffer as it is now: a message already
        // posted is in it, so only a later one is sent in
        this.posted = this.el.dataset.appMessage;
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
        // app-post! (preview.scm): the package's news, with no reload
        const msg = this.el.dataset.appMessage;
        if (msg && msg !== this.posted) {
          this.posted = msg;
          try { w.postMessage({ compos: "message", data: JSON.parse(msg).data }, "*"); }
          catch (e) { console.warn("app-message", e); }
        }
      }
    },
    // a block list that follows its tail (a chat transcript): it
    // keeps the newest child in view until the reader scrolls up.
    BlockFollow: {
      mounted() {
        // The hook lives on the list inside the BlockList
        // component, so its lifecycle runs after the component
        // patch has supplied the list's final scrollHeight.
        this.scroller = this.el;
        this.buf = this.el.dataset.buf;
        this.stick = this.el.dataset.stick !== "false";
        this.anchor = this.el.dataset.scrollAnchor ? parseInt(this.el.dataset.scrollAnchor, 10) : null;
        this.offset = parseInt(this.el.dataset.scrollOffset || "0", 10);
        this.followSeq = parseInt(this.el.dataset.followSeq || "0", 10);
        this.report = null;
        this.placing = false;
        this.ro = null;
        this.reader = false;
        this.raf = null;
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
          // the hook's own placement is not a scroll the reader
          // made, so it must not move the place they left
          if (this.placing) return;
          this.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
          // A modal overlay covers the hit test point. Keep the
          // place the reader left rather than dropping it.
          const anchor = this.lastVisible();
          if (anchor) {
            this.anchor = anchor.index;
            this.offset = Math.round(anchor.offset);
          }
          clearTimeout(this.report);
          this.report = setTimeout(() => {
            this.pushEvent("follow_place", {
              buf: this.el.dataset.buf,
              stick: this.stick,
              top: Math.round(s.scrollTop),
              anchor: this.anchor,
              offset: this.offset
            });
          }, 250);
        };
        // The last visible block, found with one hit test. A scan
        // of every block calls getBoundingClientRect per block, and
        // each call flushes layout: on a long transcript that is one
        // layout per block on every scroll event, which blocks the
        // page until the reader stops. One hit test costs one flush,
        // whatever the transcript holds.
        this.lastVisible = () => {
          const r = this.scroller.getBoundingClientRect();
          const x = r.left + r.width / 2;
          const y = Math.min(r.bottom, window.innerHeight) - 1;
          if (y <= r.top) return null;
          const hit = document.elementFromPoint(x, y);
          const block = hit && hit.closest && hit.closest("[data-index]");
          if (!block || !this.scroller.contains(block)) return null;
          const b = block.getBoundingClientRect();
          return {
            index: parseInt(block.dataset.index, 10),
            offset: b.top - r.top
          };
        };
        this.scroller.addEventListener("scroll", this.scrollH);
        // A scroll event is an effect and cannot tell the
        // reader's hand from the hook's own assignment. A
        // gesture is the cause, so it is what ends the settle.
        this.inputH = () => { this.reader = true; };
        ["wheel", "touchstart", "pointerdown"].forEach((t) =>
          this.scroller.addEventListener(t, this.inputH, { passive: true })
        );
        this.settle();
      },
      // Put the transcript where the reader left it. A window that
      // is hidden or not laid out yet reports no height and a
      // short scrollHeight, so placing then lands a long chat near
      // its top and nothing runs again to correct it. Wait for a
      // real size, and never move a scroller already there.
      place() {
        const s = this.scroller;
        if (!s.isConnected) return;
        if (s.clientHeight === 0) {
          if (this.ro || typeof ResizeObserver === "undefined") return;
          this.ro = new ResizeObserver(() => {
            if (this.scroller.clientHeight === 0) return;
            this.ro.disconnect();
            this.ro = null;
            this.place();
          });
          this.ro.observe(s);
          return;
        }
        const max = Math.max(0, s.scrollHeight - s.clientHeight);
        const saved = this.anchor !== null ? this.el.querySelector(`[data-index="${this.anchor}"]`) : null;
        if (!this.stick && saved) {
          const r = this.scroller.getBoundingClientRect();
          const delta = saved.getBoundingClientRect().top - r.top - this.offset;
          if (Math.abs(delta) <= 1) return;
          this.placing = true;
          this.scroller.scrollTop += delta;
          requestAnimationFrame(() => { this.placing = false; });
          return;
        }
        const want = this.stick
          ? max
          : Math.min(parseInt(this.el.dataset.scrollTop || "0", 10), max);
        if (Math.abs(s.scrollTop - want) <= 1) return;
        this.placing = true;
        s.scrollTop = want;
        requestAnimationFrame(() => { this.placing = false; });
      },
      // A transcript keeps growing for a moment after a page
      // load: fonts land, images decode, late patches arrive.
      // Each one moves the place under the reader, so hold the
      // place until the height stops changing, then stop. The
      // reader's first gesture ends it early: their input wins,
      // and nothing here moves the view again.
      settle() {
        let last = -1;
        let still = 0;
        const t0 = Date.now();
        const step = () => {
          this.raf = null;
          const s = this.scroller;
          if (this.reader || !s || !s.isConnected) return;
          still = s.scrollHeight === last ? still + 1 : 0;
          last = s.scrollHeight;
          this.place();
          if (still >= 3 || Date.now() - t0 > 2000) return;
          this.raf = requestAnimationFrame(step);
        };
        this.raf = requestAnimationFrame(step);
      },
      updated() {
        // A window may show another chat without replacing the DOM
        // id. Adopt that buffer's saved position once; within one
        // chat the local flag wins over a lagging server patch.
        const buf = this.el.dataset.buf;
        const seq = parseInt(this.el.dataset.followSeq || "0", 10);
        if (buf !== this.buf) {
          this.buf = buf;
          this.followSeq = seq;
          this.stick = this.el.dataset.stick !== "false";
          this.anchor = this.el.dataset.scrollAnchor ? parseInt(this.el.dataset.scrollAnchor, 10) : null;
          this.offset = parseInt(this.el.dataset.scrollOffset || "0", 10);
          this.place();
          return;
        }
        // chat-to-bottom said, in so many words, follow again, and
        // chat-to-top said go to this place. A token is unambiguous
        // where the stick flag is not: it changes only when someone
        // asked, never because a report is in flight, so adopting
        // the place it came with cannot fight the reader.
        if (seq !== this.followSeq) {
          this.followSeq = seq;
          this.stick = this.el.dataset.stick !== "false";
          this.anchor = this.el.dataset.scrollAnchor ? parseInt(this.el.dataset.scrollAnchor, 10) : null;
          this.offset = parseInt(this.el.dataset.scrollOffset || "0", 10);
          this.place();
          return;
        }
        if (this.stick) { this.place(); return; }
        // A reader who left the tail keeps the block at the top of
        // their view where it was. The transcript window draws
        // earlier blocks above it on a reveal, and without this the
        // view stays at the same scrollTop over different blocks.
        const pin = this.pin;
        this.pin = null;
        const now = pin && this.el.querySelector(`[data-index="${pin.index}"]`);
        if (!now) return;
        const want = now.offsetTop - pin.fromTop;
        if (Math.abs(this.scroller.scrollTop - want) <= 1) return;
        this.placing = true;
        this.scroller.scrollTop = want;
        requestAnimationFrame(() => { this.placing = false; });
      },
      // the block at the top of the view, noted before a patch so
      // updated() can put it back where it was
      beforeUpdate() {
        this.pin = null;
        const s = this.scroller;
        if (this.stick || !s || !s.isConnected || s.clientHeight === 0) return;
        const r = s.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + r.width / 2, Math.max(r.top, 0) + 2);
        let block = hit && hit.closest && hit.closest("[data-index]");
        // the reveal row at the top has no index: pin the first
        // block below the top edge. The window bounds this walk.
        if (!block || !s.contains(block)) {
          block = null;
          for (const b of s.querySelectorAll("[data-index]")) {
            if (b.getBoundingClientRect().bottom > r.top) { block = b; break; }
          }
        }
        if (!block) return;
        // offsetTop, not a screen rect: it moves only when content
        // above the block changes, which is the change to undo
        this.pin = { index: block.dataset.index, fromTop: block.offsetTop - s.scrollTop };
      },
      destroyed() {
        this.el.removeEventListener("click", this.linkH);
        this.scroller.removeEventListener("scroll", this.scrollH);
        ["wheel", "touchstart", "pointerdown"].forEach((t) =>
          this.scroller.removeEventListener(t, this.inputH)
        );
        clearTimeout(this.report);
        if (this.raf) cancelAnimationFrame(this.raf);
        if (this.ro) { this.ro.disconnect(); this.ro = null; }
      }
    },
    // point moves in the buffer, so the mark moves in the block
    // view — and the reader has to be able to see where it went.
    // The renderer stamps data-current on marked, anchored blocks;
    // the LAST match in document order is the innermost. Only scroll
    // when it actually changed, or every unrelated re-render would
    // yank the view back.

    PeekCard: {
      mounted() {
        const ns = "http://www.w3.org/2000/svg";
        this.wire = document.createElementNS(ns, "svg");
        this.wire.classList.add("peek-connector");
        this.wire.setAttribute("aria-hidden", "true");
        this.path = document.createElementNS(ns, "path");
        this.path.setAttribute("fill", "none");
        this.path.setAttribute("stroke", "currentColor");
        this.path.setAttribute("stroke-width", "1.5");
        this.dot = document.createElementNS(ns, "circle");
        this.dot.setAttribute("r", "3");
        this.dot.setAttribute("fill", "currentColor");
        this.wire.append(this.path, this.dot);
        document.body.append(this.wire);
        this.schedule = () => {
          cancelAnimationFrame(this.raf);
          this.raf = requestAnimationFrame(() => this.place());
        };
        this.block = e => { e.preventDefault(); e.stopPropagation(); };
        this.click = e => {
          this.block(e);
          if (e.target.closest(".peek-card-dismiss")) {
            const owner = this.el.style.getPropertyValue("--peek-source-window").trim();
            this.pushEvent("ui_cmd", {win: owner, cmd: "listing-peek-dismiss"});
          }
        };
        this.scrollPeek = e => {
          const body = this.el.querySelector(".peek-card-body");
          if (body) body.scrollTop += e.deltaY;
          e.preventDefault(); e.stopPropagation();
        };
        this.el.addEventListener("wheel", this.scrollPeek, {passive: false});
        this.el.addEventListener("pointerdown", this.block);
        this.el.addEventListener("mousedown", this.block);
        this.el.addEventListener("click", this.click);
        ["contextmenu", "dragstart"].forEach(event =>
          this.el.addEventListener(event, this.block, {passive: false}));
        window.addEventListener("resize", this.schedule);
        document.addEventListener("scroll", this.schedule, true);
        this.resize = new ResizeObserver(this.schedule);
        this.resize.observe(this.el.closest(".windows") || document.body);
        this.mutations = new MutationObserver(this.schedule);
        this.schedule();
      },
      beforeUpdate() {
        this.savedScroll = this.el.querySelector(".peek-card-body")?.scrollTop;
      },
      updated() { this.place(); },
      place() {
        const ownerId = this.el.style.getPropertyValue("--peek-source-window").trim();
        const point = Number(this.el.style.getPropertyValue("--peek-source-point"));
        const owner = document.getElementById("win-" + ownerId);
        if (this.owner !== owner) {
          this.mutations.disconnect();
          this.owner = owner;
          if (owner) this.mutations.observe(owner, {subtree: true, childList: true,
            attributes: true, attributeFilter: ["data-current", "data-s"]});
        }
        if (!owner) { this.el.style.visibility = "hidden"; this.wire.style.display = "none"; return; }
        const area = (owner.closest(".windows") || document.body).getBoundingClientRect();
        const o = owner.getBoundingClientRect();
        let row = null;
        for (const candidate of owner.querySelectorAll(".line[data-s]")) {
          if (Number(candidate.dataset.s) <= point && candidate.getClientRects().length) row = candidate;
        }
        row ||= owner.querySelector("[data-current], .line.hl-line, .selected");
        if (this.row !== row) {
          this.row?.classList.remove("peek-source-row");
          this.row = row;
          row?.classList.add("peek-source-row");
        }
        const r = row ? row.getBoundingClientRect() : o;
        const pad = 10;
        // The card lands on the pane NEXT to the list, not at a frame edge:
        // pinning it to the edge threw it clear across a wide frame. Take
        // the neighbour away from the list, and if the list is alone in the
        // frame, lay the card over the list's own right half.
        const neighbours = Array.from((owner.closest(".windows") || document.body)
            .querySelectorAll(".window"))
          .filter(w => w !== owner && w !== this.el && !w.classList.contains("listing-peek"))
          .map(w => w.getBoundingClientRect())
          .filter(b => b.width > 80 && b.height > 60
                    && b.top < o.bottom - 8 && b.bottom > o.top + 8);
        const after = neighbours.filter(b => b.left >= o.right - 8)
          .sort((a, b) => a.left - b.left)[0];
        const before = neighbours.filter(b => b.right <= o.left + 8)
          .sort((a, b) => b.right - a.right)[0];
        const outward = o.left + o.width / 2 < area.left + area.width / 2;
        const host = (outward ? (after || before) : (before || after));
        const box = host
          ? {left: host.left + pad, top: host.top + pad,
             width: host.width - pad * 2, height: host.height - pad * 2}
          : {left: o.left + o.width / 2, top: o.top + pad,
             width: o.width / 2 - pad, height: o.height - pad * 2};
        const width = Math.max(180, Math.min(box.width, area.width - pad * 2));
        const height = Math.max(100, Math.min(box.height, area.height - pad * 2));
        const left = Math.max(area.left + pad, Math.min(area.right - width - pad, box.left));
        const top = Math.max(area.top + pad, Math.min(area.bottom - height - pad, box.top));
        const right = left + width / 2 > o.left + o.width / 2;
        const sy = Math.max(o.top + 12, Math.min(o.bottom - 12, r.top + r.height / 2));
        // Compos zooms its editor root independently of the viewport.
        // DOM rectangles and the connector use viewport pixels; fixed
        // descendants still inherit CSS zoom, so convert the card back.
        let zoom = 1;
        for (let el = this.el; el; el = el.parentElement) {
          zoom *= Number.parseFloat(getComputedStyle(el).zoom) || 1;
        }
        Object.assign(this.el.style, {left: (left / zoom) + "px", top: (top / zoom) + "px",
          width: (width / zoom) + "px", height: (height / zoom) + "px", right: "auto", bottom: "auto",
          visibility: "visible"});
        const body = this.el.querySelector(".peek-card-body");
        const doc = body?.querySelector(".peek-document");
        if (doc && !doc.dataset.peekSized) {
          doc.dataset.peekSized = "true";
          const size = () => {
            const root = doc.contentDocument?.documentElement;
            if (root) doc.style.height = Math.max(300, root.scrollHeight) + "px";
          };
          doc.addEventListener("load", size);
          size();
        }
        const content = doc?.getAttribute("srcdoc") || body?.textContent;
        if (body && this.content !== content) {
          body.scrollTop = body.scrollHeight;
          this.content = content;
        } else if (body && this.savedScroll !== undefined) {
          body.scrollTop = this.savedScroll;
        }
        this.savedScroll = undefined;
        const sx = right ? Math.min(r.right, o.right) - 8 : Math.max(r.left, o.left) + 8;
        const tx = right ? left : left + width;
        const ty = Math.max(top + 28, Math.min(top + height - 28, sy));
        const bend = Math.max(24, Math.abs(tx - sx) * .45);
        const dir = right ? 1 : -1;
        this.path.setAttribute("d", "M " + sx + " " + sy + " C " +
          (sx + dir * bend) + " " + sy + ", " + (tx - dir * bend) + " " + ty + ", " + tx + " " + ty);
        this.dot.setAttribute("cx", sx);
        this.dot.setAttribute("cy", sy);
        this.wire.style.display = row && r.bottom > o.top && r.top < o.bottom ? "" : "none";
      },
      destroyed() {
        cancelAnimationFrame(this.raf);
        this.resize.disconnect(); this.mutations.disconnect();
        this.row?.classList.remove("peek-source-row");
        this.wire.remove();
        window.removeEventListener("resize", this.schedule);
        document.removeEventListener("scroll", this.schedule, true);
        this.el.removeEventListener("wheel", this.scrollPeek);
        this.el.removeEventListener("pointerdown", this.block);
        this.el.removeEventListener("mousedown", this.block);
        this.el.removeEventListener("click", this.click);
        ["contextmenu", "dragstart"].forEach(event =>
          this.el.removeEventListener(event, this.block));
      }
    },
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
    // one rule for every list the arrows move through: the area
    // scrolls, so the selected row must not leave the screen. The
    // transient and the minibuffer candidates both wear this; a
    // list that scrolls and has no hook loses its selection off
    // the bottom, which is the bug this exists to prevent.
    SelectionScroll: {
      mounted() { this.follow(); },
      updated() { this.follow(); },
      follow() {
        const cur = this.el.querySelector(".selected");
        if (cur) cur.scrollIntoView({ block: "nearest" });
      }
    },
    // The panel is one surface per pending prefix, and the filter
    // writes hidden flags on to its rows. A growing prefix -- C-x,
    // then C-x g -- patches new rows into the same element, so the
    // flags and the held modifiers of the prefix before it hid rows
    // that belong to the new one: the title said "0 / 7 bindings"
    // over "No matching commands". The hook drops the filter when
    // the prefix changes, and applies it again after every patch, so
    // the flags never outlive the rows they were written for.
    WhichKey: {
      mounted() { this.sync(); },
      updated() { this.sync(); },
      destroyed() { if (keysHook) keysHook.resetWhichKeyFilter(); },
      sync() {
        if (!keysHook) return;
        const pending = this.el.dataset.pending || "";
        if (pending !== this.pending) {
          this.pending = pending;
          keysHook.resetWhichKeyFilter();
        }
        keysHook.applyWhichKeyFilter();
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
      disconnected() { this.clientErrorsConnected = false; },
      reconnected() { this.clientErrorsConnected = true; this.bootCheck(); },
      mounted() {
        if (this.bootCheck()) return;
        Telem.attach(this);
        this.handleEvent("navigate", ({url}) => window.location.assign(url));
        keysHook = this;
        this.whichKeyHeld = new Set();
        this.whichKeyQuery = "";
        this.whichKeyFiltering = false;
        // A modifier held while the panel opens, and released while
        // another window has the focus, never sends its keyup here:
        // the filter would then hide every row of every later panel.
        // One reset answers for that too.
        this.resetWhichKeyFilter = () => {
          this.whichKeyHeld.clear();
          this.whichKeyQuery = "";
          this.whichKeyFiltering = false;
        };
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
          const staleEditable = document.activeElement?.closest?.(".window:not(.active) .buf[contenteditable]");
          // A rendered Browse pane owns focus inside its iframe.
          // Switching into the adjacent rich chat leaves that iframe
          // inactive, but a rich chat has no contenteditable node of
          // its own to reclaim focus. Return to the editor's sink so
          // its key dispatch can receive the next chat input.
          const stalePreview = document.activeElement?.closest?.(".window:not(.active) iframe");
          if (document.hasFocus() && (editorOpen || (!terminal && focusedTerminal) || staleEditable || stalePreview)) {
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
          // The terminal's own handler answers for xterm's keyboard surface,
          // and only for that surface. A key that lands anywhere else in the
          // pane reached neither handler and died there, so M-x did nothing.
          if (e.target.closest && e.target.closest(".terminal-view") &&
              e.target.classList.contains("xterm-helper-textarea")) return;
          const panel = document.querySelector(".which-key");
          // the filter dies with the panel it belonged to. A query
          // left standing swallowed the next chord's second key as
          // filter text instead of dispatching it.
          if (!panel && (this.whichKeyFiltering || this.whichKeyQuery)) {
            this.whichKeyFiltering = false;
            this.whichKeyQuery = "";
            this.whichKeyHeld.clear();
          }
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
          // The landing: the active window and the buffer it shows.
          // A new landing starts in the movement state. The state
          // then follows the keys that reach the editable surface.
          const landedWin = document.querySelector(".window.active");
          const landing = landedWin
            ? landedWin.dataset.winId + ":" + (landedWin.dataset.buffer || "")
            : null;
          if (landing !== this._landing) {
            this._landing = landing;
            this._editing = false;
          }
          const onSurface = document.activeElement && document.activeElement.closest &&
            document.activeElement.closest(".window.active .buf[contenteditable]");
          if (onSurface) this._editing = editingAfterKey(e, this._editing);
          const native = nativeTextKey(e, this._editing);
          // Typing is not a selection gesture. Finish an intentional
          // caret move before its following key, then disarm reports
          // caused by the DOM patch for that key.
          if (!native || !NATIVE_MOTION.includes(e.key)) {
            if (this._selPending && onSurface) this.sendSelection(onSurface,
              performance.now() - (this._motionAt || 0) < 1200);
            clearTimeout(this._selt);
            this._selPending = false;
            this._gestureAt = 0;
          }
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
          // a Cmd-arrow that travels as a key (movement state)
          // moves no caret and is not the cause of a selection report
          const cmdKeyed = e.metaKey && !native && e.key.startsWith("Arrow");
          if (NATIVE_MOTION.includes(e.key) && !cmdKeyed) {
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
            if (native) this._gestureAt = this._motionAt;
          }
          // Up and Down go through Selection.modify on every surface:
          // the native caret motion across the flex rows of a
          // client-scrolled buffer stops short of the next line
          if (native && onSurface &&
              !e.metaKey && !e.altKey && !e.ctrlKey &&
              (e.key === "ArrowUp" || e.key === "ArrowDown")) {
            e.preventDefault();
            this.moveEditable(onSurface, e.shiftKey ? "extend" : "move",
              e.key === "ArrowUp" ? "backward" : "forward", "line", 1);
            return;
          }
          if (native) return;
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
          // a measuring probe (rowMetrics, the column probe) stands
          // in the editable for one layout and is not source
          if (p.closest("[data-probe]")) return false;
          return !(p.classList.contains("cursor") && t.textContent === " ");
        };
        const domByte = (node, offset) => {
          const el = node.nodeType === 1 ? node : node.parentElement;
          const line = el && el.closest(".line");
          if (!line) return null;
          const start = parseInt(line.dataset.s, 10);
          if (isNaN(start)) return null;
          const content = (line.matches(".line-content") ? line : line.querySelector(".line-content"));
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
          const lines = Array.from(buf.querySelectorAll(":scope > .line, :scope > .semantic-record > .line"));
          let line = null;
          for (const l of lines) {
            const st = parseInt(l.dataset.s, 10);
            if (isNaN(st) || st > byte) break;
            line = l;
          }
          if (!line) return null;
          const content = (line.matches(".line-content") ? line : line.querySelector(".line-content"));
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
          buf.querySelectorAll(":scope > .line.hl-line, :scope > .semantic-record > .line.hl-line").forEach((l) => { if (l !== row) l.classList.remove("hl-line"); });
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
          if (this._selPending) this.sendSelection(buf,
            performance.now() - (this._motionAt || 0) < 1200);
          clearTimeout(this._selt);
          this._selPending = false;
          this._gestureAt = 0;
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
          // Carry the measured caret for diagnostics. Collapsed
          // edits use the server's point: a matching text version
          // alone does not prove the native caret has caught up.
          const caret =
            domSel && domSel.focusNode && buf.contains(domSel.focusNode)
              ? domByte(domSel.focusNode, domSel.focusOffset)
              : null;
          const ver = parseInt(buf.dataset.v, 10);
          Telem.push(this, "intent", {
            win: winIdOf(buf), type: e.inputType,
            from: from == null ? -1 : from, to: to == null ? -1 : to,
            at: caret == null ? -1 : caret,
            v: Number.isFinite(ver) ? ver : -1,
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
          // The reader's selection outranks a stale point. A report
          // is on its way, or has gone and not come back: until the
          // server's point is the one reported, a patch (a chat
          // writing above the caret) must not put the selection back
          // where the server still thinks it is. A report the server
          // never echoes (it moved point past an insertion) waits
          // three seconds, then the server's point stands.
          if (this._selPending) { markCurrentRow(buf); return; }
          // A report is acknowledged when the server's point is the
          // one reported. It is never DEFENDED: holding the caret
          // still for three seconds while the two sides disagreed was
          // a workaround for point and the caret drifting apart, and
          // the intent now carries the caret's own byte, so they do
          // not drift. The caret follows point, always.
          const rep = this._reported;
          if (rep && !rep.acked && rep.point === pt &&
              (rep.mark === null ? pt : rep.mark) === wantAnchor) rep.acked = true;
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
          // Point moves only when the user moves it. A native motion
          // key or a pointer stamps the time; a selectionchange with no
          // gesture behind it is the browser reacting to a patch
          // (a text node under the caret replaced, a focus the
          // page took) and is not a report.
          if (!this._gestureAt || performance.now() - this._gestureAt > 1500) return;
          // The last hand on the DOM decides. A patch that landed
          // after the gesture (a chat writing above the caret)
          // replaced the nodes under the caret, and the caret it
          // left is the browser's, not the reader's. Reporting it
          // moved point and dropped the region on every edit.
          if ((this._patchAt || 0) > (this._gestureAt || 0)) return;
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
          this._selPending = true;
          const gesture = this._gestureAt;
          this._selt = setTimeout(() => {
            this._selPending = false;
            if (this._settingSel) return;
            if (this._gestureAt !== gesture || (this._patchAt || 0) > gesture) return;
            // the surface that had the caret may have lost it since:
            // a patch made the buffer read-only again, or another
            // window went active. That caret is nobody's move.
            if (!buf.isConnected || !buf.hasAttribute("contenteditable")) return;
            const w = buf.closest(".window");
            if (!w || !w.classList.contains("active")) return;
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
        // Pointer gestures: a drag moves with a button down, a click ends on
        // pointerup. Capture phase, so a handler that stops the
        // event still stamps it.
        this.gestureH = (e) => {
          if (e.type === "pointermove" && !e.buttons) return;
          this._gestureAt = performance.now();
        };
        ["pointerdown", "pointerup", "pointermove", "touchstart", "touchend"]
          .forEach((t) => window.addEventListener(t, this.gestureH, true));
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
          this.pushEvent("sel", { win: winIdOf(buf), point, mark, keep: !!keep,
            v: parseInt(buf.dataset.v, 10) });
          this._gestureAt = 0;
          // syncEditable waits for the server to agree with this
          this._reported = { point, mark, at: performance.now(), acked: false };
          return true;
        };
        // a motion command asks the browser's layout to move the
        // selection; the answer is the selection, as bytes
        this.moveEditable = (buf, alter, dir, granularity, count) => {
          const sel = window.getSelection();
          if (!sel || !buf.contains(sel.focusNode)) return;
          const n = Math.max(1, Math.min(parseInt(count, 10) || 1, 1000));
          const focusRow = () => {
            const el = sel.focusNode.nodeType === 1 ? sel.focusNode : sel.focusNode.parentElement;
            return el.closest(".line");
          };
          const caretTop = () => {
            const r = document.createRange();
            r.setStart(sel.focusNode, sel.focusOffset); r.collapse(true);
            return r.getBoundingClientRect().top;
          };
          for (let i = 0; i < n; i++) {
            const before = domByte(sel.focusNode, sel.focusOffset);
            const anchor = alter === "extend" ? domByte(sel.anchorNode, sel.anchorOffset) : null;
            const row = focusRow(), top = caretTop();
            sel.modify(alter, dir, granularity);
            const after = domByte(sel.focusNode, sel.focusOffset);
            const rows = buf.querySelectorAll(".line");
            const edge = dir === "backward" ? rows[0] : rows[rows.length - 1];
            if (granularity === "line" && !buf.classList.contains("client-scroll") &&
                row === edge && focusRow() === row &&
                (before === after || Math.abs(caretTop() - top) < 1)) {
              clearTimeout(this._selt);
              this._selPending = false; this._gestureAt = 0;
              this.pushEvent("edge_motion", {win: winIdOf(buf), point: before,
                v: parseInt(buf.dataset.v, 10), dir: dir === "backward" ? -1 : 1,
                extend: alter === "extend", mark: anchor, count: n - i});
              return;
            }
          }
          // a client-scrolled buffer scrolls itself: a caret that
          // Selection.modify moved out of view lands in the middle of
          // the window, as the hl-line follow in updated() does
          if (buf.classList.contains("client-scroll") && sel.focusNode) {
            const r = document.createRange();
            r.setStart(sel.focusNode, sel.focusOffset); r.collapse(true);
            const cr = r.getBoundingClientRect(), br = buf.getBoundingClientRect();
            if (cr.height && (cr.top < br.top || cr.bottom > br.bottom)) {
              buf._composSelfScroll = performance.now();
              buf.scrollTop += (cr.top + cr.bottom) / 2 - (br.top + br.bottom) / 2;
            }
          }
          this.sendSelection(buf, true);
        };
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
          try {
            this.moveEditable(buf, alter, dir, granularity, count);
          } catch (_) { return; }
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
          const content = (lineEl.matches(".line-content") ? lineEl : lineEl.querySelector(".line-content"));
          const numEl = lineEl.querySelector(".linenum");
          if (!content || (!numEl && !lineEl.dataset.line)) return null;
          const field = el.closest(".semantic-direct > [data-col]");
          let col = field ? parseInt(field.dataset.col, 10) : 0, found = false;
          const walker = document.createTreeWalker(field || content, NodeFilter.SHOW_TEXT);
          let t;
          while ((t = walker.nextNode())) {
            if (t === node) { col += offset; found = true; break; }
            col += t.textContent.length;
          }
          if (!found && !content.contains(node)) col = 0;
          return { line: parseInt(lineEl.dataset.line || numEl.textContent, 10), col };
        };
        this.mouseH = (e) => {
          if (e.target.closest(".listing-peek")) return;
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
        // lineHeight is a row as a rect reports it, for the wheel,
        // whose deltaY arrives in that same space; rowPx is the same
        // row in layout px, for anything divided into a clientHeight
        // or added to a scrollTop. Under CSS zoom the two differ.
        this.lineHeight = 22;
        this.rowPx = 22;
        this.lastWinRows = "";
        this.lastWinCols = "";
        this.sendViewport = () => {
          const m = this.rowMetrics(document.querySelector(".line"));
          if (m) { this.lineHeight = m.visual; this.rowPx = m.layout; }
          // a frame of chat windows has no line grid to probe: carry
          // the default row into layout px anyway, or a zoomed-out
          // frame reports every row twice
          else this.rowPx = this.lineHeight / this.zoomRatio();
          const area = document.querySelector(".windows");
          if (area) this.pushEvent("viewport", { rows: Math.max(5, Math.floor(this.textHeight(area) / this.rowPx)) });
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
          const lines = buf.querySelectorAll(":scope > .line, :scope > .semantic-record > .line");
          if (!lines.length) return rows;
          const box = buf.getBoundingClientRect();
          const lo = box.top - box.height, hi = box.bottom + box.height;
          for (let k = firstFrom(lines, lo); k < lines.length; k++) {
            const ln = lines[k];
            if (ln.getBoundingClientRect().top > hi) break;
            const start = parseInt(ln.dataset.s, 10);
            if (!Number.isFinite(start)) continue;
            const content = (ln.matches(".line-content") ? ln : ln.querySelector(".line-content"));
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
            const h = this.rowHeight(ln);
            if (h > 0) rows[win.dataset.winId] = Math.max(3, Math.floor(this.textHeight(buf) / h));
            // how many characters fit on one line: the probe wears
            // the line's own font, and the gutter is not text
            const content = ln && (ln.matches(".line-content") ? ln : ln.querySelector(".line-content"));
            if (content) {
              // the same cache as rowMetrics: a character's width
              // moves with the font, not with the patch that asked
              const ccs = getComputedStyle(content);
              const ckey2 = ccs.fontFamily + "|" + ccs.fontSize + "|" +
                this.zoomRatio() + "|" + (document.fonts ? document.fonts.status : "");
              this._charWidth = this._charWidth || new WeakMap();
              const chit = this._charWidth.get(content);
              let cw;
              if (chit && chit.key === ckey2) {
                cw = chit.val;
              } else {
                const probe = document.createElement("span");
                probe.dataset.probe = "1";
                probe.textContent = "0".repeat(80);
                probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre";
                content.appendChild(probe);
                cw = probe.getBoundingClientRect().width / 80;
                probe.remove();
                this._charWidth.set(content, { key: ckey2, val: cw });
              }
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
        this.clientErrorsConnected = true;
        this.jsErrH = (e) => {
          if (!this.clientErrorsConnected) return;
          const m = e.message || (e.reason && (e.reason.stack || e.reason.message)) || "unknown";
          const at = e.filename ? ` @${e.filename}:${e.lineno}` : "";
          // Reporting must never produce another unhandled error,
          // including a disconnect racing with this event.
          try {
            Promise.resolve(this.pushEvent("client_error", { m: `${m}${at}`.slice(0, 500) })).catch(() => {});
          } catch (_) {}

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
          if (e.target.closest?.(".listing-peek")) return;
          // followed block lists (a chat transcript), diff cards
          // (.diff-scroll) and buffers under the ship-all threshold
          // (.buf.client-scroll) own their scrolling natively — the
          // server viewport only drives large line-grid buffers
          // still using the windowed path
          if (
            e.target.closest &&
            e.target.closest("[data-block-list], .blocks-scroll, .buf.client-scroll, .terminal-view")
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
          // the reader (see BlockFollow.scrollH)
          if (!el.isConnected || el.clientHeight === 0) return;
          // neither is a scroll WE made to keep point in view. It
          // reports as a pin (S1 sets manual), and a pinned window
          // stops following: the first imenu step would scroll, and
          // every step after it would mark the row and leave the
          // window where it was — a preview that quits after one
          // move. The mark expires, so a reader scroll right after
          // ours still counts.
          if (el._composSelfScroll && performance.now() - el._composSelfScroll < 300) return;
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
          // the first sight of an element records the server's
          // scroll request without applying it: a reload must
          // not replay a scroll from before
          if (el._composScrollSeen === undefined) {
            el._composScrollSeen = el.dataset.scroll || "";
          }
          if (el.dataset.manual !== "true") {
            el._composCtop = true;
            return;
          }
          const want = parseInt(el.dataset.ctop || "0", 10);
          // an element with no height clamps the offset to 0 and
          // would come back at the top for good; leave it for a
          // patch that has a size
          if (want > 0 && el.clientHeight === 0) return;
          el._composCtop = true;
          if (want > 0) el.scrollTop = want;
        });
      },
      // The server scrolls a client-scrolled window in lines
      // (scroll-other-window, scroll-window!): the leaf carries
      // data-scroll="GEN:LINES", and a new generation moves the
      // container by that many of its own visual rows. The scroll
      // event then mirrors the pixel offset back (cscroll).
      applyScrollRequests() {
        document.querySelectorAll(".buf.client-scroll[data-scroll]").forEach((el) => {
          const req = el.dataset.scroll;
          if (el._composScrollSeen === undefined) { el._composScrollSeen = req; return; }
          if (req === el._composScrollSeen) return;
          el._composScrollSeen = req;
          const lines = parseInt(req.split(":")[1] || "0", 10);
          if (!lines) return;
          // round the distance down. A part-row left behind is an
          // overlap; a part-row skipped is a gap, and the reader
          // never learns what went by.
          const h = this.rowHeight(el.querySelector(".line"));
          const px = Math.sign(lines) * Math.floor(Math.abs(lines) * h);
          el.scrollTop = Math.max(0, el.scrollTop + px);
        });
      },
      // One visual row, wearing the line's own font, in both of the
      // page's coordinate spaces. Two things make the row unreadable
      // off a .line box: .line-content wraps, so one logical line can
      // measure many rows tall, and the CSS zoom on .editor-root
      // (ui-scale, and the browser's own zoom) scales what a rect
      // reports while scrollTop, clientHeight and offsetHeight stay in
      // layout px. A 20-row probe answers both at once, at any zoom
      // and any per-buffer text scale, and offsetHeight's rounding
      // divides away.
      rowMetrics(line) {
        const host =
          line && (line.matches(".line-content") ? line : line.querySelector(".line-content") || line);
        if (!host) return null;
        // Measuring appends a node inside the editable and forces a
        // layout, and afterPatch asks after every patch. The answer
        // moves with the font and the zoom, never with the patch
        // that asked, so keep it per host and touch the DOM only
        // when one of those moves. Probing under the caret on every
        // write from another window is what reported a byte past
        // point, and an unechoed report holds the caret for three
        // seconds.
        const rcs = getComputedStyle(host);
        // fonts.status flips once when a web font lands: a metric
        // measured before it did is wrong, and nothing else moves.
        const rkey = rcs.fontFamily + "|" + rcs.fontSize + "|" + rcs.lineHeight + "|" +
          this.zoomRatio() + "|" + (document.fonts ? document.fonts.status : "");
        this._rowMetrics = this._rowMetrics || new WeakMap();
        const rhit = this._rowMetrics.get(host);
        if (rhit && rhit.key === rkey) return rhit.val;
        const probe = document.createElement("span");
        probe.dataset.probe = "1";
        probe.style.cssText =
          "position:absolute;visibility:hidden;white-space:pre;left:-9999px;top:0";
        probe.textContent = "0\n".repeat(20).slice(0, -1);
        host.appendChild(probe);
        const visual = probe.getBoundingClientRect().height / 20;
        const layout = probe.offsetHeight / 20;
        probe.remove();
        const rval = visual > 0 && layout > 0 ? { visual, layout } : null;
        this._rowMetrics.set(host, { key: rkey, val: rval });
        return rval;
      },
      // The height that actually shows text. clientHeight is the
      // padding box, and .buf pads 12px and 22px (a writing buffer
      // far more) — counting that as a row and a half made a page
      // advance past rows the reader never saw. getComputedStyle
      // answers in layout px, the same space as clientHeight.
      textHeight(el) {
        const cs = getComputedStyle(el);
        const pad = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
        return Math.max(0, el.clientHeight - pad);
      },
      // What a rect is scaled by against the layout box: the CSS
      // zoom on .editor-root (ui-scale, and the browser's own).
      // Measured on the root, so it needs to know neither the zoom
      // nor which engine draws it.
      zoomRatio() {
        const root = document.querySelector(".editor-root");
        const h = root && root.offsetHeight;
        if (!h) return 1;
        const r = root.getBoundingClientRect().height / h;
        return r > 0 ? r : 1;
      },
      // the row that scrollTop and clientHeight speak in
      rowHeight(line) {
        const m = this.rowMetrics(line);
        return (m && m.layout) || this.rowPx || 22;
      },
      placeCompletionDocs() {
        const doc = document.querySelector(".window.active .cap-doc");
        if (!doc) return;
        const popup = doc.closest(".cap-pop");
        if (!popup) return;
        if (!doc.matches(":popover-open")) doc.showPopover();
        const zoom = this.zoomRatio();
        doc.style.width = Math.min(440, window.innerWidth - 16) / zoom + "px";
        const p = popup.getBoundingClientRect();
        const right = window.innerWidth - p.right - 16;
        const left = p.left - 16;
        const beside = Math.max(right, left) >= 240;
        if (beside) doc.style.width = Math.min(440, Math.max(right, left)) / zoom + "px";
        const d = doc.getBoundingClientRect();
        const x = beside ? (right >= left ? p.right + 8 : p.left - d.width - 8)
          : Math.max(8, Math.min(p.left, window.innerWidth - d.width - 8));
        const y = beside ? p.top : p.bottom + 8;
        doc.style.left = x / zoom + "px";
        doc.style.top = Math.max(8, Math.min(y, window.innerHeight - d.height - 8)) / zoom + "px";
      },
      afterPatch() {
        // the patch stamp: selChangeH compares it with the gesture
        // stamp to tell a reader's caret move from a patch's
        this._patchAt = performance.now();
        clearTimeout(this._selt);
        this._selPending = false;
        this._gestureAt = 0;
        this.applyWhichKeyFilter();
        this.restoreClientScroll();
        this.applyScrollRequests();
        this.syncCursorFocus();
        this.syncKeyboardOwner();
        this.syncEditable();
        // re-measure after every patch: splits, buffer switches and
        this.placeCompletionDocs();
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
            // ours, not the reader's: cscrollH reads this and sends
            // no pin
            container._composSelfScroll = performance.now();
            el.scrollIntoView({ block: "center" });
          }
        });
      },
      destroyed() {
        Telem.detach(this);
        this.clientErrorsConnected = false;
        window.removeEventListener("error", this.jsErrH);
        window.removeEventListener("unhandledrejection", this.jsErrH);
        window.removeEventListener("keydown", this.handler);
        window.removeEventListener("keyup", this.keyupH);
        window.removeEventListener("resize", this.resizeH);
        window.removeEventListener("wheel", this.wheelH);
        window.removeEventListener("scroll", this.cscrollH, true);
        window.removeEventListener("focus", this.focusH);
        window.removeEventListener("blur", this.blurH);
        window.removeEventListener("pointerdown", this.proveFocusH, true);
        window.removeEventListener("pointerdown", this.pointerMarkH, true);
        ["keydown", "pointerdown", "pointerup", "pointermove", "touchstart", "touchend"]
          .forEach((t) => window.removeEventListener(t, this.gestureH, true));
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
    // strip-slide.js copies the old panes before a strip scroll replaces them
    dom: {
      onBeforeElUpdated: (from, to) => {
        if (window.stripSlide) window.stripSlide.before(from, to);
      },
      onPatchEnd: () => {
        if (window.stripSlide) window.stripSlide.after();
      }
    },
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

