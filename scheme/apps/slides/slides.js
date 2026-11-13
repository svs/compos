// slides.js --- the presenter page of slides.scm.
// The deck arrives as JSON in #deck: its Markdown source, the source line
// to open at, and whether this load is a live redraw after an edit.
'use strict';
(function () {
// One boot draws one deck. A live edit tears it down and boots the new
// deck in the same document, so the page never reloads and never blanks.
function boot(DATA) {
const life = new AbortController();
const W = 1280, H = 720;
const ANIMS = ['fade', 'up', 'down', 'left', 'right', 'zoom', 'pop', 'spin', 'blur', 'flip', 'drop', 'type'];
const TRANSITIONS = ['none', 'fade', 'slide', 'up', 'zoom', 'flip', 'cube', 'blur', 'iris', 'wipe', 'morph'];

// ---- Markdown ------------------------------------------------------------
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const q = s => esc(String(s)).replace(/\x22/g, '&quot;').replace(/'/g, '&#39;');

// ![alt](url =WxH): W or H alone is fine. A bare number is px; full is 100%.
// A sized image drops the default height cap; with both sides it crops to fit.
const dim = v => v === 'full' ? '100%' : /^[\d.]+$/.test(v) ? v + 'px' : v;
function imgSize(w, h) {
  if (!w && !h) return '';
  let css = 'max-height:none;';
  if (w) css += `width:${dim(w)};` + (h ? '' : 'height:auto;');
  if (h) css += `height:${dim(h)};` + (w ? 'object-fit:cover;' : 'width:auto;max-width:100%;');
  return ` style='${q(css)}'`;
}

function inline(s) {
  const stash = [];
  const keep = h => '\u0001' + (stash.push(h) - 1) + '\u0002';
  s = s.replace(/`([^`]+)`/g, (_, c) => keep('<code>' + esc(c) + '</code>'));
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+=([\d.]+[a-z%]*|full)?(?:x([\d.]+[a-z%]*|full))?)?\)/g,
    (_, a, u, w, h) => keep(`<img src='${q(u)}' alt='${q(a)}'${imgSize(w, h)}>`));
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, t, u) => keep(`<a href='${q(u)}' target='_blank'>`) + t + keep('</a>'));
  s = s.replace(/<\/?[A-Za-z][^>]*>/g, t => keep(t));
  s = esc(s)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/__([^_]+)__/g, '<strong>$1</strong>')
    .replace(/\*([^*\s][^*]*)\*/g, '<em>$1</em>')
    .replace(/(^|[^A-Za-z0-9])_([^_\s][^_]*)_(?![A-Za-z0-9])/g, '$1<em>$2</em>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>')
    .replace(/==([^=]+)==/g, '<mark>$1</mark>')
    .replace(/( {2}|\\)$/, '<br>');
  return s.replace(/\u0001(\d+)\u0002/g, (_, k) => stash[+k]);
}

// A block may end in {tokens}: step waits for a key press, an animation
// name animates it (on arrival without step), .name adds a class, #name
// gives it an id, and an id is what morph matches across slides.
function attrs(text) {
  const a = { cls: [], id: '', anim: '', text };
  const m = text.match(/[ \t]*\{([^{}`]*)\}[ \t]*$/);
  if (!m) return a;
  const toks = m[1].trim().split(/\s+/).filter(Boolean);
  const known = t => t === 'step' || ANIMS.includes(t) || t[0] === '.' || t[0] === '#';
  if (!toks.length || !toks.every(known)) return a;
  a.text = text.slice(0, m.index);
  for (const t of toks) {
    if (t === 'step') a.cls.push('step');
    else if (ANIMS.includes(t)) a.anim = t;
    else if (t[0] === '.') a.cls.push(t.slice(1));
    else a.id = t.slice(1);
  }
  return a;
}

function open(tag, a) {
  const cls = a.cls.slice();
  if (a.anim && !cls.includes('step')) cls.push('enter');
  let h = '<' + tag;
  if (cls.length) h += ` class='${q(cls.join(' '))}'`;
  if (a.id) h += ` id='${q(a.id)}'`;
  if (a.anim) h += ` data-anim='${a.anim}'`;
  return h + '>';
}

const ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/;
const blank = l => !l.trim();
const indentOf = l => l.match(/^\s*/)[0].replace(/\t/g, '    ').length;
const startsBlock = l => /^(#{1,6}\s|```|~~~|>|\s*<|\s*\|)/.test(l) || ITEM.test(l);

function md(src) {
  const lines = src.split('\n');
  const out = [];
  let i = 0, m;
  while (i < lines.length) {
    const l = lines[i];
    if (blank(l)) { i++; continue; }
    if ((m = l.match(/^\s*(```|~~~)\s*([^\s{]*)\s*(\{[^}]*\})?/))) {
      const fence = m[1], body = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence)) body.push(lines[i++]);
      i++;
      const a = attrs(m[3] || '');
      a.cls.unshift('code');
      out.push(open('pre', a) + `<code data-lang='${q(m[2] || '')}'>` + esc(body.join('\n')) + '</code></pre>');
      continue;
    }
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) {
      const a = attrs(m[2]), n = m[1].length;
      out.push(open('h' + n, a) + inline(a.text.replace(/\s+#+\s*$/, '')) + '</h' + n + '>');
      i++;
      continue;
    }
    if (/^\s*</.test(l)) {
      const body = [];
      while (i < lines.length && !blank(lines[i])) body.push(lines[i++]);
      out.push(body.join('\n'));
      continue;
    }
    if (/^>/.test(l)) {
      const body = [];
      while (i < lines.length && /^>/.test(lines[i])) body.push(lines[i++].replace(/^>\s?/, ''));
      const a = attrs(body[body.length - 1]);
      body[body.length - 1] = a.text;
      out.push(open('blockquote', a) + md(body.join('\n')) + '</blockquote>');
      continue;
    }
    if (/^\s*\|/.test(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const cells = r => r.trim().replace(/^\||\|$/g, '').split('|').map(c => inline(c.trim()));
      const head = cells(l);
      let rows = '';
      i += 2;
      while (i < lines.length && /^\s*\|/.test(lines[i])) {
        rows += '<tr>' + cells(lines[i++]).map(c => '<td>' + c + '</td>').join('') + '</tr>';
      }
      out.push('<table><thead><tr>' + head.map(c => '<th>' + c + '</th>').join('') + '</tr></thead><tbody>' + rows + '</tbody></table>');
      continue;
    }
    if (ITEM.test(l)) {
      const r = list(lines, i);
      out.push(r[0]);
      i = r[1];
      continue;
    }
    const body = [];
    while (i < lines.length && !blank(lines[i]) && (!body.length || !startsBlock(lines[i]))) body.push(lines[i++]);
    const a = attrs(body.join('\n'));
    if (/^(\s*!\[[^\]]*\]\([^)]*\)\s*)+$/.test(a.text)) a.cls.push('img');
    out.push(open('p', a) + a.text.split('\n').map(inline).join('\n') + '</p>');
  }
  return out.join('\n');
}

// A + item is a step: it waits for a key press.
function list(lines, i) {
  const base = indentOf(lines[i]);
  const marker = lines[i].match(ITEM)[2];
  const ordered = /\d/.test(marker);
  const items = [];
  while (i < lines.length) {
    const l = lines[i];
    if (blank(l)) {
      const nx = lines[i + 1];
      if (nx !== undefined && !blank(nx) && indentOf(nx) > base) { items[items.length - 1].lines.push(''); i++; continue; }
      if (nx !== undefined && ITEM.test(nx) && indentOf(nx) === base) { i++; continue; }
      break;
    }
    const m = l.match(ITEM), ind = indentOf(l);
    if (m && ind === base) { items.push({ marker: m[2], lines: [m[3]] }); i++; continue; }
    if (ind > base) { items[items.length - 1].lines.push(' '.repeat(Math.max(0, ind - base - 2)) + l.trim()); i++; continue; }
    if (!m && !startsBlock(l)) { const it = items[items.length - 1]; it.lines[it.lines.length - 1] += ' ' + l.trim(); i++; continue; }
    break;
  }
  const tag = ordered ? 'ol' : 'ul';
  const start = ordered && parseInt(marker, 10) !== 1 ? ` start='${parseInt(marker, 10)}'` : '';
  const lis = items.map(it => {
    const a = attrs(it.lines[0]);
    if (it.marker === '+' && !a.cls.includes('step')) a.cls.push('step');
    const rest = it.lines.slice(1).join('\n');
    return open('li', a) + inline(a.text) + (rest.trim() ? md(rest) : '') + '</li>';
  });
  return [`<${tag}${start}>` + lis.join('') + `</${tag}>`, i];
}

// ---- Deck ----------------------------------------------------------------
// <!-- key: value; key: value --> inside a slide sets that slide's options.
function directives(text) {
  const d = {};
  // a comment quoted in `code` is text, not a directive
  text = text.replace(/(^|[^`])<!--([\s\S]*?)-->/g, (all, pre, body) => {
    const pairs = body.split(/[;\n]/).map(p => p.match(/^\s*([A-Za-z-]+)\s*:\s*(.*?)\s*$/));
    if (!pairs.some(Boolean)) return all;
    pairs.forEach(p => { if (p) d[p[1].toLowerCase()] = p[2]; });
    return pre;
  });
  return [text, d];
}

// Front matter between two --- lines sets the deck; a line of --- ends a slide.
function parseDeck(src) {
  const lines = src.replace(/\r/g, '').split('\n');
  let meta = {}, start = 0;
  if (lines.length && lines[0].trim() === '---') {
    const kv = {};
    let j = 1, ok = true;
    for (; j < lines.length && lines[j].trim() !== '---'; j++) {
      const m = lines[j].match(/^([A-Za-z-]+)\s*:\s*(.*?)\s*$/);
      if (m) kv[m[1].toLowerCase()] = m[2];
      else if (lines[j].trim()) { ok = false; break; }
    }
    if (ok && j < lines.length) { meta = kv; start = j + 1; } else start = 1;
  }
  const slides = [];
  let cur = [], from = start, fence = null, noteAt = -1;
  // a line of ??? starts the slide's speaker notes; they run to the slide's end
  const flush = () => {
    const body = noteAt < 0 ? cur : cur.slice(0, noteAt), notes = noteAt < 0 ? [] : cur.slice(noteAt + 1);
    if (cur.join('').trim()) slides.push({ text: body.join('\n'), notes: notes.join('\n').trim(), line: from });
    noteAt = -1;
  };
  for (let k = start; k < lines.length; k++) {
    const l = lines[k];
    const f = l.match(/^\s*(```|~~~)/);
    if (f) fence = fence ? (fence === f[1] ? null : fence) : f[1];
    if (!fence && /^---+\s*$/.test(l)) { flush(); cur = []; from = k + 1; }
    else { if (!fence && noteAt < 0 && /^\?\?\?\s*$/.test(l)) noteAt = cur.length; cur.push(l); }
  }
  flush();
  if (!slides.length) slides.push({ text: '# An empty deck\n\nWrite slides in the buffer. A line of `---` starts the next one.', line: 0 });
  return { meta, slides };
}

const deck = parseDeck(DATA.source || '');
const META = deck.meta;
const root = document.documentElement;
root.dataset.theme = (META.theme || 'dark').toLowerCase();
root.style.removeProperty('--font');
root.style.removeProperty('--accent');
if (META.font) root.style.setProperty('--font', META.font);
if (META.accent) root.style.setProperty('--accent', META.accent);
if (META.title) document.title = META.title;
const DEF_T = TRANSITIONS.includes(META.transition) ? META.transition : 'slide';
const DEF_DUR = parseInt(META.duration, 10) || 700;
const DEF_STEP = ANIMS.includes(META.step) ? META.step : 'up';

const el = (tag, id, cls) => { const e = document.createElement(tag); if (id) e.id = id; if (cls) e.className = cls; return e; };
const viewport = el('div', 'viewport'), stage = el('div', 'stage');
const progress = el('div', 'progress'), counter = el('div', 'counter'), toastEl = el('div', 'toast');
const black = el('div', 'black'), help = el('div', 'help', 'overlay'), ov = el('div', 'overview', 'overlay');
const notesEl = el('div', 'notes'), nav = el('div', 'nav');
nav.innerHTML = `<button class='back' aria-label='back'>‹</button><button class='fwd' aria-label='next'>›</button>`;
viewport.appendChild(stage);
[viewport, progress, counter, toastEl, black, help, ov, notesEl, nav].forEach(e => document.body.appendChild(e));

// ---- Motion -------------------------------------------------------------
// Remotion's idea: a scene is a function of time. render(t) draws second t,
// so any moment can be drawn: the overview shows the last frame, a live
// redraw lands on a finished scene, and arriving plays it from 0.
// <!-- scene: NAME; key: value --> on a slide hands the slide to SCENES[NAME].
const clamp01 = x => Math.min(1, Math.max(0, x));
const EASE = {
  linear: x => x, out: x => 1 - Math.pow(1 - x, 3), in: x => x * x * x,
  inOut: x => x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2,
};
// the value at time t of a tween from v0 at t0 to v1 at t1, held at both ends
function interpolate(t, [t0, t1], [v0, v1], ease) {
  return v0 + (v1 - v0) * (ease || EASE.out)(clamp01((t - t0) / (t1 - t0)));
}
// a damped spring from 0 to 1, released at delay; it overshoots when damping is low
function spring(t, o) {
  o = o || {};
  const x = t - (o.delay || 0);
  if (x <= 0) return 0;
  const k = o.stiffness || 170, c = o.damping || 14, m = o.mass || 1;
  const w = Math.sqrt(k / m), z = c / (2 * Math.sqrt(k * m));
  if (z >= 1) return 1 - Math.exp(-w * x) * (1 + w * x);
  const wd = w * Math.sqrt(1 - z * z);
  return 1 - Math.exp(-z * w * x) * (Math.cos(wd * x) + (z * w / wd) * Math.sin(wd * x));
}
// CSS's cubic-bezier(x1, y1, x2, y2) as a function of progress, for interpolate
function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = s => ((ax * s + bx) * s + cx) * s, dX = s => (3 * ax * s + 2 * bx) * s + cx;
  return x => {
    let s = x;
    for (let k = 0; k < 8; k++) { const err = X(s) - x, dv = dX(s); if (Math.abs(err) < 1e-6 || !dv) break; s -= err / dv; }
    s = clamp01(s);
    return ((ay * s + by) * s + cy) * s;
  };
}

// ---- Sound ----------------------------------------------------------------
// Scenes play stings synthesised here, so a deck needs no audio files. The
// browser lets a page sound only after a key or click on it.
let actx = null;
function audio() {
  try {
    actx = actx || new (window.AudioContext || window.webkitAudioContext)();
    if (actx.state === 'suspended') actx.resume();
    return actx;
  } catch (err) { return null; }
}
// one note: FREQ Hz, AT seconds from now, decaying over DUR
function tone(freq, o) {
  const a = audio();
  if (!a) return;
  o = o || {};
  const t = a.currentTime + (o.at || 0), dur = o.dur || .5, g = a.createGain(), osc = a.createOscillator();
  osc.type = o.type || 'triangle';
  osc.frequency.setValueAtTime(freq, t);
  if (o.to) osc.frequency.exponentialRampToValueAtTime(o.to, t + dur);
  g.gain.setValueAtTime(0, t);
  g.gain.linearRampToValueAtTime(o.gain || .16, t + .008);
  g.gain.exponentialRampToValueAtTime(.0001, t + dur);
  osc.connect(g).connect(a.destination);
  osc.start(t);
  osc.stop(t + dur + .05);
}

// logo: the compos ending, ported frame for frame from the launch film's
// LogoEnd (~/src/compos-launch-video/src/LogoEnd.tsx), at 30 frames a second.
// (compos) is typed on the dark; when it runs, paper floods out from the
// middle, the logo's three inks burst in as light and lock into the logo,
// then the name, the tagline and the kicker rise in. The slide's heading is
// the name and its first paragraph the tagline; typed, highlight and kicker
// are directives. A chord stings as the inks burst in; sound: off keeps it quiet.
const LE = { dim: '#6e6e7a', cyan: '#00a3cc' };
const LE_EASE = bezier(.2, 0, 0, 1);
function logoScene(sec, d) {
  const content = sec.querySelector('.content');
  const h = content.querySelector('h1,h2'), p = content.querySelector('p');
  const name = h ? h.textContent.trim() : 'compos';
  const tagline = p ? p.textContent.trim() : 'the hackable harness for power users';
  const typed = d.typed || '(' + name + ')';
  const highlight = d.highlight != null ? d.highlight : 'power users';
  const kicker = d.kicker || '';
  const FPS = 30, typeAt = 6, e = 34, unit = H / 1080;
  const cut = highlight ? tagline.indexOf(highlight) : -1;
  const tag = cut < 0 ? esc(tagline)
    : esc(tagline.slice(0, cut)) + `<span class='hl'>${esc(highlight)}</span>` + esc(tagline.slice(cut + highlight.length));
  const code = [...typed].map(ch => `<span style='color:${ch === '(' || ch === ')' ? LE.dim : LE.cyan}'>${esc(ch)}</span>`).join('');
  sec.innerHTML = `<div class='logo-end'>` +
    `<div class='le-dark'><div class='le-typed'>${code}<i class='le-cursor'></i></div></div>` +
    `<div class='le-paper'><div class='le-logo'>` +
    ['c', 'm', 'y'].map(k => `<img class='le-ink' src='logo-${k}.png' alt=''>`).join('') +
    `<img class='le-full' src='compos-logo-clear.png' alt=''></div>` +
    `<div class='le-name le-rise'>${esc(name)}</div><div class='le-tag le-rise'>${tag}</div>` +
    (kicker ? `<div class='le-kicker le-rise'>${esc(kicker)}</div>` : '') + `</div></div>`;
  const keys = [...sec.querySelectorAll('.le-typed span')], cursor = sec.querySelector('.le-cursor');
  const paper = sec.querySelector('.le-paper'), inks = [...sec.querySelectorAll('.le-ink')], full = sec.querySelector('.le-full');
  const rises = [...sec.querySelectorAll('.le-rise')], riseAt = [34, 48, 66];
  return {
    dur: (e + 110) / FPS,
    cues: d.sound === 'off' ? [] : [{ at: (e + 2) / FPS, play: () => {
      tone(110, { type: 'sine', to: 38, dur: .7, gain: .45 });
      [130.81, 261.63, 392, 523.25, 659.25].forEach((fq, k) => tone(fq, { type: k ? 'triangle' : 'sine', at: .03, dur: 2.2, gain: k ? .06 : .18 }));
    } }],
    render(t) {
      const f = t * FPS;
      const ramp = (a, b) => LE_EASE(clamp01((f - a) / (b - a)));
      const n = Math.floor(typed.length * clamp01((f - typeAt) / (e - 8 - typeAt)));
      keys.forEach((k, i) => { k.style.display = i < n ? '' : 'none'; });
      cursor.style.display = f < e ? '' : 'none';
      cursor.style.opacity = Math.floor(f / 8) % 2 ? .2 : 1;
      paper.style.clipPath = `circle(${ramp(e, e + 18) * 80}% at 50% 50%)`;
      const resolved = ramp(e + 34, e + 44);
      inks.forEach((img, i) => {
        const s = spring((f - e - 2 - i * 4) / FPS, { stiffness: 100, damping: 15, mass: 1.1 }), u = 1 - s;
        const a = i * 2.1 + f / 8;
        img.style.opacity = (1 - resolved) * Math.min(1, s * 2);
        img.style.filter = `blur(${u * 30 * unit}px)`;
        img.style.transform = `translate(${Math.cos(a) * 260 * unit * u}px, ${Math.sin(a) * 220 * unit * u}px) rotate(${u * (i - 1) * 60}deg) scale(${1 + u * 1.4})`;
      });
      full.style.opacity = resolved;
      rises.forEach((el, i) => {
        const v = ramp(e + riseAt[i], e + riseAt[i] + 16);
        el.style.opacity = v;
        el.style.transform = `translateY(${(1 - v) * 22 * unit}px)`;
      });
    },
  };
}
// llm-sentry: "I ask my LLM". A terminal agent, asked about Sentry errors,
// one beat per key press: the list; the details as a wall of text; a fix
// that eats the session; subagents that get lost and ask questions while a
// meter counts who waits on you; the question. Hidden .step markers count
// the beats and time inside a beat drives the motion. The agent's clock runs
// LS_RATE times faster than ours: it is slow.
const LS_RATE = 9, LS_SPIN = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';
const lsTime = s => { s = Math.floor(s); return s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + String(s % 60).padStart(2, '0') + 's'; };
const lsGlyph = t => LS_SPIN[Math.floor(Math.max(0, t) * 12) % LS_SPIN.length];
const LS_WALL = [
  '{',
  '  "id": "9f2c41e07ab84d0c9b1e6a3f5d27c810", "issue": "SHOP-3D1", "level": "error", "platform": "javascript",',
  '  "firstSeen": "2026-11-12T08:14:03Z", "lastSeen": "2026-11-14T02:29:51Z", "count": 88, "userCount": 61,',
  '  "exception": { "type": "InvalidCouponError", "value": "Coupon DIWALI25 is not valid for this cart",',
  '    "mechanism": { "type": "onunhandledrejection", "handled": false },',
  '    "stacktrace": { "frames": [',
  '      { "filename": "webpack-internal:///./src/checkout/coupon.ts", "lineno": 54, "function": "applyCoupon" },',
  '      { "filename": "webpack-internal:///./src/checkout/cart.ts", "lineno": 131, "function": "CartStore.applyCoupon" },',
  '      { "filename": "webpack-internal:///./src/checkout/CouponForm.tsx", "lineno": 27, "function": "onSubmit" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 15486, "function": "renderWithHooks" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 20103, "function": "updateFunctionComponent" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 21626, "function": "beginWork" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 27465, "function": "performUnitOfWork" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 26599, "function": "workLoopSync" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 26505, "function": "renderRootSync" },',
  '      { "filename": "node_modules/react-dom/cjs/react-dom.development.js", "lineno": 25889, "function": "performSyncWorkOnRoot" },',
  '      { "filename": "node_modules/scheduler/cjs/scheduler.development.js", "lineno": 178, "function": "flushWork" }',
  '    ] } },',
  '  "breadcrumbs": [',
  '    { "timestamp": "02:29:41", "category": "navigation", "data": { "from": "/p/oat-milk-1l", "to": "/cart" } },',
  '    { "timestamp": "02:29:43", "category": "ui.click", "message": "div.cart-row > button.qty-minus" },',
  '    { "timestamp": "02:29:44", "category": "fetch", "data": { "method": "PATCH", "url": "/api/cart/items/77", "status_code": 200 } },',
  '    { "timestamp": "02:29:46", "category": "ui.click", "message": "form#coupon > button[type=submit]" },',
  '    { "timestamp": "02:29:47", "category": "fetch", "data": { "method": "POST", "url": "/api/cart/coupon", "status_code": 200 } },',
  '    { "timestamp": "02:29:47", "category": "console", "level": "warning", "message": "[cart] hydrate: 3 items, 2 prices" },',
  '    { "timestamp": "02:29:51", "category": "sentry.event", "message": "TypeError" }',
  '  ],',
  '  "tags": { "browser": "Chrome Mobile 131", "os": "Android 14", "device": "Pixel 7", "release": "shop-web@4.18.2",',
  '    "environment": "production", "transaction": "/cart", "url": "https://shop.example.com/cart?coupon=DIWALI25" },',
  '  "contexts": { "browser": { "name": "Chrome Mobile", "version": "131.0.6778" }, "os": { "name": "Android", "version": "14" },',
  '    "device": { "family": "Pixel 7", "model": "GVU6C" },',
  '    "trace": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "span_id": "00f067aa0ba902b7" } },',
  '  "user": { "id": "u_51983", "ip_address": "{{auto}}", "geo": { "country_code": "IN", "city": "Pune" } },',
  '  "sdk": { "name": "sentry.javascript.react", "version": "8.42.0" }, "fingerprint": ["{{ default }}"],',
  '  "_meta": { "request": { "headers": { "": { "rem": [["@password:filter", "s"]] } } } }',
  '}',
];
// the first spinner's verbs: busy, and getting nowhere
const LS_VERBS = ['Lollygagging', 'Tiddlywinking', 'Dillydallying', 'Flibbertigibbeting', 'Moseying', 'Kerfuffling',
  'Shillyshallying', 'Noodling', 'Hornswoggling', 'Discombobulating', 'Faffing about', 'Bamboozling'];
const LS_WORK = ['Reading checkout/coupon.ts', 'Reading 14 files', 'Searching for "coupon"', 'Reading 38 files', 'Running npm test',
  'Reading node_modules/react-dom/cjs/react-dom.development.js', 'Rethinking the cart', 'Reading 112 files', 'Running npm test again'];
function llmSentryScene(sec, d) {
  const h = sec.querySelector('.content h1,.content h2');
  const title = h ? h.textContent.trim() : 'I ask my LLM';
  // the beats, one key each
  const B = { list: 0, which: 1, details: 2, fix: 3, subs: 4, punch: 5 };
  const DUR = 30, END = 60, BEATS = 6;
  // seconds of each beat the clock counts; fix and subs tick until the key
  const CAP = [8, 7, 10.5, Infinity, Infinity, Infinity], NOM = [8, 7, 10.5, 9, 12];
  const BASE = [0];
  NOM.forEach((v, k) => BASE.push(BASE[k] + v * LS_RATE));
  const issues = [
    ['SHOP-3F2', "TypeError: Cannot read properties of undefined (reading 'price')", '1,204'],
    ['SHOP-3E9', 'ConnectionTimeout: payments-gw did not answer in 30000ms', '412'],
    ['SHOP-3D1', 'UnhandledRejection: InvalidCouponError', '88'],
    ['SHOP-3C7', 'ChunkLoadError: Loading chunk 742 failed', '2,931'],
    ['SHOP-3A0', 'RangeError: Maximum call stack size exceeded', '7'],
  ];
  const subs = [
    { what: 'cart price undefined', ev: [[2.6, 'work', 'reading checkout/cart.ts'], [5.2, 'q', 'Should a missing item cost 0, or throw?']] },
    { what: 'payments timeout', ev: [[2.85, 'work', 'reading payments/client.ts'],
      [4.4, 'lost', x => `lost · reading node_modules/aws-sdk/… file ${Math.floor(214 + x * 137)} of ?`], [8.6, 'lost', 'lost · now refactoring the logger']] },
    { what: 'InvalidCouponError', ev: [[3.1, 'work', 'grepping for "coupon"'], [6.4, 'q', 'Should expired coupons throw?']] },
    { what: 'ChunkLoadError', ev: [[3.35, 'work', 'reading webpack.config.js'], [5.8, 'done', '✓ added a retry · tests not run'], [7.8, 'q', 'Can I push to main?']] },
    { what: 'max call stack', ev: [[3.6, 'work', 'thinking']] },
  ];
  // the log: each line belongs to a beat and shows from its time in that beat
  const L = [];
  const you = (beat, at, text) => L.push({ beat, at, kind: 'you', text });
  const line = (beat, at, html, cls) => L.push({ beat, at, kind: 'line', html, cls });
  const spin = (beat, at, end, label, done) => L.push({ beat, at, end, kind: 'spin', label, done });
  you(B.list, .3, "what's breaking in prod?");
  spin(B.list, 1.6, 4.4, x => LS_VERBS[Math.floor(x / .45) % LS_VERBS.length], f => `· lollygagged for ${lsTime(f)}`);
  line(B.list, 4.5, '◇ sentry.list_issues(project: "shop-web", status: "unresolved")', 'tool');
  line(B.list, 4.9, '  5 issues', 'dim');
  issues.forEach((r, k) => line(B.list, 5.2 + k * .3, `<span class='id'>${k + 1}. ${r[0]}</span>  ${esc(r[1])}  <span class='n'>${r[2]}</span>`, 'issue'));
  line(B.list, 7, 'Here are the 5 unresolved issues. Want me to look into any of them?', 'say');
  // you have to name it by number, and even that is slow
  you(B.which, .2, "what's 3?");
  spin(B.which, .9, 4.6, x => ['Working out which one is 3', 'Counting to 3', 'Recounting', 'Fetching the list again'][Math.min(3, Math.floor(x / .95))], f => `· pondered for ${lsTime(f)}`);
  line(B.which, 4.7, '◇ sentry.list_issues(project: "shop-web", status: "unresolved")', 'tool');
  line(B.which, 5.0, '◇ sentry.get_issue(id: "SHOP-3D1")', 'tool');
  line(B.which, 5.5, '3 is <code>SHOP-3D1</code>: an unhandled <code>InvalidCouponError</code>, 88 events since Tuesday, mostly on /cart. Want the details?', 'say');
  you(B.details, .2, 'yes, show me the details');
  spin(B.details, 1.4, 5.3, x => ['Fetching the issue', 'Fetching the latest event', 'Reading the stack trace'][Math.min(2, Math.floor(x / 1.4))], f => `· fetched for ${lsTime(f)}`);
  line(B.details, 5.4, '◇ sentry.get_issue(id: "SHOP-3D1")', 'tool');
  line(B.details, 5.6, '◇ sentry.get_event(issue: "SHOP-3D1", event: "latest")', 'tool');
  LS_WALL.forEach((w, k) => line(B.details, 5.9 + k * .05, esc(w), 'wall'));
  const sum = 6.1 + LS_WALL.length * .05;
  line(B.details, sum, 'So <code>applyCoupon</code> rejects and nothing catches it. This could be caused by several factors:', 'say');
  ['an expired coupon', 'a coupon that does not apply to this cart', 'a stale service-worker cache', 'something else']
    .forEach((s, k) => line(B.details, sum + .3 + k * .2, `  ${k + 1}. ${s}`, 'say'));
  line(B.details, sum + 1.4, 'Would you like me to investigate further, or attempt a fix?', 'say');
  you(B.fix, .2, 'fix it');
  spin(B.fix, .8, Infinity, x => LS_WORK[Math.floor(x / 1.5) % LS_WORK.length], '⏹ interrupted · 0 bugs fixed');
  you(B.subs, .3, 'use subagents. one per issue. go.');
  line(B.subs, 1.4, '◇ spawn_subagents(5)', 'tool');
  line(B.subs, 1.8, "5 subagents are running in the background. I'll tell you when they need you.", 'say');
  subs.forEach((s, k) => s.ev.forEach(e => {
    if (e[1] === 'q') line(B.subs, e[0], `⚑ sub-${k + 1} is waiting on you: ${esc(e[2])}`, 'flag');
    if (e[1] === 'done') line(B.subs, e[0], `✓ sub-${k + 1} says it's done`, 'dim');
  }));

  sec.innerHTML = `<div class='llm'>` +
    `<div class='llm-head'><h2>${esc(title)}</h2><div class='llm-meters'>` +
    `<span>⏱ <b class='llm-clock'>0s</b></span><span>fixed <b>0</b></span>` +
    `<span class='llm-wait'>waiting on you <b>0</b></span></div></div>` +
    `<div class='llm-term'><div class='llm-bar'><i></i><i></i><i></i><span>agent — ~/src/shop-web</span></div>` +
    `<div class='llm-body'><div class='llm-log'>` + L.map(() => '<div></div>').join('') + `</div></div>` +
    `<div class='llm-input'><span class='p'>›</span><span class='tx'></span><i class='llm-cur'></i><span class='q'>queued</span></div></div>` +
    `<div class='llm-subs'>` + subs.map((s, k) => `<div class='llm-card'><div class='t'><b>sub-${k + 1}</b>  ${issues[k][0]} · ${esc(s.what)}</div><div class='s'></div></div>`).join('') + `</div>` +
    `<div class='llm-cap'>Forgot to say “use a subagent”.<br>There goes your focus.</div>` +
    `<div class='llm-punch'>How many can you handle in parallel?</div>` +
    '<i class="step llm-beat"></i>'.repeat(BEATS - 1) + `</div>`;
  const $ = s => sec.querySelector(s);
  const log = $('.llm-log'), term = $('.llm-term'), clockEl = $('.llm-clock');
  const wait = $('.llm-wait'), waitN = $('.llm-wait b'), cap = $('.llm-cap'), punch = $('.llm-punch');
  const input = $('.llm-input'), inputTx = $('.llm-input .tx'), cur = $('.llm-cur'), queued = $('.llm-input .q');
  [...log.children].forEach((e, k) => { L[k].el = e; });
  [...sec.querySelectorAll('.llm-card')].forEach((e, k) => { subs[k].el = e; subs[k].s = e.querySelector('.s'); });
  const set = (r, cls, html) => { if (r.html_ !== html || r.cls_ !== cls) { r.el.className = cls; r.el.innerHTML = html; r.html_ = html; r.cls_ = cls; } };
  const typed = (text, x) => Math.min(text.length, Math.max(0, Math.floor(x / .04)));
  const ping = () => { tone(988, { type: 'sine', dur: .3, gain: .07 }); tone(1319, { type: 'sine', at: .09, dur: .45, gain: .07 }); };

  let lastN = null, lastT = -1, beatT0 = 0, live = false, clock0 = 0, clockNow = 0, waiting = 0;
  // beat N at U seconds into it; LIVE when it was reached by one key forward
  function draw(n, u, live) {
    L.forEach(r => {
      const on = r.beat < n || (r.beat === n && u >= r.at);
      r.el.style.display = on ? '' : 'none';
      if (!on) return;
      const past = r.beat < n, x = past ? END : u - r.at;
      if (r.kind === 'you') {
        const k = typed(r.text, x);
        set(r, 'llm-you', esc(r.text.slice(0, k)) + (k < r.text.length ? `<i class='llm-cur'></i>` : ''));
      } else if (r.kind === 'spin') {
        if (!past && u < r.end) set(r, 'llm-spin', `${lsGlyph(x)} ${esc(r.label(x))}… ${lsTime(x * LS_RATE)}` + (r.end === Infinity ? ` <span class='k'>· esc to interrupt</span>` : ''));
        else set(r, 'llm-spin done', esc(typeof r.done === 'function' ? r.done((r.end - r.at) * LS_RATE) : r.done));
      } else set(r, 'llm-' + r.cls, r.html);
    });
    // the input: busy while the fix eats the session, a question typed into the queue
    const busy = n === B.fix && u > .8, q = 'wait, what about the payments one?';
    input.classList.toggle('busy', busy);
    const k = busy ? typed(q, u - 3.2) : 0;
    inputTx.textContent = busy ? (k ? q.slice(0, k) : 'agent is working…') : '';
    inputTx.classList.toggle('ph', busy && !k);
    cur.style.opacity = Math.floor(u * 2) % 2 && !(busy && k && k < q.length) ? .15 : 1;
    queued.style.opacity = busy && k === q.length ? 1 : 0;
    const co = n === B.fix ? spring(u - 5, { damping: 12 }) : 0;
    cap.style.opacity = Math.min(1, co * 1.5);
    cap.style.transform = `rotate(2deg) scale(${.7 + .3 * co})`;
    // subagents fan out to the right
    term.style.width = (n < B.subs ? 1168 : n > B.subs ? 620 : interpolate(u, [1.9, 2.7], [1168, 620], EASE.inOut)) + 'px';
    const cu = n < B.subs ? -1 : n === B.subs ? u : 20 + u;
    let w = 0;
    subs.forEach((s, k) => {
      const a = n < B.subs ? 0 : n > B.subs ? 1 : spring(u - 2.1 - k * .22, { damping: 16 });
      s.el.style.opacity = Math.min(1, a * 1.5);
      s.el.style.transform = `translateX(${(1 - a) * 80}px)`;
      let e = null;
      s.ev.forEach(v => { if (cu >= v[0]) e = v; });
      const kind = e ? e[1] : 'start';
      if (kind === 'q') w++;
      const x = e ? cu - e[0] : 0;
      const text = !e ? `${lsGlyph(cu)} starting…`
        : kind === 'work' ? `${lsGlyph(cu)} ${e[2]} · ${lsTime((cu - s.ev[0][0]) * LS_RATE)}`
        : kind === 'q' ? '? ' + e[2] : typeof e[2] === 'function' ? e[2](x) : e[2];
      s.el.className = 'llm-card ' + kind;
      if (s.s.textContent !== text) s.s.textContent = text;
    });
    if (live && w > waiting && d.sound !== 'off') ping();
    waiting = w;
    waitN.textContent = w;
    wait.style.opacity = n >= B.subs ? 1 : 0;
    wait.classList.toggle('hot', w > 0);
    clockNow = clock0 + Math.min(u, CAP[n]) * LS_RATE;
    clockEl.textContent = lsTime(clockNow);
    const po = n === B.punch ? interpolate(u, [.2, .9], [0, 1]) : 0;
    punch.style.display = po ? '' : 'none';
    punch.style.opacity = po;
    punch.style.transform = `scale(${.94 + .06 * po})`;
  }
  return {
    dur: DUR,
    render(t) {
      // t = dur draws the last frame: the overview and an instant arrival
      if (t === DUR) { clock0 = BASE[BEATS - 1]; draw(BEATS - 1, END, false); lastN = null; return; }
      const n = Math.min(BEATS - 1, sec.querySelectorAll('.llm-beat.shown').length);
      if (lastN === null || t < lastT || n !== lastN) {
        live = lastN === null || t < lastT ? n === 0 : n === lastN + 1;
        beatT0 = live ? t : t - END;
        clock0 = live && n ? clockNow : BASE[n];
        if (!live) waiting = 0;
      }
      lastN = n;
      lastT = t;
      draw(n, t - beatT0, live);
    },
  };
}
const SCENES = { logo: logoScene, 'llm-sentry': llmSentryScene };

// The current slide's scene runs on one frame loop, from when the slide's
// transition is mostly done; an instant arrival starts at the last frame.
let clock = 0;
function play(s, instant) {
  cancelAnimationFrame(clock);
  const sc = s.scene;
  if (!sc) return;
  const t0 = performance.now() + (instant ? -sc.dur * 1000 : +s.dataset.dur * .45);
  sc.render(instant ? sc.dur : 0);
  // a cue (a sound) fires once, as time passes it; an instant arrival is past them all
  let last = instant ? Infinity : -1;
  const tick = now => {
    if (life.signal.aborted || sections[idx] !== s) return;
    const t = Math.max(0, (now - t0) / 1000);
    (sc.cues || []).forEach(c => { if (last < c.at && c.at <= t) c.play(); });
    last = t;
    sc.render(t);
    clock = requestAnimationFrame(tick);
  };
  clock = requestAnimationFrame(tick);
}

const sections = deck.slides.map(s => {
  const [text, d] = directives(s.text);
  const sec = el('section', '', 'slide');
  sec.innerHTML = `<div class='content'>${md(text)}</div>`;
  const content = sec.firstChild;
  const cls = (d.class || '').split(/\s+/).filter(Boolean);
  cls.forEach(c => sec.classList.add(c));
  const kids = [...content.children];
  if (!cls.length && kids.length && kids[0].tagName === 'H1' && kids.length <= 3) sec.classList.add('title');
  const bg = d.bg || d.background;
  if (bg) {
    if (/^(url\(|https?:|\/|\.)|\.(png|jpe?g|gif|webp|svg|avif)$/i.test(bg)) {
      sec.style.backgroundImage = bg.startsWith('url(') ? bg : `url('${bg}')`;
      sec.classList.add('has-img');
    } else sec.style.background = bg;
  }
  if (d.color) sec.style.color = d.color;
  if (d.focus && d.focus !== 'off') sec.classList.add('focus');
  const stepAnim = ANIMS.includes(d.step) ? d.step : DEF_STEP;
  sec.querySelectorAll('.step:not([data-anim])').forEach(e => { e.dataset.anim = stepAnim; });
  if (d.build) {
    const anim = ANIMS.includes(d.build) ? d.build : 'up';
    kids.forEach(c => {
      const parts = /^(UL|OL)$/.test(c.tagName) ? [...c.children] : [c];
      parts.forEach(p => { if (!p.classList.contains('step') && !p.dataset.anim) { p.classList.add('enter'); p.dataset.anim = anim; } });
    });
  }
  sec.querySelectorAll('.enter').forEach((e, k) => e.style.setProperty('--delay', (k * 140) + 'ms'));
  sec.dataset.t = TRANSITIONS.includes(d.transition) ? d.transition : DEF_T;
  sec.dataset.dur = parseInt(d.duration, 10) || DEF_DUR;
  sec.dataset.line = s.line;
  sec.notes = s.notes ? md(s.notes) : '';
  if (d.scene && SCENES[d.scene]) {
    sec.classList.add('scene', 'scene-' + d.scene);
    sec.scene = SCENES[d.scene](sec, d);
    sec.scene.render(sec.scene.dur);
  }
  stage.appendChild(sec);
  return sec;
});

// ---- Steps and transitions ----------------------------------------------
let idx = 0, pending = null, hudTimer = 0, toastTimer = 0, navTimer = 0, typed = '';
const stepsOf = s => [...s.querySelectorAll('.step')];
const shownOf = s => s.querySelectorAll('.step.shown').length;

// Touch only the steps that change, so a shown step never replays.
function setSteps(s, n, instant) {
  stepsOf(s).forEach((e, k) => {
    const on = k < n;
    if (on !== e.classList.contains('shown')) {
      e.classList.toggle('shown', on);
      e.classList.toggle('instant', on && instant);
    }
    e.classList.toggle('past', on && k < n - 1);
  });
}

function arrive(s, instant) {
  s.style.setProperty('--base', instant ? '0ms' : Math.round(s.dataset.dur * 0.45) + 'ms');
  s.classList.toggle('instant', instant);
  s.querySelectorAll('.enter').forEach(e => { e.classList.remove('go'); void e.offsetWidth; e.classList.add('go'); });
  play(s, instant);
}

function finish() { if (pending) { const p = pending; pending = null; p(); } }

function transit(from, to, kind, dir, dur) {
  if (kind === 'morph' && !document.startViewTransition) kind = 'fade';
  if (kind === 'none') { from.classList.remove('current'); to.classList.add('current'); return; }
  if (kind === 'morph') return morph(from, to, dur);
  const name = kind === 'wipe' && dir < 0 ? 'wipe-rev' : kind;
  stage.style.setProperty('--dir', dir);
  from.classList.remove('current');
  from.classList.add('leaving');
  to.classList.add('current');
  const ease = `${dur}ms cubic-bezier(.65,0,.35,1) both`;
  from.style.animation = `t-${name}-out ${ease}`;
  to.style.animation = `t-${name}-in ${ease}`;
  const done = () => {
    clearTimeout(timer);
    from.classList.remove('leaving');
    from.style.animation = '';
    to.style.animation = '';
    if (pending === done) pending = null;
  };
  const timer = setTimeout(done, dur + 60);
  pending = done;
}

// morph: what the two slides share moves to its new place (a view transition).
// Shared means the same #id, heading text, image, code block or line of text.
function keysOf(sec) {
  const m = new Map();
  const add = (k, e) => { if (!m.has(k)) m.set(k, e); };
  sec.querySelectorAll('[id]').forEach(e => add('id:' + e.id, e));
  sec.querySelectorAll('h1,h2,h3,h4').forEach(e => add('h:' + e.textContent.trim().toLowerCase(), e));
  sec.querySelectorAll('img').forEach(e => add('img:' + e.getAttribute('src'), e));
  sec.querySelectorAll('pre').forEach((e, k) => add('pre:' + k, e));
  sec.querySelectorAll('li,p,blockquote,td').forEach(e => add('t:' + e.textContent.trim().toLowerCase(), e));
  return m;
}

function morph(from, to, dur) {
  const a = keysOf(from), b = keysOf(to), used = new Set(), pairs = [];
  for (const [key, e] of a) {
    const f = b.get(key);
    if (f && !used.has(e) && !used.has(f)) { used.add(e); used.add(f); pairs.push([e, f, 'm' + pairs.length]); }
  }
  root.style.setProperty('--vt', dur + 'ms');
  pairs.forEach(([e, , n]) => { e.style.viewTransitionName = n; });
  const t = document.startViewTransition(() => {
    pairs.forEach(([e, f, n]) => { e.style.viewTransitionName = ''; f.style.viewTransitionName = n; });
    // A later key may have moved on before this swap ran: show where idx is.
    sections.forEach(s => s.classList.toggle('current', s === sections[idx]));
  });
  const done = () => { pairs.forEach(([, f]) => { f.style.viewTransitionName = ''; }); if (pending === done) pending = null; };
  pending = () => { try { t.skipTransition(); } catch (err) {} done(); };
  t.finished.then(done, done);
}

function go(n, opts) {
  opts = opts || {};
  n = Math.max(0, Math.min(sections.length - 1, n));
  finish();
  const from = sections[idx], to = sections[n];
  const dir = opts.dir || (n >= idx ? 1 : -1);
  setSteps(to, opts.steps != null ? opts.steps : opts.allSteps ? stepsOf(to).length : 0, true);
  if (from === to || opts.instant) {
    sections.forEach(s => s.classList.remove('current', 'leaving'));
    to.classList.add('current');
    idx = n;
    arrive(to, !!opts.instant);
  } else {
    // Back replays the transition of the slide you leave, reversed.
    const owner = dir > 0 ? to : from;
    idx = n;
    transit(from, to, owner.dataset.t, dir, +owner.dataset.dur);
    arrive(to, false);
  }
  hud();
  showNotes();
  report();
}

function next() {
  const s = sections[idx], n = shownOf(s);
  if (n < stepsOf(s).length) { setSteps(s, n + 1, false); hud(); report(); }
  else if (idx < sections.length - 1) go(idx + 1, { dir: 1 });
}

function prev() {
  const s = sections[idx], n = shownOf(s);
  if (n > 0) { setSteps(s, n - 1, true); hud(); report(); }
  else if (idx > 0) go(idx - 1, { dir: -1, allSteps: true });
}

// ---- Chrome ----------------------------------------------------------------
function hud() {
  progress.style.width = ((idx + 1) / sections.length * 100) + '%';
  counter.textContent = typed ? 'go to ' + typed : (idx + 1) + ' / ' + sections.length;
  document.body.classList.add('hud');
  clearTimeout(hudTimer);
  hudTimer = setTimeout(() => document.body.classList.remove('hud'), 1800);
}

function toast(text) {
  toastEl.textContent = text;
  toastEl.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('on'), 2600);
}

// The editor learns which slide shows, so e in the buffer opens its source
// and a page the editor remounts comes back to the same slide and step.
function report() {
  if (resuming) return;
  const at = { slide: idx, steps: shownOf(sections[idx]), line: +sections[idx].dataset.line, stamp: DATA.stamp };
  fetch('_compos/app', { method: 'POST', body: JSON.stringify(at) }).catch(() => {});
}

// Notes survive a live redraw: the page boots again, the choice stays.
const notesPref = v => { try { return v === undefined ? sessionStorage.getItem('slides-notes') : sessionStorage.setItem('slides-notes', v); } catch (err) { return null; } };
let notesOn = notesPref() !== 'off';
function showNotes() {
  const on = notesOn;
  document.body.classList.toggle('notes-on', on);
  notesEl.innerHTML = sections[idx].notes || `<p class='none'>No notes. Write them under a line of <code>???</code></p>`;
  notesEl.scrollTop = 0;
  fit();
}

function fit() {
  const h = document.body.classList.contains('notes-on') ? innerHeight - notesEl.offsetHeight : innerHeight;
  stage.style.transform = `scale(${Math.min(innerWidth / W, h / H)})`;
  if (ov.classList.contains('on')) scaleThumbs();
}

const KEYS = [
  [['→', 'Space', 'n'], 'next step or slide'], [['←', 'p'], 'back'],
  [['Home', 'End'], 'first, last'], [['3', 'Enter'], 'go to slide 3'],
  [['o', 'Esc'], 'overview'], [['f'], 'maximize, and again to restore'], [['b'], 'black screen'], [['s'], 'speaker notes'],
  [['d'], 'outline the stage, content area and blocks'],
  [['?'], 'these keys'], [['C-g'], 'give the keyboard back to the editor']];
help.innerHTML = `<div class='card'><h3>Slides</h3><table>` +
  KEYS.map(([ks, what]) => `<tr><td>${ks.map(k => `<kbd>${esc(k)}</kbd>`).join('')}</td><td>${esc(what)}</td></tr>`).join('') +
  `</table></div>`;

let sel = 0;
function scaleThumbs() {
  ov.querySelectorAll('.thumb').forEach(t => { t.firstChild.style.transform = `scale(${t.clientWidth / W})`; });
}
// opening the overview centers the slide at once; a key after that
// scrolls only as far as the next thumb needs
function select(n, opening) {
  const thumbs = ov.querySelectorAll('.thumb');
  sel = Math.max(0, Math.min(thumbs.length - 1, n));
  thumbs.forEach((t, k) => t.classList.toggle('sel', k === sel));
  thumbs[sel].scrollIntoView(opening
    ? { block: 'center', behavior: 'instant' }
    : { block: 'nearest', behavior: 'smooth' });
}
function overview(on) {
  if (on === undefined) on = !ov.classList.contains('on');
  ov.classList.toggle('on', on);
  if (!on) return;
  ov.innerHTML = '';
  sections.forEach((s, n) => {
    const t = el('div', '', 'thumb');
    t.style.setProperty('--k', n);
    // a scene shows its last frame; the current slide shows where it is
    if (s.scene && s !== sections[idx]) s.scene.render(s.scene.dur);
    const c = s.cloneNode(true);
    c.classList.remove('leaving');
    c.classList.add('current', 'instant');
    c.style.animation = '';
    c.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
    c.querySelectorAll('.past').forEach(e => e.classList.remove('past'));
    c.querySelectorAll('.step').forEach(e => e.classList.add('shown', 'instant'));
    c.querySelectorAll('.enter').forEach(e => e.classList.add('go'));
    t.appendChild(c);
    const label = el('span', '', 'n');
    label.textContent = n + 1;
    t.appendChild(label);
    t.addEventListener('click', ev => { ev.stopPropagation(); overview(false); go(n); });
    ov.appendChild(t);
  });
  scaleThumbs();
  select(idx, true);
}
function columns() {
  return getComputedStyle(ov).gridTemplateColumns.split(' ').length || 1;
}

// The page cannot resize the editor's windows, so it asks the editor.
function maximize() {
  fetch('_compos/app', { method: 'POST', body: JSON.stringify({ action: 'maximize' }) })
    .then(r => r.json())
    .then(r => { if (r.state === 'hidden') toast('No window shows these slides.'); })
    .catch(() => toast('The editor did not answer.'));
}

// ---- Input -----------------------------------------------------------------
addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key;
  if (ov.classList.contains('on')) {
    const cols = columns();
    if (k === 'ArrowRight' || k === 'l') select(sel + 1);
    else if (k === 'ArrowLeft' || k === 'h') select(sel - 1);
    else if (k === 'ArrowDown' || k === 'j') select(sel + cols);
    else if (k === 'ArrowUp' || k === 'k') select(sel - cols);
    else if (k === 'Enter' || k === ' ') { overview(false); go(sel); }
    else if (k === 'Escape' || k === 'o') overview(false);
    else return;
    e.preventDefault();
    return;
  }
  if (help.classList.contains('on')) { help.classList.remove('on'); e.preventDefault(); return; }
  if (black.classList.contains('on') && k !== 'b' && k !== '.') { black.classList.remove('on'); e.preventDefault(); return; }
  if (/^[0-9]$/.test(k)) { typed += k; hud(); e.preventDefault(); return; }
  if (k === 'Enter' && typed) { const n = parseInt(typed, 10) - 1; typed = ''; go(n); e.preventDefault(); return; }
  typed = '';
  switch (k) {
    case 'ArrowRight': case 'ArrowDown': case 'PageDown': case 'Enter': case 'n': case 'j': case 'l':
      next(); break;
    case ' ':
      if (e.shiftKey) prev(); else next();
      break;
    case 'ArrowLeft': case 'ArrowUp': case 'PageUp': case 'Backspace': case 'p': case 'k': case 'h':
      prev(); break;
    case 'Home': go(0); break;
    case 'End': go(sections.length - 1, { allSteps: true }); break;
    case 'o': case 'Escape': overview(); break;
    case 'f': maximize(); break;
    case 'b': case '.': black.classList.toggle('on'); break;
    case 'd': document.body.classList.toggle('outline'); break;
    case 's': notesOn = !notesOn; notesPref(notesOn ? 'on' : 'off'); showNotes(); break;
    case '?': help.classList.add('on'); break;
    default: return;
  }
  e.preventDefault();
}, { signal: life.signal });

viewport.addEventListener('click', e => {
  if (e.target.closest('a')) return;
  if (e.shiftKey || e.clientX < innerWidth / 3) prev(); else next();
});
help.addEventListener('click', () => help.classList.remove('on'));
nav.addEventListener('click', e => { const bt = e.target.closest('button'); if (bt) bt.classList.contains('back') ? prev() : next(); });
addEventListener('mousemove', () => { document.body.classList.add('pointer'); clearTimeout(navTimer); navTimer = setTimeout(() => document.body.classList.remove('pointer'), 2000); }, { signal: life.signal });
ov.addEventListener('click', () => overview(false));
black.addEventListener('click', () => black.classList.remove('on'));
addEventListener('resize', fit, { signal: life.signal });

// ---- Start -----------------------------------------------------------------
// Open at the slide that holds the source line. A live redraw shows the
// slide whole; a fresh start leaves its steps to the presenter.
let startAt = 0, resuming = !DATA.live;
sections.forEach((s, n) => { if (+s.dataset.line <= (DATA.line || 0)) startAt = n; });
fit();
go(startAt, { instant: true, allSteps: !!DATA.live });
if (!DATA.live) {
  // A reload (g, f remounting the frame, a hot reload of this file) comes
  // back to the slide and step the page last showed, of any rendering.
  const done = () => { resuming = false; report(); };
  fetch('_compos/app').then(r => r.json()).then(at => {
    resuming = false;
    if (at && at.slide != null && at.slide < sections.length) {
      go(at.slide, { instant: true });
      setSteps(sections[idx], at.steps || 0, true);
    } else {
      arrive(sections[startAt], false);
      if (!startAt) toast('Press ? for keys');
    }
    done();
  }).catch(() => { arrive(sections[startAt], false); done(); });
}
return {
  // point moved to LINE in the deck: show the slide that holds it
  show(line) {
    let n = 0;
    sections.forEach((s, k) => { if (+s.dataset.line <= line) n = k; });
    if (n !== idx) go(n, { allSteps: true });
  },
  // the deck's slides-deck-mode steps the slides: next or prev
  step(dir) { dir === 'prev' ? prev() : next(); },
  // the editor read slide N and its step K off point (slides.scm): go there
  goto(n, k) {
    n = Math.max(0, Math.min(sections.length - 1, n | 0));
    k = Math.max(0, Math.min(stepsOf(sections[n]).length, k | 0));
    if (n !== idx) { go(n, { steps: k }); return; }
    if (k !== shownOf(sections[n])) { setSteps(sections[n], k, k < shownOf(sections[n])); hud(); report(); }
  },
  stop() {
    life.abort();
    cancelAnimationFrame(clock);
    clearTimeout(hudTimer);
    clearTimeout(toastTimer);
    clearTimeout(navTimer);
    [viewport, progress, counter, toastEl, black, help, ov, notesEl, nav].forEach(e => e.remove());
  }
};
}

let data = JSON.parse(document.getElementById('deck').textContent);
let deck = boot(data);
// The editor posts the deck and the line of its point (app-post!, slides.scm).
// The same deck only moves to the slide; an edited one boots again there.
addEventListener('message', e => {
  const m = e.data;
  if (e.source !== parent || !m || m.compos !== 'message' || !m.data) return;
  if (m.data.step) { deck.step(m.data.step); return; }
  if (m.data.key) { dispatchEvent(new KeyboardEvent('keydown', { key: m.data.key })); return; }
  if (m.data.goto) { deck.goto(m.data.goto.slide, m.data.goto.step); return; }
  if (m.data.source == null) return;
  if (m.data.source === data.source) { deck.show(m.data.line || 0); return; }
  data = m.data;
  deck.stop();
  deck = boot(data);
});
// Ask for the keyboard; the editor grants it only when this window is the
// selected one, so the page never takes focus from the deck being typed in.
parent.postMessage({ compos: 'request-focus' }, '*');
})();
