// nle.js -- the timeline of a video edit, run in compos's app frame.
//
// The edit file is the truth. This page asks Scheme for the edit as data
// (GET _compos/app), draws it, and plays it live: the player plays the
// sources and jumps over every hidden clip, so nothing is rendered to
// watch the cut. A change made here goes to Scheme as an operation (POST),
// Scheme writes it into the edit file and answers the new edit; a change
// made in the transcript or the file arrives as a message.
(() => {
  const API = "_compos/app";
  let S = null;          // the edit, as Scheme answers it
  let segs = [];         // the pieces in play order: {src, a, b, at}
  let cur = -1;          // the piece playing
  let playing = false;
  let whole = false;     // play a source whole, hidden clips included
  let src = 0;           // the source the source bar and transcript show
  let mIn = null, mOut = null;
  let wordA = null, wordB = null, dragging = false;
  let selPiece = null;   // the piece clicked last: where a ⇧-click range starts
  const selPieces = new Set(); // the pieces chosen, on either lane
  let selRange = null;   // the segment Scheme chose: {src, a, b}
  let selClip = null;    // the hidden clip chosen in the list or on a tick: {src, a, b}
  let auditionEnd = null; // playing a hidden clip on its own stops here
  let zoom = null;       // the source bar's window, {a, b} in source time; null shows it whole

  const el = (tag, cls, parent, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  };
  const fmt = (t) => {
    if (t == null || isNaN(t)) return "–";
    const m = Math.floor(t / 60), s = t - m * 60;
    return m + ":" + (s < 10 ? "0" : "") + s.toFixed(1);
  };

  // ---- the page
  const app = el("div", "nle", document.body);
  const head = el("div", "head", app);
  const title = el("div", "title", head);
  const clock = el("div", "clock", head);
  const status = el("div", "status", head);
  const main = el("div", "main", app);
  const left = el("div", "left", main);
  const video = el("video", "viewer", left);
  video.preload = "auto";
  video.playsInline = true;
  const ruler = el("div", "ruler", left);
  const editBar = el("div", "bar edit", left);
  const srcTabs = el("div", "tabs", left);
  const srcBar = el("div", "bar source", left);
  const tx = el("div", "transcript", main);

  // a click anywhere in the timeline asks the editor for the keys: the
  // word handlers cancel the browser's own click, and a page in another
  // origin cannot focus its own frame (AppFrame in app.js grants it)
  const askKeys = () => { try { parent.postMessage({ compos: "request-focus" }, "*"); } catch (e) {} window.focus(); };
  document.addEventListener("mousedown", askKeys, true);

  // what the page did, for the editor to read (video-edit-timeline-log)
  const log = (what) => { try { fetch("_compos/app", { method: "POST", body: JSON.stringify({ op: "log", what: String(what).slice(0, 300) }) }); } catch (e) {} };
  addEventListener("error", (e) => log("script error: " + e.message + " @" + e.lineno));
  addEventListener("unhandledrejection", (e) => log("script error: " + (e.reason && (e.reason.stack || e.reason.message) || e.reason)));

  // ---- talking to Scheme
  const get = () => fetch(API).then((r) => r.json()).then(setState);
  const op = (o) => fetch(API, { method: "POST", body: JSON.stringify(o) }).then((r) => r.json()).then(setState);
  addEventListener("message", (e) => {
    const d = e.data;
    if (d && d.compos === "message" && d.data && d.data.sources) setState(d.data);
    // a key the editor caught for this page: it runs as if typed here
    if (d && d.compos === "message" && d.data && d.data.act) runAct(d.data.act);
    if (d && d.compos === "message" && d.data && d.data.seek) {
      // the index moves the playhead and chooses; it never starts or stops playback
      const sk = d.data.seek;
      loadSource(sk.src, sk.t); cur = segAt(sk.src, sk.t);
      // a cut or a hidden part chosen from the index: it is picked, ready for the keys
      if (sk.select === "segment") act("select-segment", { src: sk.src, t: sk.t + 0.01 });
      else if (sk.select === "pause") act("select-range", { src: sk.src, t: sk.t, b: sk.b });
      else if (sk.select === "hidden") {
        const h = clipOf(sk.src, sk.t + 0.01);
        if (h) {
          selClip = { src: sk.src, a: h.a, b: h.b, name: h.name }; selTok = null; selPieces.clear();
          drawEditBar(); drawTranscript();
          status.textContent = "Hidden “" + (h.name || "hidden") + "” · " + fmt(h.b - h.a) + " · SPC plays it · ⌫ restores it · t keeps it";
        }
      }
      else if (sk.select) act("select-cut", { src: sk.src, t: sk.t });
    }
  });

  function setState(s) {
    // an answer without the edit (the editor failed): keep what is drawn
    if (!s || !Array.isArray(s.sources)) { log("bad state: " + JSON.stringify(s).slice(0, 200)); return; }
    const t = srcTime();
    const shownUrl = S && S.sources[src] ? S.sources[src].url : null;
    S = s;
    // the videos may have moved or gone: follow the one playing, and the one shown, by file
    if (video.dataset.url) {
      const now = S.sources.findIndex((x) => x.url === video.dataset.url);
      if (now >= 0) video.dataset.src = String(now);
      else { delete video.dataset.src; delete video.dataset.url; }
    }
    if (shownUrl) { const j = S.sources.findIndex((x) => x.url === shownUrl); src = j >= 0 ? j : 0; zoom = j >= 0 ? zoom : null; }
    segs = [];
    let at = 0;
    for (const p of S.pieces || []) { segs.push({ src: p.src, a: p.a, b: p.b, at }); at += p.b - p.a; }
    if (src >= S.sources.length) src = 0;
    title.textContent = S.name;
    // the buffer's text scale, as compos steps it: 1.2 a step
    tx.style.fontSize = (13 * Math.pow(1.2, S.scale || 0)).toFixed(1) + "px";
    status.textContent = S.status || "";
    drawEditBar(); drawTabs(); drawSourceBar(); drawTranscript();
    if (selPiece != null && selPiece >= segs.length) selPiece = null;
    for (const k of [...selPieces]) if (k >= segs.length) selPieces.delete(k);
    drawSelection();
    if (!placeRestored && restorePlace()) { /* back where you were */ }
    else if (video.dataset.src == null && S.sources.length) { src = Math.min(src, S.sources.length - 1); loadSource(src, segs.length ? segs.find((g) => g.src === src)?.a || 0 : 0); }
    else if (t != null) cur = segAt(Number(video.dataset.src), t);
    paint();
  }

  // ---- playing
  function loadSource(i, t) {
    const s = S.sources[i];
    if (!s) return;
    if (video.dataset.url !== s.url) {
      // a new video: a seek before its metadata loads is dropped, so it waits
      video.dataset.src = String(i);
      video.dataset.url = s.url;
      pendingT = t;
      video.src = s.url;
    } else {
      video.dataset.src = String(i);
      if (t != null) video.currentTime = t;
    }
    if (src !== i) { src = i; zoom = null; drawTabs(); drawSourceBar(); drawTranscript(); }
  }
  const srcTime = () => (video.dataset.src == null ? null : video.currentTime);
  function segAt(i, t) {
    for (let k = 0; k < segs.length; k++) if (segs[k].src === i && t >= segs[k].a - 0.01 && t < segs[k].b) return k;
    return -1;
  }
  function nextSegAfter(i, t) {
    for (let k = 0; k < segs.length; k++) if (segs[k].src === i && segs[k].a >= t - 0.01) return k;
    for (let k = 0; k < segs.length; k++) if (segs[k].src > i) return k;
    return -1;
  }
  function seekEdit(t) {
    for (let k = 0; k < segs.length; k++) {
      const g = segs[k];
      if (t < g.at + (g.b - g.a) || k === segs.length - 1) { cur = k; loadSource(g.src, g.a + Math.max(0, t - g.at)); return; }
    }
  }
  function play() {
    log("play at " + video.currentTime.toFixed(2) + " src " + video.dataset.src + " ready " + video.readyState);
    if (!whole) {
      const i = Number(video.dataset.src);
      let k = segAt(i, video.currentTime);
      if (k < 0) k = nextSegAfter(i, video.currentTime);
      if (k < 0) k = 0;
      cur = k;
      if (segs[k] && (segAt(i, video.currentTime) !== k)) loadSource(segs[k].src, segs[k].a);
    }
    playing = true;
    const p = video.play();
    if (p && p.catch) p.catch((err) => { playing = false; log("play refused: " + err.name + " " + err.message); });
  }
  function pause() { playing = false; video.pause(); }

  // the jump over a hidden clip happens here, on every frame
  function tick() {
    if (playing && whole && auditionEnd != null && video.currentTime >= auditionEnd) {
      if (rec) stopRecord(true); else { pause(); auditionEnd = null; whole = false; }
    }
    recTick();
    syncDub();
    if (playing && !whole && S && !video.seeking) {
      const i = Number(video.dataset.src);
      const t = video.currentTime;
      const k = segAt(i, t);
      // inside a piece and not at its end: play on
      if (k >= 0 && t < segs[k].b - 0.015) cur = k;
      else {
        // at the end of a piece, or inside a hidden clip: on to the next piece
        const n = k >= 0 ? k + 1 : nextSegAfter(i, t);
        const g = segs[n];
        if (!g) pause();
        else {
          cur = n;
          if (!(g.src === i && Math.abs(g.a - t) < 0.05)) { loadSource(g.src, g.a); video.play(); }
        }
      }
    }
    paint();
    requestAnimationFrame(tick);
  }
  let pendingT = null;
  video.addEventListener("loadedmetadata", () => {
    if (pendingT != null) { video.currentTime = pendingT; pendingT = null; }
    if (playing) { const p = video.play(); if (p && p.catch) p.catch((err) => log("play refused: " + err.name)); }
  });
  video.addEventListener("error", () => log("video error " + (video.error && video.error.code) + " " + video.currentSrc));
  video.addEventListener("ended", () => { if (whole) pause(); });
  // where the playhead rests, so a cut asked for in the chat lands there
  let reported = null;
  const report = () => {
    if (playing || video.dataset.src == null) return;
    const key = video.dataset.src + ":" + video.currentTime.toFixed(2);
    if (key === reported) return;
    reported = key;
    fetch(API, { method: "POST", body: JSON.stringify({ op: "at", src: Number(video.dataset.src), t: video.currentTime }) });
  };
  video.addEventListener("pause", report);
  video.addEventListener("seeked", report);

  // ---- drawing
  function drawEditBar() {
    editBar.textContent = "";
    lastOn = -2;
    const total = S.total || 1;
    segs.forEach((g, k) => {
      const first = k === 0 || segs[k - 1].src !== g.src;
      const atCut = !first && Math.abs(segs[k - 1].b - g.a) < 0.02;
      const b = el("div", "piece s" + (g.src % 6) + (first ? " first" : "") + (atCut ? " at-cut" : ""), editBar);
      if (first) el("span", "plabel", b, (g.src + 1) + ". " + S.sources[g.src].name.replace(/\.[^.]+$/, ""));
      b.style.width = ((g.b - g.a) / total) * 100 + "%";
      b.title = (k + 1) + ". " + fmt(g.a) + " → " + fmt(g.b) + " · " + fmt(g.b - g.a) + " · click selects the segment, ⇧-click a run, ⌫ removes";
      b.dataset.k = k;
      if (selPieces.has(k)) b.classList.add("sel");
      // a cut where this piece starts: a handle to pick, drag or delete
      if (atCut) {
        const h = el("div", "bhandle" + (selTok && selTok.kind === "cut" && Math.abs(selTok.t - g.a) < 0.01 && src === g.src ? " sel" : ""), editBar);
        h.style.left = (g.at / total) * 100 + "%";
        h.title = "cut at " + fmt(g.a) + " · drag to move it · ⌫ deletes it";
        if (markOf(g.src, g.a) != null) el("span", "bmark", h, String(markOf(g.src, g.a)));
        const prev = segs[k - 1];
        h.addEventListener("mousedown", (e) => {
          e.stopPropagation(); e.preventDefault();
          const r = editBar.getBoundingClientRect(), x0 = e.clientX;
          dragCut(e, g.src, g.a, h, (x) => Math.max(prev.a + 0.1, Math.min(g.b - 0.1, g.a + ((x - x0) / r.width) * total)), (x) => (((g.at + ((x - x0) / r.width) * total) / total) * 100));
        });
      }
    });
    // takes, on the program track too: a strip under each stretch that plays a take
    segs.forEach((g) => {
      for (const d of (S.sources[g.src] && S.sources[g.src].dubs) || []) {
        const a = Math.max(d.a, g.a), b = Math.min(d.b, g.b);
        if (b <= a + 0.01) continue;
        const m = el("div", "ptake", editBar);
        m.style.left = ((g.at + (a - g.a)) / total) * 100 + "%";
        m.style.width = ((b - a) / total) * 100 + "%";
        m.title = "take · " + fmt(d.a) + " – " + fmt(d.b) + " of " + S.sources[g.src].name;
      }
    });
    drawRuler();
    // where something was taken out: a tick at the join
    for (const h of hiddenClips()) {
      const d = el("div", "tick" + (sameClip(h, selClip) ? " sel" : ""), editBar);
      d.style.left = (joinAt(h) / total) * 100 + "%";
      d.title = (h.name || "hidden") + " · " + fmt(h.b - h.a) + " removed · " + fmt(h.a) + " → " + fmt(h.b) + " · click plays it";
      d.addEventListener("mousedown", (e) => { e.stopPropagation(); audition(h); });
    }
    el("div", "head-line", editBar);
  }
  function drawRuler() {
    ruler.textContent = "";
    const total = S.total || 1;
    const step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900].find((s) => total / s <= 14) || 1800;
    for (let t = 0; t <= total; t += step) {
      const m = el("div", "tick-mark", ruler);
      m.style.left = (t / total) * 100 + "%";
      el("span", "", m, fmt(t).replace(/\.0$/, ""));
    }
  }

  // moving a cut: the mark follows the pointer, and lets go on a word start when one is near
  function snapToWord(i, t) {
    const ws = (S.sources[i] && S.sources[i].words) || [];
    let best = null, bd = 0.25;
    for (const w of ws) { const d = Math.abs(w[0] - t); if (d < bd) { bd = d; best = w[0] - 0.02; } }
    return best == null ? t : best;
  }
  function dragCut(e, i, t0, mark, toTime, toLeft) {
    const x0 = e.clientX;
    let moved = false;
    const move = (ev) => {
      if (Math.abs(ev.clientX - x0) > 3) moved = true;
      if (!moved) return;
      mark.style.left = toLeft(ev.clientX) + "%";
      mark.classList.add("dragging");
      status.textContent = "Cut → " + fmt(snapToWord(i, toTime(ev.clientX)));
    };
    const up = (ev) => {
      removeEventListener("mousemove", move); removeEventListener("mouseup", up);
      if (!moved) {
        act("select-cut", { src: i, t: t0 }).then(() => openCutMenu(srcBar.querySelector(".cut.sel") || editBar.querySelector(".bhandle.sel") || mark));
        return;
      }
      const nt = snapToWord(i, toTime(ev.clientX));
      selTok = { kind: "cut", t: nt };
      op({ op: "move-cut", src: i, from: t0, t: nt });
      status.textContent = "Cut moved to " + fmt(nt);
    };
    addEventListener("mousemove", move); addEventListener("mouseup", up);
  }

  // choosing pieces: a click takes one, ⇧-click a run from the last one

  function hiddenClips() {
    const out = [];
    (S.sources || []).forEach((s, i) => (s.clips || []).forEach((c) => { if (c.state === "hidden") out.push({ src: i, a: c.a, b: c.b, name: c.name }); }));
    return out.sort((x, y) => x.src - y.src || x.a - y.a);
  }
  const sameClip = (x, y) => x && y && x.src === y.src && Math.abs(x.a - y.a) < 0.006 && Math.abs(x.b - y.b) < 0.006;
  // the edit time where a hidden clip was taken out
  function joinAt(h) {
    let at = 0;
    for (const g of segs) {
      if (g.src < h.src || (g.src === h.src && g.b <= h.a + 0.01)) at = g.at + (g.b - g.a);
    }
    return at;
  }
  function audition(h) {
    selClip = { src: h.src, a: h.a, b: h.b, name: h.name };
    selPiece = null;
    whole = true;
    auditionEnd = h.b;
    loadSource(h.src, h.a);
    playing = true; video.play();
    status.textContent = "Playing hidden “" + (h.name || "hidden") + "” · t keeps it · ⌫ restores it · n names it";
    drawEditBar(); drawTranscript();
  }
  editBar.addEventListener("mousedown", (e) => {
    const r = editBar.getBoundingClientRect();
    whole = false;
    seekEdit(((e.clientX - r.left) / r.width) * (S.total || 0));
    const g = segs[cur]; if (g) act("select-segment", { src: g.src, t: g.a + 0.01 });
  });
  function drawSelection() {
    for (const p of editBar.querySelectorAll(".piece")) p.classList.toggle("sel", selPieces.has(Number(p.dataset.k)));
    drawSourceSel();
    const n = selPieces.size, len = [...selPieces].reduce((x, k) => x + (segs[k] ? segs[k].b - segs[k].a : 0), 0);
    status.textContent = n === 1 ? "Segment " + ([...selPieces][0] + 1) + " · " + fmt(len) + " · ⌫ removes it · ⇧-click adds a run" : n > 1 ? n + " segments · " + fmt(len) + " · ⌫ removes them" : (S && S.status) || "";
  }

  // the project: every source in play order; the chosen one fills the source bar
  function drawTabs() {
    // nothing here: the keys (+ import, p project file) and the bars say it
    srcTabs.textContent = "";
    srcTabs.style.display = "none";
  }

  // the zoom: what part of the source the source bar shows
  const win = (s) => (zoom ? zoom : { a: 0, b: s.dur });
  const at = (s, t) => { const w = win(s); return ((t - w.a) / (w.b - w.a)) * 100; };
  function setZoom(s, a, b) {
    if (!s) return;
    const span = Math.max(1, Math.min(s.dur, b - a));
    if (span >= s.dur - 0.01) zoom = null;
    else { const a2 = Math.max(0, Math.min(s.dur - span, a)); zoom = { a: a2, b: a2 + span }; }
    layoutSourceBar();
  }

  // the source bar is built when the edit or the source changes; a zoom only moves
  // what is there. The two pictures are made once per file and kept.
  const imgCache = {};
  const keptImg = (cls, url) => {
    const key = cls + "|" + url;
    if (!imgCache[key]) { const i = document.createElement("img"); i.className = cls; i.decoding = "async"; i.src = url; imgCache[key] = i; }
    return imgCache[key];
  };
  let zoomLabel = null;
  function drawSourceBar() {
    srcBar.textContent = "";
    zoomLabel = null;
    const s = S && S.sources[src];
    if (!s) return;
    if (s.strip) srcBar.appendChild(keptImg("strip", s.strip));
    if (s.wave) srcBar.appendChild(keptImg("wave", s.wave));
    zoomLabel = el("div", "zoom-label", srcBar);
    for (const c of s.clips || []) {
      const d = el("div", "clip " + c.state, srcBar);
      d.dataset.a = c.a; d.dataset.b = c.b;
      d.title = (c.name ? c.name + " · " : "") + c.state + " · " + fmt(c.a) + " → " + fmt(c.b);
      if (c.name) el("span", "", d, c.name);
    }
    for (const c of s.cuts || []) {
      const d = el("div", "cut" + (selTok && selTok.kind === "cut" && Math.abs(selTok.t - c) < 0.01 ? " sel" : ""), srcBar);
      d.dataset.t = c;
      d.title = "cut at " + fmt(c) + " · drag to move it · ⌫ deletes it";
      el("span", "", d, "✂" + (markOf(src, c) != null ? markOf(src, c) : ""));
      d.addEventListener("mousedown", (e) => {
        e.stopPropagation(); e.preventDefault();
        const r = srcBar.getBoundingClientRect(), w = win(s);
        const toT = (x) => Math.max(0, Math.min(s.dur, w.a + ((x - r.left) / r.width) * (w.b - w.a)));
        dragCut(e, src, c, d, toT, (x) => at(s, toT(x)));
      });
    }
    for (const d of s.dubs || []) {
      const b = el("div", "dub" + (selTok && selTok.kind === "dub" && Math.abs(selTok.a - d.a) < 0.05 ? " sel" : ""), srcBar, "🎙 take");
      b.dataset.a = d.a; b.dataset.b = d.b;
      b.title = "take over " + fmt(d.a) + " – " + fmt(d.b) + " · click, then ⌫ takes it out";
      b.addEventListener("mousedown", (e) => { e.stopPropagation(); e.preventDefault(); act("select-dub", { src, t: d.a }); });
    }
    for (const m of s.mutes || []) { const b = el("div", "mute", srcBar, "🔇"); b.dataset.a = m.a; b.dataset.b = m.b; b.title = "muted " + fmt(m.a) + " – " + fmt(m.b) + " · m on it gives the sound back"; }
    el("div", "psel-layer", srcBar).id = "psel";
    el("div", "mark", srcBar).id = "mark";
    el("div", "head-line", srcBar);
    layoutSourceBar();
  }
  function layoutSourceBar() {
    const s = S && S.sources[src];
    if (!s) return;
    const w = win(s), span = w.b - w.a, scale = s.dur / span;
    for (const img of srcBar.querySelectorAll("img")) { img.style.width = scale * 100 + "%"; img.style.left = -(w.a / span) * 100 + "%"; }
    if (zoomLabel) { zoomLabel.style.display = zoom ? "block" : "none"; zoomLabel.textContent = Math.round(scale * 10) / 10 + "× · " + fmt(w.a) + " – " + fmt(w.b) + " · 0 whole"; }
    for (const d of srcBar.querySelectorAll(".clip")) {
      const a = Number(d.dataset.a), b = Number(d.dataset.b);
      d.style.left = at(s, a) + "%"; d.style.width = ((b - a) / span) * 100 + "%";
      const lbl = d.firstChild; if (lbl) lbl.style.display = (b - a) / span > 0.04 ? "" : "none";
    }
    for (const d of srcBar.querySelectorAll(".cut")) d.style.left = at(s, Number(d.dataset.t)) + "%";
    for (const d of srcBar.querySelectorAll(".mute")) { const a = Number(d.dataset.a), b = Number(d.dataset.b); d.style.left = at(s, a) + "%"; d.style.width = ((b - a) / span) * 100 + "%"; }
    for (const d of srcBar.querySelectorAll(".dub")) { const a = Number(d.dataset.a), b = Number(d.dataset.b); d.style.left = at(s, a) + "%"; d.style.width = ((b - a) / span) * 100 + "%"; }
    drawSourceSel();
  }
  srcBar.addEventListener("mousedown", (e) => {
    const s = S.sources[src];
    const r = srcBar.getBoundingClientRect(), w = win(s);
    loadSource(src, w.a + ((e.clientX - r.left) / r.width) * (w.b - w.a));
    cur = segAt(src, video.currentTime);
    act("select-segment", { src, t: video.currentTime });
  });

  let wheelZoom = 0, wheelPan = 0, wheelAt = null, wheelQueued = false;
  // a window the page set (the wheel, the follow while playing) is told to Scheme, once it settles
  let zoomTold = null;
  const tellZoom = () => { clearTimeout(zoomTold); zoomTold = setTimeout(() => fetch(API, { method: "POST", body: JSON.stringify({ op: "act", name: "zoom-to", src, t: zoom ? zoom.a : 0, b: zoom ? zoom.b : -1, playing }) }), 300); };
  function applyWheel() {
    wheelQueued = false;
    const s = S && S.sources[src]; if (!s) return;
    const w = win(s);
    if (wheelZoom && wheelAt) { const span = (w.b - w.a) * Math.exp(wheelZoom * 0.01); setZoom(s, wheelAt.t - wheelAt.frac * span, wheelAt.t - wheelAt.frac * span + span); }
    else if (wheelPan) setZoom(s, w.a + wheelPan, w.b + wheelPan);
    wheelZoom = 0; wheelPan = 0;
    tellZoom();
  }
  // the wheel: ⌘ or a pinch zooms around the pointer, otherwise it pans a zoomed bar
  srcBar.addEventListener("wheel", (e) => {
    const s = S && S.sources[src]; if (!s) return;
    e.preventDefault();
    const r = srcBar.getBoundingClientRect(), w = win(s);
    const frac = (e.clientX - r.left) / r.width, t = w.a + frac * (w.b - w.a);
    if (e.ctrlKey || e.metaKey) {
      wheelZoom += e.deltaY; wheelAt = { t, frac };
    } else if (zoom) wheelPan += ((e.deltaX || e.deltaY) / r.width) * (w.b - w.a);
    if (!wheelQueued) { wheelQueued = true; requestAnimationFrame(applyWheel); }
  }, { passive: false });

  // the edit points: every place a piece starts (a cut, a removed stretch, the next
  // video) and the end; in whole-source mode, the source's cuts and clip edges
  // the chosen segment, marked on the source bar as well
  function drawSourceSel() {
    const layer = document.getElementById("psel");
    const s = S && S.sources[src];
    if (!layer || !s) return;
    layer.textContent = "";
    const w = win(s);
    if (selRange && selRange.src === src) { const d = el("div", "psel", layer); d.style.left = at(s, selRange.a) + "%"; d.style.width = ((selRange.b - selRange.a) / (w.b - w.a)) * 100 + "%"; }
  }

  // the bookmark a cut carries, if any
  function markOf(i, t) { const s = S && S.sources[i]; const m = ((s && s.marks) || []).find((x) => Math.abs(x[0] - t) < 0.02); return m ? m[1] : null; }

  function clipOf(i, t) {
    const s = S.sources[i];
    for (const c of (s && s.clips) || []) if (t >= c.a && t < c.b) return c;
    return null;
  }

  function drawTranscript() {
    tx.textContent = "";
    const s = S && S.sources[src];
    if (!s) return;
    if (!s.words || !s.words.length) { el("div", "empty", tx, "No transcript yet: C-c C-t in the edit writes it."); return; }
    let line = el("p", "", tx);
    let last = null, count = 0, inClip = null;
    const cutQ = (s.cuts || []).slice().sort((x, y) => x - y);
    s.words.forEach((w, n) => {
      const c = clipOf(src, (w[0] + w[1]) / 2);
      const hid = c && c.state === "hidden" ? c : null;
      const brk = last && (/[.?!]$/.test(last[2]) || w[0] - last[1] > 0.7 || (count >= 12 && /,$/.test(last[2])) || count >= 22);
      if (hid !== inClip) {
        // a hidden clip begins or ends: its words take a row of their own
        line = el("p", hid ? "hidden-row" : "", tx); count = 0;
        if (hid) {
          const h = { src, a: hid.a, b: hid.b, name: hid.name };
          const tag = el("span", "hr-tag" + (sameClip(h, selClip) ? " sel" : ""), line, (hid.name || "hidden") + " · " + fmt(hid.b - hid.a));
          tag.title = "click plays it · t keeps it · ⌫ restores it · n names it";
          tag.addEventListener("mousedown", (e) => { e.stopPropagation(); e.preventDefault(); audition(h); });
        }
        inClip = hid;
      } else if (brk && !hid) { line = el("p", "", tx); count = 0; }
      count++;
      if (!hid && line.childNodes.length === 0) el("span", "t", line, fmt(w[0]));
      // a cut just before this word: a mark you can select, move and remove
      while (cutQ.length && cutQ[0] <= w[0] + 0.05) {
        const ct = cutQ.shift();
        const m = el("span", "tok cutmark" + (selTok && selTok.kind === "cut" && Math.abs(selTok.t - ct) < 0.01 ? " sel" : ""), line, "✂" + (markOf(src, ct) != null ? markOf(src, ct) : ""));
        m.title = "cut at " + fmt(ct) + " · click, then ← → move it a word, ⌫ removes it";
        m.addEventListener("mousedown", (e) => { e.stopPropagation(); e.preventDefault(); act("select-cut", { src, t: ct }).then(() => openCutMenu(tx.querySelector(".cutmark.sel") || m)); });
      }
      // a silence before this word: a mark you can hide
      if (last && w[0] - last[1] >= 1.0) {
        const g = { kind: "gap", a: last[1], b: w[0] };
        const m = el("span", "tok gap" + (selRange && selRange.src === src && Math.abs(selRange.a - g.a) < 0.02 && Math.abs(selRange.b - g.b) < 0.02 ? " sel" : ""), line, "⏸ " + (w[0] - last[1]).toFixed(1) + "s");
        m.title = "silence · click, then ⌫ or h hides it";
        m.addEventListener("mousedown", (e) => { e.stopPropagation(); e.preventDefault(); act("select-range", { src, t: g.a, b: g.b }); });
      }
      const sp = el("span", "w" + (c ? " " + c.state : "") + (dubAt(src, (w[0] + w[1]) / 2) ? " dubbed" : "") + ((S.sources[src].mutes || []).some((x) => (w[0] + w[1]) / 2 >= x.a && (w[0] + w[1]) / 2 < x.b) ? " muted" : ""), line, w[2] + " ");
      sp.dataset.n = n; sp.dataset.a = w[0]; sp.dataset.b = w[1];
      // inside what Scheme chose: the words the keys act on
      if (selRange && selRange.src === src && w[0] >= selRange.a - 0.02 && w[1] <= selRange.b + 0.02) sp.classList.add("sel");
      if (n === caret) sp.classList.add("caret");
      last = w;
    });
  }
  // a cut or a silence chosen in the transcript
  let selTok = null;
  // ---- the cut's menu: what can be done there, each with its key
  let cutMenu = null;
  function closeCutMenu() { if (cutMenu) { cutMenu.remove(); cutMenu = null; } }

  function openCutMenu(anchor) {
    closeCutMenu();
    if (!selTok || selTok.kind !== "cut") return;
    const t = selTok.t, s = S.sources[src], cuts = (s.cuts || []).slice().sort((x, y) => x - y);
    const next = cuts.find((c) => c > t + 0.01) ?? s.dur, prev = cuts.filter((c) => c < t - 0.01).pop() ?? 0;
    const items = [
      ["Hide or show after it, to " + (next === s.dur ? "the end" : "the next cut") + " (" + fmt(next - t) + ")", "h", () => runAct("hide")],
      ["Mute or unmute it, to " + (next === s.dur ? "the end" : "the next cut"), "m", () => runAct("mute")],
      ["Re-record the segment after it", "r", () => runAct("record")],
      ["Play from here", "RET", () => { selTok = null; loadSource(src, t); play(); }],
      ["Move it a word later", "⇧→", () => runAct("select-word-on")],
      ["Move it a line down", "⇧↓", () => runAct("select-down")],
      
      ["Delete the cut", "⌫", () => runAct("remove")],
    ];
    cutMenu = el("div", "cutmenu", document.body);
    el("div", "cm-head", cutMenu, "✂ Cut at " + fmt(t));
    for (const [label, key, act] of items) {
      const row = el("div", "cm-row", cutMenu);
      el("span", "cm-label", row, label);
      el("kbd", "", row, key);
      row.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); closeCutMenu(); act(); });
    }
    const r = anchor.getBoundingClientRect();
    const w = 300;
    cutMenu.style.left = Math.max(8, Math.min(innerWidth - w - 8, r.left - 10)) + "px";
    cutMenu.style.top = (r.bottom + 6 + 260 > innerHeight ? Math.max(8, r.top - 266) : r.bottom + 6) + "px";
  }
  addEventListener("mousedown", (e) => { if (cutMenu && !cutMenu.contains(e.target)) closeCutMenu(); }, true);
  addEventListener("keydown", () => closeCutMenu(), true);

  let dragFrom = null, dragMoved = false;
  tx.addEventListener("mousedown", (e) => {
    const n = e.target.dataset && e.target.dataset.n;
    if (n == null) return;
    e.preventDefault();
    if (e.shiftKey && wordA != null) { wordB = Number(n); marksFromWords(); chooseWords(); return; }
    dragFrom = Number(n); dragMoved = false; dragging = true;
    if (selTok) { selTok = null; }
  });
  tx.addEventListener("mouseover", (e) => {
    const n = e.target.dataset && e.target.dataset.n;
    if (dragging && n != null && Number(n) !== dragFrom) { dragMoved = true; wordA = dragFrom; wordB = Number(n); marksFromWords(); }
  });
  addEventListener("mouseup", (e) => {
    // a drag over words: the run is chosen, for h, m, r and ⌫
    if (dragging && dragMoved) chooseWords();
    if (dragging && !dragMoved && dragFrom != null) {
      // a click: the playhead goes to the start of the word, the selection goes; ⇧-click runs from here
      wordA = dragFrom; wordB = null;
      pause();
      act("caret", { src, t: S.sources[src].words[dragFrom][0], b: dragFrom });
      status.textContent = "At “" + S.sources[src].words[dragFrom][2] + "” · c cuts before it · drag over words, then ⌫ removes them";
    }
    dragging = false;
  });
  tx.addEventListener("dblclick", (e) => {
    const n = e.target.dataset && e.target.dataset.n;
    if (n != null) { loadSource(src, S.sources[src].words[Number(n)][0]); cur = segAt(src, video.currentTime); }
  });
  // the run of words from wordA to wordB, its times read off the spans
  function marksFromWords() {
    const a = Math.min(wordA, wordB), b = Math.max(wordA, wordB);
    mIn = Number(wordSpan(a).dataset.a); mOut = Number(wordSpan(b).dataset.b);
    for (const sp of tx.querySelectorAll(".w")) sp.classList.toggle("sel", Number(sp.dataset.n) >= a && Number(sp.dataset.n) <= b);
  }

  // the run goes to Scheme as the chosen range; its answer draws it from then on
  function chooseWords() {
    const t = mIn, b = mOut;
    mIn = mOut = null;
    act("select-range", { src, t, b });
  }

  // ---- the cursor: a word, moved like a text cursor; the playhead follows it
  let caret = null;
  const wordSpan = (n) => tx.querySelector('.w[data-n="' + n + '"]');
  function seekWord(n) {
    const w = S.sources[src].words[n];
    if (!w) return;
    loadSource(src, w[0]);
    cur = segAt(src, w[0]);
  }

  // each frame: only what moved. The clock and the lit piece change when they change,
  // the word at the playhead is found by halving, and nothing is searched for twice.
  let lastWord = null, lastClock = "", lastOn = -2;
  function wordAt(ws, t) {
    let lo = 0, hi = ws.length - 1, n = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (ws[mid][0] <= t) { n = mid; lo = mid + 1; } else hi = mid - 1; }
    return n;
  }
  function paint() {
    if (!S) return;
    const i = Number(video.dataset.src);
    const t = video.currentTime;
    const k = segAt(i, t);
    const et = k < 0 ? null : segs[k].at + (t - segs[k].a);
    const c = (et == null ? "(hidden) " : fmt(et)) + " / " + fmt(S.total) + "   ·   source " + fmt(t) + (whole ? "   ·   whole source" : "");
    if (c !== lastClock) { clock.textContent = c; lastClock = c; }
    const eh = editBar.lastElementChild;
    if (eh && eh.classList.contains("head-line")) eh.style.transform = "translateX(" + (et == null ? -9999 : (et / (S.total || 1)) * editBar.clientWidth) + "px)";
    const s = S.sources[src];
    // zoomed in: playing, the view moves on before the playhead reaches an edge; scrubbed
    // or jumped out of view, it comes back; either way the playhead goes to the middle
    if (zoom && s && i === src) {
      const span = zoom.b - zoom.a, m = playing ? span * 0.1 : 0;
      if (t < zoom.a + m || t > zoom.b - m) { setZoom(s, t - span / 2, t + span / 2); tellZoom(); }
    }
    const sh = srcBar.lastElementChild;
    if (sh && sh.classList.contains("head-line") && s) sh.style.transform = "translateX(" + (i === src ? (at(s, t) / 100) * srcBar.clientWidth : -9999) + "px)";
    const mk = document.getElementById("mark");
    if (mk && s) {
      if (mIn != null) {
        const b = mOut != null && mOut > mIn ? mOut : mIn + 0.05;
        mk.style.display = "block";
        mk.style.left = at(s, mIn) + "%";
        mk.style.width = ((b - mIn) / (win(s).b - win(s).a)) * 100 + "%";
      } else if (mk.style.display !== "none") mk.style.display = "none";
    }
    if (k !== lastOn) {
      const pieces = editBar.children;
      for (const p of pieces) if (p.classList.contains("piece")) p.classList.toggle("on", Number(p.dataset.k) === k);
      lastOn = k;
    }
    // on a cut, paused: no word is lit; playing (a take too), the words follow again
    if (selTok && selTok.kind === "cut" && !playing) {
      if (lastWord !== -2) { for (const w of tx.querySelectorAll(".w.now, .w.caret")) w.classList.remove("now", "caret"); lastWord = -2; }
    } else if (s && s.words && i === src) {
      const n = wordAt(s.words, t);
      if (n !== lastWord) {
        const old = tx.querySelector(".w.now"); if (old) old.classList.remove("now");
        const sp = tx.querySelector('.w[data-n="' + n + '"]');
        if (sp) { sp.classList.add("now"); if (playing) sp.scrollIntoView({ block: "nearest" }); }
        lastWord = n;
        if (playing && n >= 0) { caret = n; const oc = tx.querySelector(".w.caret"); if (oc) oc.classList.remove("caret"); if (sp) sp.classList.add("caret"); }
      }
    }
  }

  // ---- keys
  function clearMarks() {
    mIn = mOut = null; wordA = wordB = null;
    for (const sp of tx.querySelectorAll(".w.sel")) sp.classList.remove("sel");
  }
  // ---- keys and actions. The page keeps no keymap: a key typed here goes to the
  // editor, whose keymap runs a command; the command names an action. What only
  // moves the picture (play, scrub, zoom) the page does itself; every other action
  // goes to Scheme with the playhead, and Scheme answers the edit and what to show.
  addEventListener("keydown", (e) => {
    if (e.key === "Shift" || e.key === "Alt" || e.key === "Meta" || e.key === "Control") return;
    e.preventDefault();
    parent.postMessage({ compos: "key", key: e.key, code: e.code, shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey, ctrlKey: e.ctrlKey }, "*");
  });

  // the few things that are the page's own: the media element and the file buttons
  const LOCAL = {
    "export-key": () => op({ op: "export" }), "import-key": () => op({ op: "import" }), "project-file": () => op({ op: "show-edit" }),
    "source-earlier": () => op({ op: "move-source", src, dir: -1 }), "source-later": () => op({ op: "move-source", src, dir: 1 }),
    "drop-source": () => { if (confirm("Take " + S.sources[src].name + " out of the edit?")) op({ op: "remove-source", src }); },
  };
  function runAct(name, at) {
    if (rec && (name === "record" || name === "play")) return stopRecord(true);
    if (rec && name === "clear") return stopRecord(false);
    if (LOCAL[name]) return LOCAL[name]();
    return act(name, at);
  }
  // every action goes to Scheme with the playhead; the answer is the whole view
  function act(name, at) {
    const i = at ? at.src : Number(video.dataset.src), t = at ? at.t : video.currentTime;
    return fetch(API, { method: "POST", body: JSON.stringify({ op: "act", name, src: i, t, b: at && at.b, playing }) })
      .then((r) => r.json()).then((s) => { setState(s); applyView(s.view || {}); });
  }
  // the page draws Scheme's view: what is chosen, which video, the zoom, whole mode,
  // the cursor, playing or not, and where the playhead goes
  function applyView(v) {
    const sel = v.sel;
    selTok = sel && sel.kind === "cut" ? { kind: "cut", t: sel.t } : sel && sel.kind === "dub" ? { kind: "dub", a: sel.a } : null;
    selRange = sel && sel.kind === "range" ? { src: sel.src, a: sel.a, b: sel.b } : sel && sel.kind === "cut" ? (() => { const s = S.sources[sel.src], cs = (s.cuts || []).slice().sort((x, y) => x - y); return { src: sel.src, a: sel.t, b: cs.find((c) => c > sel.t + 0.02) ?? s.dur }; })() : null;
    selPieces.clear();
    if (selRange) segs.forEach((g, k) => { if (g.src === selRange.src && g.b > selRange.a + 0.01 && g.a < selRange.b - 0.01) selPieces.add(k); });
    whole = !!v.whole;
    caret = selTok ? null : (v.caret ?? null);
    if (v.shown != null && v.shown !== src && S.sources[v.shown]) { src = v.shown; drawTabs(); }
    zoom = v.zoom ? { a: v.zoom.a, b: v.zoom.b } : null;
    if (v.seek) { loadSource(v.seek.src, v.seek.t); cur = segAt(v.seek.src, v.seek.t); }
    drawEditBar(); drawSourceBar(); drawTranscript(); drawSelection();
    // what was chosen comes into view in the transcript: a cut, a pause, else the first word of the segment
    const chosen = tx.querySelector(".cutmark.sel, .tok.gap.sel") || (selRange && selRange.src === src && (() => { const ws = S.sources[src].words || []; const n = ws.findIndex((w) => w[0] >= selRange.a - 0.05); return n >= 0 ? tx.querySelector('.w[data-n="' + n + '"]') : null; })());
    if (chosen && (v.seek || v.sel)) chosen.scrollIntoView({ block: "center" });
    if (v.status != null) status.textContent = v.status;
    if (v.playing && !playing) play(); else if (v.playing === false && playing) pause();
    if (v.record) startRecord(v.record);
    paint();
  }

  // ---- re-record: the selected stretch plays, its own sound off, while the mic records.
  // The take goes to Scheme, which keeps it beside the edit and lays it in with a dub line.
  let rec = null, micStream = null;
  const recBox = el("div", "recbox", app);
  recBox.style.display = "none";
  async function startRecord(r) {
    if (r && r.src != null && r.src !== src) loadSource(r.src, r.a);
    log("record: range " + (r ? fmt(r.a) + "–" + fmt(r.b) : "none"));
    if (!r) { status.textContent = "Put the playhead in a segment, or pick one, then r records over it"; return; }
    pause();
    status.textContent = "Asking for the microphone…";
    try {
      if (!micStream) micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    } catch (e) { status.textContent = "No microphone: " + e.message; log("mic refused: " + e.name + " " + e.message); return; }
    log("record: mic ok, tracks " + micStream.getAudioTracks().length);
    const mime = ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"].find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m)) || "";
    const recorder = new MediaRecorder(micStream, mime ? { mimeType: mime } : undefined);
    const chunks = [];
    recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    // a run-up: the video plays from three seconds before, with its own sound, so you
    // can come in on time; at the start of the stretch the sound goes off and the mic on
    rec = { recorder, chunks, src, a: r.a, b: r.b, save: true, mime: recorder.mimeType || mime, armed: true };
    whole = true;
    auditionEnd = r.b;
    recBox.style.display = "flex";
    loadSource(src, Math.max(0, r.a - 3));
    playing = true; video.play();
  }
  // the count-in: a big number over the picture and a click on each second, then Speak
  const countBig = el("div", "countin", left);
  countBig.style.display = "none";
  let clickCtx = null;
  function click(high) {
    try {
      clickCtx = clickCtx || new AudioContext();
      const o = clickCtx.createOscillator(), g = clickCtx.createGain();
      o.frequency.value = high ? 1320 : 880;
      g.gain.setValueAtTime(0.25, clickCtx.currentTime);
      g.gain.exponentialRampToValueAtTime(0.001, clickCtx.currentTime + 0.08);
      o.connect(g).connect(clickCtx.destination);
      o.start(); o.stop(clickCtx.currentTime + 0.09);
    } catch (e) {}
  }
  // each frame while armed: count down to the stretch, then start the mic exactly there
  function recTick() {
    if (!rec) { if (countBig.style.display !== "none" && !(rec && rec.started)) countBig.style.display = "none"; return; }
    if (rec.started && countBig.textContent === "● Speak" && performance.now() - rec.started > 900) countBig.style.display = "none";
    if (!rec.armed || Number(video.dataset.src) !== rec.src) return;
    const left = rec.a - video.currentTime;
    if (left > 0.02) {
      const n = Math.ceil(left);
      if (rec.shown !== n) { rec.shown = n; countBig.textContent = String(n); countBig.style.display = "flex"; countBig.classList.remove("go"); click(n === 1); }
      recBox.textContent = "Recording in " + n + "… · esc cancels";
      return;
    }
    countBig.textContent = "● Speak"; countBig.classList.add("go"); countBig.style.display = "flex";
    rec.armed = false;
    rec.a = video.currentTime;
    video.muted = true;
    rec.recorder.start(250);
    rec.started = performance.now();
    log("record: started at " + fmt(rec.a));
    recBox.textContent = "● Recording · r or space stops · esc throws it away";
    recBox.classList.add("on");
  }
  function stopRecord(save) {
    if (!rec) return;
    const r = rec; rec = null;
    r.save = save;
    recBox.classList.remove("on");
    countBig.style.display = "none";
    video.muted = false; pause(); whole = false; auditionEnd = null;
    if (!r.started) { recBox.style.display = "none"; return; }
    r.recorder.onstop = () => {
      recBox.style.display = "none";
      if (!r.save || !r.chunks.length) { status.textContent = "Take thrown away"; return; }
      log("record: stopped, " + r.chunks.length + " chunks");
      const blob = new Blob(r.chunks, { type: r.mime || "audio/webm" });
      const fr = new FileReader();
      fr.onload = () => {
        const data = String(fr.result).split(",")[1] || "";
        status.textContent = "Saving the take…";
        op({ op: "dub", src: r.src, a: r.a, data, mime: r.mime });
      };
      fr.readAsDataURL(blob);
    };
    r.recorder.stop();
  }

  // ---- takes play back in place of the sound under them
  const dubAudio = new Audio();
  dubAudio.preload = "auto";
  function dubAt(i, t) {
    const s = S && S.sources[i];
    for (const d of (s && s.dubs) || []) if (t >= d.a && t < d.b) return d;
    return null;
  }
  function syncDub() {
    if (!S || rec) return;
    const i = Number(video.dataset.src), t = video.currentTime;
    const d = playing ? dubAt(i, t) : null;
    if (d) {
      video.muted = true;
      const want = t - d.a;
      if (dubAudio.dataset.url !== d.url) {
        // a take that has not loaded cannot seek: it plays only once it is at the right moment
        dubAudio.dataset.url = d.url; dubAudio.dataset.ready = "";
        dubAudio.src = d.url;
        dubAudio.onloadedmetadata = () => { dubAudio.dataset.ready = "1"; };
        return;
      }
      if (!dubAudio.dataset.ready) return;
      if (Math.abs(dubAudio.currentTime - want) > 0.12) { dubAudio.currentTime = want; return; }
      if (dubAudio.paused && !dubAudio.seeking) dubAudio.play().catch(() => {});
    } else {
      if (!dubAudio.paused) dubAudio.pause();
      const s = S.sources[i], m = playing && s && (s.mutes || []).some((x) => t >= x.a && t < x.b);
      if (!rec && video.muted !== !!m) video.muted = !!m;
    }
  }

  // ---- a reload keeps your place: where you are, what you look at, the zoom
  const placeKey = () => "nle-place:" + (S ? S.name : "");
  function savePlace() {
    if (!S || !video.dataset.url) return;
    try {
      sessionStorage.setItem(placeKey(), JSON.stringify({
        url: video.dataset.url, t: video.currentTime,
        shown: S.sources[src] ? S.sources[src].url : null,
        zoom, whole, caret, scroll: tx.scrollTop
      }));
    } catch (e) {}
  }
  let placeRestored = false;
  function restorePlace() {
    if (placeRestored || !S) return;
    placeRestored = true;
    let p = null;
    try { p = JSON.parse(sessionStorage.getItem(placeKey()) || "null"); } catch (e) {}
    if (!p) return false;
    const i = S.sources.findIndex((x) => x.url === p.url);
    const j = S.sources.findIndex((x) => x.url === p.shown);
    if (i < 0) return false;
    whole = !!p.whole;
    loadSource(i, p.t);
    cur = segAt(i, p.t);
    if (j >= 0 && j !== src) { src = j; drawTabs(); drawSourceBar(); drawTranscript(); }
    if (p.zoom && S.sources[src]) setZoom(S.sources[src], p.zoom.a, p.zoom.b);
    if (p.caret != null) { caret = p.caret; drawTranscript(); }
    if (p.scroll) tx.scrollTop = p.scroll;
    return true;
  }
  setInterval(savePlace, 1000);
  addEventListener("pagehide", savePlace);
  addEventListener("beforeunload", savePlace);

  get();
  requestAnimationFrame(tick);
})();
