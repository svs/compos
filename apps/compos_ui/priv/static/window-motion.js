// The motion of the panes. A render that changes the window tree (a
// split, a delete, a swap, a resize, a buffer that takes a window) moves
// each pane from where it was to where it is, so the user sees what went
// where. The daemon marks c-windows with data-panes: the shape of the
// tree and the buffer of each window. Only a change in that string costs
// anything here; any other render passes two attribute reads.
//
// A pane that stays moves and resizes from its old box. A new pane slides
// into its place out of the pane it split from. A pane that goes leaves a
// copy that slides away from the pane that takes its place. A window that
// shows a new buffer slides the new text in from the pane that showed it
// before, and the old text out the other way.
//
// A strip scroll and a group switch move the whole desk instead
// (strip-slide.js): a render that carries a new data-slide is theirs.
(() => {
  const EASE = 'cubic-bezier(.2,.7,.2,1)';
  // how far a pane or a buffer travels in or out, as a part of its size
  const TRAVEL = 0.35;
  let snap = null;
  let ghosts = [];
  let anims = [];

  // the duration the setting asks for (--chrome-motion); 0 is off
  function duration() {
    if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return 0;
    const v = getComputedStyle(document.documentElement).getPropertyValue('--chrome-motion').trim();
    const n = parseFloat(v);
    if (!(n > 0)) return 0;
    return v.endsWith('ms') ? n : n * 1000;
  }

  // the tiled panes; a preview card or a popup floats and does not move
  const panes = (root) =>
    [...root.querySelectorAll('c-window.window')].filter(
      (w) =>
        !w.closest('.strip-ghost, .motion-ghost') &&
        !w.classList.contains('listing-preview') &&
        ![...w.classList].some((c) => c.startsWith('popup'))
    );

  // window id -> buffer, from data-panes
  function parse(sig) {
    try {
      return new Map(JSON.parse(sig).panes);
    } catch (_) {
      return null;
    }
  }

  function finish() {
    anims.forEach((a) => a.cancel());
    ghosts.forEach((g) => g.remove());
    anims = [];
    ghosts = [];
  }

  function track(anim, ghost) {
    anims.push(anim);
    anim.onfinish = () => {
      anims = anims.filter((a) => a !== anim);
      if (ghost) {
        ghosts = ghosts.filter((g) => g !== ghost);
        ghost.remove();
      }
    };
  }

  // the scroll offsets inside a pane, by element index, so the copy
  // shows the buffer at the place the user left it
  function scrolls(el) {
    const out = [];
    el.querySelectorAll('*').forEach((e, i) => {
      if (e.scrollTop || e.scrollLeft) out.push([i, e.scrollTop, e.scrollLeft]);
    });
    return out;
  }

  function restore(el, offsets) {
    const all = el.querySelectorAll('*');
    offsets.forEach(([i, top, left]) => {
      const e = all[i];
      if (e) { e.scrollTop = top; e.scrollLeft = left; }
    });
  }

  function copy(w) {
    const g = w.cloneNode(true);
    ['id', 'phx-hook', 'data-win-id', 'data-buffer', 'buffer'].forEach((a) => g.removeAttribute(a));
    g.querySelectorAll('[id]').forEach((e) => e.removeAttribute('id'));
    g.querySelectorAll('[phx-hook]').forEach((e) => e.removeAttribute('phx-hook'));
    g.querySelectorAll('[contenteditable]').forEach((e) => e.removeAttribute('contenteditable'));
    return g;
  }

  // The frame can be zoomed (c-frame's zoom): the page measures in screen
  // pixels, but a transform or a left inside it counts in the frame's own.
  // Every box here is in the frame's pixels.
  const zoomOf = (el) => (el.offsetWidth ? el.getBoundingClientRect().width / el.offsetWidth : 1) || 1;
  function unz(r, k) {
    return {
      left: r.left / k, top: r.top / k, right: r.right / k, bottom: r.bottom / k,
      width: r.width / k, height: r.height / k
    };
  }

  const center = (r) => [r.left + r.width / 2, r.top + r.height / 2];
  const inside = (r, [x, y]) => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;

  // the unit step from box A to box B on the axis they differ most on
  function toward(a, b) {
    const [ax, ay] = center(a);
    const [bx, by] = center(b);
    const dx = bx - ax;
    const dy = by - ay;
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return null;
    return Math.abs(dx) >= Math.abs(dy) ? [Math.sign(dx), 0] : [0, Math.sign(dy)];
  }

  // a translation that keeps the visible area on the element's own box
  const clip = (dx, dy) => `inset(${-dy}px ${dx}px ${dy}px ${-dx}px)`;

  // W's content comes in along STEP, inside its own box; with no step it
  // rises from below. A FULL one travels the whole box and does not fade:
  // it is the next sheet of the stack
  function enter(w, rect, step, ms, full) {
    const [sx, sy] = step || [0, -1];
    const t = full ? 1 : TRAVEL;
    const dx = -sx * t * rect.width;
    const dy = -sy * t * rect.height;
    track(w.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, clipPath: clip(dx, dy), opacity: full ? 1 : 0 },
        { transform: 'translate(0px, 0px)', clipPath: clip(0, 0), opacity: 1 }
      ],
      { duration: ms, easing: EASE }
    ));
  }

  // W stays, and moves and resizes from box A to box B
  function reshape(w, a, b, ms) {
    const dx = a.left - b.left;
    const dy = a.top - b.top;
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1 &&
        Math.abs(a.width - b.width) < 1 && Math.abs(a.height - b.height) < 1) return false;
    const sx = a.width / b.width;
    const sy = a.height / b.height;
    track(w.animate(
      [
        { transformOrigin: '0 0', transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` },
        { transformOrigin: '0 0', transform: 'none' }
      ],
      { duration: ms, easing: EASE }
    ));
    return true;
  }

  // a buffer that a neighbour showed crosses to W as one sheet of paper:
  // it keeps its size and its ink, lifts off the old pane, slides over
  // the divider and lands on the buffer W showed before
  // a slide that starts and stops gently, as a hand moves a sheet
  const SLIDE = 'cubic-bezier(.45,0,.2,1)';
  // W comes from box A to its box B by translation only, SLIDE eased; an
  // ON-TOP one rides over the panes it crosses
  function slide(w, a, b, ms, onTop) {
    const dx = a.left - b.left;
    const dy = a.top - b.top;
    const z = onTop ? 3 : 0;
    track(w.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, zIndex: z },
        { transform: 'translate(0px, 0px)', zIndex: z }
      ],
      { duration: ms, easing: SLIDE }
    ));
  }

  function paper(w, a, b, ms) {
    const dx = a.left - b.left;
    const dy = a.top - b.top;
    const total = ms * 1.3;
    track(w.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, zIndex: 3 },
        { transform: 'translate(0px, 0px)', zIndex: 3 }
      ],
      { duration: total, easing: SLIDE }
    ));
    track(w.animate(
      [
        { boxShadow: '0 2px 6px rgba(0,0,0,.2)' },
        { boxShadow: '0 12px 30px rgba(0,0,0,.32)', offset: 0.5 },
        { boxShadow: '0 0 0 rgba(0,0,0,0)' }
      ],
      { duration: total, easing: 'linear' }
    ));
  }

  // the moving window rides over the panes it crosses, lifted off the
  // desk: it shrinks a little toward its top left while it travels, so
  // the pile under it has room to show below it inside the frame
  const CARRY = 0.88;
  const carried = [
    { scale: '1', transformOrigin: '0 0' },
    { scale: `${CARRY}`, transformOrigin: '0 0', offset: 0.18 },
    { scale: `${CARRY}`, transformOrigin: '0 0', offset: 0.72 },
    { scale: '1', transformOrigin: '0 0' }
  ];
  function lift(w, total) {
    track(w.animate(
      [{ zIndex: 3 }, { zIndex: 3 }],
      { duration: total, easing: 'linear' }
    ));
    track(w.animate(carried, { duration: total, easing: 'ease-in-out' }));
    track(w.animate(
      [
        { boxShadow: '0 0 0 rgba(0,0,0,0)' },
        { boxShadow: '0 14px 34px rgba(0,0,0,.35)', offset: 0.2 },
        { boxShadow: '0 14px 34px rgba(0,0,0,.35)', offset: 0.7 },
        { boxShadow: '0 0 0 rgba(0,0,0,0)' }
      ],
      { duration: total, easing: 'ease-out' }
    ));
  }

  // The buffers under a moving window, as the editor sent them with the
  // move: one sheet of its paper for each, nudged out behind its travel
  // and below it, its name in the strip that shows under the sheet above,
  // so the window reads as the top of its pile. Each sheet starts a
  // little later than the one above it, so the pile sweeps across with
  // its tail lagging, then folds back under the window where it lands.
  const BAND = 20;
  // as many sheets as the room the carry frees under the window shows
  const PILE = 4;
  function tail(s, p, from) {
    const box = unz(s.root.getBoundingClientRect(), s.k);
    const r = p.rect;
    const dx = from.left - r.left;
    const dy = from.top - r.top;
    const [sx] = toward(from, r) || [0, 0];
    const c = getComputedStyle(p.w);
    const head = p.w.querySelector('.dash-persistent');
    const title = head && head.querySelector('.dseg-chat-title .dseg-v');
    const look = lookOf(head, title);
    const indent = title ? Math.max(10, unz(title.getBoundingClientRect(), s.k).left - r.left) : 14;
    const names = s.move && s.move.rows[0] === s.after.get(p.id) ? s.move.rows.slice(1, 1 + PILE) : [];
    const ms = s.ms * 1.25;
    const lag = s.ms * 0.12;
    const total = ms + names.length * lag;
    lift(p.w, total);
    if (!names.length) return;
    for (let k = names.length; k >= 1; k--) {
      const sheet = document.createElement('div');
      sheet.className = 'motion-ghost motion-tail';
      sheet.setAttribute('aria-hidden', 'true');
      Object.assign(sheet.style, {
        position: 'absolute', pointerEvents: 'none', zIndex: '2',
        left: `${r.left - box.left - s.root.clientLeft}px`,
        top: `${r.top - box.top - s.root.clientTop}px`,
        width: `${r.width}px`, height: `${r.height}px`,
        background: c.backgroundColor, border: `1px solid ${c.borderTopColor}`,
        borderRadius: c.borderRadius, boxSizing: 'border-box',
        boxShadow: '0 8px 22px rgba(0, 0, 0, .28)', transformOrigin: '0 0'
      });
      const label = document.createElement('div');
      label.className = 'motion-tail-name';
      const name = names[k - 1];
      label.textContent = name.startsWith('/') ? name.split('/').filter(Boolean).pop() : name;
      Object.assign(label.style, { height: `${BAND}px`, paddingLeft: `${indent}px` },
        look ? { ...look.name, color: look.ink } : {});
      sheet.appendChild(label);
      s.root.appendChild(sheet);
      sheet._motion = { root: s.root, ghost: sheet, offsets: [] };
      ghosts.push(sheet);
      const nx = -sx * 10 * k;
      const ny = BAND * k;
      track(sheet.animate(
        [
          { transform: `translate(${dx}px, ${dy}px)`, opacity: 0 },
          { transform: `translate(${dx + nx}px, ${dy + ny}px)`, opacity: 1, offset: 0.12 },
          { transform: `translate(${nx}px, ${ny}px)`, opacity: 1, offset: 0.78 },
          { transform: 'translate(0px, 0px)', opacity: 0 }
        ],
        { duration: ms, delay: k * lag, easing: EASE, fill: 'backwards' }
      ), sheet);
      // it shrinks with the window, about the same corner, so it stays
      // under it
      track(sheet.animate(carried, { duration: total, easing: 'ease-in-out' }));
    }
  }

  // the old content of a pane, at its old box, goes out along STEP; a
  // STILL one stays under the paper that lands on it
  function leave(s, o, step, still, full, hold) {
    const box = unz(s.root.getBoundingClientRect(), s.k);
    const r = o.rect;
    const frame = document.createElement('div');
    frame.className = 'motion-ghost';
    frame.setAttribute('aria-hidden', 'true');
    frame.inert = true;
    Object.assign(frame.style, {
      position: 'absolute', overflow: 'hidden', pointerEvents: 'none', zIndex: still ? '1' : '2',
      left: `${r.left - box.left - s.root.clientLeft}px`,
      top: `${r.top - box.top - s.root.clientTop}px`,
      width: `${r.width}px`, height: `${r.height}px`
    });
    Object.assign(o.ghost.style, { position: 'absolute', inset: '0' });
    frame.appendChild(o.ghost);
    s.root.appendChild(frame);
    restore(o.ghost, o.offsets);
    frame._motion = { root: s.root, ghost: o.ghost, offsets: o.offsets };
    ghosts.push(frame);
    const [sx, sy] = step || [0, -1];
    const t = full ? 1 : TRAVEL;
    const go = still ? [0, 0, 1] : [sx * t * r.width, sy * t * r.height, full ? 1 : 0];
    track(o.ghost.animate(
      [
        { transform: 'translate(0px, 0px)', opacity: 1 },
        { transform: `translate(${go[0]}px, ${go[1]}px)`, opacity: go[2] }
      ],
      { duration: hold || s.ms, easing: EASE, fill: 'forwards' }
    ), frame);
  }

  function play(s) {
    const now = panes(s.root).map((w) => ({ w, id: w.dataset.winId, rect: unz(w.getBoundingClientRect(), s.k) }));
    const ids = new Set(now.map((p) => p.id));
    // where each buffer stood before the render, and where it stands now
    const wasAt = new Map();
    s.old.forEach((o) => { if (o.buffer) wasAt.set(o.buffer, o.rect); });
    const isAt = new Map();
    now.forEach((p) => { const b = s.after.get(p.id); if (b) isAt.set(b, p.rect); });

    now.forEach((p) => {
      const o = s.old.get(p.id);
      if (!o) {
        // a new pane comes out of the pane whose place it took
        const c = center(p.rect);
        const parent = now.find((q) => q !== p && s.old.has(q.id) && inside(s.old.get(q.id).rect, c));
        enter(p.w, p.rect, parent && toward(parent.rect, p.rect), s.ms);
        return;
      }
      const b = s.after.get(p.id);
      const src = o.ghost && b && wasAt.get(b);
      // a window moved to the next pane: the panes keep their places and
      // trade what they show. The one that shows the moved window now
      // carries it over, lifted, with its stack trailing; the window it
      // traded with slides in underneath, uncovered as it lifts away
      if (s.move && src && toward(src, p.rect)) {
        const carried = b === s.move.rows[0];
        slide(p.w, src, p.rect, carried ? s.ms * 1.1 : s.ms * 1.25, carried);
        if (carried) {
          tail(s, p, src);
          leave(s, o, null, true, false, s.ms * 1.1);
        }
        return;
      }
      // a buffer that a neighbour showed crosses to this pane as one
      // sheet, even when the pane grows into a pane that closed
      if (src && toward(src, p.rect) && !(s.walk && String(s.walk.win) === p.id)) {
        paper(p.w, src, p.rect, s.ms);
        leave(s, o, null, true, false, s.ms * 1.3);
        return;
      }
      const moved = reshape(p.w, o.rect, p.rect, s.ms);
      // the selected window went to another pane with its stack: it
      // sweeps there on top, and the stack trails behind it
      if (moved && !o.ghost && p.w.classList.contains('active')) tail(s, p, o.rect);
      if (!o.ghost) return;
      // a new buffer: it comes from the pane that showed it, or the old
      // one goes to the pane that shows it now
      // a walk of this window's stack: the two sheets pass each other,
      // down the stack the next one rises from below
      if (!moved && s.walk && String(s.walk.win) === p.id) {
        const step = s.walk.pane === 'up' ? [0, 1] : [0, -1];
        enter(p.w, p.rect, step, s.ms, true);
        leave(s, o, step, false, true);
        return;
      }
      const dst = o.buffer && isAt.get(o.buffer);
      // a buffer that went to a neighbour leaves on the paper that
      // carries it; what it uncovers lay under it, and does not move
      if (!moved && dst && toward(p.rect, dst)) return;
      const step = dst && toward(p.rect, dst);
      if (!moved) enter(p.w, p.rect, step, s.ms);
      leave(s, o, step);
    });

    // a pane that went slides away from the pane that took its place
    s.old.forEach((o, id) => {
      if (ids.has(id) || !o.ghost) return;
      // its buffer went on in another pane, on the paper that carries it
      if (o.buffer && isAt.has(o.buffer)) return;
      const heir = now.find((q) => inside(q.rect, center(o.rect)));
      leave(s, o, heir && toward(heir.rect, o.rect));
    });
  }

  // LiveView calls this for each element it updates, before the update.
  // It must stay cheap: every render passes here.
  function before(from, to) {
    if (from.tagName !== 'C-WINDOWS') return;
    const token = to.getAttribute('data-slide');
    const fresh = token && token !== from.getAttribute('data-slide');
    // a JSON token is a walk of a stack ('pane') or a window that moves
    // with its stack ('move')
    const sent = fresh && token.startsWith('{') ? parseWalk(token) : null;
    const walk = sent && sent.pane ? sent : null;
    const move = sent && sent.move ? sent : null;
    if (walk) pending = walk;
    const was = from.getAttribute('data-panes');
    const next = to.getAttribute('data-panes');
    if (!was || !next || was === next) return;
    if (fresh && !walk && !move) return;
    if (from.querySelector('.listing-preview')) return;
    const ms = duration();
    const prev = parse(was);
    const after = parse(next);
    if (!ms || !prev || !after) { finish(); return; }
    // measure before the old motion stops: a pane in motion starts from
    // where the eye sees it
    const k = zoomOf(from);
    const old = new Map();
    panes(from).forEach((w) => {
      const id = w.dataset.winId;
      const buffer = prev.get(id);
      const goes = !after.has(id) || after.get(id) !== buffer;
      old.set(id, {
        rect: unz(w.getBoundingClientRect(), k),
        buffer,
        ghost: goes ? copy(w) : null,
        offsets: goes ? scrolls(w) : null
      });
    });
    finish();
    snap = { root: from, old, after, ms, walk, move, k };
  }

  // after each patch; a render during the motion removes the copies,
  // because the server does not know them, so they go back
  function after() {
    if (pending) {
      const w = pending;
      pending = null;
      drawRail(w);
    }
    if (snap) {
      const s = snap;
      snap = null;
      if (s.root.isConnected) play(s);
      return;
    }
    ghosts.forEach((g) => {
      const m = g._motion;
      if (g.isConnected || !m.root.isConnected) return;
      m.root.appendChild(g);
      restore(m.ghost, m.offsets);
    });
  }

  // A walk of a window's stack: the token is the walk as JSON, then the
  // daemon's count. The stack shows as a rail of sheets on the pane's
  // edge while Cmd is down; the release ends the walk, here and in the
  // editor (window-walk-end, through windowMotion.onEnd). Shift walks the same way.
  let pending = null;
  let rail = null;
  let meta = false;
  let lapse = null;

  function parseWalk(token) {
    try {
      return JSON.parse(token.slice(0, token.lastIndexOf(':')));
    } catch (_) {
      return null;
    }
  }

  const SHOWN = 9;
  const RAIL_WIDTH = 260;

  // The rail hangs from the buffer title in the pane's header line:
  // the stack drops down out of the name it replaces, every sheet one
  // width, its name set as the title is, so the names line up like the
  // edges of a pile of paper. A sheet keeps its element between steps,
  // so it glides to its new place.
  function drawRail(walk) {
    const pane = document.querySelector(`c-window.window[data-win-id="${walk.win}"]`);
    if (!pane) return;
    // the rail hangs on the body, outside the zoomed frame: it takes the
    // frame's zoom, so its type is the title's size, and counts in its pixels
    const k = zoomOf(pane);
    const p = unz(pane.getBoundingClientRect(), k);
    const head = pane.querySelector('.dash-persistent');
    const title = head && head.querySelector('.dseg-chat-title .dseg-v');
    const look = lookOf(head, title);
    const h = head ? unz(head.getBoundingClientRect(), k) : { bottom: p.top };
    const t = title ? unz(title.getBoundingClientRect(), k) : { left: p.left + 12 };
    const seg = title ? unz(title.closest('.dseg-chat-title').getBoundingClientRect(), k) : t;
    if (!rail) {
      rail = document.createElement('div');
      rail.className = 'walk-rail';
      rail.setAttribute('aria-hidden', 'true');
      document.body.appendChild(rail);
    }
    rail.dataset.win = walk.win;
    rail.style.zoom = k;
    // the dropdown is as wide as its longest name, so every name shows
    // whole; only a pane too narrow for it cuts one short
    const width = Math.max(RAIL_WIDTH, (seg.width || 0) + 28);
    const room = p.width - 16;
    const left = Math.max(p.left + 8, Math.min(seg.left - 14, p.right - 8 - Math.min(width, room)));
    Object.assign(rail.style, {
      left: `${left}px`, minWidth: `${Math.min(width, room)}px`, maxWidth: `${p.right - 8 - left}px`,
      top: `${h.bottom - 1}px`, maxHeight: `${p.bottom - h.bottom - 8}px`
    });
    rail.style.setProperty('--walk-indent', `${Math.max(10, t.left - left)}px`);
    if (look) Object.assign(rail.style, { background: look.paper, borderColor: look.edge });
    const half = Math.floor(SHOWN / 2);
    const from = Math.max(0, Math.min(walk.at - half, walk.rows.length - SHOWN));
    const kept = new Map([...rail.children].map((s) => [s.dataset.name, s]));
    rail.replaceChildren(...walk.rows.slice(from, from + SHOWN).map((name, k) => {
      const i = from + k;
      const sheet = kept.get(name) || document.createElement('div');
      if (!sheet.dataset.name) {
        sheet.dataset.name = name;
        // the label is the name the title painter draws; the name stays the key
        const text = (walk.labels && walk.labels[i]) || name;
        const file = name.startsWith('/');
        const parts = file ? text.split('/').filter(Boolean) : [];
        const stack = document.createElement('span');
        stack.className = 'walk-title';
        const label = document.createElement('span');
        label.className = 'walk-name';
        label.textContent = parts.pop() || text;
        stack.append(label);
        if (file && parts.length) {
          const dir = document.createElement('span');
          dir.className = 'walk-path';
          const lead = text.startsWith('/') ? '/' : '';
          dir.textContent = (lead + parts.join('/')).replace(/^\/(Users|home)\/[^/]+/, '~');
          stack.append(dir);
        }
        const count = document.createElement('span');
        count.className = 'walk-count';
        sheet.append(stack, count);
      }
      sheet.className = i === walk.at ? 'walk-sheet current' : 'walk-sheet';
      dress(sheet, look, i === walk.at);
      sheet.style.setProperty('--d', Math.abs(i - walk.at));
      sheet.lastChild.textContent = i === walk.at ? `${i + 1}/${walk.rows.length}` : '';
      return sheet;
    }));
    // a walk with no Cmd held (M-x) ends a moment after its step
    clearTimeout(lapse);
    if (!meta) lapse = setTimeout(end, 1200);
  }

  // The sheets take the title's look from the page, not from a copy in
  // the CSS: the theme sets the header line, so only the drawn title
  // knows its font, its ink and its paper.
  const FONT = ['fontFamily', 'fontWeight', 'fontSize', 'lineHeight', 'letterSpacing', 'textTransform'];

  function fontOf(el) {
    if (!el) return null;
    const c = getComputedStyle(el);
    const f = {};
    FONT.forEach((k) => { f[k] = c[k]; });
    f.color = c.color;
    return f;
  }

  function lookOf(head, title) {
    if (!head || !title) return null;
    const h = getComputedStyle(head);
    const name = fontOf(title.querySelector('.dseg-strong') || title);
    const other = document.querySelector('.window.inactive .dash-persistent .dseg-chat-title .dseg-v');
    return {
      name, path: fontOf(head.querySelector('.dseg-chat-title .dseg-path')),
      ink: other ? fontOf(other.querySelector('.dseg-strong') || other).color : h.color,
      paper: h.backgroundColor, edge: h.borderBottomColor
    };
  }

  function dress(sheet, look, current) {
    if (!look) return;
    const label = sheet.querySelector('.walk-name');
    Object.assign(label.style, look.name, { color: current ? look.name.color : look.ink });
    const dir = sheet.querySelector('.walk-path');
    if (dir && look.path) Object.assign(dir.style, look.path);
  }

  function end() {
    clearTimeout(lapse);
    if (!rail) return;
    const win = rail.dataset.win;
    rail.remove();
    rail = null;
    if (windowMotion.onEnd) windowMotion.onEnd(win);
  }

  // the walk lasts while the key that steps it is held: Cmd for a walk of
  // one mode, Shift for the whole stack, Alt for a chat and its child chats
  window.addEventListener('keydown', (e) => { meta = e.metaKey || e.shiftKey || e.altKey; }, true);
  window.addEventListener('keyup', (e) => {
    if ((e.key === 'Meta' || e.key === 'Shift' || e.key === 'Alt') && !e.metaKey && !e.shiftKey && !e.altKey) {
      meta = false; end();
    }
  }, true);
  window.addEventListener('blur', () => { meta = false; end(); });

  const windowMotion = { before, after, onEnd: null };
  window.windowMotion = windowMotion;
})();
