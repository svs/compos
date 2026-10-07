// Local echo for typed text: the browser's rope predicts an edit and
// paints it before the daemon answers.
//
// The daemon owns the text. In a window where Scheme turns on
// predict-mode, the daemon sends a "rope" event: the whole text once,
// then one change per version, point, and ack (the last input sequence
// number it ran; Compos.Ui.RopeSync). Every intent and key carries a
// sequence number. A typed character, Enter, or Backspace at the caret
// becomes a pending op: the client applies it to the rows at once.
//
// The rows on the screen can be older than the last rope event: while
// an input waits for its reply, LiveView holds the patch of the locked
// editor but dispatches the events. So the client keeps the rope of
// each recent version, and paints against the version the rows show
// (data-v). An op stays pending until the rows show a version whose
// ack passes it; then the daemon's rows hold its real effect.
//
// A pending op acts at point, as the daemon's command does. So the
// prediction is the daemon's text plus the pending ops, each applied at
// the point the op before it left. After a patch the rows show the
// daemon's text again, and the client applies the pending ops again.
//
// The client predicts nothing that it cannot prove: an input it cannot
// predict (a chord, a paste, a selection) blocks prediction until the
// daemon acks it, and a row the client cannot read makes it stop. A key
// that a mode takes over (paredit's "(" and DEL) arrives in "skip": the
// client sends it with no prediction (predict-skip! in predict.scm).
(function () {
  const utf8 = new TextEncoder();
  const bytes = (s) => utf8.encode(s).length;
  const S = {
    Rope: null, loading: null, queue: [], h: null, seq: 0, win: null, shadow: null,
    stats: { predicted: 0, skipped: 0, drift: 0, paint: [], confirm: [] }
  };

  // helpers from the editor hook (app.js): domPos, countsBytes, place,
  // bufOf(win)
  function init(h, src) {
    S.h = h;
    if (S.loading || !window.ComposRope) return;
    S.loading = ComposRope.load(src).then((R) => {
      S.Rope = R;
      const q = S.queue; S.queue = [];
      q.forEach(event);
    }).catch((err) => console.warn("predict: no rope", err));
  }

  const rowsOf = (buf) =>
    Array.from(buf.querySelectorAll(":scope > .line, :scope > .semantic-record > .line"));
  const contentOf = (row) => row.matches(".line-content") ? row : row.querySelector(".line-content");

  // the source text a row shows: its counted text nodes, no islands
  function rowText(row) {
    const content = contentOf(row);
    if (!content || content.querySelector("[data-len]")) return null;
    let s = "";
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    let t;
    while ((t = walker.nextNode())) if (S.h.countsBytes(t)) s += t.textContent;
    return s;
  }

  function rowAt(buf, start) {
    return rowsOf(buf).find((r) => parseInt(r.dataset.s, 10) === start) || null;
  }

  // the rows from the one that starts at START, N of them, as text
  function domRegion(buf, start, n) {
    const rows = rowsOf(buf);
    const i = rows.findIndex((r) => parseInt(r.dataset.s, 10) === start);
    if (i < 0 || i + n > rows.length) return null;
    const out = [];
    for (let k = i; k < i + n; k++) {
      const t = rowText(rows[k]);
      if (t == null) return null;
      out.push(t);
    }
    return out.join("\n");
  }

  // apply op O to rope R at PT; the point it leaves
  function step(r, pt, o) {
    if (o.kind === "ins") { r.insert(pt, o.text); return pt + bytes(o.text); }
    if (o.kind === "del") { const n = r.prevCharLen(pt); r.remove(pt - n, pt); return pt - n; }
    return pt;
  }

  // V, a view: the daemon's rope at the version the rows show (server),
  // its point (pt), and the ops that version does not hold (pending)

  // the rope after the first K pending ops, and the point they leave
  function stateAfter(V, k) {
    const r = V.server.clone();
    let pt = V.pt;
    for (let i = 0; i < k; i++) pt = step(r, pt, V.pending[i]);
    return { r, pt };
  }

  function region(rope, lo, pt) {
    const l0 = rope.byteToLine(lo), l1 = rope.byteToLine(pt);
    const s = rope.lineToByte(l0);
    const lines = [];
    for (let l = l0; l <= l1; l++) lines.push(rope.line(l));
    return { start: s, n: l1 - l0 + 1, text: lines.join("\n") };
  }

  // the lowest byte the whole queue touches, in daemon coordinates
  function lowest(V) {
    let pt = V.pt, lo = V.pt;
    const r = V.server.clone();
    for (const o of V.pending) { pt = step(r, pt, o); lo = Math.min(lo, pt); }
    r.free();
    return lo;
  }

  // does the window show the text after the first K ops?
  function shows(buf, V, k, lo) {
    const st = stateAfter(V, k);
    const want = region(st.r, lo, st.pt);
    st.r.free();
    return domRegion(buf, want.start, want.n) === want.text;
  }

  // ---- row surgery: one op on rows that show the text before it ----

  function shiftRows(buf, afterRow, dBytes, dLines) {
    let seen = false;
    for (const r of rowsOf(buf)) {
      if (!seen) { if (r === afterRow) seen = true; continue; }
      r.dataset.s = String(parseInt(r.dataset.s, 10) + dBytes);
      if (dLines) renumber(r, dLines);
    }
  }

  function renumber(row, d) {
    const m = /^(ln-\d+-)(\d+)$/.exec(row.id || "");
    if (m) row.id = m[1] + (parseInt(m[2], 10) + d);
    if (row.dataset.line) row.dataset.line = String(parseInt(row.dataset.line, 10) + d);
    const num = row.querySelector(":scope > .linenum");
    if (num && /^\d+$/.test(num.textContent)) num.textContent = String(parseInt(num.textContent, 10) + d);
  }

  // a copy must not carry the ids LiveView finds its elements by
  function stripIds(node) {
    if (node.nodeType !== 1 && node.nodeType !== 11) return;
    const strip = (e) => { e.removeAttribute("id"); e.removeAttribute("data-phx-id"); };
    if (node.removeAttribute) strip(node);
    node.querySelectorAll("[id], [data-phx-id]").forEach(strip);
  }

  // ---- the shadow: edited copies beside the daemon's rows ----
  // LiveView keeps an element whose server render did not change, so an
  // edit made inside a row it rendered can stay on the screen after the
  // daemon's answer. The client never edits those rows. It hides the rows
  // from the edit to the end, and paints copies of them. restore() takes
  // the copies away and shows the daemon's rows again, as LiveView left them.

  function restore() {
    const sh = S.shadow;
    if (!sh) return;
    S.shadow = null;
    sh.clones.forEach((c) => c.remove());
    sh.hidden.forEach((r) => {
      if (!r.isConnected) return;
      r.classList.add("line");
      r.removeAttribute("hidden");
    });
    // the point we painted goes too, unless a patch set a new one
    if (sh.setPt != null && sh.buf.dataset.pt === sh.setPt) sh.buf.dataset.pt = sh.pt;
  }

  function shadow(buf, start) {
    const rows = rowsOf(buf);
    const i = rows.findIndex((r) => parseInt(r.dataset.s, 10) === start);
    if (i < 0) return false;
    const hidden = rows.slice(i);
    if (hidden.some((r) => r.matches(".semantic-direct"))) return false;
    const clones = hidden.map((r) => { const c = r.cloneNode(true); stripIds(c); return c; });
    hidden[hidden.length - 1].after(...clones);
    hidden.forEach((r) => { r.classList.remove("line"); r.setAttribute("hidden", ""); });
    S.shadow = { buf, clones, hidden, pt: buf.dataset.pt, setPt: null };
    return true;
  }

  function emptyRowMark(content) {
    const hasText = (content.textContent || "").length > 0;
    const brs = content.querySelectorAll(":scope > br.empty-row");
    if (hasText) brs.forEach((b) => b.remove());
    else if (!brs.length) {
      const br = document.createElement("br");
      br.className = "empty-row";
      content.appendChild(br);
    }
  }

  function rowOf(node) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    return el ? el.closest(".line") : null;
  }

  function paintInsert(buf, at, text) {
    const pos = S.h.domPos(buf, at);
    if (!pos) return false;
    const row = rowOf(pos.node);
    if (!row) return false;
    if (pos.node.nodeType === 3) pos.node.insertData(pos.offset, text);
    else {
      const kids = pos.node.childNodes;
      let ref = kids[pos.offset] || null;
      const prev = kids[pos.offset - 1];
      if (prev && prev.nodeName === "BR") ref = prev;
      pos.node.insertBefore(document.createTextNode(text), ref);
    }
    emptyRowMark(contentOf(row));
    shiftRows(buf, row, bytes(text), 0);
    return true;
  }

  function paintNewline(buf, at) {
    const pos = S.h.domPos(buf, at);
    if (!pos) return false;
    const row = rowOf(pos.node);
    if (!row || row.matches(".semantic-direct")) return false;
    const content = contentOf(row);
    const range = document.createRange();
    range.setStart(pos.node, pos.offset);
    range.setEnd(content, content.childNodes.length);
    const tail = range.extractContents();
    stripIds(tail);
    const next = row.cloneNode(false);
    next.classList.remove("hl-line");
    const num = row.querySelector(":scope > .linenum");
    if (num) next.appendChild(num.cloneNode(true));
    const body = content.cloneNode(false);
    body.appendChild(tail);
    next.appendChild(body);
    row.after(next);
    emptyRowMark(content);
    emptyRowMark(body);
    next.dataset.s = String(at + 1);
    renumber(next, 1);
    shiftRows(buf, next, 1, 1);
    return true;
  }

  function paintDelete(buf, at, n, newline) {
    if (!newline) {
      const a = S.h.domPos(buf, at - n), b = S.h.domPos(buf, at);
      if (!a || !b) return false;
      const row = rowOf(b.node);
      if (!row || rowOf(a.node) !== row) return false;
      const range = document.createRange();
      range.setStart(a.node, a.offset);
      range.setEnd(b.node, b.offset);
      range.deleteContents();
      emptyRowMark(contentOf(row));
      shiftRows(buf, row, -n, 0);
      return true;
    }
    // Backspace at the start of a row joins it to the row above
    const row = rowAt(buf, at);
    const prev = row && row.previousElementSibling;
    if (!row || !prev || !prev.matches(".line") || row.matches(".semantic-direct")) return false;
    const into = contentOf(prev), from = contentOf(row);
    into.querySelectorAll(":scope > br.empty-row").forEach((b) => b.remove());
    while (from.firstChild) into.appendChild(from.firstChild);
    emptyRowMark(into);
    shiftRows(buf, row, -1, -1);
    row.remove();
    return true;
  }

  // apply ops K.. to rows that show the text after the first K ops
  function paintFrom(buf, V, k) {
    const st = stateAfter(V, k);
    const r = st.r;
    let pt = st.pt, ok = true;
    for (let i = k; i < V.pending.length && ok; i++) {
      const o = V.pending[i];
      if (o.kind === "ins") {
        ok = o.text === "\n" ? paintNewline(buf, pt) : paintInsert(buf, pt, o.text);
        r.insert(pt, o.text);
        pt += bytes(o.text);
      } else if (o.kind === "del") {
        const n = r.prevCharLen(pt);
        if (n) {
          const nl = r.slice(pt - n, pt) === "\n";
          ok = paintDelete(buf, pt, n, nl);
          r.remove(pt - n, pt);
          pt -= n;
        }
      }
    }
    r.free();
    return ok ? pt : null;
  }

  // the view for the rows BUF shows, or null when the client has no rope
  // for their version
  function viewOf(W, buf) {
    const h = W.hist.get(parseInt(buf.dataset.v, 10));
    if (!h) return null;
    return { server: h.r, pt: h.pt, ack: h.ack, pending: W.ops.filter((o) => o.seq > h.ack) };
  }

  // the rows show version V: older ropes and the ops it holds can go
  function prune(W, v, ack) {
    for (const [k, h] of W.hist) if (k < v) { h.r.free(); W.hist.delete(k); }
    W.ops = W.ops.filter((o) => o.seq > ack);
  }

  // show the daemon's rows, then copies with the pending ops painted;
  // false when the rows are not the text the rope holds
  function repaint(W) {
    const buf = S.h.bufOf(W.win);
    const had = !!S.shadow;
    restore();
    if (!buf || buf.hasAttribute("phx-update")) return false;
    const V = viewOf(W, buf);
    if (!V) return false;
    prune(W, parseInt(buf.dataset.v, 10), V.ack);
    if (!V.pending.some((o) => o.kind !== "none")) {
      if (had) S.h.place();
      return true;
    }
    const lo = lowest(V);
    const ok = shows(buf, V, 0, lo) && shadow(buf, V.server.lineToByte(V.server.byteToLine(lo)));
    const pt = ok ? paintFrom(buf, V, 0) : null;
    if (pt == null) {
      restore();
      S.stats.drift++;
      S.h.place();
      return false;
    }
    buf.dataset.pt = String(pt);
    S.shadow.setPt = buf.dataset.pt;
    S.h.place();
    return true;
  }

  // ---- the daemon's side ----

  function event(p) {
    if (!S.Rope) { S.queue.push(p); return; }
    let W = S.win && S.win.win === p.win ? S.win : null;
    let rope;
    if (p.text != null) {
      restore();
      if (S.win) S.win.hist.forEach((h) => h.r.free());
      W = S.win = { win: p.win, hist: new Map(), ops: W ? W.ops : [],
        skip: W ? W.skip : new Set() };
      rope = S.Rope.from(p.text);
    } else {
      const base = W && W.hist.get(W.v);
      if (!base) return;
      rope = base.r.clone();
      if (p.at != null) {
        rope.remove(p.at, p.at + p.del);
        if (p.ins) rope.insert(p.at, p.ins);
      }
    }
    const old = W.hist.get(p.v);
    if (old) old.r.free();
    W.hist.set(p.v, { r: rope, pt: p.pt, ack: p.ack });
    W.v = p.v;
    if (p.skip) W.skip = new Set(p.skip);
    const now = performance.now();
    for (const o of W.ops) {
      if (o.seq <= p.ack && !o.confirmed) {
        o.confirmed = true;
        if (o.kind !== "none") S.stats.confirm.push(now - o.t);
      }
    }
    if (S.stats.confirm.length > 500) S.stats.confirm.splice(0, 250);
    repaint(W);
  }

  // after every patch: the patch put the daemon's rows back
  function afterPatch() {
    if (S.win && S.win.ops.length) repaint(S.win);
  }

  // ---- the client's side ----

  // a key or an input the client does not predict: it blocks prediction
  // until the rows show its effect
  function barrier() {
    const seq = ++S.seq;
    if (S.win) S.win.ops.push({ seq, kind: "none", t: performance.now() });
    return seq;
  }

  // an intent from beforeinput. Returns the sequence number to send.
  function intent(buf, e, win) {
    const t = performance.now();
    const W = S.win && S.win.win === win ? S.win : null;
    const seq = ++S.seq;
    const op = W && predictable(buf, e, W);
    if (!op) {
      if (W) { W.ops.push({ seq, kind: "none", t }); S.stats.skipped++; }
      return seq;
    }
    W.ops.push({ seq, t, ...op });
    if (!repaint(W)) {
      // the op stays as a barrier: the rows do not show it
      const o = W.ops.find((x) => x.seq === seq);
      if (o) { o.kind = "none"; delete o.text; }
      return seq;
    }
    S.stats.predicted++;
    S.stats.paint.push(performance.now() - t);
    if (S.stats.paint.length > 500) S.stats.paint.splice(0, 250);
    return seq;
  }

  function predictable(buf, e, W) {
    if (e.isComposing || buf.hasAttribute("phx-update")) return null;
    const V = viewOf(W, buf);
    if (!V || V.pending.some((o) => o.kind === "none")) return null;
    const sel = window.getSelection();
    if (!sel || !sel.isCollapsed || !buf.contains(sel.focusNode)) return null;
    const mark = buf.dataset.mark;
    if (mark !== undefined && mark !== "" && mark !== buf.dataset.pt) return null;
    // the caret must stand where the ops leave point: a native arrow
    // moved it, and its report is not an op
    const st = stateAfter(V, V.pending.length);
    const expect = st.pt;
    st.r.free();
    if (S.h.domByte(sel.focusNode, sel.focusOffset) !== expect) return null;
    const skip = (key) => W.skip.has(key);
    switch (e.inputType) {
      case "insertText":
        if (!e.data || e.data.includes("\n") || [...e.data].some(skip)) return null;
        return { kind: "ins", text: e.data };
      case "insertParagraph":
      case "insertLineBreak":
        return skip("RET") ? null : { kind: "ins", text: "\n" };
      case "deleteContentBackward":
        return skip("DEL") ? null : { kind: "del" };
      default:
        return null;
    }
  }

  function median(a) {
    if (!a.length) return null;
    const s = [...a].sort((x, y) => x - y);
    return Math.round(s[Math.floor(s.length / 2)] * 10) / 10;
  }
  function p95(a) {
    if (!a.length) return null;
    const s = [...a].sort((x, y) => x - y);
    return Math.round(s[Math.floor(s.length * 0.95)] * 10) / 10;
  }

  // composPredict.stats() in the console: paint and confirm times in ms
  function stats() {
    const s = S.stats;
    return {
      predicted: s.predicted, skipped: s.skipped, drift: s.drift,
      paint_median: median(s.paint), paint_p95: p95(s.paint),
      confirm_median: median(s.confirm), confirm_p95: p95(s.confirm),
      window: S.win ? S.win.win : null, pending: S.win ? S.win.ops.length : 0
    };
  }

  window.composPredict = { init, event, intent, barrier, afterPatch, stats };
})();
