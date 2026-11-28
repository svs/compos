// canvas-overview.js -- spatial HTML-in-Canvas overview of compos groups,
// panes, window stacks, and buffers.
(() => {
  const API = "_compos/app";

  // --- Feature detection for WICG HTML-in-Canvas (<canvas layoutsubtree>) ---
  const probe = document.createElement("canvas");
  const probeCtx = probe.getContext("2d");
  const CAPS = {
    layoutSubtree: "layoutSubtree" in HTMLCanvasElement.prototype,
    drawElementImage: Boolean(probeCtx && typeof probeCtx.drawElementImage === "function"),
    drawElement: Boolean(probeCtx && typeof probeCtx.drawElement === "function"),
    onpaint: "onpaint" in HTMLCanvasElement.prototype,
    requestPaint: typeof probe.requestPaint === "function",
    ua: navigator.userAgent
  };
  const DRAW_METHOD = CAPS.drawElementImage
    ? "drawElementImage"
    : CAPS.drawElement
      ? "drawElement"
      : null;
  const HIC_SUPPORTED = CAPS.layoutSubtree && Boolean(DRAW_METHOD);

  // --- State ---
  let renderMode = HIC_SUPPORTED ? "hic" : "dom";
  let scope = "group"; // "group" | "all"
  let snapshot = null;
  let searchQuery = "";
  let selectedCardId = null;

  const expandedPanes = new Set();     // "groupId::paneId"
  const expandedBufStacks = new Set(); // "groupId::windowKey"
  const expandedUnshown = new Set();   // "groupId::bufName"
  const liveBuffers = new Map();       // bufName -> preview object
  const pulseUntil = new Map();        // bufName -> perf.now() timestamp

  // Camera state (screenX = worldX * zoom + x)
  const cam = {
    x: 40, y: 76, zoom: 0.92,
    vx: 0, vy: 0,
    targetX: null, targetY: null, targetZoom: null
  };

  // Layout scene graph
  let scene = { groups: [], connectors: [], cards: [], bounds: { x: 0, y: 0, w: 800, h: 600 } };
  const cardDom = new Map();  // cardId -> { el, bodyEl, footEl, liveEl, titleEl, modEl, stackBtn, bufsEl, animX, animY }
  const cardById = new Map(); // cardId -> layout node

  // Telemetry
  let paintCount = 0;
  let liveUpdateCount = 0;
  let lastLiveBuf = "";
  let fpsFrames = 0;
  let fpsLast = performance.now();
  let fpsValue = 0;
  let drawErrors = 0;
  let lastDrawError = "";
  let rafHandle = 0;
  let dirtyPaint = true;
  let didInitialFit = false;

  // --- DOM scaffolding ---
  const mk = (tag, cls, parent, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  };

  const viewport = mk("div", null, document.body);
  viewport.id = "viewport";

  const canvas = mk("canvas", null, viewport);
  canvas.id = "stage";
  if (renderMode === "hic") {
    canvas.setAttribute("layoutsubtree", "");
    try { canvas.layoutSubtree = true; } catch (_) {}
  }
  const ctx = canvas.getContext("2d");

  const domLayer = mk("div", null, viewport);
  domLayer.id = "dom-layer";
  if (renderMode === "hic") domLayer.style.display = "none";

  // Minimap overlay
  const minimap = mk("canvas", null, document.body);
  minimap.id = "minimap";
  minimap.width = 220;
  minimap.height = 140;
  Object.assign(minimap.style, {
    position: "fixed",
    right: "12px",
    bottom: "12px",
    width: "220px",
    height: "140px",
    borderRadius: "10px",
    border: "1px solid var(--hud-border)",
    background: "var(--hud-bg)",
    backdropFilter: "blur(10px)",
    zIndex: "20",
    cursor: "pointer",
    boxShadow: "0 6px 20px rgba(0,0,0,0.32)"
  });
  const miniCtx = minimap.getContext("2d");

  // Top HUD
  const hud = mk("div", null, document.body);
  hud.id = "hud";

  const hudLeft = mk("div", "hud-group", hud);
  mk("span", "hud-title", hudLeft, "Canvas Overview");
  mk("span", "hud-sep", hudLeft);
  const btnThisGroup = mk("button", "hud-btn active", hudLeft, "This group");
  const btnAllGroups = mk("button", "hud-btn", hudLeft, "All groups");
  mk("span", "hud-sep", hudLeft);
  const btnExpandAll = mk("button", "hud-btn", hudLeft, "Expand stacks");
  const btnFit = mk("button", "hud-btn", hudLeft, "Fit");
  const btnPulse = mk("button", "hud-btn", hudLeft, "Pulse test");
  const searchInput = mk("input", "hud-search", hudLeft);
  searchInput.type = "search";
  searchInput.placeholder = "Filter buffers... (/)";

  const hudRight = mk("div", "hud-group", hud);
  const statusPill = mk("button", "hud-pill", hudRight);
  const statusDot = mk("span", "dot", statusPill);
  const statusText = mk("span", null, statusPill, "Loading...");

  // Diagnostics popover
  const diagPop = mk("div", null, document.body);
  diagPop.id = "diag-pop";

  const hint = mk("div", null, document.body);
  hint.id = "hint";
  hint.innerHTML =
    "<strong>Drag / wheel</strong> swoosh &middot; <strong>Pinch / Alt+wheel</strong> zoom &middot; " +
    "<strong>Dbl-click</strong> focus &middot; <strong>e</strong> expand stacks &middot; <strong>0</strong> fit &middot; <strong>q</strong> quit";

  // --- Theme ---
  let theme = {
    dark: true, bg: "#141519", fg: "#e6e7ec", dim: "#8b90a0", accent: "#6ba4ff",
    modeBg: "#1e212a", modeFg: "#cfd3df"
  };

  function applyTheme(t) {
    if (!t) return;
    theme = Object.assign({}, theme, t);
    const r = document.documentElement.style;
    const dark = Boolean(theme.dark);
    r.setProperty("--bg", theme.bg);
    r.setProperty("--fg", theme.fg);
    r.setProperty("--dim", theme.dim);
    r.setProperty("--accent", theme.accent);
    r.setProperty("--mode-bg", theme.modeBg);
    r.setProperty("--mode-fg", theme.modeFg);
    r.setProperty("--card-bg", dark ? "color-mix(in srgb, var(--bg) 82%, #ffffff)" : "color-mix(in srgb, var(--bg) 94%, #ffffff)");
    r.setProperty("--card-head", dark ? "color-mix(in srgb, var(--bg) 74%, #ffffff)" : "color-mix(in srgb, var(--bg) 90%, #000000)");
    r.setProperty("--card-border", dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.13)");
    r.setProperty("--card-shadow", dark ? "rgba(0,0,0,0.45)" : "rgba(0,0,0,0.14)");
    r.setProperty("--hud-bg", dark ? "rgba(20,22,28,0.88)" : "rgba(248,247,244,0.92)");
    r.setProperty("--hud-border", dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)");
  }

  // --- Diagnostics HUD ---
  function updateHudStatus() {
    const isHic = renderMode === "hic";
    statusPill.classList.toggle("hic-live", isHic);
    const label = isHic ? "HTML-in-Canvas" : (HIC_SUPPORTED ? "DOM Layer" : "DOM Fallback");
    const liveStr = liveUpdateCount > 0 ? " | " + liveUpdateCount + " live" : "";
    statusText.textContent = label + " | " + Math.round(cam.zoom * 100) + "% | " + fpsValue + "fps" + liveStr;
    if (diagPop.classList.contains("open")) renderDiagPopover();
  }

  function renderDiagPopover() {
    diagPop.innerHTML = "";
    mk("h3", null, diagPop, "HTML-in-Canvas Spike Diagnostics");
    const rows = [
      ["Active renderer", renderMode === "hic" ? "HTML-in-Canvas (" + DRAW_METHOD + ")" : "CSS-transform DOM", renderMode === "hic"],
      ["canvas.layoutSubtree", String(CAPS.layoutSubtree), CAPS.layoutSubtree],
      ["ctx.drawElementImage", String(CAPS.drawElementImage), CAPS.drawElementImage],
      ["ctx.drawElement (legacy)", String(CAPS.drawElement), CAPS.drawElement],
      ["canvas.onpaint", String(CAPS.onpaint), CAPS.onpaint],
      ["canvas.requestPaint()", String(CAPS.requestPaint), CAPS.requestPaint],
      ["Canvas paints / errors", paintCount + " / " + drawErrors, drawErrors === 0],
      ["Live buffer updates", String(liveUpdateCount) + (lastLiveBuf ? " (" + lastLiveBuf + ")" : ""), liveUpdateCount > 0],
      ["Cards in scene", String(scene.cards.length), true]
    ];
    for (const [k, v, ok] of rows) {
      const row = mk("div", "diag-row", diagPop);
      mk("span", null, row, k);
      mk("span", ok ? "diag-ok" : "diag-no", row, v);
    }
    if (lastDrawError) {
      mk("p", "diag-note", diagPop, "Last draw error: " + lastDrawError);
    }
    if (!HIC_SUPPORTED) {
      const p = mk("p", "diag-note", diagPop);
      p.innerHTML =
        "This browser does not expose <code>layoutsubtree</code> + <code>drawElementImage</code> yet. " +
        "In Chrome Canary/Dev, enable <code>chrome://flags/#canvas-draw-element</code> to test native HTML-in-Canvas painting; " +
        "all swoosh, stack fanning, and live-update mechanics are running in CSS-transform fallback mode.";
    } else {
      const p = mk("p", "diag-note", diagPop);
      p.textContent = "Native HTML-in-Canvas is available. Toggle renderers below to compare drawElementImage against CSS-transformed DOM.";
      const actions = mk("div", "diag-actions", diagPop);
      const toggleBtn = mk("button", "hud-btn active", actions,
        renderMode === "hic" ? "Switch to DOM Layer" : "Switch to HTML-in-Canvas");
      toggleBtn.addEventListener("click", () => {
        setRenderMode(renderMode === "hic" ? "dom" : "hic");
        renderDiagPopover();
      });
    }
  }

  function setRenderMode(next) {
    if (next === "hic" && !HIC_SUPPORTED) return;
    if (next === renderMode) return;
    renderMode = next;
    const host = renderMode === "hic" ? canvas : domLayer;
    if (renderMode === "hic") {
      canvas.setAttribute("layoutsubtree", "");
      try { canvas.layoutSubtree = true; } catch (_) {}
      domLayer.style.display = "none";
    } else {
      canvas.removeAttribute("layoutsubtree");
      try { canvas.layoutSubtree = false; } catch (_) {}
      domLayer.style.display = "block";
    }
    for (const rec of cardDom.values()) {
      host.appendChild(rec.el);
      rec.el.style.visibility = "visible";
    }
    schedulePaint();
    updateHudStatus();
  }

  statusPill.addEventListener("click", (e) => {
    e.stopPropagation();
    diagPop.classList.toggle("open");
    if (diagPop.classList.contains("open")) renderDiagPopover();
  });

  // --- API bridge to Scheme ---
  async function apiGet() {
    const res = await fetch(API);
    return res.json();
  }

  async function apiPost(payload) {
    const res = await fetch(API, { method: "POST", body: JSON.stringify(payload) });
    return res.json();
  }

  function collectWatchedBuffers() {
    const set = new Set();
    if (!snapshot) return [];
    const groups = visibleGroups();
    for (const g of groups) {
      for (const col of (g.columns || [])) {
        for (const p of col) {
          const pKey = g.id + "::" + p.id;
          const isOpen = expandedPanes.has(pKey);
          for (let i = 0; i < (p.windows || []).length; i++) {
            const w = p.windows[i];
            if (i === 0 || isOpen) {
              if (w.buffer) set.add(w.buffer);
            }
          }
        }
      }
      for (const b of (g.unshownBuffers || [])) {
        if (expandedUnshown.has(g.id + "::" + b.name)) set.add(b.name);
      }
    }
    return Array.from(set);
  }

  let watchTimer = null;
  function syncWatchesSoon() {
    clearTimeout(watchTimer);
    watchTimer = setTimeout(async () => {
      const bufs = collectWatchedBuffers();
      if (!bufs.length) return;
      try {
        const res = await apiPost({ op: "watch", buffers: bufs });
        if (res && Array.isArray(res.buffers)) applyBufferUpdates(res.buffers, false);
      } catch (_) {}
    }, 60);
  }

  // --- Layout engine ---
  function visibleGroups() {
    if (!snapshot || !Array.isArray(snapshot.groups)) return [];
    if (scope === "all") return snapshot.groups;
    const active = snapshot.groups.find((g) => g.active) || snapshot.groups[0];
    return active ? [active] : [];
  }

  function computeLayout() {
    const groups = visibleGroups();
    const outGroups = [];
    const outCards = [];
    const outConnectors = [];

    const GROUP_PAD = 24;
    const GROUP_HEAD = 44;
    const COL_GAP = 24;
    const PANE_GAP = 22;
    const CARD_W = 360;
    const CARD_H = 246;
    const STACK_W = 330;
    const STACK_H = 220;
    const STACK_GAP = 16;
    const TRAY_GAP = 12;
    const CHIP_W = 220;
    const CHIP_H = 32;
    const EXP_BUF_W = 330;
    const EXP_BUF_H = 215;

    let gxCursor = 0;
    let gyCursor = 0;
    let rowMaxH = 0;
    const maxCols = scope === "all" ? 2 : 1;
    let colInGrid = 0;

    for (const g of groups) {
      const gx = gxCursor;
      const gy = gyCursor;
      let innerX = gx + GROUP_PAD;
      const panesTop = gy + GROUP_HEAD;
      let panesBottom = panesTop + CARD_H;
      const paneBoxes = [];

      const cols = g.columns || [];
      if (cols.length === 0) {
        innerX += CARD_W + COL_GAP;
      }

      for (const col of cols) {
        // Determine column width from pane share (clamped nicely)
        const share = col[0] && typeof col[0].share === "number" ? col[0].share : 0.33;
        const colW = Math.max(330, Math.min(440, Math.round(CARD_W * (0.85 + share * 0.55))));
        let py = panesTop;
        let colRight = innerX + colW;

        for (const p of col) {
          const pKey = g.id + "::" + p.id;
          const wins = p.windows || [];
          const front = wins[0] || null;
          const stacked = wins.slice(1);
          const isOpen = expandedPanes.has(pKey);

          const cardX = innerX;
          const cardY = py;
          const frontId = front ? "win:" + g.id + ":" + p.id + ":" + front.key : "empty:" + g.id + ":" + p.id;

          if (front) {
            outCards.push({
              id: frontId,
              kind: "window",
              groupId: g.id,
              groupName: g.name,
              paneId: p.id,
              paneKey: pKey,
              paneFocused: Boolean(p.focused),
              windowKey: front.key,
              windowIndex: 0,
              stackCount: stacked.length,
              stackOpen: isOpen,
              stackTitles: stacked.slice(0, 4).map((w) => w.shortName || w.buffer || "empty"),
              buffer: front.buffer,
              shortName: front.shortName || front.buffer || "empty",
              mode: front.shortMode || "fundamental",
              buffers: front.buffers || [],
              live: Boolean(front.live),
              selected: Boolean(front.selected),
              preview: liveBuffers.get(front.buffer) || front.preview,
              x: cardX, y: cardY, w: colW, h: CARD_H,
              originX: cardX, originY: cardY
            });
          }

          paneBoxes.push({
            id: p.id,
            x: cardX,
            y: cardY,
            w: colW,
            h: CARD_H,
            focused: Boolean(p.focused),
            stackCount: stacked.length,
            stackOpen: isOpen
          });

          let blockBottom = cardY + CARD_H + (stacked.length > 0 && !isOpen ? 18 : 0);

          // If this pane's window stack is opened, fan all stacked windows underneath!
          if (isOpen && stacked.length > 0) {
            const fanCols = Math.min(2, stacked.length);
            const fanStartY = cardY + CARD_H + 34;
            const fanW = Math.max(290, Math.min(STACK_W, colW));
            for (let si = 0; si < stacked.length; si++) {
              const sw = stacked[si];
              const fc = si % fanCols;
              const fr = Math.floor(si / fanCols);
              const sx = cardX + fc * (fanW + STACK_GAP);
              const sy = fanStartY + fr * (STACK_H + STACK_GAP);
              const sid = "win:" + g.id + ":" + p.id + ":" + sw.key;
              outCards.push({
                id: sid,
                kind: "stacked-window",
                groupId: g.id,
                groupName: g.name,
                paneId: p.id,
                paneKey: pKey,
                paneFocused: false,
                windowKey: sw.key,
                windowIndex: si + 1,
                stackCount: 0,
                stackOpen: false,
                buffer: sw.buffer,
                shortName: sw.shortName || sw.buffer || "empty",
                mode: sw.shortMode || "fundamental",
                buffers: sw.buffers || [],
                live: false,
                selected: false,
                preview: liveBuffers.get(sw.buffer) || sw.preview,
                x: sx, y: sy, w: fanW, h: STACK_H,
                originX: cardX + 12, originY: cardY + 12
              });
              outConnectors.push({
                fromX: cardX + colW * 0.5,
                fromY: cardY + CARD_H,
                toX: sx + fanW * 0.5,
                toY: sy,
                color: g.color || theme.accent
              });
              colRight = Math.max(colRight, sx + fanW);
              blockBottom = Math.max(blockBottom, sy + STACK_H);
            }
          }

          py = blockBottom + PANE_GAP;
          panesBottom = Math.max(panesBottom, blockBottom);
        }

        innerX = colRight + COL_GAP;
      }

      const contentW = Math.max(innerX - gx - COL_GAP + GROUP_PAD, 420);

      // Unshown buffers tray below the panes
      const unshown = g.unshownBuffers || [];
      let trayBottom = panesBottom;
      if (unshown.length > 0) {
        let tx = gx + GROUP_PAD;
        let ty = panesBottom + 36;
        let rowH = 0;
        const maxRight = gx + contentW - GROUP_PAD;

        for (const b of unshown) {
          const bKey = g.id + "::" + b.name;
          const isExp = expandedUnshown.has(bKey);
          const cw = isExp ? EXP_BUF_W : CHIP_W;
          const ch = isExp ? EXP_BUF_H : CHIP_H;
          if (tx + cw > maxRight && tx > gx + GROUP_PAD) {
            tx = gx + GROUP_PAD;
            ty += rowH + TRAY_GAP;
            rowH = 0;
          }
          outCards.push({
            id: "buf:" + g.id + ":" + b.name,
            kind: "buffer",
            groupId: g.id,
            groupName: g.name,
            bufKey: bKey,
            expanded: isExp,
            buffer: b.name,
            shortName: b.shortName || b.name,
            mode: b.shortMode || "fundamental",
            modified: Boolean(b.modified),
            preview: liveBuffers.get(b.name) || null,
            x: tx, y: ty, w: cw, h: ch,
            originX: tx, originY: ty
          });
          tx += cw + TRAY_GAP;
          rowH = Math.max(rowH, ch);
          trayBottom = Math.max(trayBottom, ty + ch);
        }
      }

      const groupH = (trayBottom - gy) + GROUP_PAD;
      outGroups.push({
        id: g.id,
        name: g.name,
        active: Boolean(g.active),
        color: g.color || theme.accent,
        layoutName: g.layoutName || "free",
        memberCount: g.memberCount || 0,
        unshownTotal: g.unshownTotal || 0,
        unshownTop: unshown.length > 0 ? panesBottom + 18 : null,
        x: gx, y: gy, w: contentW, h: groupH,
        panes: paneBoxes
      });

      rowMaxH = Math.max(rowMaxH, groupH);
      colInGrid += 1;
      if (colInGrid >= maxCols) {
        colInGrid = 0;
        gxCursor = 0;
        gyCursor += rowMaxH + 56;
        rowMaxH = 0;
      } else {
        gxCursor += contentW + 56;
      }
    }

    // Scene bounds
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const g of outGroups) {
      minX = Math.min(minX, g.x);
      minY = Math.min(minY, g.y);
      maxX = Math.max(maxX, g.x + g.w);
      maxY = Math.max(maxY, g.y + g.h);
    }
    if (!Number.isFinite(minX)) { minX = 0; minY = 0; maxX = 800; maxY = 500; }

    scene = {
      groups: outGroups,
      connectors: outConnectors,
      cards: outCards,
      bounds: { x: minX, y: minY, w: Math.max(200, maxX - minX), h: Math.max(200, maxY - minY) }
    };

    reconcileCards();
    schedulePaint();
  }

  // --- Card DOM reconciliation ---
  function matchesQuery(card) {
    if (!searchQuery) return true;
    const q = searchQuery.toLowerCase();
    return (
      (card.shortName && card.shortName.toLowerCase().includes(q)) ||
      (card.buffer && card.buffer.toLowerCase().includes(q)) ||
      (card.mode && card.mode.toLowerCase().includes(q)) ||
      (card.groupName && card.groupName.toLowerCase().includes(q))
    );
  }

  function renderPreviewLines(bodyEl, preview) {
    bodyEl.innerHTML = "";
    if (!preview || !preview.text) {
      const empty = mk("div", null, bodyEl, preview ? "(empty buffer)" : "Loading preview...");
      empty.style.color = "var(--dim)";
      empty.style.fontStyle = "italic";
      return;
    }
    const ul = mk("ul", "card-lines", bodyEl);
    const lines = String(preview.text).split("\n");
    const firstLine = Number(preview.firstLine) || 1;
    const ptLine = Number(preview.pointLine) || -1;
    for (let i = 0; i < lines.length; i++) {
      const ln = firstLine + i;
      const li = mk("li", "card-line" + (ln === ptLine ? " is-point" : ""), ul);
      mk("span", "card-ln", li, String(ln));
      mk("span", "card-txt", li, lines[i] || " ");
    }
  }

  function createCardElement(card) {
    const el = mk("div", "card");
    el.dataset.cardId = card.id;

    const head = mk("div", "card-head", el);
    mk("span", "card-dot", head);
    const titleEl = mk("span", "card-title", head);
    const modEl = mk("span", "card-mod", head);
    const modeEl = mk("span", "card-badge", head);

    const stackBtn = mk("button", "card-btn stack-btn", head);
    stackBtn.style.display = "none";
    stackBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const cur = cardById.get(card.id);
      if (!cur || !cur.paneKey) return;
      if (expandedPanes.has(cur.paneKey)) expandedPanes.delete(cur.paneKey);
      else expandedPanes.add(cur.paneKey);
      computeLayout();
      syncWatchesSoon();
    });

    const bufsBtn = mk("button", "card-btn", head);
    bufsBtn.style.display = "none";
    bufsBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const cur = cardById.get(card.id);
      if (!cur) return;
      const bKey = cur.groupId + "::" + cur.windowKey;
      if (expandedBufStacks.has(bKey)) expandedBufStacks.delete(bKey);
      else expandedBufStacks.add(bKey);
      updateCardContent(rec, cur);
      schedulePaint();
    });

    const jumpBtn = mk("button", "card-btn", head, "Jump");
    jumpBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const cur = cardById.get(card.id);
      if (!cur) return;
      apiPost({ op: "focus", group: cur.groupId, key: cur.windowKey || null, buffer: cur.buffer || "" });
    });

    const bufsEl = mk("div", "card-bufs-strip", el);
    bufsEl.style.display = "none";

    const bodyEl = mk("div", "card-body", el);

    const footEl = mk("div", "card-foot", el);
    const metaEl = mk("span", null, footEl);
    const liveEl = mk("span", "card-live-tag", footEl);

    el.addEventListener("mousedown", (e) => {
      if (e.target.closest("button")) return;
      e.stopPropagation();
      selectedCardId = card.id;
      const cur = cardById.get(card.id);
      if (cur && cur.kind === "buffer") {
        if (expandedUnshown.has(cur.bufKey)) expandedUnshown.delete(cur.bufKey);
        else expandedUnshown.add(cur.bufKey);
        computeLayout();
        syncWatchesSoon();
      } else {
        schedulePaint();
      }
    });

    el.addEventListener("dblclick", (e) => {
      e.stopPropagation();
      const cur = cardById.get(card.id);
      if (!cur) return;
      swooshToBox(cur.x, cur.y, cur.w, cur.h, 1.05);
    });

    const rec = {
      el, titleEl, modEl, modeEl, stackBtn, bufsBtn, jumpBtn, bufsEl, bodyEl, footEl, metaEl, liveEl,
      animX: card.originX, animY: card.originY,
      lastW: 0, lastH: 0, lastPreviewTs: 0, lastBufListKey: ""
    };

    const host = renderMode === "hic" ? canvas : domLayer;
    host.appendChild(el);
    return rec;
  }

  function updateCardContent(rec, card) {
    const now = performance.now();
    const isPulsing = Boolean(card.buffer && (pulseUntil.get(card.buffer) || 0) > now);
    const isCompact = card.kind === "buffer" && !card.expanded;
    const qMatch = matchesQuery(card);

    rec.el.classList.toggle("is-selected", selectedCardId === card.id || Boolean(card.selected));
    rec.el.classList.toggle("is-stacked", card.kind === "stacked-window");
    rec.el.classList.toggle("is-live", Boolean(card.live || card.kind === "stacked-window" || card.expanded));
    rec.el.classList.toggle("is-pulsing", isPulsing);
    rec.el.classList.toggle("card-compact", card.kind === "buffer");
    rec.el.classList.toggle("is-expanded", Boolean(card.expanded));
    rec.el.classList.toggle("is-match", Boolean(searchQuery && qMatch));
    rec.el.classList.toggle("is-dimmed", Boolean(searchQuery && !qMatch));

    if (rec.lastW !== card.w) { rec.el.style.width = card.w + "px"; rec.lastW = card.w; }
    if (rec.lastH !== card.h) { rec.el.style.height = card.h + "px"; rec.lastH = card.h; }

    rec.titleEl.textContent = card.shortName || card.buffer || "empty";
    rec.titleEl.title = card.buffer || "";
    const preview = liveBuffers.get(card.buffer) || card.preview;
    const mod = Boolean((preview && preview.modified) || card.modified);
    rec.modEl.textContent = mod ? "*" : "";
    rec.modeEl.textContent = card.mode || "";

    if (card.stackCount > 0) {
      rec.stackBtn.style.display = "";
      rec.stackBtn.classList.toggle("open", Boolean(card.stackOpen));
      rec.stackBtn.textContent = card.stackOpen
        ? "Stack (" + (card.stackCount + 1) + ") -"
        : "+" + card.stackCount + " stack";
    } else {
      rec.stackBtn.style.display = "none";
    }

    const bufs = card.buffers || [];
    if (bufs.length > 1) {
      const bKey = card.groupId + "::" + card.windowKey;
      const bOpen = expandedBufStacks.has(bKey);
      rec.bufsBtn.style.display = "";
      rec.bufsBtn.textContent = bufs.length + " bufs";
      rec.bufsEl.style.display = bOpen ? "flex" : "none";
      const listKey = bufs.join("|") + "::" + (bOpen ? "1" : "0");
      if (bOpen && rec.lastBufListKey !== listKey) {
        rec.lastBufListKey = listKey;
        rec.bufsEl.innerHTML = "";
        for (const bName of bufs) {
          const short = bName.startsWith("/") ? bName.slice(bName.lastIndexOf("/") + 1) : bName;
          const chip = mk("button", "buf-chip" + (bName === card.buffer ? " active" : ""), rec.bufsEl, short);
          chip.title = bName;
          chip.addEventListener("click", (e) => {
            e.stopPropagation();
            apiPost({ op: "focus", group: card.groupId, key: card.windowKey, buffer: bName });
          });
        }
      }
    } else {
      rec.bufsBtn.style.display = "none";
      rec.bufsEl.style.display = "none";
    }

    rec.jumpBtn.style.display = isCompact ? "none" : "";
    rec.bodyEl.style.display = isCompact ? "none" : "";
    rec.footEl.style.display = isCompact ? "none" : "";

    if (!isCompact) {
      const pts = preview ? (preview.ts || 1) : 0;
      if (pts !== rec.lastPreviewTs) {
        rec.lastPreviewTs = pts;
        renderPreviewLines(rec.bodyEl, preview);
      }
      const loc = card.kind === "window"
        ? (card.paneId + " | front" + (preview && preview.totalLines ? " | L" + preview.pointLine + "/" + preview.totalLines : ""))
        : card.kind === "stacked-window"
          ? (card.paneId + " | stack #" + (card.windowIndex + 1) + (preview && preview.totalLines ? " | L" + preview.pointLine + "/" + preview.totalLines : ""))
          : (card.groupName + (preview && preview.totalLines ? " | " + preview.totalLines + " lines" : ""));
      rec.metaEl.textContent = loc;
      rec.liveEl.textContent = isPulsing ? "LIVE UPDATE" : (card.live || card.kind === "stacked-window" ? "watching" : "");
    }
  }

  function reconcileCards() {
    const keep = new Set();
    cardById.clear();
    for (const card of scene.cards) {
      keep.add(card.id);
      cardById.set(card.id, card);
      let rec = cardDom.get(card.id);
      if (!rec) {
        rec = createCardElement(card);
        cardDom.set(card.id, rec);
      }
      updateCardContent(rec, card);
    }
    for (const [id, rec] of cardDom.entries()) {
      if (!keep.has(id)) {
        rec.el.remove();
        cardDom.delete(id);
      }
    }
  }

  // --- Live delta updates from Scheme ---
  function applyBufferUpdates(updates, countAsLive) {
    const now = performance.now();
    let changed = false;
    for (const p of updates) {
      if (!p || !p.name) continue;
      liveBuffers.set(p.name, p);
      if (countAsLive) {
        pulseUntil.set(p.name, now + 950);
        liveUpdateCount += 1;
        lastLiveBuf = p.shortName || p.name;
      }
      changed = true;
    }
    if (!changed) return;
    for (const card of scene.cards) {
      if (liveBuffers.has(card.buffer)) {
        const rec = cardDom.get(card.id);
        if (rec) updateCardContent(rec, card);
      }
    }
    updateHudStatus();
    schedulePaint();
    if (countAsLive) {
      setTimeout(() => {
        for (const card of scene.cards) {
          const rec = cardDom.get(card.id);
          if (rec) updateCardContent(rec, card);
        }
        schedulePaint();
      }, 980);
    }
  }

  // --- Camera helpers (swoosh physics) ---
  function swooshTo(x, y, zoom) {
    cam.vx = 0; cam.vy = 0;
    cam.targetX = x;
    cam.targetY = y;
    cam.targetZoom = Math.max(0.16, Math.min(1.8, zoom));
    schedulePaint();
  }

  function swooshToBox(bx, by, bw, bh, maxZoom) {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const padX = 56;
    const padTop = 76;
    const padBottom = 56;
    const availW = Math.max(120, vw - padX * 2);
    const availH = Math.max(120, vh - padTop - padBottom);
    const z = Math.min(maxZoom || 1.12, Math.max(0.18, Math.min(availW / bw, availH / bh)));
    const tx = padX + (availW - bw * z) * 0.5 - bx * z;
    const ty = padTop + (availH - bh * z) * 0.5 - by * z;
    swooshTo(tx, ty, z);
  }

  function fitScene(instant) {
    const b = scene.bounds;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const padX = 48, padTop = 72, padBottom = 56;
    const availW = Math.max(120, vw - padX * 2);
    const availH = Math.max(120, vh - padTop - padBottom);
    const z = Math.min(1.02, Math.max(0.18, Math.min(availW / b.w, availH / b.h)));
    const tx = padX + (availW - b.w * z) * 0.5 - b.x * z;
    const ty = padTop + (availH - b.h * z) * 0.5 - b.y * z;
    if (instant) {
      cam.x = tx; cam.y = ty; cam.zoom = z;
      cam.targetX = null; cam.targetY = null; cam.targetZoom = null;
      schedulePaint();
    } else {
      swooshTo(tx, ty, z);
    }
  }

  function stepPhysics() {
    let moving = false;

    // Spring camera swoosh
    if (cam.targetX !== null) {
      const dx = cam.targetX - cam.x;
      const dy = cam.targetY - cam.y;
      const dz = cam.targetZoom - cam.zoom;
      cam.x += dx * 0.22;
      cam.y += dy * 0.22;
      cam.zoom += dz * 0.22;
      if (Math.abs(dx) < 0.4 && Math.abs(dy) < 0.4 && Math.abs(dz) < 0.0015) {
        cam.x = cam.targetX; cam.y = cam.targetY; cam.zoom = cam.targetZoom;
        cam.targetX = cam.targetY = cam.targetZoom = null;
      } else {
        moving = true;
      }
    } else if (Math.abs(cam.vx) > 0.15 || Math.abs(cam.vy) > 0.15) {
      cam.x += cam.vx;
      cam.y += cam.vy;
      cam.vx *= 0.89;
      cam.vy *= 0.89;
      moving = true;
    } else {
      cam.vx = 0; cam.vy = 0;
    }

    // Smooth card fan-out animation
    for (const card of scene.cards) {
      const rec = cardDom.get(card.id);
      if (!rec) continue;
      const dx = card.x - rec.animX;
      const dy = card.y - rec.animY;
      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
        rec.animX += dx * 0.26;
        rec.animY += dy * 0.26;
        moving = true;
      } else {
        rec.animX = card.x;
        rec.animY = card.y;
      }
    }

    return moving;
  }

  // --- Canvas rendering (backdrop + HTML-in-Canvas cards + minimap) ---
  function roundRect(c, x, y, w, h, r) {
    c.beginPath();
    c.roundRect ? c.roundRect(x, y, w, h, r) : c.rect(x, y, w, h);
  }

  function resizeCanvas() {
    const dpr = window.devicePixelRatio || 1;
    const w = window.innerWidth;
    const h = window.innerHeight;
    const bw = Math.max(1, Math.round(w * dpr));
    const bh = Math.max(1, Math.round(h * dpr));
    if (canvas.width !== bw || canvas.height !== bh) {
      canvas.width = bw;
      canvas.height = bh;
    }
    const mw = Math.round(220 * dpr);
    const mh = Math.round(140 * dpr);
    if (minimap.width !== mw || minimap.height !== mh) {
      minimap.width = mw;
      minimap.height = mh;
    }
  }

  function drawScene() {
    resizeCanvas();
    const dpr = window.devicePixelRatio || 1;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    paintCount += 1;
    fpsFrames += 1;
    const now = performance.now();
    if (now - fpsLast >= 500) {
      fpsValue = Math.round((fpsFrames * 1000) / (now - fpsLast));
      fpsFrames = 0;
      fpsLast = now;
      updateHudStatus();
    }

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = theme.bg;
    ctx.fillRect(0, 0, vw, vh);

    // Subtle spatial dot grid
    const step = Math.max(18, 32 * cam.zoom);
    if (step >= 10) {
      const offX = ((cam.x % step) + step) % step;
      const offY = ((cam.y % step) + step) % step;
      ctx.fillStyle = theme.dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.08)";
      for (let x = offX; x < vw; x += step) {
        for (let y = offY; y < vh; y += step) {
          ctx.fillRect(x, y, 1.5, 1.5);
        }
      }
    }

    // World-space group regions, stack deck edges, and bezier connectors
    ctx.save();
    ctx.translate(cam.x, cam.y);
    ctx.scale(cam.zoom, cam.zoom);

    for (const g of scene.groups) {
      roundRect(ctx, g.x, g.y, g.w, g.h, 16);
      ctx.fillStyle = theme.dark ? "rgba(255,255,255,0.03)" : "rgba(0,0,0,0.025)";
      ctx.fill();
      ctx.lineWidth = g.active ? 1.8 / cam.zoom : 1 / cam.zoom;
      ctx.strokeStyle = g.active ? (g.color || theme.accent) : (theme.dark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.12)");
      ctx.stroke();

      // Group header label
      ctx.fillStyle = g.color || theme.accent;
      ctx.beginPath();
      ctx.arc(g.x + 22, g.y + 22, 5, 0, Math.PI * 2);
      ctx.fill();

      ctx.font = "600 14px -apple-system, BlinkMacSystemFont, system-ui, sans-serif";
      ctx.fillStyle = theme.fg;
      ctx.fillText(g.name, g.x + 34, g.y + 27);

      ctx.font = "500 11px ui-monospace, Menlo, monospace";
      ctx.fillStyle = theme.dim;
      const meta = g.layoutName + " | " + g.memberCount + " buffers" + (g.active ? " | active" : "");
      ctx.fillText(meta, g.x + 34 + ctx.measureText(g.name).width + 16, g.y + 26);

      if (g.unshownTop != null) {
        ctx.font = "600 10.5px ui-monospace, Menlo, monospace";
        ctx.fillStyle = theme.dim;
        ctx.fillText("GROUP BUFFERS (" + g.unshownTotal + " unshown - click to expand live)", g.x + 24, g.unshownTop + 10);
      }

      // Draw stacked-card silhouettes behind collapsed pane stacks
      for (const p of g.panes) {
        if (p.stackCount > 0 && !p.stackOpen) {
          const layers = Math.min(3, p.stackCount);
          for (let i = layers; i >= 1; i--) {
            const ox = i * 6;
            const oy = i * 6;
            roundRect(ctx, p.x + ox, p.y + oy, p.w, p.h, 10);
            ctx.fillStyle = theme.dark ? "rgba(255,255,255,0.045)" : "rgba(0,0,0,0.04)";
            ctx.fill();
            ctx.lineWidth = 1;
            ctx.strokeStyle = theme.dark ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.15)";
            ctx.stroke();
          }
        }
      }
    }

    // Bezier connector ribbons from front pane to opened stack windows
    for (const c of scene.connectors) {
      const midY = (c.fromY + c.toY) * 0.5;
      ctx.beginPath();
      ctx.moveTo(c.fromX, c.fromY);
      ctx.bezierCurveTo(c.fromX, midY, c.toX, midY, c.toX, c.toY);
      ctx.lineWidth = 2;
      ctx.strokeStyle = c.color || theme.accent;
      ctx.globalAlpha = 0.55;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }

    ctx.restore();

    // Paint HTML cards either via native HTML-in-Canvas (drawElementImage) or CSS-DOM fallback
    if (renderMode === "hic" && DRAW_METHOD) {
      for (const card of scene.cards) {
        const rec = cardDom.get(card.id);
        if (!rec) continue;
        const sx = rec.animX * cam.zoom + cam.x;
        const sy = rec.animY * cam.zoom + cam.y;
        const sw = card.w * cam.zoom;
        const sh = card.h * cam.zoom;

        // Viewport frustum culling
        if (sx + sw < -40 || sy + sh < -40 || sx > vw + 40 || sy > vh + 40) {
          rec.el.style.visibility = "hidden";
          continue;
        }
        rec.el.style.visibility = "visible";

        // Canvas-painted elevation shadow & live pulse halo
        ctx.save();
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        const pulsing = Boolean(card.buffer && (pulseUntil.get(card.buffer) || 0) > now);
        ctx.shadowColor = pulsing ? "rgba(74, 222, 128, 0.55)" : (theme.dark ? "rgba(0,0,0,0.48)" : "rgba(0,0,0,0.16)");
        ctx.shadowBlur = pulsing ? 22 : 18 * cam.zoom;
        ctx.shadowOffsetY = pulsing ? 0 : 8 * cam.zoom;
        roundRect(ctx, sx, sy, sw, sh, 10 * cam.zoom);
        ctx.fillStyle = theme.bg;
        ctx.fill();
        ctx.restore();

        // Draw live HTML subtree into canvas via drawElementImage!
        ctx.save();
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.translate(sx, sy);
        ctx.scale(cam.zoom, cam.zoom);
        try {
          const mat = ctx[DRAW_METHOD](rec.el, 0, 0);
          if (mat && typeof mat.toString === "function" && Number.isFinite(mat.a)) {
            rec.el.style.transform = mat.toString();
          } else {
            rec.el.style.transform = "translate(" + sx + "px, " + sy + "px) scale(" + cam.zoom + ")";
          }
        } catch (err) {
          drawErrors += 1;
          lastDrawError = String(err && err.message ? err.message : err);
          rec.el.style.transform = "translate(" + sx + "px, " + sy + "px) scale(" + cam.zoom + ")";
        }
        ctx.restore();
      }
    } else {
      domLayer.style.transform = "translate3d(" + cam.x + "px, " + cam.y + "px, 0) scale(" + cam.zoom + ")";
      for (const card of scene.cards) {
        const rec = cardDom.get(card.id);
        if (!rec) continue;
        rec.el.style.transform = "translate3d(" + rec.animX + "px, " + rec.animY + "px, 0)";
      }
    }

    drawMinimap();
  }

  function drawMinimap() {
    const dpr = window.devicePixelRatio || 1;
    const mw = 220, mh = 140;
    miniCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    miniCtx.clearRect(0, 0, mw, mh);

    const b = scene.bounds;
    const pad = 12;
    const scale = Math.min((mw - pad * 2) / b.w, (mh - pad * 2) / b.h);
    const ox = pad + ((mw - pad * 2) - b.w * scale) * 0.5 - b.x * scale;
    const oy = pad + ((mh - pad * 2) - b.h * scale) * 0.5 - b.y * scale;
    minimap._proj = { scale, ox, oy };

    // Groups
    for (const g of scene.groups) {
      miniCtx.fillStyle = theme.dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.06)";
      miniCtx.strokeStyle = g.active ? (g.color || theme.accent) : "rgba(140,145,160,0.35)";
      miniCtx.lineWidth = 1;
      miniCtx.fillRect(ox + g.x * scale, oy + g.y * scale, g.w * scale, g.h * scale);
      miniCtx.strokeRect(ox + g.x * scale, oy + g.y * scale, g.w * scale, g.h * scale);
    }

    // Cards
    const now = performance.now();
    for (const c of scene.cards) {
      const pulsing = Boolean(c.buffer && (pulseUntil.get(c.buffer) || 0) > now);
      miniCtx.fillStyle = pulsing
        ? "#4ade80"
        : c.kind === "window"
          ? theme.accent
          : c.kind === "stacked-window"
            ? "rgba(107,164,255,0.58)"
            : "rgba(150,155,170,0.35)";
      miniCtx.fillRect(ox + c.x * scale, oy + c.y * scale, Math.max(2, c.w * scale), Math.max(2, c.h * scale));
    }

    // Viewport rectangle
    const vx = (-cam.x / cam.zoom) * scale + ox;
    const vy = (-cam.y / cam.zoom) * scale + oy;
    const vw = (window.innerWidth / cam.zoom) * scale;
    const vh = (window.innerHeight / cam.zoom) * scale;
    miniCtx.strokeStyle = theme.fg;
    miniCtx.lineWidth = 1.5;
    miniCtx.strokeRect(vx, vy, vw, vh);
    miniCtx.fillStyle = theme.dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)";
    miniCtx.fillRect(vx, vy, vw, vh);
  }

  // --- Paint scheduling ---
  function tick() {
    rafHandle = 0;
    const moving = stepPhysics();
    if (dirtyPaint || moving) {
      dirtyPaint = false;
      if (renderMode === "hic" && CAPS.requestPaint) {
        canvas.requestPaint();
      } else {
        drawScene();
      }
    }
    if (moving) rafHandle = requestAnimationFrame(tick);
  }

  function schedulePaint() {
    dirtyPaint = true;
    if (!rafHandle) rafHandle = requestAnimationFrame(tick);
  }

  if (CAPS.onpaint) {
    canvas.addEventListener("paint", () => {
      if (renderMode === "hic") drawScene();
    });
  }

  // --- Pointer / wheel / minimap / keyboard interactions ---
  let drag = null;

  viewport.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    if (e.target.closest("#hud, #diag-pop, #minimap, .card button")) return;
    // Allow dragging anywhere except interactive card buttons
    diagPop.classList.remove("open");
    cam.targetX = cam.targetY = cam.targetZoom = null;
    cam.vx = 0; cam.vy = 0;
    drag = { x: e.clientX, y: e.clientY, lastX: e.clientX, lastY: e.clientY, moved: false };
    viewport.classList.add("panning");
    try { viewport.setPointerCapture(e.pointerId); } catch (_) {}
  });

  viewport.addEventListener("pointermove", (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.lastX;
    const dy = e.clientY - drag.lastY;
    if (Math.abs(e.clientX - drag.x) > 3 || Math.abs(e.clientY - drag.y) > 3) drag.moved = true;
    cam.x += dx;
    cam.y += dy;
    cam.vx = dx * 0.75;
    cam.vy = dy * 0.75;
    drag.lastX = e.clientX;
    drag.lastY = e.clientY;
    schedulePaint();
  });

  function endDrag() {
    if (!drag) return;
    drag = null;
    viewport.classList.remove("panning");
    schedulePaint();
  }
  viewport.addEventListener("pointerup", endDrag);
  viewport.addEventListener("pointercancel", endDrag);

  viewport.addEventListener("dblclick", (e) => {
    if (e.target.closest(".card, #hud, #diag-pop, #minimap")) return;
    // Double-click inside a group container -> swoosh to fit that group!
    const wx = (e.clientX - cam.x) / cam.zoom;
    const wy = (e.clientY - cam.y) / cam.zoom;
    const hit = scene.groups.find((g) => wx >= g.x && wx <= g.x + g.w && wy >= g.y && wy <= g.y + g.h);
    if (hit) swooshToBox(hit.x, hit.y, hit.w, hit.h, 1.05);
    else fitScene(false);
  });

  viewport.addEventListener("wheel", (e) => {
    e.preventDefault();
    cam.targetX = cam.targetY = cam.targetZoom = null;
    if (e.ctrlKey || e.metaKey || e.altKey) {
      const factor = Math.exp(-e.deltaY * 0.008);
      const nextZoom = Math.max(0.16, Math.min(1.85, cam.zoom * factor));
      const wx = (e.clientX - cam.x) / cam.zoom;
      const wy = (e.clientY - cam.y) / cam.zoom;
      cam.zoom = nextZoom;
      cam.x = e.clientX - wx * cam.zoom;
      cam.y = e.clientY - wy * cam.zoom;
      updateHudStatus();
    } else {
      cam.x -= e.deltaX;
      cam.y -= e.deltaY;
      cam.vx = -e.deltaX * 0.2;
      cam.vy = -e.deltaY * 0.2;
    }
    schedulePaint();
  }, { passive: false });

  // Minimap click & drag swooshing
  let miniDrag = false;
  function minimapJump(e) {
    const p = minimap._proj;
    if (!p) return;
    const r = minimap.getBoundingClientRect();
    const wx = (e.clientX - r.left - p.ox) / p.scale;
    const wy = (e.clientY - r.top - p.oy) / p.scale;
    swooshTo(window.innerWidth * 0.5 - wx * cam.zoom, window.innerHeight * 0.5 - wy * cam.zoom, cam.zoom);
  }
  minimap.addEventListener("pointerdown", (e) => {
    e.stopPropagation();
    miniDrag = true;
    minimapJump(e);
    try { minimap.setPointerCapture(e.pointerId); } catch (_) {}
  });
  minimap.addEventListener("pointermove", (e) => { if (miniDrag) minimapJump(e); });
  minimap.addEventListener("pointerup", () => { miniDrag = false; });

  // HUD controls
  btnThisGroup.addEventListener("click", () => {
    scope = "group";
    btnThisGroup.classList.add("active");
    btnAllGroups.classList.remove("active");
    computeLayout();
    fitScene(false);
    syncWatchesSoon();
  });

  btnAllGroups.addEventListener("click", () => {
    scope = "all";
    btnAllGroups.classList.add("active");
    btnThisGroup.classList.remove("active");
    computeLayout();
    fitScene(false);
    syncWatchesSoon();
  });

  function toggleExpandAllStacks() {
    const groups = visibleGroups();
    const allKeys = [];
    for (const g of groups) {
      for (const col of (g.columns || [])) {
        for (const p of col) {
          if ((p.windows || []).length > 1) allKeys.push(g.id + "::" + p.id);
        }
      }
    }
    const anyClosed = allKeys.some((k) => !expandedPanes.has(k));
    if (anyClosed) {
      for (const k of allKeys) expandedPanes.add(k);
    } else {
      for (const k of allKeys) expandedPanes.delete(k);
    }
    btnExpandAll.classList.toggle("active", anyClosed);
    btnExpandAll.textContent = anyClosed ? "Collapse stacks" : "Expand stacks";
    computeLayout();
    syncWatchesSoon();
    fitScene(false);
  }
  btnExpandAll.addEventListener("click", toggleExpandAllStacks);

  btnFit.addEventListener("click", () => fitScene(false));

  btnPulse.addEventListener("click", async () => {
    const start = !(snapshot && snapshot.demoRunning);
    const res = await apiPost({ op: "demo", start });
    if (res && res.snapshot) {
      applySnapshot(res.snapshot, false);
      // Automatically expand the first pane stack so the pulsing buffer is immediately visible!
      if (start) {
        const ag = visibleGroups()[0];
        const firstPane = ag && ag.columns && ag.columns[0] && ag.columns[0][0];
        if (ag && firstPane) {
          expandedPanes.add(ag.id + "::" + firstPane.id);
          computeLayout();
          syncWatchesSoon();
        }
      }
    }
  });

  searchInput.addEventListener("input", () => {
    searchQuery = searchInput.value.trim();
    reconcileCards();
    if (searchQuery) {
      const hit = scene.cards.find((c) => matchesQuery(c));
      if (hit) swooshToBox(hit.x, hit.y, hit.w, hit.h, 1.0);
    }
    schedulePaint();
  });

  // Keyboard shortcuts
  addEventListener("keydown", (e) => {
    if (document.activeElement === searchInput) {
      if (e.key === "Escape") {
        searchInput.value = "";
        searchQuery = "";
        searchInput.blur();
        reconcileCards();
        schedulePaint();
      }
      return;
    }
    if (e.ctrlKey && e.key.toLowerCase() === "g") return; // bridge handles C-g
    if (e.key === "/") { e.preventDefault(); searchInput.focus(); return; }
    if (e.key === "0") { e.preventDefault(); fitScene(false); return; }
    if (e.key === "1") {
      e.preventDefault();
      const g = scene.groups.find((x) => x.active) || scene.groups[0];
      if (g) swooshToBox(g.x, g.y, g.w, g.h, 1.02);
      return;
    }
    if (e.key === "e") { e.preventDefault(); toggleExpandAllStacks(); return; }
    if (e.key === "a") { e.preventDefault(); (scope === "group" ? btnAllGroups : btnThisGroup).click(); return; }
    if (e.key === "=" || e.key === "+") {
      e.preventDefault();
      swooshTo(cam.x, cam.y, cam.zoom * 1.2);
      return;
    }
    if (e.key === "-") {
      e.preventDefault();
      swooshTo(cam.x, cam.y, cam.zoom / 1.2);
      return;
    }
    if (e.key === "r" || e.key === "g") {
      e.preventDefault();
      apiGet().then((s) => applySnapshot(s, false));
      return;
    }
    if (e.key === "q") {
      e.preventDefault();
      apiPost({ op: "quit" });
      return;
    }
    if (e.key === "Escape") {
      diagPop.classList.remove("open");
    }
  });

  // --- Snapshot ingestion & live messages from compos AppFrame ---
  function applySnapshot(s, initial) {
    if (!s || !Array.isArray(s.groups)) return;
    snapshot = s;
    applyTheme(s.theme);
    btnPulse.classList.toggle("pulse-on", Boolean(s.demoRunning));
    btnPulse.textContent = s.demoRunning ? "Stop pulse" : "Pulse test";

    // Seed liveBuffers cache from snapshot previews without clobbering newer live pushes
    for (const g of s.groups) {
      for (const col of (g.columns || [])) {
        for (const p of col) {
          for (const w of (p.windows || [])) {
            if (w.buffer && w.preview) {
              const prev = liveBuffers.get(w.buffer);
              if (!prev || (w.preview.ts || 0) >= (prev.ts || 0)) {
                liveBuffers.set(w.buffer, w.preview);
              }
            }
          }
        }
      }
    }

    computeLayout();
    if (initial && !didInitialFit) {
      didInitialFit = true;
      fitScene(true);
    }
    updateHudStatus();
  }

  addEventListener("message", (e) => {
    const d = e.data;
    if (!(d && d.compos === "message" && d.data)) return;
    const msg = d.data;
    if (msg.type === "buffers" && Array.isArray(msg.buffers)) {
      applyBufferUpdates(msg.buffers, true);
    } else if (msg.type === "snapshot" && msg.snapshot) {
      applySnapshot(msg.snapshot, false);
    }
  });

  addEventListener("resize", () => schedulePaint());

  // Request focus on click so keyboard shortcuts work immediately
  document.addEventListener("mousedown", () => {
    try { parent.postMessage({ compos: "request-focus" }, "*"); } catch (_) {}
    window.focus();
  }, true);

  // Boot
  apiGet().then((s) => {
    applySnapshot(s, true);
    syncWatchesSoon();
  }).catch((err) => {
    statusText.textContent = "Load error: " + err.message;
  });
})();
