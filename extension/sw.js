// sw.js — the extension half of the ai-max wire.
//
// Two directions, one protocol. The daemon asks the browser to do things
// (list tabs, run JS, read a page, type into it); the browser asks the daemon
// to do things (what commands exist, run this one, handle this chord). A frame
// with an `op` is a request, a frame with `ok` is a reply — so the two sides
// can use overlapping ids without colliding.
//
// One extension, many daemons: people run one per life — work, personal — each
// on its own port. Every daemon gets its own socket. Unlike v1, a daemon may
// address ANY tab, not only tabs it opened: the whole point is that ai-max's
// keys and commands are ambient.
//
// CDP is attached ON DEMAND and dropped when idle. Content scripts cover the
// overlay and ordinary reads with nothing to detect and no infobar; the
// debugger comes out only for input that has to be trusted.

const DEFAULTS = { ports: [4004], scan: true, scanFrom: 4004, scanTo: 4013, keys: true };

const RETRY_MS = 3000;
const RESCAN_MS = 15000;
// MV3 kills an idle worker at 30s; socket traffic resets that timer
const HEARTBEAT_MS = 20000;
// how long a debugger session lingers before we let go of the tab
const CDP_IDLE_MS = 30000;

/** port -> Conn */
const conns = new Map();

async function settings() {
  return { ...DEFAULTS, ...(await chrome.storage.sync.get(DEFAULTS)) };
}

// --- one daemon ------------------------------------------------------------

class Conn {
  constructor(port) {
    this.port = port;
    this.name = `:${port}`;
    this.pending = new Map(); // id -> {resolve, reject}
    this.nextId = 1;
    this.ws = null;
    this.open();
  }

  open() {
    // a scan probe to a dead port fails fast and quietly; that is the whole
    // discovery mechanism, so onerror must stay silent
    const ws = new WebSocket(`ws://127.0.0.1:${this.port}/browser`);
    this.ws = ws;

    ws.onopen = () => {
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
      else conns.delete(this.port);
    };

    ws.onerror = () => ws.close();
  }

  get up() {
    return this.ws?.readyState === 1;
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
    conns.delete(this.port);
  }
}

// --- CDP, on demand --------------------------------------------------------
// Attached only for operations that need trusted events, and released after a
// quiet period so the "started debugging this browser" bar isn't permanent.

const attached = new Map(); // tabId -> timeout handle

async function cdp(tabId, method, params = {}) {
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
  const t = attached.get(tabId);
  if (t) clearTimeout(t);
  attached.delete(tabId);
  try {
    await chrome.debugger.detach({ tabId });
  } catch {
    /* tab already gone */
  }
}

chrome.debugger.onDetach.addListener(({ tabId }) => attached.delete(tabId));
chrome.tabs.onRemoved.addListener((tabId) => attached.delete(tabId));

// --- talking to a tab's content script -------------------------------------

async function tell(tabId, msg, tries = 8) {
  // fail immediately and legibly on a bad id, rather than retrying eight times
  // and reporting "no ai-max in tab [object Object]" — that cost an assistant
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
  throw new Error(`no ai-max in tab ${tabId} (chrome:// page?)`);
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

const OPS = {
  // The editor's reader fetches THROUGH the browser: the user's cookies
  // and Chrome's HTTP cache ride along, so a page that knows them logged
  // in reads logged in. The reply is the response body as text.
  async fetch(msg) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 20000);
    try {
      const r = await fetch(msg.url, { credentials: "include", signal: ctl.signal });
      return { status: r.status, html: await r.text() };
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
  async snapshot({ url }) {
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
      // a script-rendered page needs a beat after "complete"
      await new Promise((r) => setTimeout(r, 1200));
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

  // Every ai-max tab answers a frame probe with its frame id. The daemon
  // sweeps frames with M-x refresh-frames: a frame no tab answers for is
  // dead. Probe ALL localhost tabs, not the editors map — that map keeps
  // one binding per window, and a background ai-max tab still holds a
  // live frame.
  async frames() {
    const tabs = await chrome.tabs.query({ url: ["http://localhost/*", "http://127.0.0.1/*"] });
    const out = [];
    await Promise.all(
      tabs.map(async (t) => {
        try {
          const r = await chrome.tabs.sendMessage(t.id, { cmd: "frame" });
          if (r?.frame) out.push({ window: t.windowId, tab: t.id, frame: r.frame });
        } catch {
          /* not an ai-max page, or no content script in it */
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
    if (res?.result?.error) throw new Error(res.result.error);
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
    for (const ch of text) {
      await cdp(tab, "Input.dispatchKeyEvent", { type: "keyDown", text: ch });
      await cdp(tab, "Input.dispatchKeyEvent", { type: "keyUp" });
    }
    return { typed: text.length };
  },

  async click({ tab, x, y, button = "left" }) {
    const common = { x, y, button, clickCount: 1 };
    await cdp(tab, "Input.dispatchMouseEvent", { type: "mousePressed", ...common });
    await cdp(tab, "Input.dispatchMouseEvent", { type: "mouseReleased", ...common });
    return { clicked: [x, y] };
  },

  async key({ tab, ...params }) {
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
  async open({ url, active, window }) {
    const create = { url, active: active !== false };
    if (await windowExists(window)) create.windowId = window;
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
  }
};

// --- the tab side ----------------------------------------------------------
//
// One browser window, one ai-max. A window's ai-max tab announces which frame
// it is when it loads, and from then on every other tab in that window belongs
// to that frame: M-x there runs against it, prompts open in it, and "raise"
// brings it forward. That single binding is what makes C-x b from a random
// page have an unambiguous target.

/** chrome windowId -> {tabId, frame} */
const editors = new Map();

function anyConn() {
  for (const c of conns.values()) if (c.up) return c;
  return null;
}

// the ai-max tab for a window, if this window has one
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
// themselves still know which frame they are, so ask them: every ai-max tab
// answers a frame probe. This runs when a daemon connects, which is also when
// the binding matters again.
async function rediscoverEditors() {
  const tabs = await chrome.tabs.query({ url: ["http://localhost/*", "http://127.0.0.1/*"] });
  await Promise.all(
    tabs.map(async (t) => {
      try {
        const r = await chrome.tabs.sendMessage(t.id, { cmd: "frame" });
        if (r?.frame) editors.set(t.windowId, { tabId: t.id, frame: r.frame });
      } catch {
        /* not an ai-max page, or no content script in it */
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
        port: c.port,
        name: c.name,
        up: c.up,
        pinned: !!c.pinned
      }));
    }

    if (msg.cmd === "settings") return settings();

    // an ai-max page telling us which frame it is
    if (msg.cmd === "register") {
      const was = editors.get(windowId);
      editors.set(windowId, { tabId: tab, frame: msg.frame });
      // the page re-registers on every visibility change; only a new binding
      // is worth a round trip to the daemon
      if (!was || was.frame !== msg.frame || was.tabId !== tab) announce(windowId, msg.frame);
      return { registered: msg.frame };
    }

    const conn = anyConn();
    if (!conn) throw new Error("no ai-max daemon running");

    const ed = editorFor(windowId);
    const frame = ed?.frame;

    // Bring this window's ai-max forward. The daemon says WHEN (a confirmed
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

// --- getting there ---------------------------------------------------------
//
// Typing "aimax" in the address bar. /etc/hosts can't do this on its own — it
// maps a name to an address, not a port — and dropping the port would mean
// listening on 80. The omnibox needs neither, and unlike a bookmark it knows
// which daemons are actually up, so it offers them by name.
//
// It focuses an existing ai-max tab rather than opening another: a second tab
// on the same daemon is a second frame, which is rarely what "take me to my
// editor" means.

async function focusOrOpen(port, windowId) {
  const url = `http://localhost:${port}/`;
  const existing = await chrome.tabs.query({ url: `${url}*` });

  // prefer one already in this window — one window, one ai-max
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
  return [...conns.values()].filter((c) => c.up).sort((a, b) => a.port - b.port);
}

chrome.omnibox.onInputChanged.addListener((text, suggest) => {
  const live = liveDaemons();
  const q = text.trim().toLowerCase();
  const match = (c) => !q || c.name.toLowerCase().includes(q) || String(c.port).includes(q);

  chrome.omnibox.setDefaultSuggestion({
    description: live.length
      ? `ai-max — ${live.length} running: ${live.map((c) => c.name).join(", ")}`
      : "ai-max — nothing running"
  });

  suggest(
    live.filter(match).map((c) => ({
      content: String(c.port),
      description: `<match>${c.name}</match> — localhost:${c.port}`
    }))
  );
});

chrome.omnibox.onInputEntered.addListener(async (text) => {
  const live = liveDaemons();
  const typed = parseInt(text.trim(), 10);
  const pick =
    live.find((c) => c.port === typed) ||
    live.find((c) => c.name.toLowerCase() === text.trim().toLowerCase()) ||
    live[0];

  const win = (await chrome.windows.getCurrent()).id;
  // nothing connected? still go somewhere useful — the default port
  await focusOrOpen(pick ? pick.port : DEFAULTS.ports[0], win);
});

// Alt+Shift+A: this window's ai-max, or the nearest one.
chrome.commands.onCommand.addListener(async (name) => {
  if (name !== "focus-aimax") return;
  const win = (await chrome.windows.getCurrent()).id;
  const ed = editorFor(win);
  if (ed) {
    await chrome.tabs.update(ed.tabId, { active: true });
    await chrome.windows.update(win, { focused: true });
    return;
  }
  const live = liveDaemons();
  await focusOrOpen(live.length ? live[0].port : DEFAULTS.ports[0], win);
});

// --- discovery -------------------------------------------------------------

async function sweep() {
  const { ports, scan, scanFrom, scanTo } = await settings();

  const wanted = new Set(ports);
  if (scan) for (let p = scanFrom; p <= scanTo; p++) wanted.add(p);

  for (const [port, conn] of conns) if (!wanted.has(port)) conn.close();

  for (const port of wanted) {
    const existing = conns.get(port);
    if (existing) {
      existing.pinned = ports.includes(port);
      continue;
    }
    const conn = new Conn(port);
    conn.pinned = ports.includes(port);
    conns.set(port, conn);
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
        await chrome.scripting.executeScript({ target: { tabId: t.id }, files: ["overlay.js"] });
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
// `bin/aimax bridge`.
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
