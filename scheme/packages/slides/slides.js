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
function select(n) {
  const thumbs = ov.querySelectorAll('.thumb');
  sel = Math.max(0, Math.min(thumbs.length - 1, n));
  thumbs.forEach((t, k) => t.classList.toggle('sel', k === sel));
  thumbs[sel].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}
function overview(on) {
  if (on === undefined) on = !ov.classList.contains('on');
  ov.classList.toggle('on', on);
  if (!on) return;
  ov.innerHTML = '';
  sections.forEach((s, n) => {
    const t = el('div', '', 'thumb');
    t.style.setProperty('--k', n);
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
  select(idx);
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
  // The same rendering loaded again (f remounts the frame): resume there.
  const done = () => { resuming = false; report(); };
  fetch('_compos/app').then(r => r.json()).then(at => {
    resuming = false;
    if (at && at.stamp === DATA.stamp && at.slide < sections.length) {
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
