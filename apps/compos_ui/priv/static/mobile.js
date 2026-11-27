window.addEventListener("phx:page-loading-stop", () => {
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--default-bg").trim();
  const meta = document.querySelector('meta[name="theme-color"]');
  if (bg && meta) meta.setAttribute("content", bg);
});


// the same named keys as the desktop client (app.js NAMED)
const NAMED = {
  Enter: "RET", Backspace: "DEL", Delete: "<delete>", Tab: "TAB", Escape: "ESC", " ": "SPC",
  ArrowUp: "<up>", ArrowDown: "<down>", ArrowLeft: "<left>", ArrowRight: "<right>",
  Home: "<home>", End: "<end>", PageUp: "<prior>", PageDown: "<next>"
};
const keyOf = (ch) => NAMED[ch] || ch;

const Hooks = {
  // a followed block list (a chat transcript): stay at the bottom
  // while the reader is there, and hand links to the server
  BlockFollow: {
    mounted() {
      this.stick = this.el.dataset.stick !== "false";
      this.followSeq = parseInt(this.el.dataset.followSeq || "0", 10);
      this.scrollH = () => {
        const s = this.el;
        if (!s.isConnected || s.clientHeight === 0) return;
        this.stick = s.scrollHeight - s.scrollTop - s.clientHeight < 40;
        clearTimeout(this.report);
        this.report = setTimeout(() => {
          this.pushEvent("follow_place", { buf: this.el.dataset.buf, stick: this.stick, top: Math.round(s.scrollTop) });
        }, 250);
      };
      this.el.addEventListener("scroll", this.scrollH, { passive: true });
      this.linkH = (e) => {
        const link = e.target.closest && e.target.closest("a[href]");
        if (!link || !this.el.contains(link)) return;
        const href = link.getAttribute("href") || "";
        if (href === "" || href.startsWith("#")) return;
        e.preventDefault();
        this.pushEvent("preview_link", { win: parseInt(this.el.dataset.win, 10), href });
      };
      this.el.addEventListener("click", this.linkH);
      this.place();
    },
    // the distance from the reader's view to the end: a reveal of
    // earlier blocks grows the list above the reader, and this
    // distance is what stays the same
    beforeUpdate() { const s = this.el; this.fromEnd = s.scrollHeight - s.scrollTop; },
    updated() {
      const seq = parseInt(this.el.dataset.followSeq || "0", 10);
      if (this.el.dataset.buf !== this.buf) { this.buf = this.el.dataset.buf; this.stick = true; }
      // chat-to-bottom asked to follow again, chat-to-top to go to a place
      else if (seq !== this.followSeq) {
        this.stick = this.el.dataset.stick !== "false";
        if (!this.stick) { this.followSeq = seq; this.el.scrollTop = parseInt(this.el.dataset.scrollTop || "0", 10); return; }
      }
      this.followSeq = seq;
      if (this.stick) this.place();
      else if (this.fromEnd !== undefined) this.el.scrollTop = this.el.scrollHeight - this.fromEnd;
    },
    place() { const s = this.el; if (this.stick) s.scrollTop = s.scrollHeight; },
    destroyed() { this.el.removeEventListener("scroll", this.scrollH); this.el.removeEventListener("click", this.linkH); clearTimeout(this.report); }
  },
  Handheld: {
    mounted() {
      this.remember();
      this.bootCheck();
      this.viewport();
      this.resizeH = () => this.viewport();
      window.addEventListener("resize", this.resizeH);
      this.handleEvent("navigate", ({ url }) => { window.location.href = url; });
      this.bind();
    },
    updated() { this.remember(); this.bootCheck(); this.bind(); },
    destroyed() { window.removeEventListener("resize", this.resizeH); },

    // the frame this tab holds, so a reload comes back to it
    remember() {
      const f = this.el.dataset.frame;
      if (f) { try { sessionStorage.setItem("compos-frame-m", f); } catch (e) {} }
    },
    // a daemon restart changes the boot id: this page reloads
    bootCheck() {
      const meta = document.querySelector('meta[name="boot-id"]');
      const boot = meta && meta.getAttribute("content");
      if (boot && this.el.dataset.boot && boot !== this.el.dataset.boot) { window.location.reload(); return; }
      // a saved stylesheet or script: this page holds the old ones
      const assets = document.querySelector('meta[name="assets"]');
      const have = assets && assets.getAttribute("content");
      if (have && this.el.dataset.assets && have !== this.el.dataset.assets) window.location.reload();
    },
    // the rows the one window has room for
    viewport() {
      const body = this.el.querySelector(".hh-body");
      const h = body && body.clientHeight > 0 ? body.clientHeight : window.innerHeight - 160;
      const rows = Math.max(8, Math.floor(h / 19.5));
      if (rows !== this.rows) { this.rows = rows; this.pushEvent("viewport", { rows }); }
    },
    bind() { this.bindComposer(); this.bindPrompt(); },

    // the composer: RET or Send sends the line to the chat on show
    bindComposer() {
      const input = document.getElementById("composer");
      const send = document.getElementById("composer-send");
      if (!input || input.dataset.bound) return;
      input.dataset.bound = "1";
      const arm = () => { if (send) send.classList.toggle("armed", !!input.value.trim()); };
      const submit = () => {
        const text = input.value;
        if (!text.trim()) return;
        input.value = "";
        arm();
        this.pushEvent("compose", { text });
      };
      input.addEventListener("input", arm);
      input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); submit(); } });
      if (send) send.addEventListener("click", submit);
    },

    // a prompt's field: each change goes to the prompt as keys, so its
    // rows narrow as you type; RET takes, Escape cancels
    bindPrompt() {
      const input = document.getElementById("mb-input");
      if (!input || input.dataset.bound) return;
      input.dataset.bound = "1";
      let last = input.value || "";
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.pushEvent("key", { k: "RET" }); }
        else if (e.key === "Escape") { e.preventDefault(); this.pushEvent("key", { k: "C-g" }); }
        else if (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "Tab") { e.preventDefault(); this.pushEvent("key", { k: keyOf(e.key) }); }
      });
      input.addEventListener("input", () => {
        const now = input.value;
        let common = 0;
        while (common < now.length && common < last.length && now[common] === last[common]) common++;
        const ks = [];
        for (let i = common; i < last.length; i++) ks.push("DEL");
        for (const ch of Array.from(now.slice(common))) ks.push(keyOf(ch));
        last = now;
        if (ks.length) this.pushEvent("keys", { ks });
      });
      setTimeout(() => input.focus(), 50);
    }
  }
};

const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  hooks: Hooks,
  // The daemon restarts in a few seconds. The default wait between
  // tries grows to 5 s, so the page came back seconds after the daemon
  // did. A refused try on this machine costs nothing: try four times
  // a second for the first minute, then every 2 s.
  reconnectAfterMs: (tries) => (tries <= 240 ? 250 : 2000),
  params: () => ({
    _csrf_token: csrf,
    // the phone tab is its own frame, remembered per tab
    frame: sessionStorage.getItem("compos-frame-m")
  })
});
liveSocket.connect();
// A tab in the background runs its timers late. When it shows again
// and the socket is down, try at once.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !liveSocket.isConnected()) liveSocket.connect();
});
if (liveSocket.disableDebug) liveSocket.disableDebug();

