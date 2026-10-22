// Compos homepage: reveals, the apps tabs and the film.
(function () {
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // a section wakes the first time it comes into view
  var io = new IntersectionObserver(function (es) {
    es.forEach(function (e) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    });
  }, { threshold: 0.3 });
  document.querySelectorAll('.rule, .map, .log, .ask').forEach(function (el) { io.observe(el); });

  // Reconnect when the editor replaces the gallery markup.
  var currentGallery = null, cleanupGallery = null;
  function initGallery() {
    var nextGallery = document.querySelector('.gal');
    if (nextGallery === currentGallery) return;
    if (cleanupGallery) { cleanupGallery(); cleanupGallery = null; }
    currentGallery = nextGallery;
    if (!nextGallery) return;
  // Rotate the app screenshots while the gallery is being read.
  var tabs = Array.prototype.slice.call(document.querySelectorAll('.gal-tabs [role=tab]'));
  var gallery = nextGallery;
  var galleryTimer = null, galleryVisible = false;
  var galleryPaused = reduce, galleryIndex = 0;

  function scheduleGallery() {
    clearTimeout(galleryTimer);
    galleryTimer = null;
    if (!gallery || tabs.length < 2 || galleryPaused || !galleryVisible || document.hidden) return;
    galleryTimer = setTimeout(function () {
      pick(tabs[(galleryIndex + 1) % tabs.length], false, 1);
    }, 6000);
  }
  function plateOf(t) { return document.getElementById(t.getAttribute('aria-controls')); }
  // DIR 1 slides the new plate in from the right, -1 from the left; without
  // it the plate's place in the row decides
  function pick(t, focus, dir) {
    var from = galleryIndex, to = tabs.indexOf(t);
    dir = dir || (to > from ? 1 : -1);
    if (to !== from) {
      // the incoming plate jumps to its side first, then slides in
      var inc = plateOf(t), out = plateOf(tabs[from]);
      inc.classList.add('snap');
      inc.classList.toggle('before', dir < 0);
      void inc.offsetWidth;
      inc.classList.remove('snap');
      out.classList.toggle('before', dir > 0);
    }
    galleryIndex = to;
    tabs.forEach(function (x) {
      var on = x === t;
      x.setAttribute('aria-selected', on ? 'true' : 'false');
      x.tabIndex = on ? 0 : -1;
      plateOf(x).classList.toggle('on', on);
    });
    if (focus) t.focus();
    scheduleGallery();
  }
  tabs.forEach(function (t, i) {
    if (t.getAttribute('aria-selected') === 'true') galleryIndex = i;
    t.addEventListener('click', function () { pick(t); });
    t.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault();
        pick(tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length], true, e.key === 'ArrowRight' ? 1 : -1);
      }
    });
  });
  if (gallery && tabs.length > 1) {
    // a carousel: arrows on the picture, and a swipe either way
    var slides = gallery.querySelector('.slides');
    function step(d) { pick(tabs[(galleryIndex + d + tabs.length) % tabs.length], false, d); }
    var nav = document.createElement('div');
    nav.className = 'slide-nav';
    [['prev', -1, '\u2039', 'previous app'], ['next', 1, '\u203a', 'next app']].forEach(function (b) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = b[0];
      btn.textContent = b[2];
      btn.setAttribute('aria-label', b[3]);
      btn.addEventListener('click', function () { step(b[1]); });
      nav.appendChild(btn);
    });
    slides.appendChild(nav);
    var downX = null;
    slides.addEventListener('pointerdown', function (e) { downX = e.clientX; });
    slides.addEventListener('pointerup', function (e) {
      if (downX === null) return;
      var dx = e.clientX - downX;
      downX = null;
      if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1);
    });
    slides.addEventListener('pointercancel', function () { downX = null; });
    document.addEventListener('visibilitychange', scheduleGallery);
    var galleryObserver = new IntersectionObserver(function (es) {
      galleryVisible = es[0].isIntersecting;
      scheduleGallery();
    }, { threshold: 0.1 });
    galleryObserver.observe(slides);
    cleanupGallery = function () {
      clearTimeout(galleryTimer);
      galleryObserver.disconnect();
      document.removeEventListener('visibilitychange', scheduleGallery);
    };
  }

  }
  initGallery();
  new MutationObserver(initGallery).observe(document.body, { childList: true, subtree: true });

  // the film: five scenes, need -> ask -> work -> keep -> let go
  var film = document.getElementById('film');
  if (!film) return;
  var ctl = document.getElementById('film-ctl');
  var playBtn = document.getElementById('film-play');
  var steps = ctl.querySelectorAll('.stepb');
  var DUR = [0, 5000, 5600, 8000, 5400, 5400];
  var ECHO = ['', 'Ready.', 'sentry-mode is new - 2 views, 3 keys', 'RET - ATS-1T', 'ATS-1T resolved by agent - 2 changes recorded', 'group sentry closed - 5 buffers kept'];
  var scene = 1, timers = [], playing = !reduce, visible = false;
  var msgs = film.querySelectorAll('.msg');
  var echo = film.querySelector('.echo-msg');
  var cur = film.querySelector('.row.cur');
  var btnA = film.querySelector('.btn-a'), btnR = film.querySelector('.btn-r');
  var status = film.querySelector('.kv-status');
  var note = film.querySelector('.fm-note');
  var dot = film.querySelector('.pdot');
  dot.style.left = '0'; dot.style.top = '0';

  function later(ms, fn) { timers.push(setTimeout(fn, ms)); }
  function clear() { timers.forEach(clearTimeout); timers = []; }

  function type(el, instant) {
    var text = el.dataset.full || el.textContent;
    el.dataset.full = text;
    if (instant) { el.textContent = text; return; }
    el.textContent = '';
    var n = 0;
    (function tick() {
      n++;
      el.textContent = text.slice(0, n);
      if (n < text.length) later(26 + Math.random() * 44, tick);
    })();
  }

  function fly() {
    var shown = film.querySelectorAll('.w-chat .msg.show');
    var src = shown[shown.length - 1];
    var fr = film.getBoundingClientRect(), b = cur.getBoundingClientRect();
    if (!src || !b.width) return;
    var a = src.getBoundingClientRect();
    var x0 = a.left - fr.left + 12, y0 = a.top - fr.top + a.height / 2;
    var x1 = b.right - fr.left - 40, y1 = b.top - fr.top + b.height / 2;
    function at(x, y, s) { return 'translate(' + x + 'px,' + y + 'px) scale(' + s + ')'; }
    dot.animate([
      { opacity: 0, transform: at(x0, y0, .5) },
      { opacity: 1, transform: at(x0, y0, 1), offset: .15 },
      { opacity: 1, transform: at(x1, y1, 1), offset: .8 },
      { opacity: 0, transform: at(x1, y1, 2.4) }
    ], { duration: 1300, easing: 'cubic-bezier(.5, 0, .2, 1)' });
  }

  function render(s, instant) {
    clear();
    scene = s;
    var cls = 'film';
    for (var k = 1; k <= s; k++) cls += ' at-' + k;
    if (reduce) cls += ' reduced';
    film.className = cls;
    film.dataset.scene = s;
    echo.textContent = ECHO[s];
    note.textContent = s >= 4 ? '1 resolved' : '';
    status.textContent = s >= 4 ? 'resolved' : 'unresolved';
    btnA.classList.remove('press');
    btnR.classList.remove('press');
    msgs.forEach(function (m) {
      var at = +m.dataset.at, typed = m.hasAttribute('data-type');
      m.classList.remove('show');
      if (at < s || (at === s && instant)) {
        m.classList.add('show');
        if (typed) type(m, true);
      } else if (at === s) {
        if (typed) m.textContent = '';
        later(+m.dataset.delay, function () { m.classList.add('show'); if (typed) type(m); });
      }
    });
    if (!instant && s === 3) {
      later(1000, function () { btnA.classList.add('press'); echo.textContent = 'a - ask agent about ATS-1T'; });
      later(1700, function () { btnA.classList.remove('press'); });
    }
    if (!instant && s === 4) {
      later(1900, fly);
      later(2300, function () { btnR.classList.add('press'); });
    }
    steps.forEach(function (b) { b.removeAttribute('aria-current'); });
    void ctl.offsetWidth;
    steps.forEach(function (b) { if (+b.dataset.go === s) b.setAttribute('aria-current', 'step'); });
    ctl.style.setProperty('--dur', DUR[s] + 'ms');
    var running = playing && visible;
    ctl.classList.toggle('paused', !running);
    if (running) later(DUR[s], function () { render(s % 5 + 1); });
  }

  function setPlaying(p) {
    playing = p;
    playBtn.textContent = p ? 'pause' : 'play';
    playBtn.setAttribute('aria-pressed', p ? 'false' : 'true');
    render(scene, !p);
  }

  playBtn.addEventListener('click', function () { setPlaying(!playing); });
  steps.forEach(function (b) {
    b.addEventListener('click', function () { render(+b.dataset.go, !playing); });
  });

  new IntersectionObserver(function (es) {
    var v = es[0].isIntersecting;
    if (v === visible) return;
    visible = v;
    if (playing) render(scene, !v);
  }, { threshold: 0.45 }).observe(film);
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) { visible = false; render(scene, true); return; }
    var r = film.getBoundingClientRect();
    visible = r.top < innerHeight * .7 && r.bottom > innerHeight * .3;
    if (playing) render(scene, !visible);
  });

  var pin = +new URLSearchParams(location.search).get('scene');
  if (pin >= 1 && pin <= 5) { playing = false; playBtn.textContent = 'play'; playBtn.setAttribute('aria-pressed', 'true'); render(pin, true); return; }
  if (reduce) { playing = false; playBtn.textContent = 'play'; playBtn.setAttribute('aria-pressed', 'true'); render(3, true); }
  else render(1, true);
})();
