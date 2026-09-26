// The compos logo: three musical marks in one ink at partial opacity:
// a turn, a quarter note and a slur.
// Where two marks overlap the ink is darker, and the darker part must
// read as a lambda. Drag a mark to move it, shift-drag to turn it, and
// use the wheel to size it. The panel holds the same numbers.

const VB = { x: -25, y: -30, w: 160, h: 160 };
const DEG = Math.PI / 180;
const KEY = 'compos-logo-v2';
const LAMBDA = String.fromCharCode(955);

const add = (p, q, k = 1) => [p[0] + q[0] * k, p[1] + q[1] * k];
const unit = (a) => [Math.cos(a), Math.sin(a)];
const n2 = (v) => +v.toFixed(2);
const pt = (p) => `${n2(p[0])} ${n2(p[1])}`;

function poly(points) { return 'M' + points.map(pt).join('L') + 'Z'; }

// a bar from P, LEN long along angle A, W wide, with square ends
function bar(p, a, len, w) {
  const q = add(p, unit(a), len), s = unit(a + Math.PI / 2);
  return poly([add(p, s, w / 2), add(q, s, w / 2), add(q, s, -w / 2), add(p, s, -w / 2)]);
}

function ellipse(c, rx, ry, a) {
  const p = add(c, unit(a), rx), q = add(c, unit(a), -rx), r = n2(a / DEG);
  return `M${pt(p)}A${rx} ${ry} ${r} 1 1 ${pt(q)}A${rx} ${ry} ${r} 1 1 ${pt(p)}Z`;
}

// The marks are pen strokes: a cubic Bezier chain, thin at its ends and
// widest at FAT, so every edge the overlap keeps is a curve.
function cubic(p0, p1, p2, p3, t) {
  const u = 1 - t;
  return [0, 1].map((k) => u * u * u * p0[k] + 3 * u * u * t * p1[k] + 3 * u * t * t * p2[k] + t * t * t * p3[k]);
}

function brush(segs, thin, thick, fat = 0.5, n = 48) {
  const spine = [];
  segs.forEach((s, i) => { for (let k = i ? 1 : 0; k <= n; k++) spine.push(cubic(...s, k / n)); });
  const len = [0];
  for (let i = 1; i < spine.length; i++) {
    len.push(len[i - 1] + Math.hypot(spine[i][0] - spine[i - 1][0], spine[i][1] - spine[i - 1][1]));
  }
  const total = len[len.length - 1], left = [], right = [];
  spine.forEach((p, i) => {
    const a = spine[Math.max(0, i - 1)], b = spine[Math.min(spine.length - 1, i + 1)];
    const d = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
    const nrm = [-(b[1] - a[1]) / d, (b[0] - a[0]) / d];
    const s = len[i] / total, x = s < fat ? s / fat : (1 - s) / (1 - fat);
    const w = thin + (thick - thin) * Math.sin(x * Math.PI / 2);
    left.push(add(p, nrm, w / 2)); right.push(add(p, nrm, -w / 2));
  });
  return poly(left.concat(right.reverse()));
}

// The turn lies inside the quarter note head, so the head keeps all of it:
// its S is the long stroke of the lambda, with a hook at the top and a
// flick at the foot. The slur crosses the head from the middle of the S,
// and the head clips it into the short leg.
const BEAM = Math.atan2(88, 54);
const MID = [51, 50];
const AX = unit(BEAM), PX = unit(BEAM + Math.PI / 2);
const at = (u, v) => add(add(MID, AX, u), PX, v);   // u down the stroke, v toward the leg

const MARKS = [
  { name: 'Turn', pivot: MID, paths: [
    brush([
      [at(-24, 9), at(-36, 11), at(-41, 0), at(-31, -2)],
      [at(-31, -2), at(-15, -3), at(15, 2), at(30, 0)],
      [at(30, 0), at(36, -1), at(39, -6), at(36, -11)]], 1.6, 11, 0.5),
    ellipse(at(-24, 9), 3.2, 3.2, 0), ellipse(at(36, -11), 2.2, 2.2, 0)] },
  { name: 'Quarter note', pivot: MID, paths: [
    ellipse(MID, 46, 32, BEAM), bar([MID[0] + 34, MID[1] + 2], -90 * DEG, 64, 3.2)] },
  { name: 'Slur', pivot: [30, 74], paths: [
    brush([[[52, 48], [44, 64], [30, 84], [6, 100]]], 0.8, 6.5, 0.45)] },
];
const PATHS = MARKS.map((m) => m.paths.map((d) => new Path2D(d)));

const DEFAULT = {
  alpha: 0.42, view: 'ink', guide: false, ink: '#111111', paper: '#f4f1ea',
  marks: MARKS.map(() => ({ x: 0, y: 0, r: 0, s: 1, on: true })),
};

function load() {
  try {
    const s = JSON.parse(localStorage.getItem(KEY));
    if (s && s.marks && s.marks.length === MARKS.length) return { ...structuredClone(DEFAULT), ...s };
  } catch (e) {}
  return structuredClone(DEFAULT);
}
function save() { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} }

let state = load();
let selected = null, drag = null, shown = null, optimizing = false;

// ---- drawing

function frame(w, h) {
  const k = Math.min(w / VB.w, h / VB.h);
  return { w, h, k, ox: (w - VB.w * k) / 2 - VB.x * k, oy: (h - VB.h * k) / 2 - VB.y * k };
}

function layer(fr) {
  const c = document.createElement('canvas');
  c.width = fr.w; c.height = fr.h;
  return c;
}

function place(g, i, fr) {
  const p = MARKS[i].pivot, t = state.marks[i];
  g.setTransform(fr.k, 0, 0, fr.k, fr.ox, fr.oy);
  g.translate(p[0] + t.x, p[1] + t.y);
  g.rotate(t.r * DEG);
  g.scale(t.s, t.s);
  g.translate(-p[0], -p[1]);
}

// one mark as a solid silhouette: its own parts never darken each other
function mask(i, fr, color) {
  const c = layer(fr), g = c.getContext('2d', { willReadFrequently: true });
  place(g, i, fr);
  g.fillStyle = color;
  for (const p of PATHS[i]) g.fill(p);
  return c;
}

// the pixels that two or more marks cover
function overlap(masks, fr, color) {
  const out = layer(fr), g = out.getContext('2d', { willReadFrequently: true });
  for (let i = 0; i < masks.length; i++) {
    for (let j = i + 1; j < masks.length; j++) {
      if (!masks[i] || !masks[j]) continue;
      const t = layer(fr), tg = t.getContext('2d');
      tg.drawImage(masks[i], 0, 0);
      tg.globalCompositeOperation = 'destination-in';
      tg.drawImage(masks[j], 0, 0);
      g.drawImage(t, 0, 0);
    }
  }
  if (color) {
    g.globalCompositeOperation = 'source-in';
    g.fillStyle = color;
    g.fillRect(0, 0, fr.w, fr.h);
  }
  return out;
}

function bounds(img) {
  const d = img.data, w = img.width, h = img.height;
  let x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (d[(y * w + x) * 4 + 3] > 127) {
        if (x < x0) x0 = x; if (x > x1) x1 = x;
        if (y < y0) y0 = y; if (y > y1) y1 = y;
      }
    }
  }
  return x1 < 0 ? null : { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
}

// ---- the target: a lambda glyph, cropped to its ink

function glyph(color) {
  const c = document.createElement('canvas'); c.width = c.height = 256;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.font = `italic 400 180px Palatino, 'Palatino Linotype', 'Times New Roman', serif`;
  g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillStyle = color;
  g.fillText(LAMBDA, 128, 140);
  const b = bounds(g.getImageData(0, 0, 256, 256));
  const out = document.createElement('canvas'); out.width = b.w; out.height = b.h;
  out.getContext('2d').drawImage(c, b.x, b.y, b.w, b.h, 0, 0, b.w, b.h);
  return out;
}
const GLYPH = glyph('#000'), GUIDE = glyph('#e03030');

const G = 64;
function grid(src, b) {
  const c = layer({ w: G, h: G }), g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(src, b.x, b.y, b.w, b.h, 0, 0, G, G);
  return g.getImageData(0, 0, G, G).data;
}
const GLYPH_GRID = grid(GLYPH, { x: 0, y: 0, w: GLYPH.width, h: GLYPH.height });

// how well the dark part matches the glyph: overlap over union after both
// are stretched to one box, less a cost for a wrong aspect
function score() {
  const fr = frame(160, 160);
  const masks = MARKS.map((_, i) => (state.marks[i].on ? mask(i, fr, '#000') : null));
  const ov = overlap(masks, fr);
  const b = bounds(ov.getContext('2d').getImageData(0, 0, fr.w, fr.h));
  if (!b) return { score: 0, box: null };
  const a = grid(ov, b);
  let both = 0, either = 0;
  for (let p = 3; p < a.length; p += 4) {
    const u = a[p] > 127, v = GLYPH_GRID[p] > 127;
    if (u && v) both++;
    if (u || v) either++;
  }
  const ra = b.w / b.h, rg = GLYPH.width / GLYPH.height;
  return {
    score: (both / either) * Math.sqrt(Math.min(ra / rg, rg / ra)),
    box: { x: (b.x - fr.ox) / fr.k, y: (b.y - fr.oy) / fr.k, w: b.w / fr.k, h: b.h / fr.k },
  };
}

const canvas = document.getElementById('stage');
const ctx = canvas.getContext('2d');

function draw() {
  const fr = frame(canvas.width, canvas.height);
  const masks = MARKS.map((_, i) => (state.marks[i].on ? mask(i, fr, state.ink) : null));
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.fillStyle = state.paper;
  ctx.fillRect(0, 0, fr.w, fr.h);
  if (state.view === 'ink') {
    ctx.globalAlpha = state.alpha;
    for (const m of masks) if (m) ctx.drawImage(m, 0, 0);
  } else {
    ctx.globalAlpha = 0.08;
    for (const m of masks) if (m) ctx.drawImage(m, 0, 0);
    ctx.globalAlpha = 1;
    ctx.drawImage(overlap(masks, fr, state.ink), 0, 0);
  }
  ctx.globalAlpha = 1;
  const s = score();
  if (state.guide && s.box) {
    ctx.setTransform(fr.k, 0, 0, fr.k, fr.ox, fr.oy);
    ctx.globalAlpha = 0.35;
    ctx.drawImage(GUIDE, s.box.x, s.box.y, s.box.w, s.box.h);
    ctx.globalAlpha = 1;
  }
  if (selected !== null && state.marks[selected].on) {
    place(ctx, selected, fr);
    ctx.strokeStyle = '#d03030';
    ctx.lineWidth = 1.5 / (fr.k * state.marks[selected].s);
    ctx.setLineDash([4 / fr.k, 3 / fr.k]);
    for (const p of PATHS[selected]) ctx.stroke(p);
    ctx.setLineDash([]);
  }
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  shown = { fr, masks };
  document.getElementById('score').textContent = (s.score * 100).toFixed(1) + '%';
  const link = document.getElementById('download');
  if (link.href) URL.revokeObjectURL(link.href);
  link.href = URL.createObjectURL(new Blob([svg()], { type: 'image/svg+xml' }));
}

function resize() {
  const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(r.width * dpr));
  canvas.height = Math.max(1, Math.round(r.height * dpr));
  draw();
}

// ---- export

function svg() {
  const groups = MARKS.map((m, i) => {
    const t = state.marks[i], p = m.pivot;
    if (!t.on) return '';
    const tr = `translate(${n2(p[0] + t.x)} ${n2(p[1] + t.y)}) rotate(${n2(t.r)}) scale(${+t.s.toFixed(4)}) translate(${n2(-p[0])} ${n2(-p[1])})`;
    const paths = m.paths.map((d) => `    <path d='${d}'/>`).join(`
`);
    return `  <g opacity='${state.alpha}' transform='${tr}'>
${paths}
  </g>
`;
  }).join('');
  return `<svg xmlns='http://www.w3.org/2000/svg' viewBox='${VB.x} ${VB.y} ${VB.w} ${VB.h}' fill='${state.ink}'>
${groups}</svg>
`;
}

// ---- panel

const updaters = [];
const $ = (id) => document.getElementById(id);

function el(tag, props = {}, kids = []) {
  const e = Object.assign(document.createElement(tag), props);
  for (const k of kids) e.append(k);
  return e;
}

function slider(label, min, max, step, get, set) {
  const range = el('input', { type: 'range', min, max, step });
  const num = el('input', { type: 'number', min, max, step });
  const put = (v) => { set(+v); save(); sync(); draw(); };
  range.oninput = () => put(range.value);
  num.onchange = () => put(num.value);
  updaters.push(() => { range.value = get(); num.value = n2(get()); });
  return el('div', { className: 'row' }, [label, range, num]);
}

function buildPanel() {
  $('alpha-row').replaceWith(slider('alpha', 0.05, 0.95, 0.01, () => state.alpha, (v) => (state.alpha = v)));
  const box = $('marks');
  MARKS.forEach((m, i) => {
    const t = () => state.marks[i];
    const on = el('input', { type: 'checkbox' });
    on.onchange = () => { t().on = on.checked; save(); draw(); };
    updaters.push(() => { on.checked = t().on; });
    const fs = el('fieldset', {}, [
      el('legend', {}, [on, ' ' + m.name]),
      slider('x', -60, 60, 0.25, () => t().x, (v) => (t().x = v)),
      slider('y', -60, 60, 0.25, () => t().y, (v) => (t().y = v)),
      slider('turn', -180, 180, 0.25, () => t().r, (v) => (t().r = v)),
      slider('size', 0.3, 2, 0.005, () => t().s, (v) => (t().s = v)),
    ]);
    fs.onpointerdown = () => { selected = i; sync(); draw(); };
    updaters.push(() => fs.classList.toggle('sel', selected === i));
    box.append(fs);
  });
  $('view').onchange = (e) => { state.view = e.target.value; save(); draw(); };
  $('guide').onchange = (e) => { state.guide = e.target.checked; save(); draw(); };
  $('ink').oninput = (e) => { state.ink = e.target.value; save(); draw(); };
  $('paper').oninput = (e) => { state.paper = e.target.value; save(); draw(); };
  updaters.push(() => {
    $('view').value = state.view; $('guide').checked = state.guide;
    $('ink').value = state.ink; $('paper').value = state.paper;
  });
  $('reset').onclick = () => { state = structuredClone(DEFAULT); save(); sync(); draw(); };
  $('show-json').onclick = () => { $('out').value = JSON.stringify(state, null, 1); };
  $('show-svg').onclick = () => { $('out').value = svg(); };
  $('apply').onclick = () => {
    try { state = { ...structuredClone(DEFAULT), ...JSON.parse($('out').value) }; save(); sync(); draw(); }
    catch (e) { $('out').value = 'Not JSON: ' + e.message; }
  };
  $('optimize').onclick = () => {
    optimizing = !optimizing;
    $('optimize').textContent = optimizing ? 'Stop' : 'Optimize';
    if (optimizing) optimize();
  };
}

function sync() { for (const u of updaters) u(); }

// ---- search: nudge one number at a time, keep what scores no worse

function optimize(steps = 800) {
  const keys = [['x', 1.5], ['y', 1.5], ['r', 3], ['s', 0.03]];
  let best = score().score, n = 0;
  function chunk() {
    for (let c = 0; c < 20 && n < steps && optimizing; c++, n++) {
      const live = state.marks.map((m, j) => (m.on ? j : -1)).filter((j) => j >= 0);
      const j = live[Math.floor(Math.random() * live.length)];
      const [key, step] = keys[Math.floor(Math.random() * keys.length)];
      const old = state.marks[j][key];
      let v = old + (Math.random() * 2 - 1) * step * (0.2 + (1 - n / steps));
      if (key === 's') v = Math.min(2, Math.max(0.3, v));
      state.marks[j][key] = v;
      const s = score().score;
      if (s >= best) best = s; else state.marks[j][key] = old;
    }
    sync(); draw();
    if (optimizing && n < steps) requestAnimationFrame(chunk);
    else { optimizing = false; $('optimize').textContent = 'Optimize'; save(); }
  }
  chunk();
}

// ---- pointer and keys

function pix(e) {
  const r = canvas.getBoundingClientRect();
  return [(e.clientX - r.left) * canvas.width / r.width, (e.clientY - r.top) * canvas.height / r.height];
}

function hit(px, py) {
  for (let i = MARKS.length - 1; i >= 0; i--) {
    const m = shown && shown.masks[i];
    if (m && m.getContext('2d').getImageData(Math.floor(px), Math.floor(py), 1, 1).data[3] > 0) return i;
  }
  return null;
}

function pivotPx(i) {
  const fr = shown.fr, p = MARKS[i].pivot, t = state.marks[i];
  return [fr.ox + (p[0] + t.x) * fr.k, fr.oy + (p[1] + t.y) * fr.k];
}

canvas.addEventListener('pointerdown', (e) => {
  const [px, py] = pix(e);
  selected = hit(px, py);
  if (selected !== null) {
    canvas.setPointerCapture(e.pointerId);
    drag = { i: selected, px, py, start: { ...state.marks[selected] }, turn: e.shiftKey };
  }
  sync(); draw();
});

canvas.addEventListener('pointermove', (e) => {
  if (!drag) return;
  const [px, py] = pix(e), t = state.marks[drag.i];
  if (drag.turn) {
    const [cx, cy] = pivotPx(drag.i);
    const a = Math.atan2(py - cy, px - cx) - Math.atan2(drag.py - cy, drag.px - cx);
    t.r = drag.start.r + a / DEG;
  } else {
    t.x = drag.start.x + (px - drag.px) / shown.fr.k;
    t.y = drag.start.y + (py - drag.py) / shown.fr.k;
  }
  sync(); draw();
});

canvas.addEventListener('pointerup', () => { if (drag) { drag = null; save(); } });

canvas.addEventListener('wheel', (e) => {
  if (selected === null) return;
  e.preventDefault();
  const t = state.marks[selected];
  t.s = Math.min(2, Math.max(0.3, t.s * Math.exp(-e.deltaY * 0.001)));
  save(); sync(); draw();
}, { passive: false });

document.addEventListener('keydown', (e) => {
  if (selected === null || ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) return;
  const t = state.marks[selected], d = e.shiftKey ? 2 : 0.25;
  const moves = { ArrowLeft: [-d, 0], ArrowRight: [d, 0], ArrowUp: [0, -d], ArrowDown: [0, d] };
  if (!moves[e.key]) return;
  e.preventDefault();
  if (e.altKey) t.r += moves[e.key][0] + moves[e.key][1];
  else { t.x += moves[e.key][0]; t.y += moves[e.key][1]; }
  save(); sync(); draw();
});

buildPanel();
sync();
new ResizeObserver(resize).observe(canvas);
