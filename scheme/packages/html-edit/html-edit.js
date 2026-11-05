// html-edit.js: the page half of html-edit (html-edit.scm). The page is the
// HTML file itself; every element in its body carries data-hs="START,END",
// its bytes in the source. The page edits its own DOM, inspector style, and
// sends each finished change back as one byte range of the source: an
// element's text when it loses focus, a delete, an insert. It keeps its own
// copy of the source bytes, so it moves every range itself.
(function () {
  "use strict";
  const API = "_compos/app";
  const enc = new TextEncoder(), dec = new TextDecoder();
  const VOID = new Set("area base br col embed hr img input link meta param source track wbr".split(" "));
  const RAW = new Set(["script", "style"]);
  const INLINE = new Set("a abbr b bdi bdo cite code data dfn em i kbd mark q s samp small span strong sub sup time u var".split(" "));
  const OURS = new Set(["data-hs", "contenteditable"]);
  const SIZE_KEYS = { "=": 1, "+": 1, "-": -1, "_": -1, "0": 0 };
  let src = null;
  let sel = null, hover = null, editing = null, before = null;
  let queue = Promise.resolve();
  let pending = false;

  const post = (m) => fetch(API, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(m) })
    .then((r) => r.json()).catch(() => null);
  // The file changes under the page (the source window, an undo, an
  // agent). The page never reloads, which would lose the text being typed:
  // it takes the new markup in place, once no text is open.
  const drawnFrom = document.currentScript && document.currentScript.dataset.hash;
  let headHTML = document.head.innerHTML;
  function take(j) {
    src = enc.encode(j.source);
    const doc = new DOMParser().parseFromString(j.page, "text/html");
    doc.querySelectorAll('script[src="html-edit.js"], link[href="html-edit.css"]').forEach((n) => n.remove());
    sel = hover = null;
    document.body.replaceChildren(...Array.from(doc.body.childNodes).map((n) => document.adoptNode(n)));
    if (doc.head.innerHTML !== headHTML) {
      headHTML = doc.head.innerHTML;
      const ours = Array.from(document.head.querySelectorAll('link[href="html-edit.css"], script'));
      document.head.replaceChildren(...Array.from(doc.head.childNodes).map((n) => document.adoptNode(n)), ...ours);
    }
    document.querySelectorAll(".embed-x[data-hs]").forEach(drawEmbed);
  }
  const fetchSource = () => fetch(API).then((r) => r.json());
  function refresh() {
    pending = false;
    return fetchSource().then(take).catch(() => note("The page cannot read its file"));
  }
  // later, when no text is open: the open text goes back first
  function refreshWhenIdle() {
    pending = true;
    if (!editing) queue = queue.then(refresh);
  }
  fetchSource().then((j) => {
    if (drawnFrom && j.hash && j.hash !== drawnFrom) take(j);
    else src = enc.encode(j.source);
  }).catch(() => note("The page cannot read its file: edits will not save"));
  addEventListener("message", (ev) => {
    const m = ev.data;
    if (m && m.compos === "message" && m.data && m.data.changed) refreshWhenIdle();
  });

  const blen = (t) => enc.encode(t).length;
  const range = (el) => {
    const v = el.getAttribute("data-hs");
    if (!v) return null;
    const [s, e] = v.split(",").map(Number);
    return { s, e };
  };
  const setRange = (el, s, e) => el.setAttribute("data-hs", s + "," + e);
  const marked = (n) => {
    const el = n && (n.nodeType === 1 ? n : n.parentElement);
    return el && el.closest ? el.closest("[data-hs]") : null;
  };
  const up = (el) => marked(el && el.parentElement);
  const kids = (el) => Array.from(el.children).filter((c) => c.hasAttribute("data-hs"));
  const sibling = (el, d) => { const ks = el.parentElement ? kids(el.parentElement) : []; return ks[ks.indexOf(el) + d] || null; };
  const ancestors = (el) => {
    const out = new Set();
    for (let p = el; p; p = p.parentElement) if (p.hasAttribute && p.hasAttribute("data-hs")) out.add(p);
    return out;
  };
  const tagOf = (el) => el.tagName.toLowerCase();

  // the inner bytes of EL: after its start tag, before its end tag
  function inner(el) {
    const { s, e } = range(el);
    let i = s, q = 0;
    for (; i < e; i++) {
      const c = src[i];
      if (q) { if (c === q) q = 0; }
      else if (c === 34 || c === 39) q = c;
      else if (c === 62) break;
    }
    const is = i + 1, tag = tagOf(el);
    if (VOID.has(tag)) return { is: e, ie: e };
    let j = e - 1;
    while (j > is && src[j] !== 60) j--;
    const close = "</" + tag;
    const seen = dec.decode(src.slice(j, Math.min(e, j + close.length))).toLowerCase();
    return { is, ie: seen === close ? j : e };
  }

  // NODES as HTML from byte BASE: the text, and the range each element in
  // it will hold once the text is in the source
  const escText = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\u00a0/g, "&nbsp;");
  const escAttr = (t) => t.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
  const startTag = (el) => {
    let open = "<" + tagOf(el);
    for (const a of el.attributes) {
      if (OURS.has(a.name)) continue;
      open += a.value === "" ? " " + a.name : " " + a.name + '="' + escAttr(a.value) + '"';
    }
    return open + ">";
  };
  function serialize(nodes, base, raw) {
    let out = "", n = 0;
    const marks = [];
    const put = (t) => { out += t; n += blen(t); };
    const walk = (nd, rawText) => {
      if (nd.nodeType === 3) return put(rawText ? nd.data : escText(nd.data));
      if (nd.nodeType === 8) return put("<!--" + nd.data + "-->");
      if (nd.nodeType !== 1) return;
      const tag = tagOf(nd), s = base + n;
      put(startTag(nd));
      if (!VOID.has(tag)) {
        for (const c of nd.childNodes) walk(c, RAW.has(tag));
        put("</" + tag + ">");
      }
      marks.push([nd, s, base + n]);
    };
    for (const nd of nodes) walk(nd, raw);
    return { text: out, marks };
  }

  // Replace source bytes S..E with TEXT: here at once, in the editor in
  // turn. ANC hold the change, so their ends move; every element after it
  // moves whole; MARKS are the ranges of the elements TEXT holds. CS..CE is
  // the source around the change, which finds it again if the file moved.
  function apply(s, e, text, anc, marks, cs = s, ce = e) {
    const old = dec.decode(src.slice(s, e));
    const ctx = dec.decode(src.slice(cs, ce));
    const nb = enc.encode(text), d = nb.length - (e - s);
    const next = new Uint8Array(src.length + d);
    next.set(src.subarray(0, s));
    next.set(nb, s);
    next.set(src.subarray(e), s + nb.length);
    src = next;
    if (d !== 0) {
      for (const el of document.querySelectorAll("[data-hs]")) {
        const r = range(el);
        if (anc.has(el)) setRange(el, r.s, r.e + d);
        else if (r.s >= e) setRange(el, r.s + d, r.e + d);
      }
    }
    for (const [el, a, b] of marks) setRange(el, a, b);
    queue = queue.then(() => post({ op: "replace", s, e, old, text, ctx, ctx_s: cs })).then((j) => {
      if (!j || !j.ok) { note("That edit no longer fits the file, so the page takes the file as it is"); refreshWhenIdle(); }
      else if (j.moved) refreshWhenIdle();
    });
  }

  function commitText(host) {
    const { is, ie } = inner(host);
    const { text, marks } = serialize(Array.from(host.childNodes), is, RAW.has(tagOf(host)));
    apply(is, ie, text, ancestors(host), marks);
  }

  // a line that holds only S..E goes with it
  function wholeLines(s, e) {
    let a = s, b = e;
    while (a > 0 && (src[a - 1] === 32 || src[a - 1] === 9)) a--;
    while (b < src.length && (src[b] === 32 || src[b] === 9)) b++;
    if ((a === 0 || src[a - 1] === 10) && (b === src.length || src[b] === 10)) return [a, Math.min(b + 1, src.length)];
    return [s, e];
  }

  function remove(el) {
    const r = range(el);
    const [s, e] = wholeLines(r.s, r.e);
    const anc = ancestors(el.parentElement);
    el.remove();
    apply(s, e, "", anc, []);
    select(null);
  }

  // the text size of EL: STEP 1 a size up, -1 a size down, 0 the page's own.
  // Only EL's start tag changes in the source.
  function resize(el, step) {
    const { s } = range(el), { is } = inner(el);
    if (step === 0) el.style.removeProperty("font-size");
    else {
      const px = parseFloat(getComputedStyle(el).fontSize);
      el.style.fontSize = Math.max(6, Math.round(px * (step > 0 ? 1.1 : 1 / 1.1))) + "px";
    }
    if (el.getAttribute("style") === "") el.removeAttribute("style");
    apply(s, is, startTag(el), ancestors(el), []);
  }

  // put EL after X, on a line of its own at X's indent
  function insertAfter(x, el) {
    const { s, e } = range(x);
    let a = s;
    while (a > 0 && (src[a - 1] === 32 || src[a - 1] === 9)) a--;
    const prefix = "\n" + (a === 0 || src[a - 1] === 10 ? dec.decode(src.slice(a, s)) : "");
    x.after(el);
    const { text, marks } = serialize([el], e + blen(prefix));
    apply(e, e, prefix + text, ancestors(x.parentElement), marks, s, e);
  }

  // the block a paste goes after: inline elements stand in their block
  function blockOf(el) {
    while (el && INLINE.has(tagOf(el)) && up(el)) el = up(el);
    return el;
  }

  const hasText = (el) => Array.from(el.childNodes).some((c) => c.nodeType === 3 && c.data.trim() !== "");
  // the element whose text a click edits: inline text belongs to its block
  function textHost(n) {
    let el = marked(n);
    if (!el || !hasText(el)) return null;
    while (INLINE.has(tagOf(el)) && up(el) && hasText(up(el))) el = up(el);
    return el;
  }

  // what a copy editor works on: text, or a picture or an embed to remove.
  // Layout (the divs that only hold other things) never lights up.
  function content(n) {
    const host = textHost(n);
    if (host) return host;
    const el = n && (n.nodeType === 1 ? n : n.parentElement);
    const media = el && el.closest && el.closest("img[data-hs], .embed[data-hs]");
    return media || null;
  }

  // --- the marks: hover, selection, a note -------------------------------
  const ui = (id) => {
    const d = document.createElement("div");
    d.id = id;
    d.setAttribute("data-he-ui", "");
    document.documentElement.appendChild(d);
    return d;
  };
  const hoverBox = ui("he-hover"), selBox = ui("he-sel"), noteBox = ui("he-note");
  let noteTimer = null;
  function note(t) {
    noteBox.textContent = t;
    noteBox.style.display = "block";
    clearTimeout(noteTimer);
    noteTimer = setTimeout(() => { noteBox.style.display = "none"; }, 2500);
  }
  function place(box, el) {
    if (!el || !el.isConnected) { box.style.display = "none"; return null; }
    // a little air around the mark, so it never touches the text
    const r = el.getBoundingClientRect(), pad = 4;
    Object.assign(box.style, { display: "block", left: r.left - pad + "px", top: r.top - pad + "px",
      width: r.width + 2 * pad + "px", height: r.height + 2 * pad + "px" });
    return r;
  }
  function frame() {
    place(hoverBox, hover && hover !== sel && hover !== editing ? hover : null);
    place(selBox, editing ? null : sel);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  function select(el) {
    sel = el;
    if (el) el.scrollIntoView({ block: "nearest" });
  }

  // --- text: the caret goes in on a click, the text goes back on blur ----
  function startEdit(host) {
    editing = host;
    sel = host;
    host.setAttribute("contenteditable", "true");
    before = host.innerHTML;
    host.addEventListener("blur", () => { if (editing === host) finishEdit(); }, { once: true });
  }
  function finishEdit() {
    const host = editing;
    if (!host) return;
    editing = null;
    host.removeAttribute("contenteditable");
    if (host.isConnected && src && host.innerHTML !== before) commitText(host);
    if (pending) queue = queue.then(refresh);
  }
  function caretAtEnd(host) {
    host.focus();
    const r = document.createRange();
    r.selectNodeContents(host);
    r.collapse(false);
    const s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
  }

  // Option or Cmd (M in the editor) marks any element, the layout too
  const picking = (ev) => ev.altKey || ev.metaKey;
  addEventListener("mousemove", (ev) => { hover = picking(ev) ? marked(ev.target) : content(ev.target); }, true);
  addEventListener("mouseleave", () => { hover = null; });
  addEventListener("dragstart", (ev) => ev.preventDefault(), true);
  // a link is text to edit here, not a way out of the page
  addEventListener("click", (ev) => { if (ev.target.closest && ev.target.closest("a")) ev.preventDefault(); }, true);
  addEventListener("mousedown", (ev) => {
    parent.postMessage({ compos: "request-focus" }, "*");
    if (editing && editing.contains(ev.target)) return;
    finishEdit();
    const host = !picking(ev) && textHost(ev.target);
    if (host) { startEdit(host); return; }
    // the page takes the keyboard, so Delete reaches it, not the editor
    ev.preventDefault();
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    window.focus();
    select(picking(ev) ? marked(ev.target) : content(ev.target));
  }, true);

  addEventListener("keydown", (ev) => {
    const mod = ev.metaKey || ev.ctrlKey;
    // in text, Cmd-arrows move the caret; the app bridge, which listens
    // after this, would hand them to the editor as window motion
    if (editing && ev.metaKey && /^Arrow/.test(ev.key)) { ev.stopImmediatePropagation(); return; }
    // Cmd-+ and Cmd-- size the block's text, in it or selected; Cmd-0 undoes it
    const step = mod ? SIZE_KEYS[ev.key] : undefined;
    const block = editing || sel;
    if (step !== undefined && block && src && !VOID.has(tagOf(block))) {
      ev.preventDefault();
      ev.stopImmediatePropagation();
      resize(block, step);
      return;
    }
    if (editing) {
      // only Escape leaves the text: Enter is a new line in it
      if (ev.key === "Escape") {
        ev.preventDefault();
        const host = editing;
        finishEdit();
        host.blur();
        select(host);
      }
      return;
    }
    if (mod && ev.key.toLowerCase() === "z") {
      ev.preventDefault();
      queue = queue.then(() => post({ op: "undo" }));
      return;
    }
    if (!sel || mod) return;
    switch (ev.key) {
      case "Backspace": case "Delete": ev.preventDefault(); if (src) remove(sel); break;
      case "Escape": ev.preventDefault(); select(null); break;
      // the arrows walk the elements: out, in, and along
      case "ArrowUp": case "ArrowDown": case "ArrowLeft": case "ArrowRight": {
        const to = ev.key === "ArrowUp" ? up(sel) : ev.key === "ArrowDown" ? kids(sel)[0] : sibling(sel, ev.key === "ArrowRight" ? 1 : -1);
        ev.preventDefault();
        ev.stopImmediatePropagation();
        if (to) select(to);
        break;
      }
      case "Enter": {
        const host = hasText(sel) ? sel : null;
        if (host) { ev.preventDefault(); startEdit(host); caretAtEnd(host); }
        break;
      }
    }
  }, true);

  // --- paste: an image, an X post or a YouTube video goes after the block --
  const X_URL = /^https?:\/\/(?:mobile\.)?(?:x|twitter)\.com\/[A-Za-z0-9_]+\/status(?:es)?\/\d+/;
  const YT_URL = /^https?:\/\/(?:(?:www|m)\.)?(?:youtube\.com\/(?:watch\?(?:[^ ]*&)?v=|shorts\/|live\/|embed\/)|youtu\.be\/)([A-Za-z0-9_-]{11})/;
  function embedFor(t) {
    if (!t || /\s/.test(t)) return null;
    let m = t.match(X_URL);
    if (m) {
      const d = document.createElement("div");
      d.className = "embed embed-x";
      d.innerHTML = '<blockquote class="twitter-tweet"><a href="' + escAttr(m[0]) + '">' + escText(m[0]) +
        '</a></blockquote><script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>';
      return d;
    }
    m = t.match(YT_URL);
    if (m) {
      const d = document.createElement("div");
      d.className = "embed embed-youtube";
      d.innerHTML = '<iframe src="https://www.youtube-nocookie.com/embed/' + m[1] + '" title="YouTube video" ' +
        'style="width:100%;aspect-ratio:16/9;border:0" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen></iframe>';
      return d;
    }
    return null;
  }
  // a script set by innerHTML never runs: the page loads X's itself
  function drawEmbed(el) {
    if (!el.classList.contains("embed-x")) return;
    const draw = () => window.twttr && window.twttr.widgets && window.twttr.widgets.load(el);
    if (window.twttr) return draw();
    const s = document.createElement("script");
    s.src = "https://platform.twitter.com/widgets.js";
    s.onload = draw;
    document.head.appendChild(s);
  }
  // a screenshot is 5K wide and megabytes big: the page sends a WebP no
  // wider than the site needs
  const MAX_WIDTH = 2560;
  const readImage = (file) => createImageBitmap(file).then((bmp) => {
    const w = Math.min(bmp.width, MAX_WIDTH), h = Math.round(bmp.height * w / bmp.width);
    const c = document.createElement("canvas");
    c.width = w;
    c.height = h;
    c.getContext("2d").drawImage(bmp, 0, 0, w, h);
    return { data: c.toDataURL("image/webp", 0.82).split(",")[1], mime: "image/webp", width: w, height: h };
  });

  addEventListener("paste", (ev) => {
    const cd = ev.clipboardData;
    if (!cd || !src) return;
    const item = Array.from(cd.items || []).find((i) => i.kind === "file" && i.type.startsWith("image/"));
    const file = item && item.getAsFile();
    const text = cd.getData("text/plain") || "";
    const embed = !file && embedFor(text.trim());
    const anchor = blockOf(editing || sel);
    if (file || embed) {
      ev.preventDefault();
      if (!anchor) { note("Select an element first: the paste goes after it"); return; }
      if (editing) { const h = editing; finishEdit(); h.blur(); }
      if (embed) { insertAfter(anchor, embed); drawEmbed(embed); select(embed); return; }
      note("Saving the image…");
      let size = null;
      readImage(file).then((img) => { size = img; return post({ op: "image", data: img.data, mime: img.mime }); }).then((j) => {
        if (!j || !j.src) { note("The image was not saved"); return; }
        note("Image saved as " + j.src);
        const el = document.createElement("img");
        el.setAttribute("src", j.src);
        el.setAttribute("width", String(size.width));
        el.setAttribute("height", String(size.height));
        el.setAttribute("alt", "");
        el.setAttribute("style", "max-width:100%;height:auto");
        insertAfter(anchor, el);
        select(el);
      });
      return;
    }
    // text comes in plain: the page's markup stays the page's
    if (editing) { ev.preventDefault(); document.execCommand("insertText", false, text); return; }
    if (anchor && text.trim()) {
      ev.preventDefault();
      const p = document.createElement("p");
      p.textContent = text.trim();
      insertAfter(anchor, p);
      select(p);
    }
  }, true);
})();
