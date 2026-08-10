// overlay.js — ai-max's minibuffer, in every tab.
//
// M-x opens a command palette over whatever page you're on; the list comes
// from the daemon and the command runs there, so a tab gets the real editor's
// commands rather than a copy of them. C-x starts a chord and hands the whole
// sequence to the daemon's key dispatch.
//
// The UI lives in a shadow root: pages have opinions about `div`, and none of
// them should reach this. Everything is drawn from scratch so a page's CSS
// reset, z-index stacking or font can't disturb it.

const HOST_ID = "aimax-overlay-host";

// Reloading the extension orphans every content script already running in an
// open page: chrome.runtime.id goes undefined and every sendMessage throws
// "Extension context invalidated". An orphan that keeps its keydown listener
// is worse than no extension at all — it still swallows C-x and M-x and then
// fails — so it tears itself down the moment it notices.
if (window.__aimaxOverlay) throw new Error("ai-max overlay already in this page");
window.__aimaxOverlay = true;

const alive = () => {
  try {
    return !!chrome.runtime?.id;
  } catch {
    return false;
  }
};

let host = null;
let root = null;
let palette = null;
let pending = null; // an in-flight chord, e.g. ["C-x"]
let enabled = true;

// --- the shadow UI ---------------------------------------------------------

const CSS = `
:host { all: initial; }
.wrap {
  position: fixed; inset: auto 0 0 0; z-index: 2147483647;
  font: 13px/1.5 ui-monospace, "IBM Plex Mono", Menlo, monospace;
  color: #2b2a26; background: #fdfcf8;
  border-top: 1px solid #d8d2c4;
  box-shadow: 0 -8px 24px rgba(0,0,0,0.10);
  padding: 0; max-height: 45vh; display: flex; flex-direction: column;
}
.cands { overflow-y: auto; max-height: 38vh; }
.row { padding: 3px 14px; display: flex; gap: 12px; align-items: baseline; }
.row.sel { background: #e7e9f1; }
.name { flex: 0 0 auto; }
.doc { color: #6f6a5e; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.inputrow { display: flex; gap: 8px; padding: 7px 14px; border-top: 1px solid #eae5d8; align-items: baseline; }
.prompt { color: #6f6a5e; flex: 0 0 auto; }
.typed { white-space: pre; }
.cursor { background: #2b2a26; color: #fdfcf8; }
.count { margin-left: auto; color: #8a8577; font-size: 11px; }
.echo {
  position: fixed; inset: auto 0 0 0; z-index: 2147483647;
  font: 13px/1.5 ui-monospace, Menlo, monospace;
  background: #2b2a26; color: #f4f0e6; padding: 6px 14px;
}
.echo.error { background: #6b2020; }
@media (prefers-color-scheme: dark) {
  .wrap { color: #e6e2d8; background: #1c1b19; border-top-color: #3c382f; }
  .row.sel { background: #2e2b25; }
  .doc, .prompt, .count { color: #9a9386; }
  .inputrow { border-top-color: #2e2b25; }
  .cursor { background: #e6e2d8; color: #1c1b19; }
}
`;

function ensureRoot() {
  if (root) return root;
  host = document.createElement("div");
  host.id = HOST_ID;
  root = host.attachShadow({ mode: "closed" });
  const style = document.createElement("style");
  style.textContent = CSS;
  root.appendChild(style);
  document.documentElement.appendChild(host);
  return root;
}

function ask(msg) {
  return new Promise((resolve, reject) => {
    if (!alive()) {
      teardown();
      return reject(new Error("ai-max was reloaded — refresh this page"));
    }
    try {
      chrome.runtime.sendMessage(msg, (r) => {
        const err = chrome.runtime.lastError;
        if (err) {
          if (/context invalidated|receiving end/i.test(err.message)) teardown();
          return reject(new Error(err.message));
        }
        if (!r) return reject(new Error("no answer"));
        r.ok ? resolve(r.result) : reject(new Error(r.error));
      });
    } catch (e) {
      teardown();
      reject(e);
    }
  });
}

// Give the page its keyboard back. An orphan holding onto C-x is a worse
// citizen than one that quietly disappears.
let torndown = false;

function teardown() {
  if (torndown) return;
  torndown = true;
  enabled = false;
  pending = null;
  window.removeEventListener("keydown", onKey, true);
  try {
    palette?.wrap.remove();
    host?.remove();
  } catch {
    /* already gone */
  }
  palette = null;
}

let echoTimer;
function echo(text, kind = "info") {
  const r = ensureRoot();
  let el = r.querySelector(".echo");
  if (!el) {
    el = document.createElement("div");
    el.className = "echo";
    r.appendChild(el);
  }
  el.className = `echo ${kind === "error" ? "error" : ""}`;
  el.textContent = text;
  clearTimeout(echoTimer);
  echoTimer = setTimeout(() => el.remove(), 4000);
}

// --- the palette -----------------------------------------------------------

function openPalette(items, prompt = "M-x ") {
  closePalette();
  const r = ensureRoot();

  const wrap = document.createElement("div");
  wrap.className = "wrap";
  wrap.innerHTML = `<div class="cands"></div>
    <div class="inputrow"><span class="prompt"></span><span class="typed"></span><span class="cursor"> </span><span class="count"></span></div>`;
  r.appendChild(wrap);
  wrap.querySelector(".prompt").textContent = prompt;

  palette = { wrap, items, input: "", sel: 0, shown: items };
  render();
}

function closePalette() {
  palette?.wrap.remove();
  palette = null;
}

// serverDriven: the daemon's minibuffer already filtered and chose, so we draw
// its answer verbatim. Otherwise this is our own M-x list and we filter here.
function render(serverDriven) {
  if (!palette) return;

  const shown = serverDriven
    ? palette.items
    : palette.items
        .filter((it) => matches(it.name.toLowerCase(), palette.input.toLowerCase()))
        .slice(0, 200);

  palette.shown = shown;
  if (!serverDriven) palette.sel = Math.max(0, Math.min(palette.sel, shown.length - 1));

  const list = palette.wrap.querySelector(".cands");
  list.textContent = "";
  shown.forEach((it, i) => {
    const row = document.createElement("div");
    row.className = `row ${i === palette.sel ? "sel" : ""}`;
    const n = document.createElement("span");
    n.className = "name";
    n.textContent = it.name;
    const d = document.createElement("span");
    d.className = "doc";
    d.textContent = it.doc || "";
    row.append(n, d);
    list.appendChild(row);
  });

  list.children[palette.sel]?.scrollIntoView({ block: "nearest" });
  palette.wrap.querySelector(".typed").textContent = palette.input;
  palette.wrap.querySelector(".count").textContent =
    serverDriven && palette.total != null ? `${palette.total}` : `${shown.length}`;
}

function matches(name, q) {
  if (!q) return true;
  let i = 0;
  for (const ch of q) {
    i = name.indexOf(ch, i);
    if (i === -1) return false;
    i++;
  }
  return true;
}

// --- keys ------------------------------------------------------------------

// ai-max's own spelling, so a chord that leaves here is one KeyDispatch knows
function spec(e) {
  const mods = [];
  if (e.ctrlKey) mods.push("C");
  if (e.metaKey) mods.push("s");
  if (e.altKey) mods.push("M");

  // the editor's own spelling for the named keys — its minibuffer keymap binds
  // "<down>"/"<up>", so that is what has to leave here
  const NAMED = {
    " ": "SPC",
    Enter: "RET",
    Tab: "TAB",
    Escape: "ESC",
    Backspace: "DEL",
    ArrowDown: "<down>",
    ArrowUp: "<up>",
    ArrowLeft: "<left>",
    ArrowRight: "<right>",
    Home: "<home>",
    End: "<end>",
    PageUp: "<prior>",
    PageDown: "<next>",
    Delete: "<delete>"
  };

  let base;
  if (NAMED[e.key]) base = NAMED[e.key];
  else if (e.key.length === 1) base = e.key;
  // e.code survives Option-as-compose on macOS, where Option-x yields "≈"
  else if (/^Key[A-Z]$/.test(e.code)) base = e.code.slice(3).toLowerCase();
  else return null;

  return mods.length ? `${mods.join("-")}-${base}` : base;
}

// --- the daemon's minibuffer, drawn here -----------------------------------
//
// Commands ask questions — C-x b, C-x C-f, M-x itself. The question has to be
// answered where it was asked, so every reply carries the minibuffer's state
// and we render it. While a prompt is up this overlay owns the keyboard and
// every key goes to the daemon.

let prompting = false;

function showMinibuffer(mb) {
  prompting = true;
  const items = (mb.candidates || []).map((c) => ({ name: c.label, doc: c.hint }));
  if (!palette) openPalette(items, mb.prompt);
  else {
    palette.items = items;
    palette.wrap.querySelector(".prompt").textContent = mb.prompt;
  }
  // the daemon owns filtering and selection here — we only draw them
  palette.sel = mb.sel || 0;
  palette.input = mb.input || "";
  palette.total = mb.total;
  render(true);
}

// A reply either carries a prompt to show, or means the prompt is gone.
function applyReply(r) {
  if (r && r.minibuffer) return showMinibuffer(r.minibuffer);
  if (prompting) {
    prompting = false;
    closePalette();
  }
  if (r && r.message) echo(r.message);
}

async function mbKey(spec) {
  try {
    applyReply(await ask({ cmd: "mb-key", spec }));
  } catch (e) {
    prompting = false;
    closePalette();
    echo(String(e.message || e), "error");
  }
}

async function runCommand(name) {
  closePalette();
  try {
    applyReply(await ask({ cmd: "run", name }));
  } catch (e) {
    echo(String(e.message || e), "error");
  }
}

async function onKey(e) {
  if (!enabled) return;
  // checked before any preventDefault: an orphaned script must not eat a key
  // it can no longer act on
  if (!alive()) return teardown();

  // a prompt from the daemon is the daemon's to answer: every key goes there,
  // so the minibuffer keymap stays in one place instead of being reimplemented
  if (prompting) {
    e.preventDefault();
    e.stopPropagation();
    const s = spec(e);
    if (s) await mbKey(s);
    return;
  }

  // while our own palette is up it owns the keyboard
  if (palette) {
    e.preventDefault();
    e.stopPropagation();

    const s = spec(e);
    if (s === "ESC" || s === "C-g") return closePalette();
    if (s === "RET") {
      const pick = palette.shown[palette.sel];
      return pick ? runCommand(pick.name) : closePalette();
    }
    if (s === "C-n" || e.key === "ArrowDown") { palette.sel++; return render(); }
    if (s === "C-p" || e.key === "ArrowUp") { palette.sel--; return render(); }
    if (s === "DEL") { palette.input = palette.input.slice(0, -1); return render(); }
    if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) { palette.input += e.key; return render(); }
    return;
  }

  // mid-chord: this key completes it
  if (pending) {
    e.preventDefault();
    e.stopPropagation();
    const s = spec(e);
    const keys = [...pending, s].filter(Boolean);
    pending = null;
    if (s === "C-g" || s === "ESC") return echo("quit");
    try {
      applyReply(await ask({ cmd: "chord", keys }));
      // dispatch-key runs off-process so the prompt may not be up yet when the
      // chord replies — ask once more before giving up on it
      if (!prompting) {
        setTimeout(async () => {
          try {
            const r = await ask({ cmd: "mb-state" });
            if (r && r.minibuffer) applyReply(r);
          } catch {
            /* daemon went away */
          }
        }, 120);
      }
    } catch (err) {
      echo(String(err.message || err), "error");
    }
    return;
  }

  // M-x — e.code because Option-x is a dead key on macOS
  if (e.altKey && !e.ctrlKey && !e.metaKey && e.code === "KeyX") {
    e.preventDefault();
    e.stopPropagation();
    try {
      const { commands } = await ask({ cmd: "commands" });
      openPalette(commands || []);
    } catch (err) {
      echo(String(err.message || err), "error");
    }
    return;
  }

  // C-x starts a chord and waits for the next key
  if (e.ctrlKey && !e.altKey && !e.metaKey && e.code === "KeyX") {
    e.preventDefault();
    e.stopPropagation();
    pending = ["C-x"];
    echo("C-x-");
    setTimeout(() => {
      if (pending) { pending = null; echo("C-x quit"); }
    }, 3000);
  }
}

// capture phase, so a page that swallows keydown on its own handlers still
// yields M-x and C-x to us
window.addEventListener("keydown", onKey, true);

// --- what the daemon can ask of this tab -----------------------------------

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  switch (msg.cmd) {
    case "read":
      reply({
        url: location.href,
        title: document.title,
        text: (document.body?.innerText || "").replace(/\n{3,}/g, "\n\n").trim()
      });
      return false;
    case "overlay":
      echo(msg.text, msg.kind);
      reply({ shown: true });
      return false;
    case "ping":
      reply({ alive: true });
      return false;
    default:
      reply({ error: `unknown ${msg.cmd}` });
      return false;
  }
});

// --- am I the editor? ------------------------------------------------------
//
// An ai-max page has its own minibuffer and its own key handling, so this
// overlay must keep its hands off it entirely — M-x there belongs to the
// editor. What the page does instead is announce which frame it is, so every
// OTHER tab in this browser window knows where its commands should land.
//
// The frame id arrives from the server after the LiveView connects, so it may
// not be in localStorage yet when this script runs.

function isEditorPage() {
  return !!document.getElementById("editor");
}

async function registerFrame(tries = 20) {
  for (let i = 0; i < tries; i++) {
    const frame = localStorage.getItem("aimax-frame");
    if (frame) {
      try {
        await ask({ cmd: "register", frame });
      } catch {
        /* worker asleep; the next visibility change retries */
      }
      return;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
}

if (isEditorPage()) {
  enabled = false; // never capture keys on the editor itself
  registerFrame();
  // a daemon restart hands out a new frame id, and the tab may have been
  // dragged to another window since we registered
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) registerFrame(1);
  });
} else {
  chrome.storage.sync.get({ keys: true }).then((s) => (enabled = s.keys));
  chrome.storage.sync.onChanged.addListener((ch) => {
    if (ch.keys) enabled = ch.keys.newValue;
  });
}
