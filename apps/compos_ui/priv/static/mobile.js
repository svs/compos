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
      this.push = (ev, payload) => this.pushEvent(ev, payload);
      this.remember();
      this.bootCheck();
      this.viewport();
      this.dock();
      this.resizeH = () => { this.viewport(); this.dock(); };
      window.addEventListener("resize", this.resizeH);
      this.handleEvent("navigate", ({ url }) => { window.location.href = url; });
      this.bindRail();
      this.bindComposer();
    },
    updated() {
      this.remember();
      this.bootCheck();
      this.dock();
      this.bindRail();
      this.bindComposer();
      if (this.el.dataset.mb !== this.mbWas) {
        this.mbWas = this.el.dataset.mb;
        const input = document.getElementById("composer");
        if (input) { input.value = ""; this.last = ""; this.arm(); }
      }
    },
    destroyed() { window.removeEventListener("resize", this.resizeH); },

    // the frame this tab holds, so a reload comes back to it
    remember() {
      const f = this.el.dataset.frame;
      if (f) { try { sessionStorage.setItem("compos-frame-m", f); } catch (e) {} }
    },
    // a daemon restart changes the boot id; this page belongs
    // to the old one and reloads
    bootCheck() {
      const meta = document.querySelector('meta[name="boot-id"]');
      const boot = meta && meta.getAttribute("content");
      if (boot && this.el.dataset.boot && boot !== this.el.dataset.boot) window.location.reload();
    },
    // how tall the composer and the bar are: a prompt's sheet stops
    // above both, so the field stays under the thumb; a sheet of rows
    // stops above the bar alone
    dock() {
      const c = this.el.querySelector(".hh-composer");
      const n = this.el.querySelector(".hh-nav");
      const nh = n ? n.offsetHeight : 0;
      const h = (c ? c.offsetHeight : 0) + nh;
      if (h && h !== this.dockH) { this.dockH = h; this.el.style.setProperty("--dock-h", h + "px"); }
      if (nh && nh !== this.navH) { this.navH = nh; this.el.style.setProperty("--nav-h", nh + "px"); }
    },
    viewport() {
      // the window's own height when it is drawn, else the screen less the chrome
      const body = this.el.querySelector(".hh-body");
      const h = body && body.clientHeight > 0 ? body.clientHeight - 26 : window.innerHeight - 200;
      const rows = Math.max(8, Math.floor(h / 19.5));
      if (rows !== this.rows) { this.rows = rows; this.push("viewport", { rows }); }
    },

    // ── the rail: a drag is point ──────────────────────────
    bindRail() {
      const rail = this.el.querySelector("[data-rail]");
      if (!rail || rail.dataset.bound) return;
      rail.dataset.bound = "1";
      const scrub = (e) => {
        const r = rail.getBoundingClientRect();
        const frac = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
        const now = Date.now();
        if (this.railAt && now - this.railAt < 60) { this.railNext = frac; return; }
        this.railAt = now;
        this.push("rail", { frac });
      };
      rail.addEventListener("pointerdown", (e) => { e.preventDefault(); rail.setPointerCapture(e.pointerId); this.scrubbing = true; scrub(e); });
      rail.addEventListener("pointermove", (e) => { if (this.scrubbing) scrub(e); });
      const stop = () => {
        this.scrubbing = false;
        if (this.railNext != null) { this.push("rail", { frac: this.railNext }); this.railNext = null; }
      };
      rail.addEventListener("pointerup", stop);
      rail.addEventListener("pointercancel", stop);
    },

    // ── the composer: one field, three registers ───────────
    // While a prompt is up the field feeds the minibuffer one
    // key at a time, so the prompt narrows as the user types.
    // Otherwise RET sends the line to Scheme, which decides.
    arm() {
      const input = document.getElementById("composer");
      const send = document.getElementById("composer-send");
      if (send) send.classList.toggle("armed", !!(input && input.value));
    },
    bindComposer() {
      const input = document.getElementById("composer");
      const send = document.getElementById("composer-send");
      if (!input || input.dataset.bound) return;
      input.dataset.bound = "1";
      this.last = "";
      const submit = () => {
        if (this.el.dataset.mb === "true") { this.push("key", { k: "RET" }); return; }
        const text = input.value;
        if (!text.trim()) return;
        input.value = "";
        this.last = "";
        this.arm();
        this.push("compose", { text });
      };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); submit(); }
        else if (e.key === "Escape") { e.preventDefault(); this.push("key", { k: "C-g" }); }
        else if (this.el.dataset.mb === "true" && (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "Tab")) {
          e.preventDefault(); this.push("key", { k: keyOf(e.key) });
        }
      });
      input.addEventListener("input", () => {
        this.arm();
        if (this.el.dataset.mb !== "true") return;
        const now = input.value, was = this.last || "";
        let common = 0;
        while (common < now.length && common < was.length && now[common] === was[common]) common++;
        const ks = [];
        for (let i = common; i < was.length; i++) ks.push("DEL");
        for (const ch of Array.from(now.slice(common))) ks.push(keyOf(ch));
        this.last = now;
        if (ks.length) this.push("keys", { ks });
      });
      if (send) send.addEventListener("click", submit);
    }
  }
};

const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  hooks: Hooks,
  params: () => ({
    _csrf_token: csrf,
    // the phone tab is its own frame, remembered per tab
    frame: sessionStorage.getItem("compos-frame-m")
  })
});
liveSocket.connect();
if (liveSocket.disableDebug) liveSocket.disableDebug();

