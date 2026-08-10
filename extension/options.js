const DEFAULTS = { ports: [4004], scan: true, scanFrom: 4004, scanTo: 4013, keys: true };

const $ = (id) => document.getElementById(id);

async function load() {
  const s = { ...DEFAULTS, ...(await chrome.storage.sync.get(DEFAULTS)) };
  $("ports").value = s.ports.join(", ");
  $("scan").checked = s.scan;
  $("scanFrom").value = s.scanFrom;
  $("scanTo").value = s.scanTo;
  $("keys").checked = s.keys;
}

async function save() {
  const ports = $("ports")
    .value.split(",")
    .map((p) => parseInt(p.trim(), 10))
    .filter((p) => p >= 1 && p <= 65535);

  await chrome.storage.sync.set({
    ports,
    scan: $("scan").checked,
    scanFrom: parseInt($("scanFrom").value, 10) || DEFAULTS.scanFrom,
    scanTo: parseInt($("scanTo").value, 10) || DEFAULTS.scanTo,
    keys: $("keys").checked
  });

  $("status").textContent = "saved";
  setTimeout(() => ($("status").textContent = ""), 1500);
}

async function refresh() {
  let rows = [];
  try {
    const r = await chrome.runtime.sendMessage({ cmd: "status" });
    rows = (r && r.ok && r.result) || [];
  } catch {
    /* worker asleep — it wakes on the next sweep */
  }

  const body = $("conns");
  body.textContent = "";

  if (!rows.length) {
    const td = body.insertRow().insertCell();
    td.colSpan = 3;
    td.textContent = "nothing connected — is a daemon running?";
    return;
  }

  for (const r of rows.sort((a, b) => a.port - b.port)) {
    const tr = body.insertRow();
    const dot = tr.insertCell();
    const span = document.createElement("span");
    span.className = `dot ${r.up ? "up" : "down"}`;
    dot.appendChild(span);
    tr.insertCell().textContent = r.port + (r.pinned ? "" : " (scanned)");
    tr.insertCell().textContent = r.up ? r.name : "—";
  }
}

$("save").addEventListener("click", save);
load();
refresh();
setInterval(refresh, 2000);
