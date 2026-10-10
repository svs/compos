// a daemon is "PORT" on this machine, or "HOST:PORT" on another one
const DEFAULTS = { daemons: ["4004"], scan: true, scanFrom: 4004, scanTo: 4013, keys: true };
const DAEMON = /^(?:(\[[^\]]+\]|[^:\s]+):)?(\d{1,5})$/;

const $ = (id) => document.getElementById(id);

async function load() {
  const stored = await chrome.storage.sync.get(null);
  const s = { ...DEFAULTS, ...stored };
  // v0.6 stored pinned ports as numbers under `ports`
  if (!stored.daemons && Array.isArray(stored.ports)) s.daemons = stored.ports.map(String);
  $("daemons").value = s.daemons.join(", ");
  $("scan").checked = s.scan;
  $("scanFrom").value = s.scanFrom;
  $("scanTo").value = s.scanTo;
  $("keys").checked = s.keys;
}

async function save() {
  const daemons = $("daemons")
    .value.split(",")
    .map((d) => d.trim())
    .filter((d) => {
      const m = DAEMON.exec(d);
      return m && Number(m[2]) >= 1 && Number(m[2]) <= 65535;
    });

  await chrome.storage.sync.remove("ports");
  await chrome.storage.sync.set({
    daemons,
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

  const order = (a, b) => (a.host === b.host ? a.port - b.port : a.address.localeCompare(b.address));
  for (const r of rows.sort(order)) {
    const tr = body.insertRow();
    const dot = tr.insertCell();
    const span = document.createElement("span");
    span.className = `dot ${r.up ? "up" : "down"}`;
    dot.appendChild(span);
    tr.insertCell().textContent = r.address + (r.pinned ? "" : " (scanned)");
    tr.insertCell().textContent = r.up ? r.name : "—";
  }
}

$("save").addEventListener("click", save);
load();
refresh();
setInterval(refresh, 2000);
