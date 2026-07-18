const REFRESH_MS = 60000;
let refreshTimer = null;

const CLEANUP_ACTIONS = {
  "clear-audit-log": {
    label: "Clear Audit Log",
    confirm: "Clear all audit log rows? This cannot be undone.",
  },
  "shrink-unclassified-messages": {
    label: "Shrink Unclassified Messages",
    confirm: "Replace content with an empty string for every active message classified as unclassified?",
  },
  "clear-inactive-workers": {
    label: "Clear Inactive Workers",
    confirm: "Delete all inactive worker rows and their related keys/metadata?",
  },
  "clear-inactive-worker-metadata": {
    label: "Clear Inactive Worker Metadata",
    confirm: "Delete metadata rows for inactive workers? This cannot be undone.",
  },
  "clear-completed-failed-tasks": {
    label: "Clear Completed / Failed Tasks",
    confirm: "Delete all completed and failed task rows?",
  },
  "clear-task-metadata-history": {
    label: "Clear Task Metadata History",
    confirm: "Delete all task metadata history rows? This cannot be undone.",
  },
  "clear-logs-before-date": {
    label: "Clear Logs",
    confirm: "Delete app logs before the selected date?",
    requiresDate: true,
  },
  "clear-llm-usage": {
    label: "Clear LLM Usage",
    confirm: "Delete all LLM usage rows?",
  },
};

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value === "string" && value.trim()) {
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed : [];
    } catch (_) {
      return [];
    }
  }
  return [];
}

function formatNumber(value) {
  const number = Number(value ?? 0);
  return Number.isFinite(number) ? number.toLocaleString() : "0";
}

function formatBool(value) {
  if (value === true) return "Yes";
  if (value === false) return "No";
  return "-";
}

function formatDateTime(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleString();
}

function formatAge(seconds) {
  if (seconds === null || seconds === undefined) return "-";
  const value = Number(seconds);
  if (!Number.isFinite(value)) return "-";
  if (value < 60) return `${Math.max(0, Math.round(value))}s ago`;
  const minutes = Math.floor(value / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

function setPill(element, label, tone) {
  if (!element) return;
  element.textContent = label;
  element.className = "worker-manager-pill";
  if (tone) element.classList.add(`worker-manager-pill-${tone}`);
}

function supervisorHealth(state) {
  if (!state) return { label: "Unknown", tone: "warn" };
  if (state.supervisor_recent && state.database_available !== false) return { label: "Running", tone: "ok" };
  if (state.supervisor_recent) return { label: "Degraded", tone: "warn" };
  if (state.supervisor_last_seen_at) return { label: "Stale", tone: "warn" };
  return { label: "Unknown", tone: "warn" };
}

function maintenanceHealth(state) {
  if (!state) return { label: "Unknown", tone: "warn" };
  if (state.maintenance_enabled === false || state.maintenance_status === "disabled") {
    return { label: "Disabled", tone: "warn" };
  }
  if (state.maintenance_status === "degraded") return { label: "Degraded", tone: "warn" };
  if (state.maintenance_recent && state.maintenance_status === "running") return { label: "Running", tone: "ok" };
  if (state.maintenance_last_seen_at) return { label: "Stale", tone: "warn" };
  if (state.maintenance_status === "missing") return { label: "Missing", tone: "bad" };
  return { label: "Unknown", tone: "warn" };
}

function renderDetails(element, rows) {
  if (!element) return;
  element.innerHTML = rows.map(([label, value]) => `
    <div class="worker-manager-detail-row">
      <dt>${escapeHtml(label)}</dt>
      <dd>${escapeHtml(value ?? "-")}</dd>
    </div>
  `).join("");
}

function renderStats(element, rows) {
  if (!element) return;
  element.innerHTML = rows.map(([label, value]) => `
    <div class="worker-manager-stat">
      <div class="worker-manager-stat-label">${escapeHtml(label)}</div>
      <div class="worker-manager-stat-value">${escapeHtml(value ?? "-")}</div>
    </div>
  `).join("");
}

function renderAlert(root, payload, state) {
  const alert = root.querySelector("#worker-manager-alert");
  if (!alert) return;
  const messages = [];
  if (!payload.state_table_installed) {
    messages.push("Worker manager state table is not installed yet.");
  } else if (!state) {
    messages.push("No worker manager heartbeat has been recorded yet.");
  } else {
    if (!state.supervisor_recent) messages.push("Supervisor heartbeat is stale or missing.");
    if (state.maintenance_enabled !== false && !state.maintenance_recent) {
      messages.push("Maintenance heartbeat is stale or missing.");
    }
    if (state.last_maintenance_loop_error) {
      messages.push(`Maintenance loop error: ${state.last_maintenance_loop_error}`);
    }
  }

  if (!messages.length) {
    alert.classList.add("hidden");
    alert.textContent = "";
    return;
  }
  alert.className = "mt-3 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800 dark:border-amber-400 dark:bg-amber-950/40 dark:text-amber-100";
  alert.textContent = messages.join(" ");
}

function renderAuditRows(root, rows) {
  const tbody = root.querySelector("#worker-manager-audit-rows");
  if (!tbody) return;
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="text-sm text-slate-500 dark:text-slate-300">No audit rows in the last hour.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((row) => `
    <tr>
      <td class="font-mono text-xs">${escapeHtml(row.operation || "-")}</td>
      <td>${formatNumber(row.count_5m)}</td>
      <td>${formatNumber(row.count_1h)}</td>
    </tr>
  `).join("");
}

function renderGrowthRows(root, rows) {
  const tbody = root.querySelector("#worker-manager-growth-rows");
  if (!tbody) return;
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="4" class="text-sm text-slate-500 dark:text-slate-300">No growth monitor rows available.</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((row) => `
    <tr>
      <td class="font-mono text-xs">${escapeHtml(row.tablename || "-")}</td>
      <td>${escapeHtml(row.total_size || "-")}</td>
      <td>${formatNumber(row.live_rows)}</td>
      <td>${formatNumber(row.dead_rows)} (${escapeHtml(row.dead_row_pct ?? 0)}%)</td>
    </tr>
  `).join("");
}

function getCleanupButtons(root) {
  return Array.from(root.querySelectorAll("[data-cleanup-action]"));
}

function setCleanupStatus(root, message, isError = false) {
  const status = root.querySelector("#worker-manager-cleanup-status");
  if (!status) return;
  status.textContent = message || "";
  status.className = isError
    ? "mt-1 text-xs text-rose-600 dark:text-rose-300"
    : "mt-1 text-xs text-slate-500 dark:text-slate-400";
}

function setCleanupControls(root, context, busyAction = null) {
  const user = typeof context.getCurrentUser === "function" ? context.getCurrentUser() : null;
  const isDenied = user && user.is_admin === false;
  const state = root.querySelector("#worker-manager-cleanup-admin-state");
  if (state) {
    setPill(state, isDenied ? "Admin required" : "Ready", isDenied ? "warn" : "ok");
  }
  getCleanupButtons(root).forEach((button) => {
    button.disabled = Boolean(busyAction) || isDenied;
    const action = button.dataset.cleanupAction;
    const config = CLEANUP_ACTIONS[action];
    button.textContent = busyAction === action ? "Working..." : (config?.label || button.textContent);
  });
}

function renderCleanupResult(root, result) {
  const element = root.querySelector("#worker-manager-cleanup-result");
  if (!element) return;
  element.classList.remove("hidden");
  element.textContent = JSON.stringify({
    action: result.action,
    rows_affected: result.rows_affected,
    details: result.details || {},
    executed_at: result.executed_at,
  }, null, 2);
}

function buildCleanupBody(root, action) {
  const config = CLEANUP_ACTIONS[action];
  if (!config?.requiresDate) return {};
  const dateInput = root.querySelector("#worker-manager-log-before-date");
  const beforeDate = dateInput?.value?.trim();
  if (!beforeDate) {
    throw new Error("Choose a date before clearing logs.");
  }
  return { before_date: beforeDate };
}

async function runCleanupAction(context, action, trigger) {
  const config = CLEANUP_ACTIONS[action];
  if (!config) return;
  const { root } = context;
  let body;
  try {
    body = buildCleanupBody(root, action);
  } catch (error) {
    setCleanupStatus(root, error.message, true);
    context.setStatus(error.message, true);
    return;
  }
  if (!window.confirm(config.confirm)) return;

  setCleanupControls(root, context, action);
  if (trigger) trigger.disabled = true;
  setCleanupStatus(root, `${config.label} is running...`);
  try {
    const result = await context.requestJSON(`/pwsadmin/api/worker-manager/cleanup/${encodeURIComponent(action)}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    renderCleanupResult(root, result);
    const message = `${config.label} completed; ${formatNumber(result.rows_affected)} row(s) affected.`;
    setCleanupStatus(root, message);
    context.setStatus(message, false);
    await loadWorkerManagerState(context);
  } catch (error) {
    setCleanupStatus(root, error.message, true);
    context.setStatus(error.message, true);
  } finally {
    setCleanupControls(root, context);
  }
}

function renderState(context, payload) {
  const { root } = context;
  const state = payload.state || null;
  const workers = payload.workers || {};
  const maintenance = payload.maintenance || {};
  const auditLog = payload.disk?.audit_log || {};
  const supervisor = supervisorHealth(state);
  const maintenanceStatus = maintenanceHealth(state);
  const managedNames = asArray(state?.managed_worker_names);
  const actions = asArray(state?.maintenance_actions).filter((item) => item?.enabled !== false);
  const lastAction = state?.last_maintenance_action_name
    ? `${state.last_maintenance_action_name} (${state.last_maintenance_action_success === false ? "failed" : "ok"})`
    : "-";

  setPill(root.querySelector("#worker-manager-supervisor-status"), supervisor.label, supervisor.tone);
  setPill(root.querySelector("#worker-manager-maintenance-status"), maintenanceStatus.label, maintenanceStatus.tone);

  const checkedAt = root.querySelector("#worker-manager-checked-at");
  if (checkedAt) checkedAt.textContent = `Checked ${formatDateTime(payload.checked_at)}`;

  renderAlert(root, payload, state);
  renderDetails(root.querySelector("#worker-manager-supervisor-details"), [
    ["PID", state?.supervisor_pid ?? "-"],
    ["Last seen", formatAge(state?.supervisor_last_seen_seconds)],
    ["Database available", formatBool(state?.database_available)],
    ["Expected workers", formatNumber(state?.managed_workers_expected ?? workers.total_workers)],
    ["Running processes", formatNumber(state?.managed_workers_running)],
    ["Manifest workers", managedNames.length ? managedNames.join(", ") : "-"],
    ["Last seed check", formatDateTime(state?.last_seed_check_at)],
    ["Seed result", state?.last_seed_success === false ? state?.last_seed_error || "Failed" : formatBool(state?.last_seed_success)],
    ["Seed interval", state?.seed_check_interval_seconds ? `${formatNumber(state.seed_check_interval_seconds)}s` : "-"],
    ["Manifest", state?.manifest_path || "-"],
  ]);

  renderDetails(root.querySelector("#worker-manager-maintenance-details"), [
    ["PID", state?.maintenance_pid ?? "-"],
    ["Last seen", formatAge(state?.maintenance_last_seen_seconds)],
    ["Interval", state?.maintenance_interval_seconds ? `${formatNumber(state.maintenance_interval_seconds)}s` : "-"],
    ["Actions", actions.length ? actions.map((item) => item.name).join(", ") : "-"],
    ["Last action", lastAction],
    ["Rows affected", state?.last_maintenance_action_rows ?? "-"],
    ["Promote / reset", `${state?.last_promote_count ?? "-"} / ${state?.last_reset_count ?? "-"}`],
    ["Loop error", state?.last_maintenance_loop_error || "-"],
  ]);

  renderStats(root.querySelector("#worker-manager-worker-summary"), [
    ["DB active", formatNumber(workers.active_workers)],
    ["Heartbeat late", formatNumber(workers.heartbeat_late_workers)],
    ["Busy", formatNumber(workers.busy_workers)],
    ["Current load", formatNumber(workers.current_load)],
  ]);

  renderStats(root.querySelector("#worker-manager-disk-summary"), [
    ["Disk guard", maintenance.small_server_disk_maintenance_installed ? "Installed" : "Missing"],
    ["Audit cleanup", maintenance.audit_cleanup_installed ? "Installed" : "Missing"],
    ["Audit rows", formatNumber(auditLog.row_count)],
    ["Audit size", auditLog.total_size || "-"],
    ["Oldest audit", formatDateTime(auditLog.oldest_created_at)],
    ["Latest audit", formatDateTime(auditLog.newest_created_at)],
  ]);

  renderAuditRows(root, payload.audit_noise || []);
  renderGrowthRows(root, payload.disk?.growth_monitor || []);
  setCleanupControls(root, context);
}

async function loadWorkerManagerState(context) {
  const refreshButton = context.root.querySelector("#worker-manager-refresh");
  if (refreshButton) refreshButton.disabled = true;
  try {
    const payload = await context.requestJSON("/pwsadmin/api/worker-manager/state");
    renderState(context, payload);
    context.setStatus("Loaded worker manager state.", false);
  } catch (error) {
    context.setStatus(error.message, true);
  } finally {
    if (refreshButton) refreshButton.disabled = false;
  }
}

export function mount(context) {
  const refreshButton = context.root.querySelector("#worker-manager-refresh");
  if (refreshButton) {
    refreshButton.addEventListener("click", () => loadWorkerManagerState(context));
  }
  context.root.addEventListener("click", (event) => {
    const button = event.target.closest("[data-cleanup-action]");
    if (!button || !context.root.contains(button)) return;
    runCleanupAction(context, button.dataset.cleanupAction, button);
  });
  setCleanupControls(context.root, context);
}

export function onShow(context) {
  context.sharedState.activeTab = context.tabKey;
  loadWorkerManagerState(context);
  if (refreshTimer) window.clearInterval(refreshTimer);
  refreshTimer = window.setInterval(() => loadWorkerManagerState(context), REFRESH_MS);
}

export function onHide() {
  if (refreshTimer) {
    window.clearInterval(refreshTimer);
    refreshTimer = null;
  }
}
