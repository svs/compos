// recorder.js -- the voice recorder of tts-training, run in compos's app frame.
// The page only records and draws: the script, the mood and every rule are Scheme's.
(() => {
  const API = "_compos/app";
  let S = null, rec = null, stream = null, analyser = null, t0 = 0;
  const el = (tag, cls, parent, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  };
  const fmt = (t) => Math.floor(t / 60) + ":" + String(Math.floor(t % 60)).padStart(2, "0");

  const app = el("div", "rec", document.body);
  const mood = el("div", "mood", app);
  const script = el("div", "script", app);
  const meter = el("div", "meter", app);
  const bar = el("div", "bar", meter);
  const row = el("div", "row", app);
  const btn = el("button", "btn", row, "● Record");
  const clock = el("div", "clock", row);
  const status = el("div", "status", app);
  const keys = el("div", "keys", app);

  const post = (o) => fetch(API, { method: "POST", body: JSON.stringify(o) }).then((r) => r.json()).then(set);
  function set(s) {
    S = s || S || {};
    mood.textContent = S.mood || "";
    script.textContent = S.script || "";
    status.textContent = rec ? "● Recording · SPC stops and keeps it · x throws it away" : (S.status || "");
    keys.textContent = S.keys || "";
  }

  // a key typed here goes to the editor, whose keymap runs the command
  addEventListener("keydown", (e) => {
    if (["Shift", "Alt", "Meta", "Control"].includes(e.key)) return;
    e.preventDefault();
    parent.postMessage({ compos: "key", key: e.key, code: e.code, shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey, ctrlKey: e.ctrlKey }, "*");
  });
  document.addEventListener("mousedown", () => { try { parent.postMessage({ compos: "request-focus" }, "*"); } catch (e) {} window.focus(); }, true);
  addEventListener("message", (e) => {
    const d = e.data;
    if (!(d && d.compos === "message" && d.data)) return;
    if (d.data.state) set(d.data.state);
    if (d.data.act) run(d.data.act);
  });
  btn.addEventListener("click", () => run("toggle"));

  function run(a) {
    if (a === "toggle") return rec ? stop(true) : start();
    if (a === "cancel") return stop(false);
  }
  async function start() {
    try {
      if (!stream) stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
    } catch (e) { status.textContent = "No microphone: " + e.message; return; }
    if (!analyser) {
      const ctx = new AudioContext();
      analyser = ctx.createAnalyser();
      analyser.fftSize = 1024;
      ctx.createMediaStreamSource(stream).connect(analyser);
    }
    const mime = ["audio/webm;codecs=opus", "audio/mp4", "audio/webm"].find((m) => window.MediaRecorder && MediaRecorder.isTypeSupported(m)) || "";
    const r = new MediaRecorder(stream, mime ? { mimeType: mime, audioBitsPerSecond: 256000 } : undefined);
    const chunks = [];
    r.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    rec = { r, chunks, mime: r.mimeType || mime };
    r.start(250);
    t0 = performance.now();
    btn.textContent = "■ Stop";
    app.classList.add("on");
    set();
  }
  function stop(save) {
    if (!rec) return;
    const x = rec;
    rec = null;
    btn.textContent = "● Record";
    app.classList.remove("on");
    const secs = (performance.now() - t0) / 1000;
    x.r.onstop = () => {
      if (!save || !x.chunks.length) { status.textContent = "Thrown away"; return; }
      const fr = new FileReader();
      fr.onload = () => { status.textContent = "Saving…"; post({ op: "save", data: String(fr.result).split(",")[1] || "", mime: x.mime, secs }); };
      fr.readAsDataURL(new Blob(x.chunks, { type: x.mime || "audio/webm" }));
    };
    x.r.stop();
  }

  // the level: green is right, red clips
  function tick() {
    if (analyser) {
      const a = new Float32Array(analyser.fftSize);
      analyser.getFloatTimeDomainData(a);
      let p = 0;
      for (const v of a) p = Math.max(p, Math.abs(v));
      const db = 20 * Math.log10(p || 1e-6);
      bar.style.width = Math.max(0, Math.min(100, ((db + 60) / 60) * 100)) + "%";
      bar.className = "bar" + (db > -3 ? " hot" : db > -20 ? " ok" : "");
    }
    clock.textContent = rec ? fmt((performance.now() - t0) / 1000) : "";
    requestAnimationFrame(tick);
  }

  fetch(API).then((r) => r.json()).then(set);
  requestAnimationFrame(tick);
})();
