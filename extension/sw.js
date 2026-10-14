// sw.js — the extension half of the compos wire.
//
// Two directions, one protocol. The daemon asks the browser to do things
// (list tabs, run JS, read a page, type into it); the browser asks the daemon
// to do things (what commands exist, run this one, handle this chord). A frame
// with an `op` is a request, a frame with `ok` is a reply — so the two sides
// can use overlapping ids without colliding.
//
// One extension, many daemons: people run one per life — work, personal — each
// on its own port, or on another machine. Every daemon gets its own socket. Unlike v1, a daemon may
// address ANY tab, not only tabs it opened: the whole point is that compos's
// keys and commands are ambient.
//
// CDP is attached ON DEMAND and dropped when idle. Content scripts cover the
// overlay and ordinary reads with nothing to detect and no infobar; the
// debugger comes out only for input that has to be trusted.

// a daemon is "PORT" on this machine, or "HOST:PORT" on another one
const DEFAULTS = { daemons: ["4004"], scan: true, scanFrom: 4004, scanTo: 4013, keys: true };
const LOCAL = "127.0.0.1";
const DEFAULT_URL = "http://localhost:4004/";

const RETRY_MS = 3000;
const RESCAN_MS = 15000;
// MV3 kills an idle worker at 30s; socket traffic resets that timer
const HEARTBEAT_MS = 20000;
// how long a debugger session lingers before we let go of the tab
const CDP_IDLE_MS = 30000;

/** "host:port" -> Conn */
const conns = new Map();

function localHost(host) {
  return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(String(host).toLowerCase());
}

/** the one record for a daemon's address; every local spelling is one key */
function daemonAt(host, port) {
  host = localHost(host) ? LOCAL : String(host).toLowerCase();
  return { host, port, key: `${host}:${port}`, local: host === LOCAL };
}

/** "4004" | "host:4004" | "[::1]:4004" -> daemon record, or null */
function parseDaemon(text) {
  const m = /^(?:(\[[^\]]+\]|[^:\s]+):)?(\d{1,5})$/.exec(String(text).trim());
  if (!m) return null;
  const port = Number(m[2]);
  if (port < 1 || port > 65535) return null;
  return daemonAt(m[1] || LOCAL, port);
}

async function settings() {
  const stored = await chrome.storage.sync.get(null);
  const s = { ...DEFAULTS, ...stored };
  // v0.6 stored pinned ports as numbers under `ports`
  if (!stored.daemons && Array.isArray(stored.ports)) s.daemons = stored.ports.map(String);
  s.daemons = s.daemons.map(parseDaemon).filter(Boolean);
  return s;
}

// --- one daemon ------------------------------------------------------------

class Conn {
  constructor(host, port) {
    this.host = host;
    this.port = port;
    this.local = host === LOCAL;
    this.key = `${host}:${port}`;
    this.address = this.local ? `:${port}` : this.key;
    this.name = this.address;
    this.pending = new Map(); // id -> {resolve, reject}
    this.nextId = 1;
    this.ws = null;
    this.open();
  }

  open() {
    // a scan probe to a dead port fails fast and quietly; that is the whole
    // discovery mechanism, so onerror must stay silent
    const ws = new WebSocket(`ws://${this.host}:${this.port}/browser`);
    this.ws = ws;

    ws.onopen = () => {
      for (const w of [...connWaiters]) w(this);
      clearInterval(this.heart);
      this.heart = setInterval(() => this.post({ op: "ping" }), HEARTBEAT_MS);
      // a fresh daemon knows nothing about our windows; tell it at once, so
      // the first tab it opens already lands beside the frame that asked
      announceAll().catch(() => {});
    };

    ws.onmessage = (ev) => this.onFrame(ev.data);

    ws.onclose = () => {
      clearInterval(this.heart);
      this.ws = null;
      for (const { reject } of this.pending.values()) reject(new Error("daemon went away"));
      this.pending.clear();
      // a pinned port is worth waiting for; a scanned one is rediscovered
      if (this.pinned) this.retry = setTimeout(() => this.open(), RETRY_MS);
      else conns.delete(this.key);
    };

    ws.onerror = () => ws.close();
  }

  get up() {
    return this.ws?.readyState === 1;
  }

  /** where a browser tab finds this daemon's editor */
  get url() {
    return `http://${this.local ? "localhost" : this.host}:${this.port}/`;
  }

  post(msg) {
    if (this.up) this.ws.send(JSON.stringify(msg));
  }

  /** send a line to the daemon's log — see below for why */
  say(level, text) {
    this.post({ event: "log", level, text });
  }

  /** ask the daemon something and await its reply */
  ask(op, args = {}) {
    return new Promise((resolve, reject) => {
      if (!this.up) return reject(new Error("daemon not connected"));
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.post({ id, op, ...args });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${op} timed out`));
      }, 30000);
    });
  }

  async onFrame(data) {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return;
    }

    // a reply to something we asked
    if (msg.ok !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error || "failed"));
      return;
    }

    if (msg.op === "ping") return;
    if (msg.event === "hello") {
      this.name = msg.name || this.name;
      return;
    }

    // a request from the daemon
    try {
      const op = OPS[msg.op];
      if (!op) throw new Error(`unknown op ${msg.op}`);
      this.post({ id: msg.id, ok: true, result: await op.call(this, msg) });
    } catch (e) {
      this.post({ id: msg.id, ok: false, error: String((e && e.message) || e) });
    }
  }

  close() {
    this.pinned = false;
    clearTimeout(this.retry);
    clearInterval(this.heart);
    this.ws?.close();
    conns.delete(this.key);
  }
}

// --- CDP, on demand --------------------------------------------------------
// Attached only for operations that need trusted events, and released after a
// quiet period so the "started debugging this browser" bar isn't permanent.

const attached = new Map(); // tabId -> timeout handle

// Firefox has no chrome.debugger. The same sw.js runs there, and every op that
// wanted CDP falls back to what a content script can do, or says it can't.
const HAS_CDP = !!chrome.debugger;

async function cdp(tabId, method, params = {}) {
  if (!HAS_CDP) throw new Error(`${method} needs the debugger, which this browser does not have`);
  if (!attached.has(tabId)) {
    await chrome.debugger.attach({ tabId }, "1.3");
  } else {
    clearTimeout(attached.get(tabId));
  }
  attached.set(
    tabId,
    setTimeout(() => detach(tabId), CDP_IDLE_MS)
  );
  return chrome.debugger.sendCommand({ tabId }, method, params);
}

async function detach(tabId) {
  if (!HAS_CDP) return;
  const t = attached.get(tabId);
  if (t) clearTimeout(t);
  attached.delete(tabId);
  try {
    await chrome.debugger.detach({ tabId });
  } catch {
    /* tab already gone */
  }
}

if (HAS_CDP) chrome.debugger.onDetach.addListener(({ tabId }) => attached.delete(tabId));
chrome.tabs.onRemoved.addListener((tabId) => attached.delete(tabId));

// Without CDP, input is dispatched from inside the page. These events carry
// isTrusted:false, so a hardened page may ignore them; most pages don't.
// Text goes in through execCommand("insertText"), which frameworks such as
// React see as real typing.
async function synthetic(tabId, kind, args) {
  const [res] = await chrome.scripting.executeScript({
    target: { tabId },
    func: (kind, a) => {
      // CDP's modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8
      const mods = (m = 0) => ({ altKey: !!(m & 1), ctrlKey: !!(m & 2), metaKey: !!(m & 4), shiftKey: !!(m & 8) });
      const target = () => document.activeElement || document.body;
      const key = (type, init) => target().dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }));
      if (kind === "type") {
        for (const ch of a.text) {
          key("keydown", { key: ch });
          key("keypress", { key: ch });
          document.execCommand("insertText", false, ch);
          key("keyup", { key: ch });
        }
        return { typed: a.text.length };
      }
      if (kind === "key") {
        const init = { key: a.key || a.text || "", code: a.code || "", keyCode: a.windowsVirtualKeyCode || 0, ...mods(a.modifiers) };
        key("keydown", init);
        if (a.text) document.execCommand("insertText", false, a.text);
        key("keyup", init);
        return { ok: true };
      }
      if (kind === "click") {
        const el = document.elementFromPoint(a.x, a.y);
        if (!el) return { error: `nothing at ${a.x},${a.y}` };
        const button = { left: 0, middle: 1, right: 2 }[a.button] ?? 0;
        const init = { bubbles: true, cancelable: true, composed: true, clientX: a.x, clientY: a.y, button };
        el.dispatchEvent(new PointerEvent("pointerdown", init));
        el.dispatchEvent(new MouseEvent("mousedown", init));
        if (el.focus) el.focus();
        el.dispatchEvent(new PointerEvent("pointerup", init));
        el.dispatchEvent(new MouseEvent("mouseup", init));
        el.dispatchEvent(new MouseEvent(button === 2 ? "contextmenu" : "click", init));
        return { clicked: [a.x, a.y] };
      }
      return { error: `unknown input ${kind}` };
    },
    args: [kind, args],
  });
  const r = res?.result;
  if (r?.error) throw new Error(r.error);
  return r;
}

// --- talking to a tab's content script -------------------------------------

async function tell(tabId, msg, tries = 8) {
  // fail immediately and legibly on a bad id, rather than retrying eight times
  // and reporting "no compos in tab [object Object]" — that cost an assistant
  // its whole turn budget
  if (typeof tabId !== "number") {
    throw new Error(`bad tab id ${JSON.stringify(tabId)} — pass the id, or a tab from tab-list`);
  }
  for (let i = 0; i < tries; i++) {
    try {
      const r = await chrome.tabs.sendMessage(tabId, msg);
      if (r !== undefined) return r;
    } catch {
      /* not injected yet, or a chrome:// page */
    }
    await new Promise((r) => setTimeout(r, 120));
  }
  throw new Error(`no compos in tab ${tabId} (chrome:// page?)`);
}

// --- ops the daemon can call ----------------------------------------------

// The daemon's idea of a window can outlive the window: a frame keeps the
// binding until something replaces it. Ask before we use it, and fall back to
// Chrome's own choice rather than failing the call.
async function windowExists(windowId) {
  if (typeof windowId !== "number") return false;
  try {
    await chrome.windows.get(windowId);
    return true;
  } catch {
    return false;
  }
}

// the reader's own window: minimized, made once, reused — snapshots
// load their tabs here so the user's tab strip never changes
async function readerWindow() {
  const stored = await chrome.storage.session.get("readerWin");
  if (stored.readerWin && (await windowExists(stored.readerWin))) return stored.readerWin;
  const w = await chrome.windows.create({
    url: "about:blank",
    state: "minimized",
    focused: false,
  });
  await chrome.storage.session.set({ readerWin: w.id });
  return w.id;
}

// what travels as text; everything else travels as bytes
const TEXT_TYPE = /^text\/|xml|json|javascript|x-sh$/;

// one fetch reply carries at most this many bytes
const MAX_BYTES = 16 * 1024 * 1024;

// bytes -> base64, in chunks: one apply() over a megabyte overflows the
// argument stack
function base64(buf) {
  const bytes = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

async function waitTabComplete(tab, cap = 25000) {
  const current = await chrome.tabs.get(tab);
  if (current.status === "complete") return true;
  return new Promise((resolve) => {
    const done = (value) => {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(value);
    };
    const timer = setTimeout(() => done(false), cap);
    const listener = (id, info) => {
      if (id === tab && info.status === "complete") done(true);
    };
    chrome.tabs.onUpdated.addListener(listener);
  });
}

async function waitRendered(tab, selector, cap = 8000, quiet = 250) {
  await chrome.scripting.executeScript({
    target: { tabId: tab },
    func: (sel, timeout, quietMs) =>
      new Promise((resolve) => {
        const found = () => !!sel && !!document.querySelector(sel);
        if (found()) return resolve(true);
        let idle;
        const stop = (value) => {
          observer.disconnect();
          clearTimeout(cutoff);
          clearTimeout(idle);
          resolve(value);
        };
        const settle = () => {
          clearTimeout(idle);
          idle = setTimeout(() => stop(false), quietMs);
        };
        const cutoff = setTimeout(() => stop(false), timeout);
        const observer = new MutationObserver(() => {
          if (found()) return stop(true);
          if (!sel) settle();
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });
        if (!sel) settle();
      }),
    args: [selector || null, cap, quiet],
  });
}

async function renderedPage(tab) {
  const [result] = await chrome.scripting.executeScript({
    target: { tabId: tab },
    func: () => ({
      html: document.documentElement.outerHTML,
      url: location.href,
      title: document.title,
    }),
  });
  return result?.result || { html: "", url: "", title: "" };
}

const OPS = {
  // Run Chrome's built-in Gemini Nano Prompt API in the active page. The
  // model is local to Chrome, so this connector needs no network credential.
  async "gemini-nano"({ system = "", messages = [], prompt }) {
    const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab?.id) throw new Error("Chrome has no active tab for Gemini Nano");

    const result = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      world: "MAIN",
      func: async ({ system, messages, prompt }) => {
        if (!globalThis.LanguageModel?.create) {
          throw new Error("Chrome Prompt API is not available in this tab");
        }

        const initialPrompts = [];
        if (system) initialPrompts.push({ role: "system", content: system });
        for (const message of messages || []) {
          if (message?.role && typeof message.content === "string") {
            initialPrompts.push({ role: message.role, content: message.content });
          }
        }

        const session = await LanguageModel.create({ initialPrompts });
        return session.prompt(prompt);
      },
      args: [{ system, messages, prompt }],
    });

    return result?.[0]?.result || "";
  },

  // The editor's reader fetches THROUGH the browser: the user's cookies
  // and Chrome's HTTP cache ride along, so a page that knows them logged
  // in reads logged in. The reply names the content TYPE, because the
  // editor reads by type: text comes back as text, and anything else
  // comes back as bytes. A PDF read as text is not a PDF any more --
  // every byte that is not UTF-8 becomes a replacement character.
  async fetch(msg) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 20000);
    try {
      const r = await fetch(msg.url, { credentials: "include", signal: ctl.signal });
      const type = (r.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
      if (!type || TEXT_TYPE.test(type)) {
        return { status: r.status, type, html: await r.text() };
      }
      const buf = await r.arrayBuffer();
      // a body too big for one frame is a download, not a reading
      if (buf.byteLength > MAX_BYTES) return { status: r.status, type, bytes: buf.byteLength };
      return { status: r.status, type, body: base64(buf), bytes: buf.byteLength };
    } finally {
      clearTimeout(timer);
    }
  },

  // The AUTHENTICATED read: a real background tab loads the page — the
  // site's own session cookies, SSO redirects and scripts all run —
  // and the rendered document comes back; the tab closes behind it.
  // The plain fetch op above misses per-site sessions (Substack keeps
  // one per publication subdomain, refreshed only in a real tab).
  // The tab lives in the reader's own MINIMIZED window, so nothing
  // shows in the user's tab strip.
  async snapshot({ url, wait }) {
    const t = await chrome.tabs.create({
      url,
      active: false,
      windowId: await readerWindow(),
    });
    try {
      await new Promise((resolve) => {
        const done = () => {
          clearTimeout(timer);
          chrome.tabs.onUpdated.removeListener(listener);
          resolve();
        };
        const timer = setTimeout(done, 25000);
        const listener = (id, info) => {
          if (id === t.id && info.status === "complete") done();
        };
        chrome.tabs.onUpdated.addListener(listener);
      });
      // A script-rendered page is not done when the load is, and nothing
      // here polls for it. WAIT names a selector the caller knows the
      // content by: a MutationObserver inside the page answers the instant
      // that selector arrives, so the read costs exactly as long as the page
      // took. Without a selector there is no event to name, so the observer
      // waits for the DOM to stop changing instead, and a page that is
      // already still answers at once rather than serving a flat beat.
      // Amazon's cart is the case that made this necessary: it answers
      // "complete" with an empty basket and fills it afterwards, so reading
      // on "complete" reads a cart with nothing in it.
      await chrome.scripting.executeScript({
        target: { tabId: t.id },
        func: (sel, cap, quiet) =>
          new Promise((resolve) => {
            const found = () => !!sel && !!document.querySelector(sel);
            if (found()) return resolve(true);
            let idle;
            const stop = (v) => {
              obs.disconnect();
              clearTimeout(cutoff);
              clearTimeout(idle);
              resolve(v);
            };
            // no selector: the page is done when it goes QUIET for a beat
            const settle = () => {
              clearTimeout(idle);
              idle = setTimeout(() => stop(false), quiet);
            };
            const cutoff = setTimeout(() => stop(false), cap);
            const obs = new MutationObserver(() => {
              if (found()) return stop(true);
              if (!sel) settle();
            });
            obs.observe(document.documentElement, { childList: true, subtree: true });
            if (!sel) settle();
          }),
        args: [wait || null, 8000, 250],
      });
      const [res] = await chrome.scripting.executeScript({
        target: { tabId: t.id },
        func: () => document.documentElement.outerHTML,
      });
      return { html: (res && res.result) || "" };
    } finally {
      try {
        await chrome.tabs.remove(t.id);
      } catch {}
    }
  },

  // Navigate the app's persistent background tab and answer only when the
  // rendered page is ready. The tab stays where it is and never takes focus.
  async navigate({ tab, url, wait }) {
    await chrome.tabs.update(tab, { url, active: false });
    await waitTabComplete(tab);
    await waitRendered(tab, wait || null);
    return { tab, ...(await renderedPage(tab)) };
  },

  // Press a button in the app's background tab, the way a person would, and
  // answer with the page once it has settled. No debugger: el.click() is
  // enough for LiveView. LiveView marks the pressed element phx-click-loading
  // until the server's patch lands, and applies the patch in one task, so the
  // first mutation after the mark clears (and WAIT matches) is the finished page.
  async press({ tab, selector, wait, cap = 10000 }) {
    const [res] = await chrome.scripting.executeScript({
      target: { tabId: tab },
      func: (sel, wait, cap) =>
        new Promise((resolve) => {
          const el = document.querySelector(sel);
          if (!el) return resolve({ error: `no element: ${sel}` });
          const ready = () =>
            !document.querySelector(".phx-click-loading") && (!wait || !!document.querySelector(wait));
          const stop = (timedOut) => {
            obs.disconnect();
            clearTimeout(cutoff);
            resolve({ html: document.documentElement.outerHTML, timedOut });
          };
          const obs = new MutationObserver(() => ready() && stop(false));
          obs.observe(document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            characterData: true,
          });
          const cutoff = setTimeout(() => stop(true), cap);
          el.click();
          if (ready()) stop(false);
        }),
      args: [selector, wait || null, cap],
    });
    const r = res?.result;
    if (r?.error) throw new Error(r.error);
    return { tab, ...r };
  },

  // Every compos tab answers a frame probe with its frame id. The daemon
  // sweeps frames with M-x refresh-frames: a frame no tab answers for is
  // dead. Probe ALL editor tabs, not the editors map — that map keeps
  // one binding per window, and a background compos tab still holds a
  // live frame.
  async frames() {
    const tabs = await chrome.tabs.query({ url: editorUrlPatterns() });
    const out = [];
    await Promise.all(
      tabs.map(async (t) => {
        try {
          const r = await chrome.tabs.sendMessage(t.id, { cmd: "frame" });
          if (r?.frame) out.push({ window: t.windowId, tab: t.id, frame: r.frame });
        } catch {
          /* not an compos page, or no content script in it */
        }
      })
    );
    return { frames: out };
  },

  async tabs() {
    const tabs = await chrome.tabs.query({});
    return {
      tabs: tabs.map((t) => ({
        id: t.id,
        title: t.title,
        url: t.url,
        active: t.active,
        window: t.windowId
      }))
    };
  },

  // world "MAIN" reaches the page's own globals; the default isolated world
  // sees the DOM but not the page's JS
  async eval({ tab, code, world }) {
    const [res] = await chrome.scripting.executeScript({
      target: { tabId: tab },
      world: world === "main" ? "MAIN" : "ISOLATED",
      func: (src) => {
        try {
          // indirect eval keeps this out of the injected function's scope
          const value = (0, eval)(src);
          return { value: value === undefined ? null : JSON.parse(JSON.stringify(value ?? null)) };
        } catch (e) {
          return { error: String((e && e.message) || e) };
        }
      },
      args: [code]
    });
    const err = res?.result?.error;
    if (err && HAS_CDP && /Content Security Policy|unsafe-eval/.test(err)) {
      // a strict-CSP page (the editor's own is one) refuses string eval;
      // the debugger evaluates outside the page's policy entirely
      const r = await cdp(tab, "Runtime.evaluate", {
        expression: code,
        returnByValue: true,
      });
      if (r.exceptionDetails) {
        throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text || "eval failed");
      }
      return { value: r.result?.value ?? null };
    }
    if (err) throw new Error(err);
    return { value: res?.result?.value ?? null };
  },

  async read({ tab }) {
    return tell(tab, { cmd: "read" });
  },

  // push a line into the page's overlay — this is how Scheme talks to a tab
  async overlay({ tab, text, kind }) {
    return tell(tab, { cmd: "overlay", text, kind: kind || "info" });
  },

  // trusted input. el.click() and dispatchEvent carry isTrusted:false, which a
  // hardened page can see and ignore; CDP's Input domain does not.
  async type({ tab, text }) {
    if (!HAS_CDP) return synthetic(tab, "type", { text });
    for (const ch of text) {
      await cdp(tab, "Input.dispatchKeyEvent", { type: "keyDown", text: ch });
      await cdp(tab, "Input.dispatchKeyEvent", { type: "keyUp" });
    }
    return { typed: text.length };
  },

  async click({ tab, x, y, button = "left" }) {
    if (!HAS_CDP) return synthetic(tab, "click", { x, y, button });
    const common = { x, y, button, clickCount: 1 };
    await cdp(tab, "Input.dispatchMouseEvent", { type: "mousePressed", ...common });
    await cdp(tab, "Input.dispatchMouseEvent", { type: "mouseReleased", ...common });
    return { clicked: [x, y] };
  },

  async key({ tab, ...params }) {
    if (!HAS_CDP) return synthetic(tab, "key", params);
    await cdp(tab, "Input.dispatchKeyEvent", { type: "keyDown", ...params });
    await cdp(tab, "Input.dispatchKeyEvent", { type: "keyUp", ...params });
    return { ok: true };
  },

  async cdp({ tab, method, params }) {
    return { result: await cdp(tab, method, params || {}) };
  },

  async release({ tab }) {
    await detach(tab);
    return { released: true };
  },

  // A tab belongs beside the thing that asked for it. The daemon names the
  // browser window — the one its frame is displayed in — and the tab opens
  // there, not in whichever window Chrome last focused. Without this, a chat
  // on the left screen answers by opening a tab on the right one.
  // BACKGROUND opens it behind the tab you are on. It is its own flag because
  // the daemon sends a Scheme #f as null, and `active: null` read as "not
  // false" and took the focus.
  // READER puts it in the reader's minimized window instead: a tab the
  // editor works for you, which you never see.
  async open({ url, active, window, background, after, reader }) {
    const create = { url, active: !background && active !== false };
    if (reader) {
      const t = await chrome.tabs.create({ ...create, active: false, windowId: await readerWindow() });
      return { tab: t.id, window: t.windowId };
    }
    // AFTER is the tab of the frame that asked: two frames can share a
    // window, so the window alone does not say whose tab this is. The new
    // tab sits right after it.
    const at = after && (await chrome.tabs.get(after).catch(() => null));
    if (at) {
      create.windowId = at.windowId;
      create.index = at.index + 1;
    } else if (await windowExists(window)) create.windowId = window;
    const t = await chrome.tabs.create(create);
    return { tab: t.id, window: t.windowId };
  },

  async activate({ tab }) {
    const t = await chrome.tabs.update(tab, { active: true });
    await chrome.windows.update(t.windowId, { focused: true });
    return { tab };
  },

  async close({ tab }) {
    await chrome.tabs.remove(tab);
    return { closed: tab };
  },

  // --- tiling ---------------------------------------------------------------
  //
  // The editor tiles its own windows; these ops let it tile the browser the
  // same way. Chrome has no split view an extension can reach, so a tile is a
  // WINDOW, not a pane inside one. One tab per window, each window placed on
  // the work area, is the same thing every tiling window manager does.
  //
  // Mechanism only. Which tab goes where, and what the rectangles are, is
  // chrome.scm's policy.

  // the usable rectangle of every display: the work area excludes the menu
  // bar and the dock, so a placed window is never under them
  async displays() {
    // Firefox has no system.display: the screen this window is on is all it knows
    if (!chrome.system?.display) {
      return {
        displays: [
          {
            id: "0",
            primary: true,
            left: screen.availLeft,
            top: screen.availTop,
            width: screen.availWidth,
            height: screen.availHeight
          }
        ]
      };
    }
    const ds = await chrome.system.display.getInfo();
    return {
      displays: ds.map((d) => ({
        id: d.id,
        primary: d.isPrimary,
        // workArea, not bounds: bounds includes the menu bar and the dock
        left: d.workArea.left,
        top: d.workArea.top,
        width: d.workArea.width,
        height: d.workArea.height
      }))
    };
  },

  async windows() {
    const ws = await chrome.windows.getAll({ populate: true });
    return {
      windows: ws.map((w) => ({
        id: w.id,
        type: w.type,
        state: w.state,
        focused: w.focused,
        left: w.left,
        top: w.top,
        width: w.width,
        height: w.height,
        tabs: (w.tabs || []).map((t) => ({
          id: t.id,
          url: t.url,
          title: t.title,
          active: t.active
        }))
      }))
    };
  },

  // A minimized or maximized window ignores a move, so the state comes back
  // to normal first and the geometry lands in a second call.
  async "window-place"({ window, left, top, width, height }) {
    const w = await chrome.windows.get(window);
    if (w.state !== "normal") await chrome.windows.update(window, { state: "normal" });
    await chrome.windows.update(window, {
      left: Math.round(left),
      top: Math.round(top),
      width: Math.round(width),
      height: Math.round(height)
    });
    return { window };
  },

  // A tile of its own: the tab leaves its strip for a new window at RECT.
  // type "popup" drops the tab strip and the address bar, so the tile shows
  // the page and nothing else — the editor is the chrome now.
  async "tab-tile"({ tab, left, top, width, height, popup }) {
    const t = await chrome.tabs.get(tab);
    const w = await chrome.windows.create({
      tabId: tab,
      type: popup === false ? "normal" : "popup",
      focused: false,
      left: Math.round(left),
      top: Math.round(top),
      width: Math.round(width),
      height: Math.round(height)
    });
    return { window: w.id, tab: t.id };
  },

  // the other direction: gather a tiled tab back into one window's strip
  async "tab-gather"({ tab, window, index }) {
    const moved = await chrome.tabs.move(tab, {
      windowId: window,
      index: index === undefined ? -1 : index
    });
    return { tab: Array.isArray(moved) ? moved[0].id : moved.id };
  }
};

// --- the tab side ----------------------------------------------------------
//
// One browser window, one compos. A window's compos tab announces which frame
// it is when it loads, and from then on every other tab in that window belongs
// to that frame: M-x there runs against it, prompts open in it, and "raise"
// brings it forward. That single binding is what makes C-x b from a random
// page have an unambiguous target.

/** chrome windowId -> {tabId, frame} */
const editors = new Map();

// the hosts an editor page can load from: this machine, plus every daemon
// host in the settings. A match pattern names no port, so one pattern per
// host covers every daemon there. A bracketed IPv6 host is no match pattern.
function editorUrlPatterns() {
  const hosts = new Set(["localhost", "127.0.0.1"]);
  for (const c of conns.values()) if (!c.local && !c.host.startsWith("[")) hosts.add(c.host);
  return [...hosts].flatMap((h) => [`http://${h}/*`, `https://${h}/*`]);
}

function anyConn() {
  for (const c of conns.values()) if (c.up) return c;
  return null;
}

// A message can wake a sleeping worker before any socket is open again: the
// side panel's first ask always does. Take the first daemon that comes up,
// and give up after MS.
const connWaiters = new Set();

function whenConn(ms = 5000) {
  const c = anyConn();
  if (c) return Promise.resolve(c);
  if (!conns.size) sweep();
  return new Promise((resolve, reject) => {
    const w = (conn) => {
      clearTimeout(t);
      connWaiters.delete(w);
      resolve(conn);
    };
    const t = setTimeout(() => {
      connWaiters.delete(w);
      reject(new Error("no compos daemon running"));
    }, ms);
    connWaiters.add(w);
  });
}

// the compos tab for a window, if this window has one
function editorFor(windowId) {
  return editors.get(windowId) || null;
}

// The daemon needs the same binding, and for a different reason: it decides
// WHERE a tab it opens should go. A frame that has never sent a key from a
// page has no window on the daemon side, so the answer to "open this link"
// used to land in whichever window Chrome focused last. Tell it at register
// time instead, and again whenever a daemon connects.
function announce(windowId, frame) {
  if (!frame) return;
  for (const c of conns.values()) {
    if (c.up) c.ask("register", { frame, window: windowId }).catch(() => {});
  }
}

// MV3 discards the worker after 30s and `editors` goes with it. The pages
// themselves still know which frame they are, so ask them: every compos tab
// answers a frame probe. This runs when a daemon connects, which is also when
// the binding matters again.
async function rediscoverEditors() {
  const tabs = await chrome.tabs.query({ url: editorUrlPatterns() });
  await Promise.all(
    tabs.map(async (t) => {
      try {
        const r = await chrome.tabs.sendMessage(t.id, { cmd: "frame" });
        if (r?.frame) {
          editors.set(t.windowId, { tabId: t.id, frame: r.frame });
        }
      } catch {
        /* not an compos page, or no content script in it */
      }
    })
  );
}

async function announceAll() {
  await rediscoverEditors();
  for (const [windowId, ed] of editors) announce(windowId, ed.frame);
}

// a tab closing or navigating away takes its window's binding with it
chrome.tabs.onRemoved.addListener((tabId) => {
  for (const [win, ed] of editors) if (ed.tabId === tabId) editors.delete(win);
});

// A top-level navigation turns the old compos tab into an ordinary tab. A
// newly loaded compos page registers itself again when its editor frame is
// ready.
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (!change.url) return;
  for (const [win, ed] of editors) if (ed.tabId === tabId) editors.delete(win);
});

// dragging a tab between windows moves the binding with it
chrome.tabs.onAttached.addListener((tabId, { newWindowId }) => {
  for (const [win, ed] of editors) {
    if (ed.tabId === tabId) {
      editors.delete(win);
      editors.set(newWindowId, ed);
      announce(newWindowId, ed.frame);
    }
  }
});

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const tab = sender.tab?.id;
  const windowId = sender.tab?.windowId;

  const answer = async () => {
    if (msg.cmd === "status") {
      return [...conns.values()].map((c) => ({
        key: c.key,
        host: c.host,
        port: c.port,
        address: c.address,
        name: c.name,
        up: c.up,
        pinned: !!c.pinned
      }));
    }

    if (msg.cmd === "settings") return settings();

    // an compos page telling us which frame it is
    if (msg.cmd === "register") {
      const was = editors.get(windowId);
      editors.set(windowId, { tabId: tab, frame: msg.frame });
      // the page re-registers on every visibility change; only a new binding
      // is worth a round trip to the daemon
      if (!was || was.frame !== msg.frame || was.tabId !== tab) announce(windowId, msg.frame);
      return { registered: msg.frame };
    }

    // the side panel is no tab: it names the page it sits beside
    if (msg.cmd === "site-chat") {
      const conn = await whenConn();
      const r = await conn.ask("site-chat", { host: msg.host, tab: msg.tab, url: msg.url, window: msg.window });
      return { ...r, port: conn.port, url: conn.url };
    }

    const conn = anyConn();
    if (!conn) throw new Error("no compos daemon running");

    const ed = editorFor(windowId);
    const frame = ed?.frame;

    // Bring this window's compos forward. The daemon says WHEN (a confirmed
    // prompt); the extension knows WHICH tab.
    const maybeRaise = async (result) => {
      if (result?.raise && ed) await chrome.tabs.update(ed.tabId, { active: true });
      return result;
    };

    switch (msg.cmd) {
      case "run": return maybeRaise(await conn.ask("run", { tab, frame, window: windowId, name: msg.name }));
      case "chord": return maybeRaise(await conn.ask("chord", { tab, frame, window: windowId, keys: msg.keys }));
      case "mb-key": return maybeRaise(await conn.ask("mb-key", { tab, frame, window: windowId, spec: msg.spec }));
      case "mb-state": return conn.ask("mb-state", { tab, frame, window: windowId });
      default: throw new Error(`unknown ${msg.cmd}`);
    }
  };

  answer().then(
    (result) => reply({ ok: true, result }),
    (e) => reply({ ok: false, error: String((e && e.message) || e) })
  );

  return true; // async reply
});

// --- the site's chat --------------------------------------------------------
//
// The toolbar button opens a side panel on THIS tab only, and the panel
// shows this site's chat. The editor finds or makes it; see sidepanel.js.
// A compos tab gets none: the chat is already there.

chrome.sidePanel?.setPanelBehavior({ openPanelOnActionClick: false }).catch(() => {});

/** the connection whose daemon serves this URL, if we hold one */
function connFor(url) {
  try {
    const u = new URL(url || "");
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    const port = Number(u.port || (u.protocol === "https:" ? 443 : 80));
    return conns.get(daemonAt(u.hostname, port).key) || null;
  } catch {
    return null;
  }
}

function composTab(url) {
  return !!connFor(url);
}

chrome.action.onClicked.addListener((tab) => {
  if (!tab.id || composTab(tab.url)) return;
  // no await between the click and open(): the panel needs the user gesture
  if (!chrome.sidePanel) {
    // Firefox: one sidebar per window, with a panel per tab
    browser.sidebarAction.setPanel({ tabId: tab.id, panel: chrome.runtime.getURL(`sidepanel.html?tab=${tab.id}`) });
    browser.sidebarAction.open();
    return;
  }
  chrome.sidePanel.setOptions({ tabId: tab.id, path: `sidepanel.html?tab=${tab.id}`, enabled: true });
  chrome.sidePanel.open({ tabId: tab.id });
});

// --- getting there ---------------------------------------------------------
//
// Typing "compos" in the address bar. /etc/hosts can't do this on its own — it
// maps a name to an address, not a port — and dropping the port would mean
// listening on 80. The omnibox needs neither, and unlike a bookmark it knows
// which daemons are actually up, so it offers them by name.
//
// It focuses an existing compos tab rather than opening another: a second tab
// on the same daemon is a second frame, which is rarely what "take me to my
// editor" means.

async function focusOrOpen(conn, windowId) {
  // nothing connected? still go somewhere useful — the default daemon
  const url = conn ? conn.url : DEFAULT_URL;
  // a match pattern with a port is Chrome's extension; Firefox rejects it
  const existing = (await chrome.tabs.query({})).filter((t) => (t.url || "").startsWith(url));

  // prefer one already in this window — one window, one compos
  const here = existing.find((t) => t.windowId === windowId) || existing[0];
  if (here) {
    await chrome.tabs.update(here.id, { active: true });
    await chrome.windows.update(here.windowId, { focused: true });
    return here.id;
  }

  const t = await chrome.tabs.create({ url, active: true });
  return t.id;
}

function liveDaemons() {
  // this machine first, then by host, then by port
  const order = (a, b) =>
    a.host === b.host ? a.port - b.port : a.local ? -1 : b.local ? 1 : a.host.localeCompare(b.host);
  return [...conns.values()].filter((c) => c.up).sort(order);
}

chrome.omnibox.onInputChanged.addListener((text, suggest) => {
  const live = liveDaemons();
  const q = text.trim().toLowerCase();
  const match = (c) => !q || c.name.toLowerCase().includes(q) || c.key.includes(q);

  chrome.omnibox.setDefaultSuggestion({
    description: live.length
      ? `compos — ${live.length} running: ${live.map((c) => c.name).join(", ")}`
      : "compos — nothing running"
  });

  suggest(
    live.filter(match).map((c) => ({
      content: c.key,
      description: `<match>${c.name}</match> — ${c.local ? "localhost" : c.host}:${c.port}`
    }))
  );
});

chrome.omnibox.onInputEntered.addListener(async (text) => {
  const live = liveDaemons();
  const typed = text.trim().toLowerCase();
  const pick =
    live.find((c) => c.key === typed) ||
    live.find((c) => String(c.port) === typed) ||
    live.find((c) => c.name.toLowerCase() === typed) ||
    live[0];

  const win = (await chrome.windows.getCurrent()).id;
  await focusOrOpen(pick || null, win);
});

// Alt+Shift+A: this window's compos, or the nearest one.
chrome.commands.onCommand.addListener(async (name) => {
  if (name !== "focus-compos") return;
  const win = (await chrome.windows.getCurrent()).id;
  const ed = editorFor(win);
  if (ed) {
    await chrome.tabs.update(ed.tabId, { active: true });
    await chrome.windows.update(win, { focused: true });
    return;
  }
  await focusOrOpen(liveDaemons()[0] || null, win);
});

// --- discovery -------------------------------------------------------------

async function sweep() {
  const { daemons, scan, scanFrom, scanTo } = await settings();

  // the pinned daemons by key; the scan adds local ports around them
  const wanted = new Map(daemons.map((d) => [d.key, d]));
  const pinned = new Set(wanted.keys());
  if (scan) {
    for (let p = scanFrom; p <= scanTo; p++) {
      const d = daemonAt(LOCAL, p);
      if (!wanted.has(d.key)) wanted.set(d.key, d);
    }
  }

  for (const [key, conn] of conns) if (!wanted.has(key)) conn.close();

  for (const [key, d] of wanted) {
    const existing = conns.get(key);
    if (existing) {
      existing.pinned = pinned.has(key);
      continue;
    }
    const conn = new Conn(d.host, d.port);
    conn.pinned = pinned.has(key);
    conns.set(key, conn);
  }
}

// Reloading the extension leaves every open tab running the OLD content
// script, orphaned and useless — normally you'd have to refresh each tab by
// hand. Re-inject on install/update instead. The fresh script bails if one is
// already live in the page, and the orphan tears itself down when it notices
// its context died, so no tab ends up with two.
async function reinject() {
  const tabs = await chrome.tabs.query({});
  await Promise.all(
    tabs.map(async (t) => {
      if (!t.id || !/^https?:/.test(t.url || "")) return;
      try {
        await chrome.scripting.executeScript({
          target: { tabId: t.id, allFrames: true },
          files: ["overlay.js"]
        });
      } catch {
        /* a page we're not allowed into */
      }
    })
  );
}

chrome.runtime.onInstalled.addListener(reinject);
chrome.runtime.onStartup.addListener(reinject);

// --- make the extension visible --------------------------------------------
//
// The service worker's console lives in a devtools window nobody has open, so
// an error in here was simply invisible — every failure had to be inferred
// from the daemon side. Forward it instead: one stream, both halves. See
// `bin/compos bridge`.
function report(level, args) {
  const text = args
    .map((a) => (a instanceof Error ? `${a.message}` : typeof a === "string" ? a : JSON.stringify(a)))
    .join(" ");
  for (const c of conns.values()) if (c.up) c.say(level, text);
}

for (const level of ["warn", "error"]) {
  const original = console[level].bind(console);
  console[level] = (...args) => {
    original(...args);
    try {
      report(level, args);
    } catch {
      /* never let logging break the thing it is logging */
    }
  };
}

self.addEventListener("error", (e) => report("error", [e.message]));
self.addEventListener("unhandledrejection", (e) => report("error", [String(e.reason)]));

chrome.storage.sync.onChanged.addListener(sweep);
sweep();

// setInterval alone is not enough. MV3 suspends an idle service worker after
// ~30s, and a suspended worker's timers never fire — so once a daemon goes
// away there is no socket traffic to keep us awake, the rescan stops, and the
// extension never reconnects no matter how long the daemon has been back.
// chrome.alarms survives suspension and wakes the worker to run the sweep.
// The interval stays for the case where we ARE awake and want a faster retry.
setInterval(sweep, RESCAN_MS);
chrome.alarms.create("sweep", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => a.name === "sweep" && sweep());
