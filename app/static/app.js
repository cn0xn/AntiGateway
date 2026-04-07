/* ═══════════════════════════════════════════════════════════════
   Pi Gateway UI — app.js
   ═══════════════════════════════════════════════════════════════ */

/* ── State ─────────────────────────────────────────────────────── */
let currentLogService = "zapret2";
let refreshTimer      = null;
let syncPollTimer     = null;
let listsData         = null;

/* ── Auth ──────────────────────────────────────────────────────── */
function getToken() {
  return localStorage.getItem("gw_token") || "";
}
function setToken(t) {
  localStorage.setItem("gw_token", t);
}
function clearToken() {
  localStorage.removeItem("gw_token");
}

function showAuthModal(errorMsg) {
  const modal = document.getElementById("authModal");
  const err   = document.getElementById("authError");
  modal.style.display = "flex";
  if (errorMsg) {
    err.textContent = errorMsg;
    err.style.display = "block";
  } else {
    err.style.display = "none";
  }
  setTimeout(() => document.getElementById("authTokenInput").focus(), 50);
}

function hideAuthModal() {
  document.getElementById("authModal").style.display = "none";
  document.getElementById("authTokenInput").value = "";
}

async function submitToken() {
  const token = document.getElementById("authTokenInput").value.trim();
  if (!token) return;
  setToken(token);
  // Test the token
  const res = await fetch("/api/service", {
    method:  "POST",
    headers: {"Content-Type": "application/json", "X-Auth-Token": token},
    body:    JSON.stringify({name: "__ping__", action: "status"}),
  }).catch(() => null);
  if (res && res.status === 401) {
    clearToken();
    showAuthModal("Неверный токен");
    return;
  }
  hideAuthModal();
  showToast("Авторизован ✓", "success");
}

/* Central fetch wrapper — adds auth header, handles 401 */
async function apiFetch(url, opts = {}) {
  const token = getToken();
  if (token && opts.method && opts.method !== "GET") {
    opts.headers = Object.assign({}, opts.headers || {}, {"X-Auth-Token": token});
  }
  const res = await fetch(url, opts);
  if (res.status === 401) {
    showAuthModal("Сессия истекла или токен неверный");
    throw new Error("Unauthorized");
  }
  return res;
}

/* ── Init ──────────────────────────────────────────────────────── */
document.addEventListener("DOMContentLoaded", () => {
  if (!getToken()) showAuthModal();
  refreshStatus();
  refreshLogs();
  startAutoRefresh();
});

/* ── Tab switching ─────────────────────────────────────────────── */
function switchTab(name, btn) {
  document.querySelectorAll(".tab-content").forEach(el => el.classList.remove("active"));
  document.querySelectorAll(".nav-tab").forEach(el => el.classList.remove("active"));
  document.getElementById("tab-" + name).classList.add("active");
  if (btn) btn.classList.add("active");

  if (name === "lists" && !listsData) loadListsTab();
  if (name === "vpn")                 loadVpnTab();
}

/* ═══════════════════════════════════════════════════════════════
   DASHBOARD
   ═══════════════════════════════════════════════════════════════ */

function startAutoRefresh() {
  clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshStatus, 5000);
}

async function refreshStatus() {
  const dot = document.getElementById("updateDot");
  try {
    const res  = await fetch("/api/status");
    const data = await res.json();
    renderStatus(data);
    dot.classList.add("pulse");
    setTimeout(() => dot.classList.remove("pulse"), 500);
    document.getElementById("lastUpdated").textContent = "обновлено " + data.ts;
  } catch {
    dot.style.background = "var(--red)";
  }
}

function renderStatus(d) {
  const s = d.services;

  setServiceCard("zapret2", s.zapret2.active,
    s.zapret2.active ? `PID ${s.zapret2.pid}` : "не запущен");

  const awgMeta = s.awg.active
    ? (s.awg.handshake ? `handshake ${s.awg.handshake}` : "туннель активен")
      + (s.awg.rx ? ` · ↓${s.awg.rx} ↑${s.awg.tx}` : "")
    : "интерфейс DOWN";
  setServiceCard("awg", s.awg.active, awgMeta);

  setServiceCard("dnsmasq", s.dnsmasq.active,
    s.dnsmasq.active ? "обслуживает DNS" : "не запущен");

  setModeButtons("svc_youtube", d.routing.youtube);
  setModeButtons("svc_discord", d.routing.discord);

  document.getElementById("stat-blocked").textContent = fmtNum(d.stats.blocked_ips);
  document.getElementById("stat-zapret").textContent  = fmtNum(d.stats.zapret_ips);
  document.getElementById("stat-rx").textContent      = s.awg.rx  || "—";
  document.getElementById("stat-tx").textContent      = s.awg.tx  || "—";
}

function setServiceCard(name, active, meta) {
  const badge  = document.getElementById(`status-${name}`);
  const card   = document.getElementById(`card-${name}`);
  const metaEl = document.getElementById(`meta-${name}`);
  if (!badge) return;
  badge.textContent = active ? "active" : "inactive";
  badge.className   = "status-badge " + (active ? "active" : "inactive");
  if (metaEl) metaEl.textContent = meta;
  card.classList.toggle("active-glow", active);
  card.classList.toggle("error-glow",  !active);
}

function setModeButtons(listId, mode) {
  document.querySelectorAll(`.mode-btn[data-lid="${listId}"]`).forEach(b => {
    b.classList.remove("active-tunnel","active-zapret","active-direct","active-disabled");
    if (b.dataset.mode === mode) b.classList.add(`active-${mode}`);
  });
}

/* ── Service actions ────────────────────────────────────────────── */
async function serviceAction(name, action) {
  showToast(`${action} ${name}…`, "info");
  try {
    const res  = await apiFetch("/api/service", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({name, action}),
    });
    const data = await res.json();
    showToast(data.ok ? `${name}: ${action} ✓` : `Ошибка: ${data.error||data.output}`,
              data.ok ? "success" : "error");
    setTimeout(refreshStatus, 1200);
    if (data.ok) setTimeout(runDiagnostics, 2000);
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Сетевая ошибка: " + e.message, "error");
  }
}

/* ── Quick routing from dashboard ──────────────────────────────── */
async function setListMode(listId, mode) {
  try {
    const res  = await apiFetch("/api/lists/save", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({updates: {[listId]: {mode}}}),
    });
    const data = await res.json();
    if (!data.ok) { showToast("Ошибка сохранения", "error"); return; }
    setModeButtons(listId, mode);
    await triggerApply();
    showToast(`Применено: ${mode}`, "success");
    listsData = null;
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Ошибка: " + e.message, "error");
  }
}

async function triggerApply() {
  await apiFetch("/api/lists/sync", {
    method:  "POST",
    headers: {"Content-Type": "application/json"},
    body:    JSON.stringify({force: false}),
  });
}

/* ── Logs ────────────────────────────────────────────────────────── */
function switchLog(service, btn) {
  currentLogService = service;
  document.querySelectorAll(".log-tab").forEach(t => t.classList.remove("active"));
  if (btn) btn.classList.add("active");
  refreshLogs();
}

async function refreshLogs() {
  const viewer = document.getElementById("logViewer");
  if (!viewer) return;
  try {
    const res  = await fetch(`/api/logs?service=${currentLogService}`);
    const data = await res.json();
    if (!data.lines?.length) {
      viewer.innerHTML = `<div class="log-placeholder">Нет записей</div>`;
      return;
    }
    viewer.innerHTML = data.lines.map(line => {
      const lo = line.toLowerCase();
      let cls = "";
      if (lo.includes("error")||lo.includes("failed")||lo.includes("fail")||lo.includes("emerg")||lo.includes("crit")) cls = "err";
      else if (lo.includes("warn")) cls = "warn";
      return `<div class="log-line ${cls}">${escHtml(line)}</div>`;
    }).join("");
    viewer.scrollTop = viewer.scrollHeight;
  } catch (e) {
    viewer.innerHTML = `<div class="log-placeholder log-line err">Ошибка: ${escHtml(e.message)}</div>`;
  }
}

/* ── Diagnostics ─────────────────────────────────────────────────── */
async function runDiagnostics() {
  const panel  = document.getElementById("diagPanel");
  const checks = document.getElementById("diagChecks");
  if (!panel || !checks) return;

  panel.style.display = "block";
  checks.innerHTML = '<div class="diag-running">Проверка…</div>';

  try {
    const res  = await fetch("/api/diagnostics");
    const data = await res.json();

    document.getElementById("diagTs").textContent = data.ts || "";

    checks.innerHTML = data.checks.map(c => `
      <div class="diag-check ${c.ok ? "ok" : "fail"}">
        <span class="diag-icon">${c.ok ? "✓" : "✗"}</span>
        <span class="diag-name">${escHtml(c.name)}</span>
        <span class="diag-detail">${escHtml(c.detail)}</span>
      </div>
    `).join("");
  } catch (e) {
    checks.innerHTML = `<div class="diag-running" style="color:var(--red)">Ошибка: ${escHtml(e.message)}</div>`;
  }
}

/* ═══════════════════════════════════════════════════════════════
   LISTS TAB
   ═══════════════════════════════════════════════════════════════ */

const CATEGORIES = {
  "Russia":     "Россия",
  "Services":   "Сервисы",
  "Categories": "Категории",
};

const MODE_LABELS = {
  tunnel:   "Tunnel",
  zapret:   "Zapret",
  direct:   "Direct",
  disabled: "Off",
};

async function loadListsTab() {
  const container = document.getElementById("listsContainer");
  container.innerHTML = '<div class="lists-loading">Загрузка…</div>';
  try {
    const res = await fetch("/api/lists");
    listsData = await res.json();
    renderListsTab();
    updateSyncStatus();
  } catch (e) {
    container.innerHTML = `<div class="lists-loading" style="color:var(--red)">Ошибка: ${escHtml(e.message)}</div>`;
  }
}

function renderListsTab() {
  if (!listsData) return;
  const container = document.getElementById("listsContainer");
  container.innerHTML = "";

  const groups = {};
  for (const lst of Object.values(listsData.lists)) {
    if (!groups[lst.category]) groups[lst.category] = [];
    groups[lst.category].push(lst);
  }

  for (const [catKey, catLabel] of Object.entries(CATEGORIES)) {
    const items = groups[catKey];
    if (!items) continue;

    const section = document.createElement("div");
    section.className = "list-category";

    const title = document.createElement("div");
    title.className = "category-title";
    title.textContent = catLabel;
    section.appendChild(title);

    for (const lst of items) {
      section.appendChild(renderListItem(lst));
    }
    container.appendChild(section);
  }
}

function renderListItem(lst) {
  const row = document.createElement("div");
  row.className = `list-item mode-${lst.mode || "disabled"}`;
  row.id = `list-row-${lst.id}`;

  const toggleWrap = document.createElement("label");
  toggleWrap.className = "toggle";
  const input = document.createElement("input");
  input.type    = "checkbox";
  input.checked = lst.enabled && lst.mode !== "disabled";
  input.onchange = () => onToggle(lst.id, input.checked);
  const slider = document.createElement("div");
  slider.className = "toggle-slider";
  toggleWrap.append(input, slider);

  const info = document.createElement("div");
  info.className = "list-info";
  info.innerHTML = `
    <div class="list-name">${escHtml(lst.name)}</div>
    <div class="list-desc">${escHtml(lst.description || "")}</div>
    <div class="list-count" id="count-${lst.id}">${lst.domain_count ? lst.domain_count.toLocaleString("ru") + " доменов" : ""}</div>
  `;

  const modes = document.createElement("div");
  modes.className = "list-modes";
  for (const [mode, label] of Object.entries(MODE_LABELS)) {
    const btn = document.createElement("button");
    btn.className = `mode-btn${lst.mode === mode ? " active-" + mode : ""}`;
    btn.dataset.lid  = lst.id;
    btn.dataset.mode = mode;
    btn.textContent  = label;
    btn.onclick = () => onModeChange(lst.id, mode);
    modes.appendChild(btn);
  }

  row.append(toggleWrap, info, modes);
  return row;
}

function onToggle(listId, enabled) {
  if (!listsData?.lists[listId]) return;
  const lst = listsData.lists[listId];
  lst.enabled = enabled;
  if (!enabled) lst.mode = "disabled";
  updateListRow(listId);
  savePending();
}

function onModeChange(listId, mode) {
  if (!listsData?.lists[listId]) return;
  const lst = listsData.lists[listId];
  lst.mode    = mode;
  lst.enabled = mode !== "disabled";
  updateListRow(listId);
  savePending();
  if (listId === "svc_youtube") setModeButtons("svc_youtube", mode);
  if (listId === "svc_discord") setModeButtons("svc_discord", mode);
}

function updateListRow(listId) {
  const lst = listsData?.lists[listId];
  if (!lst) return;
  const row = document.getElementById(`list-row-${listId}`);
  if (!row) return;
  row.className = `list-item mode-${lst.mode || "disabled"}`;

  const input = row.querySelector("input[type=checkbox]");
  if (input) input.checked = lst.enabled && lst.mode !== "disabled";

  row.querySelectorAll(".mode-btn").forEach(b => {
    b.classList.remove("active-tunnel","active-zapret","active-direct","active-disabled");
    if (b.dataset.mode === lst.mode) b.classList.add(`active-${lst.mode}`);
  });
}

let saveTimer = null;
function savePending() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveAllLists, 800);
}

async function saveAllLists() {
  if (!listsData) return;
  const updates = {};
  for (const [id, lst] of Object.entries(listsData.lists)) {
    updates[id] = {mode: lst.mode, enabled: lst.enabled};
  }
  try {
    await apiFetch("/api/lists/save", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({updates}),
    });
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Ошибка сохранения: " + e.message, "error");
  }
}

/* ── Sync ────────────────────────────────────────────────────────── */
async function syncLists(force) {
  await saveAllLists();
  showSyncLog();
  document.getElementById("btnSync").disabled  = true;
  document.getElementById("btnForce").disabled = true;
  document.getElementById("btnApply").disabled = true;
  document.getElementById("syncStatus").textContent = "⟳ Синхронизация…";

  try {
    const res = await apiFetch("/api/lists/sync", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({force}),
    });
    if ((await res.json()).ok) pollSyncStatus();
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Ошибка: " + e.message, "error");
    resetSyncButtons();
  }
}

async function applyLists() {
  await saveAllLists();
  showSyncLog();
  document.getElementById("btnApply").disabled = true;
  document.getElementById("syncStatus").textContent = "⟳ Применение…";

  try {
    const res = await apiFetch("/api/lists/sync", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({force: false}),
    });
    if ((await res.json()).ok) pollSyncStatus();
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Ошибка: " + e.message, "error");
    resetSyncButtons();
  }
}

function showSyncLog() {
  const wrap = document.getElementById("syncLogWrap");
  const log  = document.getElementById("syncLog");
  wrap.style.display = "block";
  log.innerHTML = "";
}

function pollSyncStatus() {
  clearInterval(syncPollTimer);
  let lastLen = 0;
  syncPollTimer = setInterval(async () => {
    try {
      const res  = await fetch("/api/lists/sync/status");
      const data = await res.json();

      const log = document.getElementById("syncLog");
      if (log && data.log) {
        for (let i = lastLen; i < data.log.length; i++) {
          const line = data.log[i];
          const span = document.createElement("div");
          span.textContent = line;
          if (line.includes("✗") || line.includes("Ошибка")) span.className = "err";
          if (line.includes("Готово")) span.className = "ok";
          log.appendChild(span);
          log.scrollTop = log.scrollHeight;
        }
        lastLen = data.log.length;
      }

      if (!data.running) {
        clearInterval(syncPollTimer);
        resetSyncButtons();
        if (data.error) {
          showToast("Ошибка синхронизации: " + data.error, "error");
        } else {
          showToast("Синхронизация завершена", "success");
          listsData = null;
          loadListsTab();
          setTimeout(runDiagnostics, 800);
        }
        document.getElementById("syncStatus").textContent = "";
      }
    } catch { /* ignore */ }
  }, 500);
}

function resetSyncButtons() {
  document.getElementById("btnSync").disabled  = false;
  document.getElementById("btnForce").disabled = false;
  document.getElementById("btnApply").disabled = false;
}

function updateSyncStatus() {
  const el = document.getElementById("syncStatus");
  if (!listsData?.last_sync || !el) return;
  const d = new Date(listsData.last_sync);
  el.textContent = `Синхронизировано: ${d.toLocaleString("ru")}`;
}

/* ═══════════════════════════════════════════════════════════════
   SHARED UTILS
   ═══════════════════════════════════════════════════════════════ */

function showToast(msg, type = "info") {
  const c = document.getElementById("toastContainer");
  const t = document.createElement("div");
  t.className = `toast ${type}`;
  t.textContent = msg;
  c.appendChild(t);
  setTimeout(() => { t.classList.add("fadeout"); setTimeout(() => t.remove(), 300); }, 3500);
}

function escHtml(s) {
  return String(s)
    .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

function fmtNum(n) {
  return (n != null) ? n.toLocaleString("ru") : "—";
}

/* ═══════════════════════════════════════════════════════════════
   VPN TAB
   ═══════════════════════════════════════════════════════════════ */

async function loadVpnTab() {
  setVpnStatus("Загрузка…");
  try {
    const res  = await fetch("/api/awg/config");
    const data = await res.json();
    if (!data.ok) { setVpnStatus("Ошибка: " + data.error, true); return; }

    const nc = data.network || {};
    document.getElementById("vpn-iface").value = nc.iface || "";
    document.getElementById("vpn-gw").value    = nc.gw_ip || "";

    const info = document.getElementById("vpn-current-info");
    const pre  = document.getElementById("vpn-current-conf");
    if (data.has_config && data.config) {
      info.style.display = "block";
      pre.textContent    = data.config;
    } else {
      info.style.display = "none";
    }

    setVpnStatus(data.has_config ? "Конфиг загружен ✓" : "Конфиг не задан");
  } catch (e) {
    setVpnStatus("Ошибка: " + e.message, true);
  }
}

async function applyAwgConfig() {
  const conf  = document.getElementById("vpn-conf").value.trim();
  const iface = document.getElementById("vpn-iface").value.trim();
  const gw    = document.getElementById("vpn-gw").value.trim();

  if (!conf)          { showToast("Вставьте содержимое awg0.conf", "error"); return; }
  if (!iface || !gw)  { showToast("Укажите интерфейс и IP шлюза", "error"); return; }

  const btn = document.getElementById("btnApplyVpn");
  btn.disabled = true;
  setVpnStatus("Применение…");

  try {
    const res  = await apiFetch("/api/awg/config", {
      method:  "POST",
      headers: {"Content-Type": "application/json"},
      body:    JSON.stringify({config: conf, iface, gw_ip: gw}),
    });
    const data = await res.json();
    if (data.ok) {
      showToast("AWG конфиг применён, туннель перезапущен ✓", "success");
      setVpnStatus("Применено ✓");
      document.getElementById("vpn-conf").value = "";
      setTimeout(loadVpnTab, 1500);
      setTimeout(refreshStatus, 2000);
    } else {
      showToast("Ошибка: " + (data.error || data.output), "error");
      setVpnStatus("Ошибка: " + (data.error || data.output), true);
    }
  } catch (e) {
    if (e.message !== "Unauthorized")
      showToast("Сетевая ошибка: " + e.message, "error");
    setVpnStatus("Ошибка: " + e.message, true);
  } finally {
    btn.disabled = false;
  }
}

function setVpnStatus(msg, isError) {
  const el = document.getElementById("vpn-status");
  if (!el) return;
  el.textContent = msg;
  el.style.color = isError ? "var(--red)" : "var(--text2)";
}
