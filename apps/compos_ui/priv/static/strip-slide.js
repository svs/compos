// The slide that a strip scroll shows (layout-forward, layout-backward,
// and a focus move past the frame edge). The daemon marks the render with
// a new data-slide token on c-windows: "forward:N" or "backward:N".
//
// Before LiveView patches c-windows, `before` copies the old panes. After
// the patch, the copy sits one pane-step behind the new panes, and the
// two slide together. The pane that leaves goes out one side, the pane
// that arrives comes in the other, and a pane on both sides stays where
// the eye is. The user sees which buffer left and which buffer arrived.
//
// A group switch marks "down:N" or "up:N": the groups stack in the
// order of their tabs, and the whole desk moves by the frame's height.
(() => {
  let current = null;

  // the duration the setting asks for (--chrome-motion); 0 is off
  function duration() {
    if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return 0;
    const v = getComputedStyle(document.documentElement).getPropertyValue("--chrome-motion").trim();
    const n = parseFloat(v);
    if (!(n > 0)) return 0;
    return v.endsWith("ms") ? n : n * 1000;
  }

  // the panes in screen order; a preview card floats and does not scroll
  const panes = (root) =>
    [...root.querySelectorAll("c-window.window")].filter(
      (w) => !w.classList.contains("listing-preview")
    );

  // The axis and the distance of one pane-step. Panes that share one left
  // edge are rows, and the strip moves vertically. One pane moves by the
  // frame's width.
  // The distance is in the frame's own pixels: a zoomed frame (c-frame's
  // zoom) measures larger on the screen than a transform inside it moves.
  function step(root, forward, desk) {
    const s = measure(root, forward, desk);
    const k = (root.offsetWidth ? root.getBoundingClientRect().width / root.offsetWidth : 1) || 1;
    return s && { vertical: s.vertical, d: s.d / k };
  }

  function measure(root, forward, desk) {
    const box = root.getBoundingClientRect();
    if (desk) return { vertical: true, d: box.height };
    const rs = panes(root).map((w) => w.getBoundingClientRect());
    if (rs.length === 0) return null;
    const vertical = rs.length > 1 && rs.every((r) => Math.abs(r.left - rs[0].left) < 1);
    if (rs.length === 1) return { vertical: false, d: box.width };
    const n = rs.length;
    const d = vertical
      ? (forward ? rs[1].top - rs[0].top : rs[n - 1].bottom - rs[n - 2].bottom)
      : (forward ? rs[1].left - rs[0].left : rs[n - 1].right - rs[n - 2].right);
    return d > 0 ? { vertical, d } : null;
  }

  // the scroll offsets of the old panes, by element index, so the copy
  // shows each buffer at the place the user left it
  function scrolls(root) {
    const out = [];
    root.querySelectorAll("*").forEach((el, i) => {
      if (el.scrollTop || el.scrollLeft) out.push([i, el.scrollTop, el.scrollLeft]);
    });
    return out;
  }

  function ghostOf(root) {
    const g = root.cloneNode(true);
    g.removeAttribute("data-slide");
    g.removeAttribute("role");
    g.querySelectorAll("[id]").forEach((el) => el.removeAttribute("id"));
    g.querySelectorAll("[phx-hook]").forEach((el) => el.removeAttribute("phx-hook"));
    g.querySelectorAll("[contenteditable]").forEach((el) => el.removeAttribute("contenteditable"));
    g.setAttribute("aria-hidden", "true");
    g.inert = true;
    g.classList.add("strip-ghost");
    return g;
  }

  function finish() {
    if (!current) return;
    const c = current;
    current = null;
    c.anim.cancel();
    c.ghost.remove();
  }

  function restore(ghost, offsets) {
    const all = ghost.querySelectorAll("*");
    offsets.forEach(([i, top, left]) => {
      const el = all[i];
      if (el) { el.scrollTop = top; el.scrollLeft = left; }
    });
  }

  function run(root, ghost, offsets, forward, s, ms) {
    const d = forward ? s.d : -s.d;
    const t = (v) => (s.vertical ? `translateY(${v}px)` : `translateX(${v}px)`);
    // the copy stands one step behind the new panes, in the old place
    ghost.style.transform = t(-d);
    root.appendChild(ghost);
    restore(ghost, offsets);
    // c-windows moves; the clip keeps the visible area on the frame's box
    const clip = (v) =>
      s.vertical ? `inset(${-v}px 0px ${v}px 0px)` : `inset(0px ${v}px 0px ${-v}px)`;
    const anim = root.animate(
      [
        { transform: t(d), clipPath: clip(d) },
        { transform: t(0), clipPath: clip(0) }
      ],
      { duration: ms, easing: "cubic-bezier(.2,.7,.2,1)" }
    );
    current = { anim, ghost, root, offsets };
    anim.onfinish = () => { if (current && current.anim === anim) finish(); };
  }

  // LiveView calls this for each element it updates, before the update.
  // It must stay cheap: every render passes here.
  function before(from, to) {
    if (from.tagName !== "C-WINDOWS") return;
    const token = to.getAttribute("data-slide");
    if (!token || token === from.getAttribute("data-slide")) return;
    // a walk of one window's stack is window-motion.js's
    if (token.startsWith("{")) return;
    finish();
    const ms = duration();
    if (!ms) return;
    const forward = !token.startsWith("backward") && !token.startsWith("up");
    const desk = token.startsWith("up") || token.startsWith("down");
    const s = step(from, forward, desk);
    if (!s) return;
    const ghost = ghostOf(from);
    const offsets = scrolls(from);
    // the patch is synchronous: the microtask sees the new panes, and the
    // browser paints no frame between the patch and the slide
    queueMicrotask(() => {
      if (from.isConnected) run(from, ghost, offsets, forward, s, ms);
    });
  }

  // A render during the slide removes the copy: the server does not know
  // it. LiveView calls this after each patch, and the copy goes back.
  function after() {
    if (!current || current.ghost.isConnected || !current.root.isConnected) return;
    current.root.appendChild(current.ghost);
    restore(current.ghost, current.offsets);
  }

  window.stripSlide = { before, after };
})();
