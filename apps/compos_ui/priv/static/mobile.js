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
      this.resizeH = () => { this.viewport(); this.dock(); this.bindKey(); };
      window.addEventListener("resize", this.resizeH);
      this.handleEvent("navigate", ({ url }) => { window.location.href = url; });
      this.loadKeyPos();
      this.bindKey();
      this.bindRail();
      this.bindComposer();
      this.bindTabs();
      this.bindFilter();
    },
    updated() {
      this.remember();
      this.bootCheck();
      this.dock();
      this.bindFilter();
      this.bindKey();
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
    // how tall the composer and the tab rail are together, so a
    // sheet stops above them
    dock() {
      const c = this.el.querySelector(".hh-composer");
      const t = this.el.querySelector(".hh-tabs");
      const h = (c ? c.offsetHeight : 0) + (t ? t.offsetHeight : 0);
      if (h && h !== this.dockH) { this.dockH = h; this.el.style.setProperty("--dock-h", h + "px"); }
    },
    viewport() {
      const rows = Math.max(8, Math.floor((window.innerHeight - 260) / 19.5));
      if (rows !== this.rows) { this.rows = rows; this.push("viewport", { rows }); }
    },

    // ── the chord key: a tap toggles the panel, a drag moves it ──
    // Called after every patch and every resize: it places the key
    // and binds it once. The place is a property of the hook, not
    // of the element, because a re-render writes the element's
    // attributes again and an inline style set here does not
    // survive that.
    bindKey() {
      const key = document.getElementById("chord-key");
      if (!key) return;
      this.placeKey(key);
      if (key.hhBound) return;
      key.hhBound = true;
      let moved = false, startX = 0, startY = 0, offsetX = 0, offsetY = 0;
      key.addEventListener("pointerdown", (e) => {
        e.preventDefault(); key.setPointerCapture(e.pointerId);
        const r = key.getBoundingClientRect(); startX = e.clientX; startY = e.clientY;
        offsetX = e.clientX - r.left; offsetY = e.clientY - r.top;
        this.keyDrag = true; moved = false; key.classList.add("dragging");
      });
      key.addEventListener("pointermove", (e) => {
        if (!this.keyDrag) return;
        if (Math.abs(e.clientX - startX) > 6 || Math.abs(e.clientY - startY) > 6) moved = true;
        if (!moved) return;
        this.keyPos = { x: e.clientX - offsetX, y: e.clientY - offsetY };
        this.placeKey(key);
      });
      const stop = (e) => {
        if (!this.keyDrag) return;
        this.keyDrag = false; key.classList.remove("dragging");
        if (e.pointerId != null && key.hasPointerCapture(e.pointerId)) key.releasePointerCapture(e.pointerId);
        if (moved) this.saveKeyPos();
        else this.push("fan", { open: !key.classList.contains("on") });
      };
      key.addEventListener("pointerup", stop); key.addEventListener("pointercancel", stop);
    },
    // the key stays inside the window: a smaller window, or a
    // turn of the phone, brings it back in without losing where
    // the user put it
    placeKey(key) {
      if (!this.keyPos) return;
      const maxX = Math.max(0, window.innerWidth - key.offsetWidth);
      const maxY = Math.max(0, window.innerHeight - key.offsetHeight);
      key.style.left = Math.max(0, Math.min(maxX, this.keyPos.x)) + "px";
      key.style.top = Math.max(0, Math.min(maxY, this.keyPos.y)) + "px";
      key.style.right = "auto"; key.style.bottom = "auto";
    },
    // the place survives a reload, like the frame does
    loadKeyPos() {
      try {
        const raw = localStorage.getItem("compos-key-pos");
        const pos = raw && JSON.parse(raw);
        if (pos && typeof pos.x === "number" && typeof pos.y === "number") this.keyPos = pos;
      } catch (e) {}
    },
    saveKeyPos() {
      try { localStorage.setItem("compos-key-pos", JSON.stringify(this.keyPos)); } catch (e) {}
    },

    // ── the keys panel's filter: type, and Scheme searches every command ──
    // The field is outside the patch (phx-update="ignore"), so
    // its text survives a re-render. Each edit goes to the
    // server after a short pause; the reply is the list.
    bindFilter() {
      const input = document.getElementById("keys-filter-input");
      if (!input || input.dataset.bound) return;
      input.dataset.bound = "1";
      input.addEventListener("input", () => this.pushFilter());
      input.addEventListener("keydown", (e) => {
        if (e.key === "Escape") { e.preventDefault(); input.value = ""; this.pushFilter(); input.blur(); }
      });
    },
    pushFilter() {
      const input = document.getElementById("keys-filter-input");
      if (!input) return;
      clearTimeout(this.filterT);
      this.filterT = setTimeout(() => this.push("fan_filter", { q: input.value }), 60);
    },

    // ── the tab rail: a tap is the group, a hold is its buffers ──
    // One listener on the rail, so re-rendered tabs need no
    // rebinding. A hold that moves is a scroll, not a press.
    bindTabs() {
      const rail = this.el.querySelector(".hh-tabs");
      if (!rail || rail.dataset.bound) return;
      rail.dataset.bound = "1";
      const cancel = () => { clearTimeout(this.holdT); this.holdT = null; };
      rail.addEventListener("pointerdown", (e) => {
        const tab = e.target.closest && e.target.closest("[data-tab]");
        if (!tab) return;
        this.holdX = e.clientX; this.holdY = e.clientY; this.held = false;
        cancel();
        this.holdT = setTimeout(() => {
          this.held = true;
          this.push("tab_hold", { buf: tab.dataset.tab });
        }, 450);
      });
      rail.addEventListener("pointermove", (e) => {
        if (this.holdT && (Math.abs(e.clientX - this.holdX) > 8 || Math.abs(e.clientY - this.holdY) > 8)) cancel();
      });
      rail.addEventListener("pointerup", cancel);
      rail.addEventListener("pointercancel", cancel);
      // the tap that ends a hold is not a tap on the tab
      rail.addEventListener("click", (e) => {
        if (this.held) { this.held = false; e.stopPropagation(); e.preventDefault(); }
      }, true);
      rail.addEventListener("contextmenu", (e) => e.preventDefault());
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

