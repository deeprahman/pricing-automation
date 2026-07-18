import { configureHttp, requestJSON } from "./http.js";
import { sharedState } from "./state.js";

const manifestElement = document.getElementById("pwsadmin-dashboard-manifest");
const dashboardManifest = manifestElement
  ? JSON.parse(manifestElement.textContent || "{}")
  : { tabs: [], initial_tab: "tasks", initial_subtabs: {} };

sharedState.manifest = dashboardManifest;
sharedState.activeTab = dashboardManifest.initial_tab || "tasks";
sharedState.activeSubtabs = { ...(dashboardManifest.initial_subtabs || {}) };

    const statusEl = document.getElementById("status");
    const panels = Array.from(document.querySelectorAll("[data-registry-panel]"));
    const navButtons = Array.from(document.querySelectorAll("[data-registry-nav]"));
    const panelByTab = new Map(panels.map((panel) => [panel.dataset.tabKey, panel]));
    const navByTab = new Map(navButtons.map((button) => [button.dataset.tabKey, button]));
    const tabModuleCache = new Map();
    const subtabModuleCache = new Map();
    let taskCursor = null, logCursor = null, bookingCursor = null, remoteCache = [];
    let workerCursor = null;
    const taskDetailCache = new Map();
    let bookingHasNext = false;
    let bsoCursor = null;
    let bsoHasNext = false;
    let platformTokenItems = [];
    let llmUsageCursor = null;
    let llmUsageHasNext = false;
    let llmProviderItems = [];
    let llmPricingItems = [];
    let activeLlmSubtab = "usage";
    let pricingPropertiesCache = [];
    let pricingPlatformsCache = [];
    let pricingListingCacheByPlatformId = new Map();
    let pricingListingRows = [];
    let bookingPropertyNameById = new Map();
    let bookingPlatformNameById = new Map();
    const PROPERTY_STAGE_ORDER = ["pms", "ota", "dpt"];
    const PROPERTY_STAGE_LABELS = { pms: "PMS", ota: "OTA (OTP)", dpt: "DPT" };
    const REMOTE_PAGE_SIZE = 20;
    let activePropertyStage = "pms";
    let activePropertiesSubtab = "import";
    let activePricingSubtab = "rules";
    let currentUserProfile = null;
    let propertyStagePlatformByType = { pms: "", ota: "", dpt: "" };
    const EMPTY_PROPERTY_STAGE_COMPLETION = { pms: false, ota: false, dpt: false };
    let propertyStageCompleted = { ...EMPTY_PROPERTY_STAGE_COMPLETION };
    let remoteColumnDefs = [];
    let remoteCurrentPage = 1;
    let remoteSelectedIds = new Set();
    let existingPropertyLinksModalState = { lookupId: null, items: [], propertyName: "", listingLabel: "", selectedTargetsByLookupId: {} };
    const EXISTING_PROPERTIES_PAGE_SIZE = 50;
    let existingPropertiesPage = 1;
    let existingPropertiesPageCursors = [null];
    let existingPropertiesNextCursor = null;
    let existingPropertiesTotalCount = 0;
    let messageClassesCache = [];
    let messageClassAdminCache = [];
    let messageClassTableItems = [];
    let messageClassCursor = null;
    let messageClassTotalCount = 0;
    let taskEnqueueOptions = { queues: [], workers: [] };
    let selectedMessageClassId = null;
    let selectedPricingRuleUuid = null;
    const SIMPLE_PRICING_MODE_KEY = "pwsadmin_pricing_mode";
    configureHttp({
      onUnauthorized: () => {
        sessionStorage.removeItem("pwsadmin_token");
        localStorage.removeItem("pwsadmin_token");
        localStorage.removeItem(SIMPLE_PRICING_MODE_KEY);
        window.location.replace("/pwsadmin/home");
      },
    });
    const PRICING_TARGET_SCOPE_OPTIONS = new Set(["property_platform", "property", "platform", "global", "listing"]);
    const PRICING_STAY_LENGTH_OPERATORS = new Set(["gt", "gte", "lt", "lte", "between"]);
    const MODERATE_NUMERIC_COMPARISON_OPERATORS = new Set(["eq", "gt", "gte", "lt", "lte", "between"]);
    const MODERATE_BOOKING_CLASS_OPERATORS = new Set(["any_of", "all_of"]);
    const PRICING_TARGET_RATE_TYPES = new Set(["base", "recommended", "minimum", "maximum"]);
    const PRICING_SEASON_APPLIES_TO_VALUES = new Set(["target_date", "arrival_date", "departure_date"]);
    const MODERATE_STAY_CONDITION_FIELDS = [
      {
        key: "stay_length",
        idBase: "pricing-moderate-stay-length",
        label: "stay_length",
      },
      {
        key: "stay_extended",
        idBase: "pricing-moderate-stay-extended",
        label: "stay_extended",
      },
      {
        key: "stay_contracted",
        idBase: "pricing-moderate-stay-contracted",
        label: "stay_contracted",
      },
    ];
    const SIMPLE_PRICING_SUPPORTED_OPERATIONS = new Set(["increase", "decrease", "set", "multiplier"]);
    const MODERATE_PRICING_OPERATION_CONFIG = {
      increase: { subject: "price", amountTypeOptions: ["percentage", "flat"], amountLabel: "Amount", amountMin: 0, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: true, amountMode: "decimal" },
      decrease: { subject: "price", amountTypeOptions: ["percentage", "flat"], amountLabel: "Amount", amountMin: 0, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: true, amountMode: "decimal" },
      set: { subject: "price", fixedType: "fixed", amountLabel: "Price", amountMin: 0, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: true, amountMode: "decimal" },
      multiplier: { subject: "price", fixedType: "multiplier", amountLabel: "Multiplier", amountMin: 0.01, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: true, amountMode: "decimal", allowEqualMin: false },
      min_price: { subject: "price", fixedType: "min_price", amountLabel: "Minimum price", amountMin: 0, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: false, amountMode: "decimal" },
      max_price: { subject: "price", fixedType: "max_price", amountLabel: "Maximum price", amountMin: 0, amountStep: "0.01", requiresAmount: true, requiresApplyWindow: false, amountMode: "decimal" },
      remove_overrides: { subject: "price", fixedType: "remove_overrides", amountLabel: "Amount", amountMin: 0, amountStep: "0.01", requiresAmount: false, requiresApplyWindow: false, amountMode: "decimal" },
      close_dates: { subject: "availability", fixedType: "close_dates", amountLabel: "Amount", amountMin: 0, amountStep: "0.01", requiresAmount: false, requiresApplyWindow: false, amountMode: "decimal" },
      open_dates: { subject: "availability", fixedType: "open_dates", amountLabel: "Amount", amountMin: 0, amountStep: "0.01", requiresAmount: false, requiresApplyWindow: false, amountMode: "decimal" },
      min_stay: { subject: "length_of_stay", fixedType: "min_stay", amountLabel: "Minimum nights", amountMin: 1, amountStep: "1", requiresAmount: true, requiresApplyWindow: false, amountMode: "integer" },
      max_stay: { subject: "length_of_stay", fixedType: "max_stay", amountLabel: "Maximum nights", amountMin: 1, amountStep: "1", requiresAmount: true, requiresApplyWindow: false, amountMode: "integer" },
    };
    const MODERATE_PRICING_SUPPORTED_OPERATIONS = new Set(Object.keys(MODERATE_PRICING_OPERATION_CONFIG));

    function setStatus(msg, err = false) {
      statusEl.textContent = msg;
      statusEl.className = err
        ? "mt-2 text-sm text-rose-600 dark:text-rose-300"
        : "mt-2 text-sm text-slate-600 dark:text-slate-300";
    }

    function getTabManifest(tabKey) {
      return (dashboardManifest.tabs || []).find((item) => item.key === tabKey) || null;
    }

    function buildModuleContext(root, tabKey, subtabKey = null) {
      return {
        root,
        tabKey,
        subtabKey,
        requestJSON,
        setStatus,
        getCurrentUser: () => currentUserProfile || sharedState.currentUserProfile || null,
        sharedState,
      };
    }

    function syncDashboardUrl(tabKey, subtabKey = null) {
      const url = new URL(window.location.href);
      url.searchParams.set("tab", tabKey);
      if (subtabKey) {
        url.searchParams.set("subtab", subtabKey);
      } else {
        url.searchParams.delete("subtab");
      }
      url.searchParams.delete("token");
      window.history.replaceState({}, "", url.toString());
    }

    function normalizeLegacyHosts() {
      document.querySelectorAll("[data-registry-panel] > .panel-legacy-host > section.panel.hidden").forEach((node) => node.classList.remove("hidden"));
      document.querySelectorAll("[data-subtab-panel] > .legacy-subtab-host > div.hidden[id$='-panel']").forEach((node) => node.classList.remove("hidden"));
    }

    function ensureTabModule(tabKey, lifecycle = "onShow") {
      const tabManifest = getTabManifest(tabKey);
      const root = panelByTab.get(tabKey);
      if (!tabManifest?.js_module || !root) return;
      let record = tabModuleCache.get(tabKey);
      if (!record) {
        record = { mounted: false, module: null, promise: null };
        record.promise = import(tabManifest.js_module).then((module) => {
          record.module = module;
          if (!record.mounted && typeof module.mount === "function") {
            return Promise.resolve(module.mount(buildModuleContext(root, tabKey))).then(() => {
              record.mounted = true;
              return module;
            });
          }
          record.mounted = true;
          return module;
        });
        tabModuleCache.set(tabKey, record);
      }
      record.promise.then((module) => {
        if (typeof module?.[lifecycle] === "function") {
          module[lifecycle](buildModuleContext(root, tabKey));
        }
      });
    }

    function ensureSubtabModule(tabKey, subtabKey, lifecycle = "onShow") {
      if (!subtabKey) return;
      const tabManifest = getTabManifest(tabKey);
      const subtabManifest = (tabManifest?.subtabs || []).find((item) => item.key === subtabKey);
      const root = document.getElementById(`subtab-${tabKey}-${subtabKey}-panel`);
      if (!subtabManifest?.js_module || !root) return;
      const cacheKey = `${tabKey}::${subtabKey}`;
      let record = subtabModuleCache.get(cacheKey);
      if (!record) {
        record = { mounted: false, module: null, promise: null };
        record.promise = import(subtabManifest.js_module).then((module) => {
          record.module = module;
          if (!record.mounted && typeof module.mount === "function") {
            return Promise.resolve(module.mount(buildModuleContext(root, tabKey, subtabKey))).then(() => {
              record.mounted = true;
              return module;
            });
          }
          record.mounted = true;
          return module;
        });
        subtabModuleCache.set(cacheKey, record);
      }
      record.promise.then((module) => {
        if (typeof module?.[lifecycle] === "function") {
          module[lifecycle](buildModuleContext(root, tabKey, subtabKey));
        }
      });
    }

    function activateSubtab(tabKey, subtabKey, options = {}) {
      const tabManifest = getTabManifest(tabKey);
      const available = (tabManifest?.subtabs || []).map((item) => item.key);
      if (!available.length) return null;
      const nextSubtab = available.includes(subtabKey) ? subtabKey : (tabManifest.default_subtab || available[0]);
      const previousSubtab = sharedState.activeSubtabs[tabKey];
      document.querySelectorAll(`[data-subtab-panel][data-subtab-parent="${tabKey}"]`).forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.subtabKey !== nextSubtab);
      });
      document.querySelectorAll(`[data-subtab-trigger][data-subtab-parent="${tabKey}"]`).forEach((button) => {
        button.classList.toggle("nav-btn-active", button.dataset.subtabKey === nextSubtab);
      });
      sharedState.activeSubtabs[tabKey] = nextSubtab;
      if (previousSubtab && previousSubtab !== nextSubtab) {
        ensureSubtabModule(tabKey, previousSubtab, "onHide");
      }
      ensureSubtabModule(tabKey, nextSubtab, "onShow");
      if (options.syncUrl !== false && sharedState.activeTab === tabKey) {
        syncDashboardUrl(tabKey, nextSubtab);
      }
      return nextSubtab;
    }

    function showPanel(name, options = {}) {
      const tabManifest = getTabManifest(name) || getTabManifest(dashboardManifest.initial_tab || "tasks") || (dashboardManifest.tabs || [])[0];
      const nextTab = tabManifest?.key || "tasks";
      const previousTab = sharedState.activeTab;
      panels.forEach((panel) => panel.classList.toggle("hidden", panel.dataset.tabKey !== nextTab));
      navButtons.forEach((button) => button.classList.toggle("nav-btn-active", button.dataset.tabKey === nextTab));
      sharedState.activeTab = nextTab;
      if (previousTab && previousTab !== nextTab) {
        ensureTabModule(previousTab, "onHide");
      }
      ensureTabModule(nextTab, "onShow");
      const activeSubtab = tabManifest?.subtabs?.length
        ? activateSubtab(nextTab, sharedState.activeSubtabs[nextTab] || tabManifest.default_subtab || tabManifest.subtabs[0].key, { syncUrl: false })
        : null;
      if (nextTab === "pricing") {
        window.requestAnimationFrame(refreshPricingCategoryViewportLimits);
      }
      if (options.syncUrl !== false) {
        syncDashboardUrl(nextTab, activeSubtab);
      }
      return nextTab;
    }
    window.PwsAdminApp = {
      activateTab: showPanel,
      activateSubtab,
    };
    navButtons.forEach((b) => b.addEventListener("click", () => showPanel(b.dataset.nav)));

    const themeToggleButton = document.getElementById("theme-toggle");
    const systemThemeQuery = window.matchMedia("(prefers-color-scheme: dark)");

    function readSavedThemePreference() {
      const raw = localStorage.getItem("pwsadmin_theme");
      if (raw === "dark" || raw === "light") return raw;
      if (raw) localStorage.removeItem("pwsadmin_theme");
      return null;
    }

    function getSystemTheme() {
      return systemThemeQuery.matches ? "dark" : "light";
    }

    function syncThemeToggleButton() {
      if (!themeToggleButton) return;
      const nextAction = document.documentElement.classList.contains("dark")
        ? "Switch to light"
        : "Switch to dark";
      themeToggleButton.textContent = nextAction;
      themeToggleButton.setAttribute("aria-label", nextAction);
    }

    function applyTheme(theme, options = {}) {
      const normalized = theme === "dark" ? "dark" : "light";
      const persist = Boolean(options.persist);
      document.documentElement.classList.toggle("dark", normalized === "dark");
      document.documentElement.dataset.theme = normalized;
      if (persist) {
        localStorage.setItem("pwsadmin_theme", normalized);
      }
      syncThemeToggleButton();
    }

    const savedThemePreference = readSavedThemePreference();
    applyTheme(savedThemePreference || getSystemTheme());

    if (!savedThemePreference) {
      const onSystemThemeChange = (event) => {
        if (readSavedThemePreference()) return;
        applyTheme(event.matches ? "dark" : "light");
      };
      if (typeof systemThemeQuery.addEventListener === "function") {
        systemThemeQuery.addEventListener("change", onSystemThemeChange);
      } else if (typeof systemThemeQuery.addListener === "function") {
        systemThemeQuery.addListener(onSystemThemeChange);
      }
    }

    if (themeToggleButton) {
      themeToggleButton.addEventListener("click", () => {
        applyTheme(
          document.documentElement.classList.contains("dark") ? "light" : "dark",
          { persist: true },
        );
      });
    }

    const isoDatePattern = /^\d{4}-\d{2}-\d{2}$/;
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    const tokenLikePattern = /^[A-Za-z][A-Za-z0-9_:\-/]{0,63}$/;
    const sourcePattern = /^[A-Za-z0-9_.:/ -]{1,80}$/;

    const idValidationRules = {
      "task-status": {
        tooltip: "Format: status token (letters, numbers, _ or -). Example: pending",
        validate: (value) => (tokenLikePattern.test(value) ? null : "Use letters/numbers/_/- only"),
      },
      "task-queue": {
        tooltip: "Format: queue token (letters, numbers, _ or -). Example: default",
        validate: (value) => (tokenLikePattern.test(value) ? null : "Use letters/numbers/_/- only"),
      },
      "task-limit": {
        tooltip: "Format: whole number from 1 to 200",
        validate: (value) => validateIntegerRange(value, 1, 200),
      },
      "task-enqueue-queue": {
        tooltip: "Select an active scheduler queue",
        validate: (value) => (value ? null : "Select a queue"),
      },
      "task-enqueue-worker": {
        tooltip: "Select a worker subscribed to the queue",
        validate: (value) => (value ? null : "Select a worker"),
      },
      "task-enqueue-action": {
        tooltip: "Format: action token. Example: fetch",
        validate: (value) => (/^[A-Za-z0-9_.:-]{1,100}$/.test(value) ? null : "Use letters, numbers, _ . : -"),
      },
      "task-enqueue-priority": {
        tooltip: "Format: whole number from 0 to 100",
        validate: (value) => validateIntegerRange(value, 0, 100),
      },
      "task-enqueue-max-attempts": {
        tooltip: "Format: whole number from 1 to 10",
        validate: (value) => validateIntegerRange(value, 1, 10),
      },
      "task-enqueue-payload": {
        tooltip: "Format: JSON object. Example: {\"limit\":25}",
        validate: (value) => {
          try {
            const parsed = JSON.parse(value);
            return parsed && !Array.isArray(parsed) && typeof parsed === "object" ? null : "Use a JSON object";
          } catch (_) {
            return "Use valid JSON";
          }
        },
      },
      "log-level": {
        tooltip: "Format: DEBUG | INFO | WARNING | ERROR | CRITICAL",
        validate: (value) =>
          ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"].includes(value.toUpperCase())
            ? null
            : "Use DEBUG, INFO, WARNING, ERROR, or CRITICAL",
      },
      "log-source": {
        tooltip: "Format: letters/numbers and . _ : / - spaces (max 80 chars)",
        validate: (value) => (sourcePattern.test(value) ? null : "Invalid source format"),
      },
      "log-workflow": {
        tooltip: "Format: letters/numbers and . _ : / - spaces (max 80 chars)",
        validate: (value) => (sourcePattern.test(value) ? null : "Invalid workflow format"),
      },
      "log-limit": {
        tooltip: "Format: whole number from 1 to 200",
        validate: (value) => validateIntegerRange(value, 1, 200),
      },
      "pricing-property": {
        tooltip: "Format: positive integer property_id. Demo example: 389550",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "pricing-platform": {
        tooltip: "Format: positive integer platform_id. Demo example: 432",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "pricing-scope": {
        tooltip: "Filter by listing, property, platform, or global scope",
        validate: (value) => (["listing", "property", "platform", "global"].includes(value) ? null : "Select a valid scope"),
      },
      "pricing-lookup": {
        tooltip: "Format: positive integer platform_property_lookup_id. Example: 42",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "pricing-operation": {
        tooltip: "Format: operation_code token. Example: increase",
        validate: (value) => (tokenLikePattern.test(value) ? null : "Invalid operation_code format"),
      },
      "pricing-status": {
        tooltip: "Format: rule status. Example: active",
        validate: (value) => (tokenLikePattern.test(value) ? null : "Invalid status format"),
      },
      "pricing-simple-target-scope": {
        tooltip: "Choose whether this rule targets a property, platform, global scope, or one linked listing",
        validate: (value) => (PRICING_TARGET_SCOPE_OPTIONS.has(value) ? null : "Select a supported target"),
      },
      "pricing-simple-property": {
        tooltip: "Select the property this rule belongs to",
        validate: (value) => (value ? null : "Select a property"),
      },
      "pricing-simple-platform": {
        tooltip: "Select the platform this rule targets",
        validate: (value) => (value ? null : "Select a platform"),
      },
      "pricing-simple-listing": {
        tooltip: "Select the linked listing used for listing scope",
        validate: (value) => (value ? null : "Select a listing"),
      },
      "pricing-simple-operation": {
        tooltip: "Select the pricing action: increase, decrease, set, or multiplier",
        validate: (value) => (SIMPLE_PRICING_SUPPORTED_OPERATIONS.has(value) ? null : "Select a supported action"),
      },
      "pricing-simple-amount-type": {
        tooltip: "Select whether the amount is percentage, flat, fixed, or multiplier",
        validate: (value) => (value ? null : "Select an amount type"),
      },
      "pricing-simple-amount": {
        tooltip: "Format: numeric amount. Example: 12 or 45",
        validate: (value) => validateNumericMinimum(value, 0),
      },
      "pricing-simple-duration-days": {
        tooltip: "Format: whole number of days to apply. Example: 2",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "pricing-simple-offset-days": {
        tooltip: "Format: whole-number offset from arrival/departure. Example: 0",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-simple-applies-from": {
        tooltip: "Choose whether pricing starts from arrival or departure",
        validate: (value) => (["arrival", "departure"].includes(value) ? null : "Select arrival or departure"),
      },
      "pricing-simple-longer-stay-enabled": {
        tooltip: "Check to use stay length plus booking classes instead of the legacy booking category condition",
        validate: () => null,
      },
      "pricing-simple-stay-length-op": {
        tooltip: "Select the stay length comparison",
        validate: (value) => (PRICING_STAY_LENGTH_OPERATORS.has(value) ? null : "Select a supported comparison"),
      },
      "pricing-simple-stay-length-value": {
        tooltip: "Format: whole number of nights. Example: 15",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-simple-stay-length-max": {
        tooltip: "Format: whole number of nights for the upper end of between",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-simple-status": {
        tooltip: "Select the rule status. Example: active",
        validate: (value) => (value ? null : "Select a status"),
      },
      "pricing-simple-priority": {
        tooltip: "Format: integer from 0 to 100. Higher number wins. Example: 90",
        validate: (value) => validateIntegerRange(value, 0, 100),
      },
      "pricing-simple-start-date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-01-01",
        validate: (value) => validateIsoDate(value),
      },
      "pricing-simple-end-date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-12-31",
        validate: (value) => validateIsoDate(value),
      },
      "pricing-moderate-target-scope": {
        tooltip: "Choose whether this rule targets a property, platform, global scope, or one linked listing",
        validate: (value) => (PRICING_TARGET_SCOPE_OPTIONS.has(value) ? null : "Select a supported target"),
      },
      "pricing-moderate-property": {
        tooltip: "Select the property this rule belongs to",
        validate: (value) => (value ? null : "Select a property"),
      },
      "pricing-moderate-platform": {
        tooltip: "Select the platform this rule targets",
        validate: (value) => (value ? null : "Select a platform"),
      },
      "pricing-moderate-listing": {
        tooltip: "Select the linked listing used for listing scope",
        validate: (value) => (value ? null : "Select a listing"),
      },
      "pricing-moderate-operation": {
        tooltip: "Select a structured pricing, availability, or stay-length operation",
        validate: (value) => (MODERATE_PRICING_SUPPORTED_OPERATIONS.has(value) ? null : "Select a supported operation"),
      },
      "pricing-moderate-amount-type": {
        tooltip: "Select the value type when the operation supports multiple styles",
        validate: (value) => (value ? null : "Select a value type"),
      },
      "pricing-moderate-target-rate-type": {
        tooltip: "Select the captured nightly rate baseline used by this operation. Default: base",
        validate: (value) => (PRICING_TARGET_RATE_TYPES.has(value) ? null : "Select a supported target rate type"),
      },
      "pricing-moderate-amount": {
        tooltip: "Format: numeric value required by the selected operation",
        validate: (value) => validateNumericMinimum(value, 0),
      },
      "pricing-moderate-duration-days": {
        tooltip: "Format: whole number of days to apply. Example: 2",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "pricing-moderate-offset-days": {
        tooltip: "Format: whole-number offset from arrival/departure. Example: 0",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-applies-from": {
        tooltip: "Choose whether pricing starts from arrival or departure",
        validate: (value) => (["arrival", "departure"].includes(value) ? null : "Select arrival or departure"),
      },
      "pricing-moderate-booking-class-operator": {
        tooltip: "Choose whether any selected booking class can match, or all selected classes are required",
        validate: (value) => (MODERATE_BOOKING_CLASS_OPERATORS.has(value) ? null : "Select any_of or all_of"),
      },
      "pricing-moderate-stay-length-op": {
        tooltip: "Optional stay_length comparison operator",
        validate: (value) => (!value || MODERATE_NUMERIC_COMPARISON_OPERATORS.has(value) ? null : "Select a supported operator"),
      },
      "pricing-moderate-stay-length-value": {
        tooltip: "Whole-number comparison value for stay_length. Example: 15",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-stay-length-max": {
        tooltip: "Whole-number max value for stay_length between",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-stay-extended-op": {
        tooltip: "Optional stay_extended comparison operator",
        validate: (value) => (!value || MODERATE_NUMERIC_COMPARISON_OPERATORS.has(value) ? null : "Select a supported operator"),
      },
      "pricing-moderate-stay-extended-value": {
        tooltip: "Whole-number comparison value for stay_extended. Example: 2",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-stay-extended-max": {
        tooltip: "Whole-number max value for stay_extended between",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-stay-contracted-op": {
        tooltip: "Optional stay_contracted comparison operator",
        validate: (value) => (!value || MODERATE_NUMERIC_COMPARISON_OPERATORS.has(value) ? null : "Select a supported operator"),
      },
      "pricing-moderate-stay-contracted-value": {
        tooltip: "Whole-number comparison value for stay_contracted. Example: 1",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-stay-contracted-max": {
        tooltip: "Whole-number max value for stay_contracted between",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "pricing-moderate-status": {
        tooltip: "Select the rule status. Example: active",
        validate: (value) => (value ? null : "Select a status"),
      },
      "pricing-moderate-priority": {
        tooltip: "Format: integer from 0 to 100. Higher number wins. Example: 90",
        validate: (value) => validateIntegerRange(value, 0, 100),
      },
      "pricing-moderate-start-date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-01-01",
        validate: (value) => validateIsoDate(value),
      },
      "pricing-moderate-end-date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-12-31",
        validate: (value) => validateIsoDate(value),
      },
      "pricing-moderate-season-start-mmdd": {
        tooltip: "Format: MM-DD. Example: 12-10",
        validate: (value) => validateMonthDay(value),
      },
      "pricing-moderate-season-end-mmdd": {
        tooltip: "Format: MM-DD. Example: 03-21",
        validate: (value) => validateMonthDay(value),
      },
      "pricing-moderate-season-applies-to": {
        tooltip: "Choose which date is tested against the season window",
        validate: (value) => (PRICING_SEASON_APPLIES_TO_VALUES.has(value) ? null : "Select target_date, arrival_date, or departure_date"),
      },
      "booking-property": {
        tooltip: "Format: positive integer property_id. Example: 123",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "booking-platform": {
        tooltip: "Format: positive integer platform_id. Example: 3",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "booking-from": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-04-01",
        validate: (value) => validateIsoDate(value),
      },
      "booking-to": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-04-30",
        validate: (value) => validateIsoDate(value),
      },
      "booking-limit": {
        tooltip: "Format: integer from 1 to 200. Example: 50",
        validate: (value) => validateIntegerRange(value, 1, 200),
      },
      "bso-booking-entry-id": {
        tooltip: "Format: positive integer booking_entry_id. Example: 52000001",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "bso-status": {
        tooltip: "Optional status filter: processing, applied, removed, or failed",
        validate: (value) => (!value || ["processing", "applied", "removed", "failed"].includes(value) ? null : "Select a valid status"),
      },
      "bso-updated-from": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-04-01",
        validate: (value) => validateIsoDate(value),
      },
      "bso-updated-to": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-04-30",
        validate: (value) => validateIsoDate(value),
      },
      "bso-limit": {
        tooltip: "Format: integer from 1 to 500. Example: 50",
        validate: (value) => validateIntegerRange(value, 1, 500),
      },
      "message-class-name": {
        tooltip: "Format: plain text category name. Example: medical",
        required: true,
        validate: (value) => {
          const normalized = value.trim();
          if (!normalized) return "Name is required";
          if (normalized.length > 255) return "Name must be 255 characters or fewer";
          return null;
        },
      },
      "message-class-description": {
        tooltip: "Format: short plain text description used by operators and classifiers",
        required: true,
        validate: (value) => {
          const normalized = value.trim();
          if (!normalized) return "Description is required";
          if (normalized.length > 2000) return "Description is too long";
          return null;
        },
      },
      "platform-select": {
        tooltip: "Select a platform from the dropdown",
        validate: (value) => (value ? null : "Select a platform"),
      },
      "pricing-listings-platform-filter": {
        tooltip: "Optional platform filter for the pricing listings catalog",
        validate: () => null,
      },
      "pricing-listings-property-filter": {
        tooltip: "Optional property filter for the pricing listings catalog",
        validate: () => null,
      },
      "remote-page": {
        tooltip: "Format: page number (integer >= 1)",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "remote-per-page": {
        tooltip: "Format: integer from 1 to 100",
        validate: (value) => validateIntegerRange(value, 1, 100),
      },
      "remote-select-all": {
        tooltip: "Toggle all listed remote properties for import",
        validate: () => null,
      },
      "platform-token-select": {
        tooltip: "Select a platform before loading or writing API tokens",
        validate: (value) => (value ? null : "Select a platform"),
      },
      "llm-provider-model": {
        tooltip: "Format: model identifier. Example: gpt-5-nano",
        validate: (value) => (/^[A-Za-z0-9_.:-]{1,200}$/.test(value) ? null : "Use letters, numbers, _ . : -"),
      },
      "llm-provider-model-custom": {
        tooltip: "Optional custom model identifier. Example: llama3.2:3b",
        validate: (value) => (/^[A-Za-z0-9_.:-]{1,200}$/.test(value) ? null : "Use letters, numbers, _ . : -"),
      },
      "llm-provider-timeout": {
        tooltip: "Format: timeout seconds from 1 to 600",
        validate: (value) => validateIntegerRange(value, 1, 600),
      },
      "llm-provider-settings-select": {
        tooltip: "Select an LLM provider",
        validate: (value) => (value ? null : "Select an LLM provider"),
      },
      "llm-from": {
        tooltip: "Format: YYYY-MM-DD",
        validate: (value) => validateIsoDate(value),
      },
      "llm-to": {
        tooltip: "Format: YYYY-MM-DD",
        validate: (value) => validateIsoDate(value),
      },
      "llm-min-tokens": {
        tooltip: "Format: integer >= 0",
        validate: (value) => validateIntegerRange(value, 0),
      },
      "llm-pricing-provider": {
        tooltip: "Format: provider key. Example: openai",
        validate: (value) => (/^[A-Za-z0-9_.:-]{1,200}$/.test(value) ? null : "Use letters, numbers, _ . : -"),
      },
      "llm-pricing-model": {
        tooltip: "Format: model identifier. Example: gpt-5-nano",
        validate: (value) => (/^[A-Za-z0-9_.:/-]{1,200}$/.test(value) ? null : "Use letters, numbers, _ . : / -"),
      },
      "llm-pricing-input": {
        tooltip: "Format: non-negative decimal price per 1M input tokens",
        validate: (value) => (Number(value) >= 0 ? null : "Enter a non-negative number"),
      },
      "llm-pricing-output": {
        tooltip: "Format: non-negative decimal price per 1M output tokens",
        validate: (value) => (Number(value) >= 0 ? null : "Enter a non-negative number"),
      },
      "llm-pricing-currency": {
        tooltip: "Format: currency code. Example: USD",
        validate: (value) => (/^[A-Za-z]{3,12}$/.test(value) ? null : "Use 3-12 letters"),
      },
    };

    const nameValidationRules = {
      "rule_uuid": {
        tooltip: "Format: UUID (optional for update). Example: 3fa85f64-5717-4562-b3fc-2c963f66afa6",
        validate: (value) => (uuidPattern.test(value) ? null : "Enter a valid UUID"),
      },
      "operation_code": {
        tooltip: "Format: operation_code token. Example: increase",
        required: true,
        validate: (value) => (tokenLikePattern.test(value) ? null : "Invalid operation_code format"),
      },
      "property_id": {
        tooltip: "Format: positive integer property_id. Demo example: 389550",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "platform_id": {
        tooltip: "Format: positive integer platform_id. Demo example: 432",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "platform_property_lookup_id": {
        tooltip: "Format: positive integer platform_property_lookup_id. Example: 42",
        validate: (value) => validateIntegerRange(value, 1),
      },
      "priority": {
        tooltip: "Format: integer from 0 to 100. Higher number wins. Example: 90",
        validate: (value) => validateIntegerRange(value, 0, 100),
      },
      "status": {
        tooltip: "Format: rule status token. Example: active",
        validate: (value) => (tokenLikePattern.test(value) ? null : "Invalid status format"),
      },
      "rule_config": {
        tooltip: "Format: JSON object. Example: {\"subject\":\"price\",\"operation\":{\"type\":\"percentage\",\"amount\":12},\"apply_window\":{\"applies_from\":\"departure\",\"duration_days\":2,\"offset_days\":0},\"conditions_version\":2,\"condition_tree\":{\"type\":\"condition\",\"condition_name\":\"booking_category\",\"comparison_operator\":\"any_of\",\"value\":[\"potential_extension\"]}}",
        required: true,
        validate: (value) => {
          try {
            const parsed = JSON.parse(value);
            return parsed && typeof parsed === "object" && !Array.isArray(parsed)
              ? null
              : "rule_config must be a JSON object";
          } catch {
            return "Invalid JSON";
          }
        },
      },
      "applicable_dates": {
        tooltip: "Format: JSON array of exact YYYY-MM-DD strings. Example: [\"2026-02-23\",\"2026-02-24\"]",
        validate: (value) => {
          try {
            const parsed = JSON.parse(value);
            if (!Array.isArray(parsed)) return "Use a JSON array";
            return parsed.every((item) => typeof item === "string" && !validateIsoDate(item))
              ? null
              : "Each date must be YYYY-MM-DD";
          } catch {
            return "Invalid JSON array";
          }
        },
      },
      "start_date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-01-01",
        validate: (value) => validateIsoDate(value),
      },
      "end_date": {
        tooltip: "Format: YYYY-MM-DD. Example: 2026-12-31",
        validate: (value) => validateIsoDate(value),
      },
      "day_of_week_pattern": {
        tooltip: "Format: integer bitmask from 0 to 127. Example: 96 for Saturday + Sunday",
        validate: (value) => validateIntegerRange(value, 0, 127),
      },
      "secret": {
        tooltip: "Format: plain text secret value (min 3 chars)",
        required: true,
        validate: (value) => (value.length >= 3 ? null : "Secret must be at least 3 characters"),
      },
      "description": {
        tooltip: "Format: optional plain text (max 255 chars)",
        validate: (value) => (value.length <= 255 ? null : "Description is too long"),
      },
    };

    function validateIntegerRange(value, min, max = null) {
      if (!/^-?\d+$/.test(value)) return "Use a whole number";
      const numeric = Number(value);
      if (!Number.isInteger(numeric)) return "Use a whole number";
      if (numeric < min) return `Value must be >= ${min}`;
      if (max !== null && numeric > max) return `Value must be <= ${max}`;
      return null;
    }

    function validateNumericMinimum(value, min, allowEqual = true) {
      if (!/^-?\d+(\.\d+)?$/.test(value)) return "Use a number";
      const numeric = Number(value);
      if (!Number.isFinite(numeric)) return "Use a number";
      if (allowEqual ? numeric < min : numeric <= min) {
        return allowEqual ? `Value must be >= ${min}` : `Value must be > ${min}`;
      }
      return null;
    }

    function validateIsoDate(value) {
      if (!isoDatePattern.test(value)) return "Use YYYY-MM-DD";
      const parsed = new Date(`${value}T00:00:00Z`);
      if (Number.isNaN(parsed.getTime())) return "Use a valid date";
      const [year, month, day] = value.split("-").map(Number);
      if (
        parsed.getUTCFullYear() !== year ||
        parsed.getUTCMonth() + 1 !== month ||
        parsed.getUTCDate() !== day
      ) {
        return "Use a valid calendar date";
      }
      return null;
    }

    function validateMonthDay(value) {
      if (!/^\d{2}-\d{2}$/.test(String(value || ""))) return "Use MM-DD";
      const [month, day] = String(value).split("-").map(Number);
      const parsed = new Date(Date.UTC(2000, month - 1, day));
      if (
        Number.isNaN(parsed.getTime()) ||
        parsed.getUTCMonth() + 1 !== month ||
        parsed.getUTCDate() !== day
      ) {
        return "Use a valid calendar month/day";
      }
      return null;
    }

    function getValidationRule(element) {
      if (!element) return null;
      if (element.id && idValidationRules[element.id]) return idValidationRules[element.id];
      if (element.name && nameValidationRules[element.name]) return nameValidationRules[element.name];
      return null;
    }

    function getDefaultTooltip(element) {
      if (element.type === "hidden") return "";
      if (element.tagName === "SELECT") return "Select a value from the list";
      if (element.type === "date") return "Format: YYYY-MM-DD";
      if (element.type === "number") return "Format: whole number";
      if (element.type === "radio") return "Choose an option";
      if (element.type === "checkbox") return "Check or uncheck this option";
      if (element.tagName === "TEXTAREA") return "Format: plain text";
      return "Format: text input";
    }

    function setControlErrorState(element, errorMessage) {
      const baseTooltip = element.dataset.tooltipBase || "";
      if (errorMessage) {
        element.classList.add("format-invalid");
        element.setAttribute("aria-invalid", "true");
        element.setCustomValidity(errorMessage);
        element.title = `${baseTooltip} | Error: ${errorMessage}`;
      } else {
        element.classList.remove("format-invalid");
        element.removeAttribute("aria-invalid");
        element.setCustomValidity("");
        element.title = baseTooltip;
      }
    }

    function validateControl(element, options = {}) {
      if (!element) return false;
      const { silent = false, required = false } = options;
      const rule = getValidationRule(element);
      const value = (element.value || "").trim();
      const isRequired = Boolean(required || rule?.required || element.required);
      let errorMessage = null;

      if (isRequired && !value) {
        errorMessage = "This field is required";
      } else if (value && rule?.validate) {
        errorMessage = rule.validate(value, element);
      }

      setControlErrorState(element, errorMessage);
      if (errorMessage && !silent) {
        const label = element.id || element.name || "field";
        setStatus(`${label}: ${errorMessage}`, true);
      }
      return !errorMessage;
    }

    function validateControls(elements, options = {}) {
      const controls = elements.filter(Boolean);
      let firstInvalid = null;
      controls.forEach((element) => {
        const isValid = validateControl(element, options);
        if (!isValid && !firstInvalid) firstInvalid = element;
      });
      if (firstInvalid) firstInvalid.focus();
      return !firstInvalid;
    }

    function initControlTooltipsAndValidation() {
      const controls = Array.from(document.querySelectorAll(".panel input, .panel select, .panel textarea"));
      controls.forEach((control) => {
        const rule = getValidationRule(control);
        const tooltip = rule?.tooltip || getDefaultTooltip(control);
        control.dataset.tooltipBase = tooltip;
        control.title = tooltip;
        const listener = () => validateControl(control, { silent: true });
        control.addEventListener("input", listener);
        control.addEventListener("change", listener);
        control.addEventListener("blur", listener);
      });
    }

    async function loadCurrentUserProfile() {
      currentUserProfile = await requestJSON("/pwsadmin/api/auth/me");
      sharedState.currentUserProfile = currentUserProfile;
      updateMessageClassFormState();
      updateTaskEnqueueFormState();
      return currentUserProfile;
    }

    function normalizeDateValue(value) {
      if (!value) return "";
      if (typeof value === "string") return value.slice(0, 10);
      if (value instanceof Date) return value.toISOString().slice(0, 10);
      return String(value).slice(0, 10);
    }

    function formatDateTimeInBrowserTimezone(value) {
      if (value === null || value === undefined || value === "") return "-";
      const date = new Date(value);
      if (Number.isNaN(date.getTime())) {
        return String(value);
      }
      return date.toLocaleString(undefined, {
        year: "numeric",
        month: "short",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
        timeZoneName: "short",
      });
    }

    function extractPropertyName(property) {
      if (!property) return "";
      if (property.name) return property.name;
      const descrp = property.descrp;
      if (descrp && typeof descrp === "object") {
        return descrp.name || descrp.title || descrp.label || `Property ${property.id}`;
      }
      if (typeof descrp === "string" && descrp.trim()) {
        try {
          const parsed = JSON.parse(descrp);
          if (parsed && typeof parsed === "object") {
            return parsed.name || parsed.title || parsed.label || `Property ${property.id}`;
          }
        } catch {
          return descrp;
        }
      }
      return `Property ${property.id}`;
    }

    function getLookupKey(value) {
      if (value === null || value === undefined) return "";
      const text = String(value).trim();
      return text;
    }

    function setBookingPropertyNameLookup(items) {
      const next = new Map();
      (items || []).forEach((item) => {
        const key = getLookupKey(item.id);
        if (!key) return;
        next.set(key, extractPropertyName(item));
      });
      bookingPropertyNameById = next;
    }

    function setBookingPlatformNameLookup(items) {
      const next = new Map();
      (items || []).forEach((item) => {
        const key = getLookupKey(item.id);
        if (!key) return;
        const name = item.name ? String(item.name) : `Platform #${key}`;
        next.set(key, name);
      });
      bookingPlatformNameById = next;
    }

    function resolveBookingPropertyName(propertyId) {
      const key = getLookupKey(propertyId);
      if (!key) return "-";
      return bookingPropertyNameById.get(key) || `Property #${key}`;
    }

    function resolveBookingPlatformName(platformId) {
      const key = getLookupKey(platformId);
      if (!key) return "-";
      return bookingPlatformNameById.get(key) || `Platform #${key}`;
    }

    function createBookingMessageClassSummary(messages) {
      const counters = new Map();
      (messages || []).forEach((message) => {
        const rawName = typeof message?.class_name === "string" ? message.class_name.trim() : "";
        const className = rawName || "unclassified";
        counters.set(className, (counters.get(className) || 0) + 1);
      });
      return Array.from(counters.entries())
        .sort((left, right) => left[0].localeCompare(right[0]))
        .map(([className, count]) => ({ class_name: className, message_count: count }));
    }

    function isObjectLike(value) {
      return typeof value === "object" && value !== null && !Array.isArray(value);
    }

    function quoteYmfString(value) {
      if (value === "") return '""';
      return JSON.stringify(value);
    }

    function formatYmfScalar(value) {
      if (value === null || value === undefined) return "null";
      if (typeof value === "number" || typeof value === "boolean") return String(value);
      if (typeof value === "string") return quoteYmfString(value);
      return quoteYmfString(JSON.stringify(value));
    }

    function toYmfLines(value, depth = 0) {
      const indent = "  ".repeat(depth);
      if (Array.isArray(value)) {
        if (!value.length) return [`${indent}[]`];
        const lines = [];
        value.forEach((item) => {
          if (Array.isArray(item) || isObjectLike(item)) {
            lines.push(`${indent}-`);
            lines.push(...toYmfLines(item, depth + 1));
          } else {
            lines.push(`${indent}- ${formatYmfScalar(item)}`);
          }
        });
        return lines;
      }
      if (isObjectLike(value)) {
        const keys = Object.keys(value);
        if (!keys.length) return [`${indent}{}`];
        const lines = [];
        keys.forEach((key) => {
          const item = value[key];
          if (Array.isArray(item) || isObjectLike(item)) {
            lines.push(`${indent}${key}:`);
            lines.push(...toYmfLines(item, depth + 1));
          } else {
            lines.push(`${indent}${key}: ${formatYmfScalar(item)}`);
          }
        });
        return lines;
      }
      return [`${indent}${formatYmfScalar(value)}`];
    }

    function renderYmf(value) {
      return toYmfLines(value, 0).join("\n");
    }

    function buildBookingDetailYmfPayload(booking) {
      const source = isObjectLike(booking) ? booking : {};
      const messages = Array.isArray(source.messages) ? source.messages : [];
      const appliedRules = Array.isArray(source.applied_rules) ? source.applied_rules : [];
      const metadata = source.metadata;
      const bookingData = { ...source };
      delete bookingData.messages;
      delete bookingData.applied_rules;
      delete bookingData.guest_id;
      delete bookingData.metadata;
      delete bookingData.property_id;
      delete bookingData.platform_id;
      bookingData.property_name = resolveBookingPropertyName(source.property_id);
      bookingData.platform_name = resolveBookingPlatformName(source.platform_id);
      bookingData.additional_data = metadata ?? {};
      return {
        booking: bookingData,
        message_classes: createBookingMessageClassSummary(messages),
        applied_rules: appliedRules,
      };
    }

    function formatBookingDetailYmf(booking) {
      return renderYmf(buildBookingDetailYmfPayload(booking));
    }

    function parseBookingThreadIds(booking) {
      const source = isObjectLike(booking) ? booking : {};
      let rawThreadIds = source.thread_ids_json;
      if (typeof rawThreadIds === "string") {
        try {
          rawThreadIds = JSON.parse(rawThreadIds);
        } catch {
          rawThreadIds = [];
        }
      }
      if (!Array.isArray(rawThreadIds)) return [];
      return rawThreadIds
        .map((threadId) => String(threadId ?? "").trim())
        .filter((threadId) => threadId.length > 0);
    }

    function renderBookingThreadList(booking) {
      const listEl = document.getElementById("booking-thread-list");
      listEl.innerHTML = "";
      const bookingId = booking?.id;
      const threadIds = parseBookingThreadIds(booking);
      if (!bookingId || !threadIds.length) {
        listEl.textContent = "No message threads found for this booking.";
        return;
      }
      threadIds.forEach((threadId) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "secondary-btn rounded border px-2 py-1 font-mono text-xs";
        button.textContent = threadId;
        button.title = `View messages for thread ${threadId}`;
        button.addEventListener("click", () => {
          openBookingThreadMessagesModal(bookingId, threadId);
        });
        listEl.appendChild(button);
      });
    }

    function closeBookingThreadMessagesModal() {
      document.getElementById("booking-thread-messages-modal").classList.add("hidden");
      document.getElementById("booking-thread-messages-modal").classList.remove("flex");
      document.getElementById("booking-thread-messages-title").textContent = "Messages for Thread";
      document.getElementById("booking-thread-message-rows").innerHTML = "";
      document.getElementById("booking-thread-messages-empty").classList.add("hidden");
    }

    function setBookingThreadMessagesLoading() {
      const tbody = document.getElementById("booking-thread-message-rows");
      document.getElementById("booking-thread-messages-empty").classList.add("hidden");
      tbody.innerHTML = "";
      const tr = document.createElement("tr");
      const td = document.createElement("td");
      td.colSpan = 3;
      td.className = "py-6 text-center text-sm text-slate-600 dark:text-slate-300";
      td.textContent = "Loading...";
      tr.appendChild(td);
      tbody.appendChild(tr);
    }

    function formatBookingThreadMessageClassStatus(item) {
      const className = typeof item?.class_name === "string" ? item.class_name.trim() : "";
      if (className) return className;
      const status = String(item?.processing_status || "pending").trim() || "pending";
      return `Not classified yet (${status})`;
    }

    function renderBookingThreadMessageRows(items) {
      const tbody = document.getElementById("booking-thread-message-rows");
      const emptyEl = document.getElementById("booking-thread-messages-empty");
      tbody.innerHTML = "";
      const rows = Array.isArray(items) ? items : [];
      emptyEl.classList.toggle("hidden", rows.length > 0);
      rows.forEach((item) => {
        const tr = document.createElement("tr");
        [item?.message_id, item?.content_preview, formatBookingThreadMessageClassStatus(item)].forEach((value, index) => {
          const td = document.createElement("td");
          if (index === 1) td.className = "max-w-[520px] break-words";
          td.textContent = value === null || value === undefined || value === "" ? "-" : String(value);
          tr.appendChild(td);
        });
        tbody.appendChild(tr);
      });
    }

    async function openBookingThreadMessagesModal(bookingId, threadId) {
      const modal = document.getElementById("booking-thread-messages-modal");
      document.getElementById("booking-thread-messages-title").textContent = `Messages for Thread #${threadId}`;
      setBookingThreadMessagesLoading();
      modal.classList.remove("hidden");
      modal.classList.add("flex");
      try {
        const url = `/pwsadmin/api/bookings/${encodeURIComponent(bookingId)}/message-threads/${encodeURIComponent(threadId)}/messages`;
        const res = await requestJSON(url);
        renderBookingThreadMessageRows(res.items || []);
        setStatus(`Messages for thread ${threadId}: ${(res.items || []).length}`);
      } catch (error) {
        renderBookingThreadMessageRows([]);
        setStatus(error.message || "Failed to load thread messages.", true);
      }
    }

    function populateSelect(select, items, { placeholder, getValue, getLabel }) {
      if (!select) return;
      const currentValue = select.value;
      select.innerHTML = "";
      if (placeholder) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = placeholder;
        select.appendChild(option);
      }
      items.forEach((item) => {
        const option = document.createElement("option");
        option.value = getValue(item);
        option.textContent = getLabel(item);
        select.appendChild(option);
      });
      if (currentValue && Array.from(select.options).some((option) => option.value === currentValue)) {
        select.value = currentValue;
      } else if (placeholder) {
        select.value = "";
      }
    }

    function setPricingSubtab(tab) {
      const nextTab = tab === "listings" ? "listings" : "rules";
      activePricingSubtab = nextTab;
      activateSubtab("pricing", nextTab, { syncUrl: sharedState.activeTab === "pricing" });
      if (nextTab === "rules") {
        window.requestAnimationFrame(refreshPricingCategoryViewportLimits);
      }
      if (nextTab === "listings" && !pricingListingRows.length) {
        loadPricingListings().catch((error) => setStatus(error.message, true));
      }
    }

    function buildPricingListingLabel(item) {
      const platformName = item?.platform_name || `Platform #${item?.platform_id ?? "-"}`;
      const listingName = item?.listing_name ? ` | ${item.listing_name}` : "";
      const propertyName = item?.property_name ? ` | ${item.property_name}` : "";
      const listingId = item?.platform_property_id || `Lookup #${item?.lookup_id ?? "-"}`;
      return `${platformName}${listingName}${propertyName} | ${listingId}`;
    }

    function buildPricingRuleTargetLabel(rule) {
      if (!rule || typeof rule !== "object") return "-";
      if (rule.scope === "listing") {
        const listingId = rule.platform_property_id || `Lookup #${rule.platform_property_lookup_id ?? "-"}`;
        const listingName = rule.listing_name ? ` | ${rule.listing_name}` : "";
        const propertyName = rule.property_name ? ` | ${rule.property_name}` : "";
        return `${rule.platform_name || "Listing"}${listingName}${propertyName} | ${listingId}`;
      }
      if (rule.property_id && rule.platform_id) {
        return `${rule.property_name || `Property #${rule.property_id}`} | ${rule.platform_name || `Platform #${rule.platform_id}`}`;
      }
      if (rule.property_id) {
        return rule.property_name || `Property #${rule.property_id}`;
      }
      if (rule.platform_id) {
        return rule.platform_name || `Platform #${rule.platform_id}`;
      }
      return "Global";
    }

    function getPricingTargetMode(prefix) {
      const value = document.getElementById(`${prefix}-target-scope`)?.value || "";
      return PRICING_TARGET_SCOPE_OPTIONS.has(value) ? value : "property_platform";
    }

    function getPricingTargetModeFromRule(rule) {
      const lookupId = normalizeLookupId(rule?.platform_property_lookup_id);
      const propertyId = normalizeLookupId(rule?.property_id);
      const platformId = normalizeLookupId(rule?.platform_id);
      if (lookupId !== null) {
        return propertyId === null && platformId === null ? "listing" : null;
      }
      if (propertyId !== null && platformId !== null) return "property_platform";
      if (propertyId !== null) return "property";
      if (platformId !== null) return "platform";
      if (propertyId === null && platformId === null) return "global";
      return null;
    }

    function populatePricingListingSelectControl(select, items, { placeholder, selectedValue = "" } = {}) {
      if (!select) return;
      const normalizedSelected = selectedValue === null || selectedValue === undefined ? "" : String(selectedValue);
      select.innerHTML = "";
      const placeholderOption = document.createElement("option");
      placeholderOption.value = "";
      placeholderOption.textContent = placeholder || "Select listing";
      select.appendChild(placeholderOption);
      (items || []).forEach((item) => {
        const option = document.createElement("option");
        option.value = String(item.lookup_id);
        option.textContent = buildPricingListingLabel(item);
        select.appendChild(option);
      });
      if (normalizedSelected && Array.from(select.options).some((option) => option.value === normalizedSelected)) {
        select.value = normalizedSelected;
      } else {
        select.value = "";
      }
    }

    async function ensurePricingListingsLoaded(platformId, { force = false } = {}) {
      const key = String(platformId || "").trim();
      if (!key) return [];
      if (!force && pricingListingCacheByPlatformId.has(key)) {
        return pricingListingCacheByPlatformId.get(key) || [];
      }
      const res = await requestJSON(`/pwsadmin/api/pricing/listings?platform_id=${encodeURIComponent(key)}&limit=500`);
      const items = Array.isArray(res.items) ? res.items : [];
      pricingListingCacheByPlatformId.set(key, items);
      return items;
    }

    async function syncPricingTargetScope(prefix, options = {}) {
      const { selectedLookupId = null, forceReload = false } = options;
      const mode = getPricingTargetMode(prefix);
      const propertyRow = document.getElementById(`${prefix}-property-row`);
      const propertyEl = document.getElementById(`${prefix}-property`);
      const platformRow = document.getElementById(`${prefix}-platform-row`);
      const platformEl = document.getElementById(`${prefix}-platform`);
      const listingRow = document.getElementById(`${prefix}-listing-row`);
      const listingEl = document.getElementById(`${prefix}-listing`);
      const showProperty = mode === "property_platform" || mode === "property";
      const showPlatform = mode === "property_platform" || mode === "platform" || mode === "listing";
      const showListing = mode === "listing";

      propertyRow.classList.toggle("hidden", !showProperty);
      platformRow.classList.toggle("hidden", !showPlatform);
      listingRow.classList.toggle("hidden", !showListing);
      propertyEl.disabled = !showProperty;
      platformEl.disabled = !showPlatform;
      listingEl.disabled = !showListing;

      if (!showProperty) setControlErrorState(propertyEl, null);
      if (!showPlatform) setControlErrorState(platformEl, null);
      if (!showListing) {
        setControlErrorState(listingEl, null);
        populatePricingListingSelectControl(listingEl, [], { placeholder: "Select single listing target" });
        return;
      }

      const platformId = String(platformEl.value || "").trim();
      if (!platformId) {
        populatePricingListingSelectControl(listingEl, [], { placeholder: "Select platform first" });
        return;
      }

      const items = await ensurePricingListingsLoaded(platformId, { force: forceReload });
      const nextSelectedLookupId = normalizeLookupId(selectedLookupId) ?? normalizeLookupId(listingEl.value);
      populatePricingListingSelectControl(listingEl, items, {
        placeholder: items.length ? "Select listing" : "No listings found",
        selectedValue: nextSelectedLookupId === null ? "" : String(nextSelectedLookupId),
      });
    }

    function buildPricingTargetPayload(prefix) {
      const mode = getPricingTargetMode(prefix);
      const propertyId = normalizeLookupId(document.getElementById(`${prefix}-property`).value);
      const platformId = normalizeLookupId(document.getElementById(`${prefix}-platform`).value);
      const listingLookupId = normalizeLookupId(document.getElementById(`${prefix}-listing`).value);
      if (mode === "listing") {
        return { property_id: null, platform_id: null, platform_property_lookup_id: listingLookupId };
      }
      if (mode === "global") {
        return { property_id: null, platform_id: null, platform_property_lookup_id: null };
      }
      if (mode === "platform") {
        return { property_id: null, platform_id: platformId, platform_property_lookup_id: null };
      }
      if (mode === "property") {
        return { property_id: propertyId, platform_id: null, platform_property_lookup_id: null };
      }
      return { property_id: propertyId, platform_id: platformId, platform_property_lookup_id: null };
    }

    function getPricingMode() {
      const savedMode = localStorage.getItem(SIMPLE_PRICING_MODE_KEY);
      return ["simple", "moderate", "advanced"].includes(savedMode) ? savedMode : "simple";
    }

    function setPricingMode(mode, { persist = true } = {}) {
      const nextMode = ["simple", "moderate", "advanced"].includes(mode) ? mode : "simple";
      document.getElementById("pricing-simple-wrap").classList.toggle("hidden", nextMode !== "simple");
      document.getElementById("pricing-moderate-wrap").classList.toggle("hidden", nextMode !== "moderate");
      document.getElementById("pricing-advanced-wrap").classList.toggle("hidden", nextMode !== "advanced");
      document.getElementById("pricing-help-simple").classList.toggle("hidden", nextMode !== "simple");
      document.getElementById("pricing-help-moderate").classList.toggle("hidden", nextMode !== "moderate");
      document.getElementById("pricing-help-advanced").classList.toggle("hidden", nextMode !== "advanced");
      document.getElementById("pricing-mode-simple").classList.toggle("nav-btn-active", nextMode === "simple");
      document.getElementById("pricing-mode-moderate").classList.toggle("nav-btn-active", nextMode === "moderate");
      document.getElementById("pricing-mode-advanced").classList.toggle("nav-btn-active", nextMode === "advanced");
      if (nextMode === "simple" || nextMode === "moderate") {
        window.requestAnimationFrame(refreshPricingCategoryViewportLimits);
      }
      if (persist) localStorage.setItem(SIMPLE_PRICING_MODE_KEY, nextMode);
    }

    function markPricingSelection(ruleUuid = null) {
      selectedPricingRuleUuid = ruleUuid || null;
      document.querySelectorAll("#pricing-rows tr").forEach((row) => {
        const isSelected = selectedPricingRuleUuid && row.dataset.ruleUuid === selectedPricingRuleUuid;
        row.style.backgroundColor = isSelected
          ? (document.documentElement.classList.contains("dark") ? "rgba(15, 118, 110, 0.24)" : "rgba(15, 118, 110, 0.08)")
          : "";
      });
    }

    function getSimpleDateScope() {
      const selected = document.querySelector('input[name="pricing_simple_date_scope"]:checked');
      return selected?.value === "exact" ? "exact" : "range";
    }

    function setSimpleDateScope(scope) {
      const nextScope = scope === "exact" ? "exact" : "range";
      document.getElementById("pricing-simple-range-fields").classList.toggle("hidden", nextScope !== "range");
      document.getElementById("pricing-simple-exact-fields").classList.toggle("hidden", nextScope !== "exact");
      document.getElementById("pricing-simple-start-date").disabled = nextScope !== "range";
      document.getElementById("pricing-simple-end-date").disabled = nextScope !== "range";
      document.querySelectorAll(".pricing-simple-exact-date").forEach((input) => {
        input.disabled = nextScope !== "exact";
      });
      const radio = document.querySelector(`input[name="pricing_simple_date_scope"][value="${nextScope}"]`);
      if (radio) radio.checked = true;
    }

    function buildSimpleExactDateRow(value = "") {
      const wrapper = document.createElement("div");
      wrapper.className = "grid gap-2 md:grid-cols-[minmax(0,1fr)_auto]";

      const input = document.createElement("input");
      input.type = "date";
      input.value = value;
      input.className = "pricing-simple-exact-date control-surface w-full rounded border px-2 py-2 text-sm";
      input.dataset.tooltipBase = "Format: YYYY-MM-DD";
      input.title = input.dataset.tooltipBase;
      input.disabled = getSimpleDateScope() !== "exact";
      const validate = () => {
        const current = input.value.trim();
        setControlErrorState(input, current ? validateIsoDate(current) : null);
      };
      input.addEventListener("input", validate);
      input.addEventListener("change", validate);
      input.addEventListener("blur", validate);

      const removeButton = document.createElement("button");
      removeButton.type = "button";
      removeButton.className = "secondary-btn rounded border px-3 py-2 text-xs font-semibold";
      removeButton.textContent = "Remove";
      removeButton.addEventListener("click", () => {
        wrapper.remove();
        const container = document.getElementById("pricing-simple-exact-dates");
        if (!container.children.length) container.appendChild(buildSimpleExactDateRow());
      });

      wrapper.appendChild(input);
      wrapper.appendChild(removeButton);
      return wrapper;
    }

    function setSimpleExactDates(values = []) {
      const container = document.getElementById("pricing-simple-exact-dates");
      container.innerHTML = "";
      const normalizedValues = values.length ? values.map((value) => normalizeDateValue(value)) : [""];
      normalizedValues.forEach((value) => container.appendChild(buildSimpleExactDateRow(value)));
    }

    function getSimpleExactDates() {
      return Array.from(document.querySelectorAll(".pricing-simple-exact-date"))
        .map((input) => input.value.trim())
        .filter(Boolean);
    }

    function applyCategoryViewportLimit(container, itemSelector) {
      if (!container) return;
      container.style.maxHeight = "";

      const items = Array.from(container.querySelectorAll(itemSelector));
      if (!items.length) return;

      const visibleCount = Math.min(5, items.length);
      const computed = window.getComputedStyle(container);
      const rowGapValue = computed.rowGap && computed.rowGap !== "normal" ? computed.rowGap : computed.gap;
      const rowGap = Number.parseFloat(rowGapValue) || 0;
      const minItemHeight = items.reduce((minHeight, item) => {
        const height = item.getBoundingClientRect().height;
        return height > 0 ? Math.min(minHeight, height) : minHeight;
      }, Number.POSITIVE_INFINITY);

      if (!Number.isFinite(minItemHeight)) return;

      const maxHeight = (minItemHeight * visibleCount) + (rowGap * Math.max(0, visibleCount - 1)) + 2;
      container.style.maxHeight = `${Math.ceil(maxHeight)}px`;
    }

    function refreshPricingCategoryViewportLimits() {
      applyCategoryViewportLimit(document.getElementById("pricing-simple-categories"), ".pricing-simple-category-row");
      applyCategoryViewportLimit(document.getElementById("pricing-moderate-categories"), ".pricing-moderate-category-row");
    }

    function renderSimpleCategoryOptions() {
      const container = document.getElementById("pricing-simple-categories");
      container.innerHTML = "";
      if (!messageClassesCache.length) {
        container.textContent = "No active message classes found.";
        applyCategoryViewportLimit(container, ".pricing-simple-category-row");
        return;
      }
      messageClassesCache.forEach((item) => {
        const label = document.createElement("label");
        label.className = "pricing-simple-category-row flex items-start gap-2 rounded-lg border border-slate-200 bg-white/90 p-2 dark:border-slate-700 dark:bg-slate-900/70";

        const input = document.createElement("input");
        input.type = "checkbox";
        input.value = item.name;
        input.className = "pricing-simple-category mt-0.5";

        const textWrap = document.createElement("span");
        textWrap.className = "min-w-0";

        const name = document.createElement("span");
        name.className = "block font-semibold text-slate-700 dark:text-slate-100";
        name.textContent = item.name;
        textWrap.appendChild(name);

        if (item.description) {
          const description = document.createElement("span");
          description.className = "mt-0.5 block text-[11px] text-slate-500 dark:text-slate-400";
          description.textContent = item.description;
          textWrap.appendChild(description);
        }

        label.appendChild(input);
        label.appendChild(textWrap);
        container.appendChild(label);
      });
      applyCategoryViewportLimit(container, ".pricing-simple-category-row");
    }

    function setSimpleCategories(categories = []) {
      const selected = new Set(categories);
      document.querySelectorAll(".pricing-simple-category").forEach((input) => {
        input.checked = selected.has(input.value);
      });
    }

    function getSimpleCategories() {
      return Array.from(document.querySelectorAll(".pricing-simple-category"))
        .filter((input) => input.checked)
        .map((input) => input.value);
    }

    function normalizePricingStringList(value) {
      if (!Array.isArray(value) || !value.length) return null;
      const normalized = [];
      for (const item of value) {
        if (typeof item !== "string" || !item.trim()) return null;
        normalized.push(item.trim());
      }
      return normalized;
    }

    function parsePricingStayLengthCondition(condition) {
      if (!condition || typeof condition !== "object" || Array.isArray(condition)) return null;
      const keys = Object.keys(condition);
      if (keys.length !== 1) return null;
      const operator = keys[0];
      if (!PRICING_STAY_LENGTH_OPERATORS.has(operator)) return null;
      if (operator === "between") {
        const range = condition.between;
        if (!Array.isArray(range) || range.length !== 2) return null;
        const minimum = Number(range[0]);
        const maximum = Number(range[1]);
        if (!Number.isInteger(minimum) || minimum < 0 || !Number.isInteger(maximum) || maximum < 0 || minimum > maximum) {
          return null;
        }
        return { operator, value: minimum, max: maximum };
      }
      const value = Number(condition[operator]);
      if (!Number.isInteger(value) || value < 0) return null;
      return { operator, value };
    }

    function getPricingLegacyConditionCompatibility(conditions, modeLabel) {
      if (!conditions || typeof conditions !== "object" || Array.isArray(conditions)) {
        return { compatible: false, reason: "The booking condition is missing." };
      }

      const conditionKeys = Object.keys(conditions);
      const hasStayLength = Object.prototype.hasOwnProperty.call(conditions, "stay_length");
      const hasBookingClass = Object.prototype.hasOwnProperty.call(conditions, "booking_class");
      if (hasStayLength || hasBookingClass) {
        if (!hasStayLength || !hasBookingClass) {
          return { compatible: false, reason: "Longer-stay rules require both stay_length and booking_class." };
        }
        if (conditionKeys.some((key) => !["stay_length", "booking_class"].includes(key))) {
          return { compatible: false, reason: "This rule mixes condition shapes that the structured editor cannot rebuild." };
        }
        const stayLength = parsePricingStayLengthCondition(conditions.stay_length);
        if (!stayLength) {
          return { compatible: false, reason: "The stay_length condition is invalid." };
        }
        const bookingClass = conditions.booking_class;
        if (!bookingClass || typeof bookingClass !== "object" || Array.isArray(bookingClass)) {
          return { compatible: false, reason: "The booking_class condition is invalid." };
        }
        if (Object.keys(bookingClass).some((key) => key !== "any_of")) {
          return { compatible: false, reason: "This rule uses advanced booking_class fields." };
        }
        const classes = normalizePricingStringList(bookingClass.any_of);
        if (!classes) {
          return { compatible: false, reason: `${modeLabel} mode requires at least one booking class.` };
        }
        const activeCategoryNames = new Set(messageClassesCache.map((item) => item.name));
        if (activeCategoryNames.size && classes.some((item) => !activeCategoryNames.has(item))) {
          return { compatible: false, reason: `This rule references classes not available in ${modeLabel} mode.` };
        }
        return { compatible: true, classes, stayLength };
      }

      if (conditionKeys.some((key) => key !== "booking_category")) {
        return { compatible: false, reason: "This rule uses advanced condition settings." };
      }
      const bookingCategory = conditions.booking_category;
      if (!bookingCategory || typeof bookingCategory !== "object" || Array.isArray(bookingCategory)) {
        return { compatible: false, reason: "The booking category condition is invalid." };
      }
      if (Object.keys(bookingCategory).some((key) => key !== "in")) {
        return { compatible: false, reason: "This rule uses advanced booking category fields." };
      }
      const categories = normalizePricingStringList(bookingCategory.in);
      if (!categories) {
        return { compatible: false, reason: `${modeLabel} mode requires at least one trigger category.` };
      }
      const activeCategoryNames = new Set(messageClassesCache.map((item) => item.name));
      if (activeCategoryNames.size && categories.some((item) => !activeCategoryNames.has(item))) {
        return { compatible: false, reason: `This rule references categories not available in ${modeLabel} mode.` };
      }
      return { compatible: true, classes: categories, stayLength: null };
    }

    function parseSimpleConditionTreeStayLength(operator, rawValue) {
      if (!PRICING_STAY_LENGTH_OPERATORS.has(operator)) return null;
      if (operator === "between") {
        if (!rawValue || typeof rawValue !== "object" || Array.isArray(rawValue)) return null;
        const minimum = Number(rawValue.min);
        const maximum = Number(rawValue.max);
        if (!Number.isInteger(minimum) || minimum < 0 || !Number.isInteger(maximum) || maximum < 0 || minimum > maximum) {
          return null;
        }
        return { operator, value: minimum, max: maximum };
      }
      const value = Number(rawValue);
      if (!Number.isInteger(value) || value < 0) return null;
      return { operator, value };
    }

    function parseSimpleConditionTreeState(ruleConfig, modeLabel) {
      if (Number(ruleConfig.conditions_version) !== 2) {
        return { compatible: false, reason: "condition_tree rules require conditions_version = 2." };
      }
      const conditionTree = ruleConfig.condition_tree;
      if (!conditionTree || typeof conditionTree !== "object" || Array.isArray(conditionTree)) {
        return { compatible: false, reason: "condition_tree must be an object." };
      }

      const treeType = String(conditionTree.type || "").toLowerCase();
      let members = [];
      if (treeType === "condition") {
        members = [conditionTree];
      } else if (treeType === "group") {
        if (String(conditionTree.evaluation_operator || "").toLowerCase() !== "and") {
          return { compatible: false, reason: "Simple mode only supports AND condition groups." };
        }
        if (!Array.isArray(conditionTree.members) || !conditionTree.members.length) {
          return { compatible: false, reason: "condition_tree group must contain members." };
        }
        if (conditionTree.members.some((member) => String(member?.type || "").toLowerCase() !== "condition")) {
          return { compatible: false, reason: "Simple mode does not support nested condition_tree groups." };
        }
        members = conditionTree.members;
      } else {
        return { compatible: false, reason: "condition_tree must be a condition node or AND group." };
      }

      let classes = null;
      let stayLength = null;
      for (const member of members) {
        const conditionName = String(member?.condition_name || "").trim().toLowerCase();
        if (conditionName === "booking_category" || conditionName === "booking_class") {
          if (classes) {
            return { compatible: false, reason: "Simple mode supports only one booking category/class condition node." };
          }
          const operator = String(member?.comparison_operator || "").trim().toLowerCase();
          if (operator !== "any_of") {
            return { compatible: false, reason: "Simple mode only supports booking category/class any_of." };
          }
          const nextClasses = normalizePricingStringList(member?.value);
          if (!nextClasses) {
            return { compatible: false, reason: `${modeLabel} mode requires at least one trigger category.` };
          }
          classes = nextClasses;
          continue;
        }
        if (conditionName === "stay_length") {
          if (stayLength) {
            return { compatible: false, reason: "Simple mode supports one stay_length condition only." };
          }
          const operator = String(member?.comparison_operator || "").trim().toLowerCase();
          const parsed = parseSimpleConditionTreeStayLength(operator, member?.value);
          if (!parsed) {
            return { compatible: false, reason: "The stay_length condition is invalid." };
          }
          stayLength = parsed;
          continue;
        }
        return { compatible: false, reason: `Simple mode does not support condition_tree condition_name=${conditionName}.` };
      }

      if (!classes) {
        return { compatible: false, reason: "The booking condition is missing." };
      }
      const activeCategoryNames = new Set(messageClassesCache.map((item) => item.name));
      if (activeCategoryNames.size && classes.some((item) => !activeCategoryNames.has(item))) {
        return { compatible: false, reason: `This rule references categories not available in ${modeLabel} mode.` };
      }
      return { compatible: true, classes, stayLength };
    }

    function getSimpleConditionCompatibility(ruleConfig, modeLabel) {
      if (!ruleConfig || typeof ruleConfig !== "object" || Array.isArray(ruleConfig)) {
        return { compatible: false, reason: "rule_config must be an object." };
      }
      if (ruleConfig.condition_tree !== null && ruleConfig.condition_tree !== undefined) {
        return parseSimpleConditionTreeState(ruleConfig, modeLabel);
      }
      return getPricingLegacyConditionCompatibility(ruleConfig.conditions, modeLabel);
    }

    function isPricingLongerStayEnabled(prefix) {
      return Boolean(document.getElementById(`${prefix}-longer-stay-enabled`)?.checked);
    }

    function syncPricingStayLengthFields(prefix) {
      const enabled = isPricingLongerStayEnabled(prefix);
      const operatorEl = document.getElementById(`${prefix}-stay-length-op`);
      const valueEl = document.getElementById(`${prefix}-stay-length-value`);
      const maxEl = document.getElementById(`${prefix}-stay-length-max`);
      const maxRowEl = document.getElementById(`${prefix}-stay-length-max-row`);
      const fieldsEl = document.getElementById(`${prefix}-longer-stay-fields`);
      const isBetween = operatorEl.value === "between";

      fieldsEl.classList.toggle("opacity-60", !enabled);
      operatorEl.disabled = !enabled;
      valueEl.disabled = !enabled;
      maxEl.disabled = !enabled || !isBetween;
      maxRowEl.classList.toggle("hidden", !enabled || !isBetween);

      if (!enabled) {
        [operatorEl, valueEl, maxEl].forEach((element) => setControlErrorState(element, null));
      } else if (!isBetween) {
        setControlErrorState(maxEl, null);
      }
    }

    function resetPricingStayLengthFields(prefix) {
      document.getElementById(`${prefix}-longer-stay-enabled`).checked = false;
      document.getElementById(`${prefix}-stay-length-op`).value = "gt";
      document.getElementById(`${prefix}-stay-length-value`).value = "";
      document.getElementById(`${prefix}-stay-length-max`).value = "";
      syncPricingStayLengthFields(prefix);
    }

    function setPricingStayLengthFields(prefix, stayLength) {
      const enabled = Boolean(stayLength);
      document.getElementById(`${prefix}-longer-stay-enabled`).checked = enabled;
      document.getElementById(`${prefix}-stay-length-op`).value = stayLength?.operator || "gt";
      document.getElementById(`${prefix}-stay-length-value`).value = stayLength ? String(stayLength.value) : "";
      document.getElementById(`${prefix}-stay-length-max`).value = stayLength?.operator === "between" ? String(stayLength.max) : "";
      syncPricingStayLengthFields(prefix);
    }

    function validatePricingStayLengthControls(prefix) {
      if (!isPricingLongerStayEnabled(prefix)) return true;
      const operatorEl = document.getElementById(`${prefix}-stay-length-op`);
      const valueEl = document.getElementById(`${prefix}-stay-length-value`);
      const maxEl = document.getElementById(`${prefix}-stay-length-max`);
      const controls = operatorEl.value === "between" ? [operatorEl, valueEl, maxEl] : [operatorEl, valueEl];
      if (!validateControls(controls, { required: true })) return false;
      if (operatorEl.value === "between" && Number(valueEl.value) > Number(maxEl.value)) {
        const message = "Minimum nights must be <= max nights";
        setControlErrorState(maxEl, message);
        setStatus(`${prefix}-stay-length-max: ${message}`, true);
        maxEl.focus();
        return false;
      }
      return true;
    }

    function buildPricingStayLengthCondition(prefix) {
      const operator = document.getElementById(`${prefix}-stay-length-op`).value;
      const value = Number(document.getElementById(`${prefix}-stay-length-value`).value);
      if (operator === "between") {
        return { between: [value, Number(document.getElementById(`${prefix}-stay-length-max`).value)] };
      }
      return { [operator]: value };
    }

    function buildPricingConditions(prefix, classes) {
      if (isPricingLongerStayEnabled(prefix)) {
        return {
          stay_length: buildPricingStayLengthCondition(prefix),
          booking_class: {
            any_of: classes,
          },
        };
      }
      return {
        booking_category: {
          in: classes,
        },
      };
    }

    function buildSimpleConditionTree(classes) {
      const classNode = {
        type: "condition",
        condition_name: isPricingLongerStayEnabled("pricing-simple") ? "booking_class" : "booking_category",
        comparison_operator: "any_of",
        value: classes,
      };
      if (!isPricingLongerStayEnabled("pricing-simple")) {
        return classNode;
      }

      const stayLengthCondition = buildPricingStayLengthCondition("pricing-simple");
      const operator = Object.keys(stayLengthCondition)[0];
      const stayValue = stayLengthCondition[operator];
      return {
        type: "group",
        evaluation_operator: "and",
        members: [
          classNode,
          {
            type: "condition",
            condition_name: "stay_length",
            comparison_operator: operator,
            value: operator === "between"
              ? { min: stayValue[0], max: stayValue[1] }
              : stayValue,
          },
        ],
      };
    }

    function parseModerateOptionalInteger(value, fieldLabel) {
      const raw = String(value ?? "").trim();
      if (!raw) return { ok: true, value: null };
      const numeric = Number(raw);
      if (!Number.isInteger(numeric) || numeric < 0) {
        return { ok: false, reason: `${fieldLabel} must be a whole number >= 0.` };
      }
      return { ok: true, value: numeric };
    }

    function parseModerateNumericConditionShape(rawCondition, fieldLabel) {
      if (rawCondition === null || rawCondition === undefined) {
        return { compatible: true, state: null };
      }
      if (typeof rawCondition === "number") {
        const parsed = parseModerateOptionalInteger(rawCondition, fieldLabel);
        if (!parsed.ok || parsed.value === null) {
          return { compatible: false, reason: parsed.reason || `${fieldLabel} must be a whole number >= 0.` };
        }
        return {
          compatible: true,
          state: { operator: "eq", value: parsed.value, max: null },
        };
      }
      if (!rawCondition || typeof rawCondition !== "object" || Array.isArray(rawCondition)) {
        return { compatible: false, reason: `${fieldLabel} must be a number or comparison object.` };
      }
      const keys = Object.keys(rawCondition);
      if (keys.length !== 1) {
        return { compatible: false, reason: `${fieldLabel} must include exactly one operator.` };
      }
      const operator = keys[0];
      if (!MODERATE_NUMERIC_COMPARISON_OPERATORS.has(operator)) {
        return { compatible: false, reason: `${fieldLabel} uses unsupported operator ${operator}.` };
      }
      if (operator === "between") {
        const between = rawCondition.between;
        if (!between || typeof between !== "object" || Array.isArray(between)) {
          return { compatible: false, reason: `${fieldLabel}.between must include min and max.` };
        }
        const minParsed = parseModerateOptionalInteger(between.min, `${fieldLabel}.between.min`);
        if (!minParsed.ok || minParsed.value === null) return { compatible: false, reason: minParsed.reason };
        const maxParsed = parseModerateOptionalInteger(between.max, `${fieldLabel}.between.max`);
        if (!maxParsed.ok || maxParsed.value === null) return { compatible: false, reason: maxParsed.reason };
        if (minParsed.value > maxParsed.value) {
          return { compatible: false, reason: `${fieldLabel}.between.min must be <= max.` };
        }
        return {
          compatible: true,
          state: { operator: "between", value: minParsed.value, max: maxParsed.value },
        };
      }
      const parsed = parseModerateOptionalInteger(rawCondition[operator], `${fieldLabel}.${operator}`);
      if (!parsed.ok || parsed.value === null) return { compatible: false, reason: parsed.reason };
      return {
        compatible: true,
        state: { operator, value: parsed.value, max: null },
      };
    }

    function parseModerateStayNodeCondition(node) {
      const conditionName = String(node?.condition_name || "").trim();
      const operator = String(node?.comparison_operator || "").trim();
      if (!conditionName || !operator) {
        return { compatible: false, reason: "Condition tree stay nodes require condition_name and comparison_operator." };
      }
      const normalizedOperator = operator.toLowerCase();
      if (!MODERATE_NUMERIC_COMPARISON_OPERATORS.has(normalizedOperator)) {
        return { compatible: false, reason: `${conditionName} uses unsupported operator ${operator}.` };
      }
      const rawShape = normalizedOperator === "between"
        ? { between: node?.value }
        : { [normalizedOperator]: node?.value };
      return parseModerateNumericConditionShape(rawShape, conditionName);
    }

    function parseModerateBookingClassConditionNode(node) {
      if (!node || typeof node !== "object" || Array.isArray(node)) {
        return { compatible: false, reason: "The booking_class condition is invalid." };
      }
      const operator = String(node.comparison_operator || "").trim().toLowerCase();
      if (!MODERATE_BOOKING_CLASS_OPERATORS.has(operator)) {
        return { compatible: false, reason: "booking_class supports only any_of or all_of in Moderate mode." };
      }
      const classes = normalizePricingStringList(node.value);
      if (!classes) {
        return { compatible: false, reason: "Moderate mode requires at least one booking class." };
      }

      let positions = classes.map(() => null);
      if (node.pos !== null && node.pos !== undefined) {
        if (!Array.isArray(node.pos) || node.pos.length !== classes.length) {
          return { compatible: false, reason: "booking_class.pos must be an array aligned with value." };
        }
        positions = [];
        for (let index = 0; index < node.pos.length; index += 1) {
          const rawPos = node.pos[index];
          if (rawPos === null || rawPos === undefined || rawPos === "") {
            positions.push(null);
            continue;
          }
          const parsed = parseModerateOptionalInteger(rawPos, `booking_class.pos[${index}]`);
          if (!parsed.ok || parsed.value === null) {
            return { compatible: false, reason: parsed.reason || "booking_class.pos must contain non-negative integers or null." };
          }
          positions.push(parsed.value);
        }
      }

      return {
        compatible: true,
        state: {
          operator,
          classes,
          positions,
        },
      };
    }

    function ensureModerateClassesAvailable(classes) {
      const activeClassNames = new Set(messageClassesCache.map((item) => item.name));
      if (!activeClassNames.size) return { compatible: true };
      if (classes.some((item) => !activeClassNames.has(item))) {
        return { compatible: false, reason: "This rule references classes not available in Moderate mode." };
      }
      return { compatible: true };
    }

    function parseModerateConditionTreeState(ruleConfig) {
      const allowedRootKeys = new Set(["subject", "operation", "apply_window", "conditions_version", "condition_tree", "season_window"]);
      if (Object.keys(ruleConfig).some((key) => !allowedRootKeys.has(key))) {
        return { compatible: false, reason: "This rule contains extra JSON branches." };
      }
      if (Number(ruleConfig.conditions_version) !== 2) {
        return { compatible: false, reason: "condition_tree rules require conditions_version = 2." };
      }
      const emptyState = {
        classState: {
          operator: "any_of",
          classes: [],
          positions: [],
        },
        stayState: {
          stay_length: null,
          stay_extended: null,
          stay_contracted: null,
        },
      };
      const conditionTree = ruleConfig.condition_tree;
      if (conditionTree === null || conditionTree === undefined) {
        return {
          compatible: true,
          state: emptyState,
        };
      }
      if (typeof conditionTree !== "object" || Array.isArray(conditionTree)) {
        return { compatible: false, reason: "condition_tree must be an object." };
      }

      const treeType = String(conditionTree.type || "").toLowerCase();
      let members = [];
      if (treeType === "condition") {
        members = [conditionTree];
      } else if (treeType === "group") {
        if (String(conditionTree.evaluation_operator || "").toLowerCase() !== "and") {
          return { compatible: false, reason: "Moderate mode only supports AND condition groups." };
        }
        if (!Array.isArray(conditionTree.members) || !conditionTree.members.length) {
          return { compatible: false, reason: "condition_tree group must contain members." };
        }
        if (conditionTree.members.some((member) => String(member?.type || "").toLowerCase() !== "condition")) {
          return { compatible: false, reason: "Moderate mode does not support nested condition_tree groups." };
        }
        members = conditionTree.members;
      } else {
        return { compatible: false, reason: "condition_tree must be a condition node or AND group." };
      }

      const stayState = { ...emptyState.stayState };
      let classState = null;

      for (const member of members) {
        const conditionName = String(member?.condition_name || "").trim().toLowerCase();
        if (conditionName === "booking_class" || conditionName === "booking_category") {
          if (classState) {
            return { compatible: false, reason: "Moderate mode supports only one booking_class condition node." };
          }
          const parsedClass = parseModerateBookingClassConditionNode(member);
          if (!parsedClass.compatible) return parsedClass;
          classState = parsedClass.state;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(stayState, conditionName)) {
          if (stayState[conditionName] !== null) {
            return { compatible: false, reason: `Moderate mode supports one ${conditionName} node only.` };
          }
          const parsedStay = parseModerateStayNodeCondition(member);
          if (!parsedStay.compatible) return parsedStay;
          stayState[conditionName] = parsedStay.state;
          continue;
        }
        return { compatible: false, reason: `Moderate mode does not support condition_tree condition_name=${conditionName}.` };
      }

      if (classState) {
        const classCatalog = ensureModerateClassesAvailable(classState.classes);
        if (!classCatalog.compatible) return classCatalog;
      } else {
        classState = emptyState.classState;
      }

      return {
        compatible: true,
        state: {
          classState,
          stayState,
        },
      };
    }

    function parseModerateLegacyState(ruleConfig) {
      const allowedRootKeys = new Set(["subject", "operation", "apply_window", "conditions", "stay_length", "stay_extended", "stay_contracted", "season_window"]);
      if (Object.keys(ruleConfig).some((key) => !allowedRootKeys.has(key))) {
        return { compatible: false, reason: "Legacy rule contains JSON branches Moderate mode cannot safely convert." };
      }
      const conditions = ruleConfig.conditions;
      if (!conditions || typeof conditions !== "object" || Array.isArray(conditions)) {
        return { compatible: false, reason: "Legacy rule must include conditions." };
      }

      let classState = null;
      const conditionKeys = Object.keys(conditions);
      if (conditionKeys.length !== 1) {
        return { compatible: false, reason: "Legacy Moderate rules must have exactly one condition key." };
      }

      if (conditionKeys[0] === "booking_category") {
        const bookingCategory = conditions.booking_category;
        if (!bookingCategory || typeof bookingCategory !== "object" || Array.isArray(bookingCategory)) {
          return { compatible: false, reason: "Legacy booking_category condition is invalid." };
        }
        if (Object.keys(bookingCategory).some((key) => key !== "in")) {
          return { compatible: false, reason: "Legacy booking_category condition uses unsupported fields." };
        }
        const classes = normalizePricingStringList(bookingCategory.in);
        if (!classes) {
          return { compatible: false, reason: "Legacy rule must include at least one booking category." };
        }
        classState = {
          operator: "any_of",
          classes,
          positions: classes.map(() => null),
        };
      } else if (conditionKeys[0] === "booking_class") {
        const bookingClass = conditions.booking_class;
        if (!bookingClass || typeof bookingClass !== "object" || Array.isArray(bookingClass)) {
          return { compatible: false, reason: "Legacy booking_class condition is invalid." };
        }
        let operator = null;
        let classes = null;
        if (Object.prototype.hasOwnProperty.call(bookingClass, "any_of")) {
          operator = "any_of";
          classes = normalizePricingStringList(bookingClass.any_of);
        } else if (Object.prototype.hasOwnProperty.call(bookingClass, "all_of")) {
          operator = "all_of";
          classes = normalizePricingStringList(bookingClass.all_of);
        }
        if (!operator || !classes) {
          return { compatible: false, reason: "Legacy booking_class condition must include any_of or all_of." };
        }
        const parsedClass = parseModerateBookingClassConditionNode({
          comparison_operator: operator,
          value: classes,
          pos: bookingClass.pos,
        });
        if (!parsedClass.compatible) return parsedClass;
        classState = parsedClass.state;
      } else {
        return { compatible: false, reason: "Legacy Moderate rules require booking_category or booking_class." };
      }

      const classCatalog = ensureModerateClassesAvailable(classState.classes);
      if (!classCatalog.compatible) return classCatalog;

      const stayState = {
        stay_length: null,
        stay_extended: null,
        stay_contracted: null,
      };
      for (const field of MODERATE_STAY_CONDITION_FIELDS) {
        const parsed = parseModerateNumericConditionShape(ruleConfig[field.key], field.label);
        if (!parsed.compatible) return parsed;
        stayState[field.key] = parsed.state;
      }

      return {
        compatible: true,
        state: {
          classState,
          stayState,
        },
      };
    }

    function parseModerateRuleConditionState(ruleConfig) {
      if (!ruleConfig || typeof ruleConfig !== "object" || Array.isArray(ruleConfig)) {
        return { compatible: false, reason: "rule_config must be an object." };
      }
      if (
        Number(ruleConfig.conditions_version) === 2 ||
        Object.prototype.hasOwnProperty.call(ruleConfig, "condition_tree")
      ) {
        return parseModerateConditionTreeState(ruleConfig);
      }
      return parseModerateLegacyState(ruleConfig);
    }

    function setModerateBookingClassOperator(operator = "any_of") {
      const operatorEl = document.getElementById("pricing-moderate-booking-class-operator");
      operatorEl.value = MODERATE_BOOKING_CLASS_OPERATORS.has(operator) ? operator : "any_of";
    }

    function getModerateBookingClassOperator() {
      const operator = document.getElementById("pricing-moderate-booking-class-operator").value;
      return MODERATE_BOOKING_CLASS_OPERATORS.has(operator) ? operator : "any_of";
    }

    function syncModerateCategoryPositionInputs() {
      document.querySelectorAll(".pricing-moderate-category-row").forEach((row) => {
        const classCheckbox = row.querySelector(".pricing-moderate-category");
        const positionInput = row.querySelector(".pricing-moderate-category-position");
        if (!classCheckbox || !positionInput) return;
        const enabled = Boolean(classCheckbox.checked);
        positionInput.disabled = !enabled;
        if (!enabled) {
          setControlErrorState(positionInput, null);
        }
      });
    }

    function getModerateClassSelectionState() {
      const classes = [];
      const positions = [];
      document.querySelectorAll(".pricing-moderate-category-row").forEach((row) => {
        const classCheckbox = row.querySelector(".pricing-moderate-category");
        const positionInput = row.querySelector(".pricing-moderate-category-position");
        if (!classCheckbox || !classCheckbox.checked) return;
        classes.push(classCheckbox.value);
        const rawPos = (positionInput?.value || "").trim();
        if (!rawPos) {
          positions.push(null);
          return;
        }
        positions.push(Number(rawPos));
      });
      return { classes, positions };
    }

    function buildModerateClassPositionMap(classState) {
      const map = {};
      const classes = Array.isArray(classState?.classes) ? classState.classes : [];
      const positions = Array.isArray(classState?.positions) ? classState.positions : [];
      classes.forEach((className, index) => {
        map[className] = positions[index] !== undefined ? positions[index] : null;
      });
      return map;
    }

    function getModerateStayFieldElements(field) {
      return {
        operator: document.getElementById(`${field.idBase}-op`),
        value: document.getElementById(`${field.idBase}-value`),
        max: document.getElementById(`${field.idBase}-max`),
        maxRow: document.getElementById(`${field.idBase}-max-row`),
      };
    }

    function syncModerateStayConditionFields() {
      MODERATE_STAY_CONDITION_FIELDS.forEach((field) => {
        const elements = getModerateStayFieldElements(field);
        const hasOperator = Boolean(elements.operator.value);
        const isBetween = hasOperator && elements.operator.value === "between";
        elements.value.disabled = !hasOperator;
        elements.max.disabled = !isBetween;
        elements.maxRow.classList.toggle("hidden", !isBetween);
        if (!hasOperator) {
          setControlErrorState(elements.value, null);
          setControlErrorState(elements.max, null);
        } else if (!isBetween) {
          setControlErrorState(elements.max, null);
        }
      });
    }

    function setModerateStayAdjustmentFields(stayState = null) {
      MODERATE_STAY_CONDITION_FIELDS.forEach((field) => {
        const elements = getModerateStayFieldElements(field);
        const condition = stayState?.[field.key] || null;
        elements.operator.value = condition?.operator || "";
        elements.value.value = condition?.value !== null && condition?.value !== undefined ? String(condition.value) : "";
        elements.max.value = condition?.operator === "between" ? String(condition.max) : "";
      });
      syncModerateStayConditionFields();
    }

    function resetModerateStayAdjustmentFields() {
      setModerateStayAdjustmentFields(null);
      MODERATE_STAY_CONDITION_FIELDS.forEach((field) => {
        const elements = getModerateStayFieldElements(field);
        setControlErrorState(elements.operator, null);
        setControlErrorState(elements.value, null);
        setControlErrorState(elements.max, null);
      });
    }

    function validateModerateStayAdjustmentFields() {
      for (const field of MODERATE_STAY_CONDITION_FIELDS) {
        const elements = getModerateStayFieldElements(field);
        const operator = elements.operator.value;

        if (!validateControl(elements.operator, { silent: true, required: false })) {
          setStatus(`${elements.operator.id}: ${elements.operator.validationMessage || "Invalid value"}`, true);
          elements.operator.focus();
          return false;
        }

        if (!operator) {
          setControlErrorState(elements.value, null);
          setControlErrorState(elements.max, null);
          continue;
        }

        const valueRaw = elements.value.value.trim();
        const valueError = valueRaw ? validateIntegerRange(valueRaw, 0) : "This field is required";
        setControlErrorState(elements.value, valueError);
        if (valueError) {
          setStatus(`${elements.value.id}: ${valueError}`, true);
          elements.value.focus();
          return false;
        }

        if (operator === "between") {
          const maxRaw = elements.max.value.trim();
          const maxError = maxRaw ? validateIntegerRange(maxRaw, 0) : "This field is required";
          setControlErrorState(elements.max, maxError);
          if (maxError) {
            setStatus(`${elements.max.id}: ${maxError}`, true);
            elements.max.focus();
            return false;
          }
          if (Number(valueRaw) > Number(maxRaw)) {
            const message = `${field.label}.between.min must be <= max.`;
            setControlErrorState(elements.max, message);
            setStatus(`${elements.max.id}: ${message}`, true);
            elements.max.focus();
            return false;
          }
        } else {
          setControlErrorState(elements.max, null);
        }
      }
      return true;
    }

    function buildModerateStayConditionNodes() {
      const nodes = [];
      MODERATE_STAY_CONDITION_FIELDS.forEach((field) => {
        const elements = getModerateStayFieldElements(field);
        const operator = elements.operator.value;
        if (!operator) return;
        const value = Number(elements.value.value);
        nodes.push({
          type: "condition",
          condition_name: field.key,
          comparison_operator: operator,
          value: operator === "between"
            ? { min: value, max: Number(elements.max.value) }
            : value,
        });
      });
      return nodes;
    }

    function buildPricingApplyWindow(prefix) {
      const applyWindow = {
        applies_from: document.getElementById(`${prefix}-applies-from`).value,
        duration_days: Number(document.getElementById(`${prefix}-duration-days`).value),
      };
      const offsetDays = Number(document.getElementById(`${prefix}-offset-days`).value || 0);
      if (offsetDays > 0) {
        applyWindow.offset_days = offsetDays;
      }
      return applyWindow;
    }

    function syncSimpleOperationFields() {
      const operation = document.getElementById("pricing-simple-operation").value;
      const amountType = document.getElementById("pricing-simple-amount-type");
      const amountLabel = document.getElementById("pricing-simple-amount-label");
      const amountInput = document.getElementById("pricing-simple-amount");
      const previousValue = amountType.value;

      if (operation === "set") {
        amountType.innerHTML = '<option value="fixed">fixed price</option>';
        amountType.disabled = true;
        amountLabel.textContent = "Price";
        amountInput.min = "0";
      } else if (operation === "multiplier") {
        amountType.innerHTML = '<option value="multiplier">multiplier factor</option>';
        amountType.disabled = true;
        amountLabel.textContent = "Multiplier";
        amountInput.min = "0.01";
      } else {
        amountType.innerHTML = '<option value="percentage">percentage</option><option value="flat">flat</option>';
        amountType.disabled = false;
        amountType.value = previousValue === "flat" ? "flat" : "percentage";
        amountLabel.textContent = "Amount";
        amountInput.min = "0";
      }
    }

    function getModerateOperationConfig(operation) {
      return MODERATE_PRICING_OPERATION_CONFIG[operation] || MODERATE_PRICING_OPERATION_CONFIG.increase;
    }

    function getModerateDateScope() {
      const selected = document.querySelector('input[name="pricing_moderate_date_scope"]:checked');
      return ["exact", "dow"].includes(selected?.value) ? selected.value : "range";
    }

    function setModerateDateScope(scope) {
      const nextScope = ["exact", "dow"].includes(scope) ? scope : "range";
      document.getElementById("pricing-moderate-range-fields").classList.toggle("hidden", nextScope !== "range");
      document.getElementById("pricing-moderate-exact-fields").classList.toggle("hidden", nextScope !== "exact");
      document.getElementById("pricing-moderate-dow-fields").classList.toggle("hidden", nextScope !== "dow");
      document.getElementById("pricing-moderate-start-date").disabled = nextScope !== "range";
      document.getElementById("pricing-moderate-end-date").disabled = nextScope !== "range";
      document.querySelectorAll(".pricing-moderate-exact-date").forEach((input) => {
        input.disabled = nextScope !== "exact";
      });
      document.querySelectorAll(".pricing-moderate-dow-day").forEach((input) => {
        input.disabled = nextScope !== "dow";
      });
      const radio = document.querySelector(`input[name="pricing_moderate_date_scope"][value="${nextScope}"]`);
      if (radio) radio.checked = true;
    }

    function buildModerateExactDateRow(value = "") {
      const wrapper = document.createElement("div");
      wrapper.className = "grid gap-2 md:grid-cols-[minmax(0,1fr)_auto]";

      const input = document.createElement("input");
      input.type = "date";
      input.value = value;
      input.className = "pricing-moderate-exact-date control-surface w-full rounded border px-2 py-2 text-sm";
      input.dataset.tooltipBase = "Format: YYYY-MM-DD";
      input.title = input.dataset.tooltipBase;
      input.disabled = getModerateDateScope() !== "exact";
      const validate = () => {
        const current = input.value.trim();
        setControlErrorState(input, current ? validateIsoDate(current) : null);
      };
      input.addEventListener("input", validate);
      input.addEventListener("change", validate);
      input.addEventListener("blur", validate);

      const removeButton = document.createElement("button");
      removeButton.type = "button";
      removeButton.className = "secondary-btn rounded border px-3 py-2 text-xs font-semibold";
      removeButton.textContent = "Remove";
      removeButton.addEventListener("click", () => {
        wrapper.remove();
        const container = document.getElementById("pricing-moderate-exact-dates");
        if (!container.children.length) container.appendChild(buildModerateExactDateRow());
      });

      wrapper.appendChild(input);
      wrapper.appendChild(removeButton);
      return wrapper;
    }

    function setModerateExactDates(values = []) {
      const container = document.getElementById("pricing-moderate-exact-dates");
      container.innerHTML = "";
      const normalizedValues = values.length ? values.map((value) => normalizeDateValue(value)) : [""];
      normalizedValues.forEach((value) => container.appendChild(buildModerateExactDateRow(value)));
    }

    function getModerateExactDates() {
      return Array.from(document.querySelectorAll(".pricing-moderate-exact-date"))
        .map((input) => input.value.trim())
        .filter(Boolean);
    }

    function renderModerateCategoryOptions() {
      const container = document.getElementById("pricing-moderate-categories");
      container.innerHTML = "";
      if (!messageClassesCache.length) {
        container.textContent = "No active message classes found.";
        applyCategoryViewportLimit(container, ".pricing-moderate-category-row");
        return;
      }
      messageClassesCache.forEach((item) => {
        const label = document.createElement("label");
        label.className = "pricing-moderate-category-row grid gap-2 rounded-lg border border-slate-200 bg-white/90 p-2 dark:border-slate-700 dark:bg-slate-900/70 md:grid-cols-[auto_minmax(0,1fr)_9rem]";

        const input = document.createElement("input");
        input.type = "checkbox";
        input.value = item.name;
        input.className = "pricing-moderate-category mt-0.5";
        input.addEventListener("change", syncModerateCategoryPositionInputs);

        const textWrap = document.createElement("span");
        textWrap.className = "min-w-0";

        const name = document.createElement("span");
        name.className = "block font-semibold text-slate-700 dark:text-slate-100";
        name.textContent = item.name;
        textWrap.appendChild(name);

        const positionWrap = document.createElement("span");
        positionWrap.className = "min-w-0";
        const positionLabel = document.createElement("span");
        positionLabel.className = "block text-[11px] font-semibold text-slate-600 dark:text-slate-300";
        positionLabel.textContent = "position (optional)";
        positionWrap.appendChild(positionLabel);

        const positionInput = document.createElement("input");
        positionInput.type = "number";
        positionInput.min = "0";
        positionInput.className = "pricing-moderate-category-position control-surface mt-1 w-full rounded border px-2 py-1 text-xs";
        positionInput.dataset.className = item.name;
        positionInput.dataset.tooltipBase = "Optional class position (0-based). Leave blank to match any position.";
        positionInput.title = positionInput.dataset.tooltipBase;
        positionWrap.appendChild(positionInput);

        label.appendChild(input);
        label.appendChild(textWrap);
        label.appendChild(positionWrap);
        container.appendChild(label);
      });
      syncModerateCategoryPositionInputs();
      applyCategoryViewportLimit(container, ".pricing-moderate-category-row");
    }

    function setModerateCategories(categories = [], positionsByClass = {}) {
      const selected = new Set(Array.isArray(categories) ? categories : []);
      document.querySelectorAll(".pricing-moderate-category").forEach((input) => {
        input.checked = selected.has(input.value);
        const row = input.closest(".pricing-moderate-category-row");
        const positionInput = row?.querySelector(".pricing-moderate-category-position");
        if (!positionInput) return;
        const mapped = Object.prototype.hasOwnProperty.call(positionsByClass, input.value)
          ? positionsByClass[input.value]
          : null;
        positionInput.value = mapped === null || mapped === undefined ? "" : String(mapped);
      });
      syncModerateCategoryPositionInputs();
    }

    function getModerateCategories() {
      return getModerateClassSelectionState().classes;
    }

    function validateModerateBookingClassInputs() {
      const operatorEl = document.getElementById("pricing-moderate-booking-class-operator");
      if (!validateControls([operatorEl])) return false;

      for (const row of document.querySelectorAll(".pricing-moderate-category-row")) {
        const classCheckbox = row.querySelector(".pricing-moderate-category");
        const positionInput = row.querySelector(".pricing-moderate-category-position");
        if (!classCheckbox || !positionInput) continue;
        if (!classCheckbox.checked) {
          setControlErrorState(positionInput, null);
          continue;
        }
        const value = positionInput.value.trim();
        if (!value) {
          setControlErrorState(positionInput, null);
          continue;
        }
        const error = validateIntegerRange(value, 0);
        setControlErrorState(positionInput, error);
        if (error) {
          setStatus(`${positionInput.dataset.className || "class"} position: ${error}`, true);
          positionInput.focus();
          return false;
        }
      }
      return true;
    }

    function getModerateDayOfWeekPattern() {
      return Array.from(document.querySelectorAll(".pricing-moderate-dow-day"))
        .filter((input) => input.checked)
        .reduce((sum, input) => sum + Number(input.value), 0);
    }

    function setModerateDayOfWeekPattern(pattern = 0) {
      const numericPattern = Number(pattern) || 0;
      document.querySelectorAll(".pricing-moderate-dow-day").forEach((input) => {
        const bit = Number(input.value);
        input.checked = Boolean(numericPattern & bit);
      });
    }

    function getModerateTargetRateType() {
      const value = document.getElementById("pricing-moderate-target-rate-type").value;
      return PRICING_TARGET_RATE_TYPES.has(value) ? value : "base";
    }

    function setModerateTargetRateType(value = "base") {
      document.getElementById("pricing-moderate-target-rate-type").value =
        PRICING_TARGET_RATE_TYPES.has(value) ? value : "base";
    }

    function getModerateSeasonWindow() {
      return {
        start_mmdd: document.getElementById("pricing-moderate-season-start-mmdd").value.trim(),
        end_mmdd: document.getElementById("pricing-moderate-season-end-mmdd").value.trim(),
        applies_to: document.getElementById("pricing-moderate-season-applies-to").value,
      };
    }

    function isModerateSeasonWindowEnabled() {
      return Boolean(document.getElementById("pricing-moderate-season-enabled")?.checked);
    }

    function setModerateSeasonWindowEnabled(enabled) {
      const isEnabled = Boolean(enabled);
      const checkbox = document.getElementById("pricing-moderate-season-enabled");
      if (checkbox) checkbox.checked = isEnabled;
      document.getElementById("pricing-moderate-season-fields")?.classList.toggle("hidden", !isEnabled);
      [
        "pricing-moderate-season-start-mmdd",
        "pricing-moderate-season-end-mmdd",
        "pricing-moderate-season-applies-to",
      ].forEach((id) => {
        const input = document.getElementById(id);
        if (!input) return;
        input.disabled = !isEnabled;
        if (!isEnabled) setControlErrorState(input, null);
      });
    }

    function setModerateSeasonWindow(seasonWindow = null) {
      document.getElementById("pricing-moderate-season-start-mmdd").value = seasonWindow?.start_mmdd || "";
      document.getElementById("pricing-moderate-season-end-mmdd").value = seasonWindow?.end_mmdd || "";
      document.getElementById("pricing-moderate-season-applies-to").value =
        PRICING_SEASON_APPLIES_TO_VALUES.has(seasonWindow?.applies_to)
          ? seasonWindow.applies_to
          : "target_date";
      setModerateSeasonWindowEnabled(Boolean(seasonWindow));
    }

    function syncModerateOperationFields() {
      const operation = document.getElementById("pricing-moderate-operation").value;
      const config = getModerateOperationConfig(operation);
      const amountTypeRow = document.getElementById("pricing-moderate-amount-type-row");
      const amountType = document.getElementById("pricing-moderate-amount-type");
      const amountRow = document.getElementById("pricing-moderate-amount-row");
      const amountLabel = document.getElementById("pricing-moderate-amount-label");
      const amountInput = document.getElementById("pricing-moderate-amount");
      const applyWindowRow = document.getElementById("pricing-moderate-apply-window-row");
      const offsetInput = document.getElementById("pricing-moderate-offset-days");
      const previousAmountType = amountType.value;

      if (config.amountTypeOptions) {
        amountTypeRow.classList.remove("hidden");
        amountType.disabled = false;
        amountType.innerHTML = config.amountTypeOptions
          .map((value) => `<option value="${value}">${value}</option>`)
          .join("");
        amountType.value = config.amountTypeOptions.includes(previousAmountType)
          ? previousAmountType
          : config.amountTypeOptions[0];
      } else {
        amountTypeRow.classList.add("hidden");
        amountType.disabled = true;
        amountType.innerHTML = config.fixedType ? `<option value="${config.fixedType}">${config.fixedType}</option>` : "";
        if (config.fixedType) amountType.value = config.fixedType;
      }

      amountRow.classList.toggle("hidden", !config.requiresAmount);
      amountInput.disabled = !config.requiresAmount;
      amountLabel.textContent = config.amountLabel;
      amountInput.min = String(config.amountMin);
      amountInput.step = config.amountStep;

      applyWindowRow.classList.toggle("hidden", !config.requiresApplyWindow);
      document.getElementById("pricing-moderate-applies-from").disabled = !config.requiresApplyWindow;
      document.getElementById("pricing-moderate-duration-days").disabled = !config.requiresApplyWindow;
      offsetInput.disabled = !config.requiresApplyWindow;
      if (!config.requiresApplyWindow) setControlErrorState(offsetInput, null);
    }

    function resetSimplePricingForm() {
      document.getElementById("pricing-simple-form").reset();
      document.getElementById("pricing-simple-rule-uuid").value = "";
      document.getElementById("pricing-simple-edit-state").textContent = "Creating a new pricing rule.";
      document.getElementById("pricing-simple-target-scope").value = "property_platform";
      document.getElementById("pricing-simple-priority").value = "50";
      document.getElementById("pricing-simple-duration-days").value = "1";
      document.getElementById("pricing-simple-offset-days").value = "0";
      document.getElementById("pricing-simple-status").value = "active";
      document.getElementById("pricing-simple-applies-from").value = "departure";
      document.getElementById("pricing-simple-operation").value = "increase";
      syncSimpleOperationFields();
      document.getElementById("pricing-simple-amount").value = "";
      setSimpleCategories([]);
      resetPricingStayLengthFields("pricing-simple");
      document.getElementById("pricing-simple-start-date").value = "";
      document.getElementById("pricing-simple-end-date").value = "";
      setSimpleDateScope("range");
      setSimpleExactDates([]);
      syncPricingTargetScope("pricing-simple").catch((error) => setStatus(error.message, true));
    }

    function resetModeratePricingForm() {
      document.getElementById("pricing-moderate-form").reset();
      document.getElementById("pricing-moderate-rule-uuid").value = "";
      document.getElementById("pricing-moderate-edit-state").textContent = "Creating a new pricing rule.";
      document.getElementById("pricing-moderate-target-scope").value = "property_platform";
      document.getElementById("pricing-moderate-priority").value = "50";
      document.getElementById("pricing-moderate-status").value = "active";
      document.getElementById("pricing-moderate-applies-from").value = "departure";
      document.getElementById("pricing-moderate-duration-days").value = "1";
      document.getElementById("pricing-moderate-offset-days").value = "0";
      setModerateTargetRateType("base");
      document.getElementById("pricing-moderate-operation").value = "increase";
      syncModerateOperationFields();
      document.getElementById("pricing-moderate-amount").value = "";
      setModerateBookingClassOperator("any_of");
      setModerateCategories([], {});
      resetModerateStayAdjustmentFields();
      document.getElementById("pricing-moderate-start-date").value = "";
      document.getElementById("pricing-moderate-end-date").value = "";
      setModerateDateScope("range");
      setModerateExactDates([]);
      setModerateDayOfWeekPattern(0);
      setModerateSeasonWindow(null);
      syncPricingTargetScope("pricing-moderate").catch((error) => setStatus(error.message, true));
    }

    function resetAdvancedPricingForm() {
      document.getElementById("pricing-form-advanced").reset();
      document.getElementById("pricing-rule-uuid").value = "";
      document.getElementById("pricing-advanced-edit-state").textContent = "Create a new rule or click a row to load one for editing.";
    }

    function resetPricingEditor() {
      markPricingSelection(null);
      resetSimplePricingForm();
      resetModeratePricingForm();
      resetAdvancedPricingForm();
    }

    function getSimpleCompatibility(rule) {
      if (!rule || typeof rule !== "object") return { compatible: false, reason: "Rule data is missing." };
      if (!getPricingTargetModeFromRule(rule)) {
        return { compatible: false, reason: "This rule uses a target scope Simple mode cannot rebuild." };
      }
      if (!SIMPLE_PRICING_SUPPORTED_OPERATIONS.has(rule.operation_code)) {
        return { compatible: false, reason: "This action is only supported in Advanced mode." };
      }
      if (rule.day_of_week_pattern !== null && rule.day_of_week_pattern !== undefined) {
        return { compatible: false, reason: "Day-of-week rules are Advanced-only." };
      }
      if (rule.requires_approval) {
        return { compatible: false, reason: "Approval-required rules are Advanced-only." };
      }
      if (rule.allow_override === false) {
        return { compatible: false, reason: "allow_override = false is Advanced-only." };
      }

      const ruleConfig = rule.rule_config;
      if (!ruleConfig || typeof ruleConfig !== "object" || Array.isArray(ruleConfig)) {
        return { compatible: false, reason: "rule_config must be an object." };
      }
      const hasConditionTree = ruleConfig.condition_tree !== null && ruleConfig.condition_tree !== undefined;
      const allowedRootKeys = hasConditionTree
        ? new Set(["subject", "operation", "apply_window", "conditions_version", "condition_tree"])
        : new Set([
          "subject",
          "operation",
          "apply_window",
          "conditions",
          "stay_length",
          "stay_extended",
          "stay_contracted",
          "net_stay",
        ]);
      if (Object.keys(ruleConfig).some((key) => !allowedRootKeys.has(key))) {
        return { compatible: false, reason: "This rule contains extra JSON branches." };
      }
      if (ruleConfig.subject !== "price") {
        return { compatible: false, reason: "Simple mode only supports price rules." };
      }

      const operation = ruleConfig.operation;
      if (!operation || typeof operation !== "object" || Array.isArray(operation)) {
        return { compatible: false, reason: "The operation block is missing." };
      }
      if (Object.keys(operation).some((key) => !["type", "amount"].includes(key))) {
        return { compatible: false, reason: "This rule uses advanced operation settings." };
      }
      if (!Number.isFinite(Number(operation.amount))) {
        return { compatible: false, reason: "The operation amount is invalid." };
      }
      if ((rule.operation_code === "increase" || rule.operation_code === "decrease") && !["percentage", "flat"].includes(operation.type)) {
        return { compatible: false, reason: "Increase/decrease rules must use percentage or flat type." };
      }
      if (rule.operation_code === "set" && operation.type !== "fixed") {
        return { compatible: false, reason: "Set rules must use type = fixed." };
      }
      if (rule.operation_code === "multiplier" && operation.type !== "multiplier") {
        return { compatible: false, reason: "Multiplier rules must use type = multiplier." };
      }

      const applyWindow = ruleConfig.apply_window;
      if (!applyWindow || typeof applyWindow !== "object" || Array.isArray(applyWindow)) {
        return { compatible: false, reason: "The apply window is missing." };
      }
      if (Object.keys(applyWindow).some((key) => !["applies_from", "duration_days", "offset_days"].includes(key))) {
        return { compatible: false, reason: "This rule uses advanced apply-window settings." };
      }
      if (!["arrival", "departure"].includes(applyWindow.applies_from)) {
        return { compatible: false, reason: "Simple mode only supports arrival or departure." };
      }
      if (!Number.isInteger(Number(applyWindow.duration_days)) || Number(applyWindow.duration_days) < 1) {
        return { compatible: false, reason: "Duration days must be a positive whole number." };
      }
      if (applyWindow.offset_days !== null && applyWindow.offset_days !== undefined) {
        if (!Number.isInteger(Number(applyWindow.offset_days)) || Number(applyWindow.offset_days) < 0) {
          return { compatible: false, reason: "Offset days must be zero or a positive whole number." };
        }
      }

      const conditionCompatibility = getSimpleConditionCompatibility(ruleConfig, "Simple");
      if (!conditionCompatibility.compatible) return conditionCompatibility;

      const hasExactDates = Array.isArray(rule.applicable_dates) && rule.applicable_dates.length > 0;
      const hasRange = Boolean(rule.start_date && rule.end_date);
      if (hasExactDates === hasRange) {
        return { compatible: false, reason: "Simple mode supports either exact dates or a date range, not both." };
      }

      return { compatible: true, reason: "" };
    }

    function getModerateCompatibility(rule) {
      if (!rule || typeof rule !== "object") return { compatible: false, reason: "Rule data is missing." };
      if (!getPricingTargetModeFromRule(rule)) {
        return { compatible: false, reason: "This rule uses a target scope Moderate mode cannot rebuild." };
      }
      if (!MODERATE_PRICING_SUPPORTED_OPERATIONS.has(rule.operation_code)) {
        return { compatible: false, reason: "This action is only supported in Advanced mode." };
      }
      if (rule.requires_approval) {
        return { compatible: false, reason: "Approval-required rules are Advanced-only." };
      }
      if (rule.allow_override === false) {
        return { compatible: false, reason: "allow_override = false is Advanced-only." };
      }

      const config = getModerateOperationConfig(rule.operation_code);
      const ruleConfig = rule.rule_config;
      if (!ruleConfig || typeof ruleConfig !== "object" || Array.isArray(ruleConfig)) {
        return { compatible: false, reason: "rule_config must be an object." };
      }
      if (ruleConfig.subject !== config.subject) {
        return { compatible: false, reason: `Moderate mode expects subject = ${config.subject} for this action.` };
      }

      const operation = ruleConfig.operation;
      if (!operation || typeof operation !== "object" || Array.isArray(operation)) {
        return { compatible: false, reason: "The operation block is missing." };
      }
      const allowedOperationKeys = new Set(config.requiresAmount ? ["type", "amount", "target_rate_type"] : ["type", "target_rate_type"]);
      if (Object.keys(operation).some((key) => !allowedOperationKeys.has(key))) {
        return { compatible: false, reason: "This rule uses advanced operation settings." };
      }
      if (
        operation.target_rate_type !== null &&
        operation.target_rate_type !== undefined &&
        !PRICING_TARGET_RATE_TYPES.has(String(operation.target_rate_type).toLowerCase())
      ) {
        return { compatible: false, reason: "This rule uses an unsupported target rate type." };
      }
      if (config.amountTypeOptions) {
        if (!config.amountTypeOptions.includes(operation.type)) {
          return { compatible: false, reason: "This rule uses an unsupported value type." };
        }
      } else if (operation.type !== config.fixedType) {
        return { compatible: false, reason: `This action must use type = ${config.fixedType}.` };
      }
      if (config.requiresAmount) {
        const amount = Number(operation.amount);
        if (!Number.isFinite(amount)) {
          return { compatible: false, reason: "The operation amount is invalid." };
        }
        if (config.amountMode === "integer" && (!Number.isInteger(amount) || amount < config.amountMin)) {
          return { compatible: false, reason: "This action requires a positive whole-number amount." };
        }
        if (config.amountMode !== "integer") {
          const allowEqualMin = config.allowEqualMin !== false;
          if ((allowEqualMin && amount < config.amountMin) || (!allowEqualMin && amount <= config.amountMin)) {
            return { compatible: false, reason: "The operation amount is out of range." };
          }
        }
      } else if (Object.prototype.hasOwnProperty.call(operation, "amount")) {
        return { compatible: false, reason: "This action should not include an amount." };
      }

      const applyWindow = ruleConfig.apply_window;
      if (config.requiresApplyWindow) {
        if (!applyWindow || typeof applyWindow !== "object" || Array.isArray(applyWindow)) {
          return { compatible: false, reason: "The apply window is missing." };
        }
        if (Object.keys(applyWindow).some((key) => !["applies_from", "duration_days", "offset_days"].includes(key))) {
          return { compatible: false, reason: "This rule uses advanced apply-window settings." };
        }
        if (!["arrival", "departure"].includes(applyWindow.applies_from)) {
          return { compatible: false, reason: "Moderate mode only supports arrival or departure anchors." };
        }
        if (!Number.isInteger(Number(applyWindow.duration_days)) || Number(applyWindow.duration_days) < 1) {
          return { compatible: false, reason: "Duration days must be a positive whole number." };
        }
        if (applyWindow.offset_days !== null && applyWindow.offset_days !== undefined) {
          if (!Number.isInteger(Number(applyWindow.offset_days)) || Number(applyWindow.offset_days) < 0) {
            return { compatible: false, reason: "Offset days must be zero or a positive whole number." };
          }
        }
      } else if (applyWindow !== null && applyWindow !== undefined) {
        return { compatible: false, reason: "This action uses an apply window that Moderate mode does not manage." };
      }

      const seasonWindow = ruleConfig.season_window;
      if (seasonWindow !== null && seasonWindow !== undefined) {
        if (!seasonWindow || typeof seasonWindow !== "object" || Array.isArray(seasonWindow)) {
          return { compatible: false, reason: "season_window must be an object." };
        }
        if (Object.keys(seasonWindow).some((key) => !["start_mmdd", "end_mmdd", "applies_to"].includes(key))) {
          return { compatible: false, reason: "This season window uses fields Moderate mode cannot rebuild." };
        }
        if (validateMonthDay(seasonWindow.start_mmdd) || validateMonthDay(seasonWindow.end_mmdd)) {
          return { compatible: false, reason: "season_window must use valid MM-DD values." };
        }
        const appliesTo = seasonWindow.applies_to || "target_date";
        if (!PRICING_SEASON_APPLIES_TO_VALUES.has(appliesTo)) {
          return { compatible: false, reason: "season_window.applies_to is unsupported." };
        }
      }

      const moderateConditionState = parseModerateRuleConditionState(ruleConfig);
      if (!moderateConditionState.compatible) return moderateConditionState;

      const hasExactDates = Array.isArray(rule.applicable_dates) && rule.applicable_dates.length > 0;
      const hasRange = Boolean(rule.start_date && rule.end_date);
      const hasDayOfWeek = rule.day_of_week_pattern !== null && rule.day_of_week_pattern !== undefined;
      const activeScopeCount = [hasExactDates, hasRange, hasDayOfWeek].filter(Boolean).length;
      if (activeScopeCount !== 1) {
        return { compatible: false, reason: "Moderate mode supports exactly one base scope: exact dates, a date range, or days of week. Season window is an optional filter." };
      }
      if (hasDayOfWeek && (!Number.isInteger(Number(rule.day_of_week_pattern)) || Number(rule.day_of_week_pattern) < 1 || Number(rule.day_of_week_pattern) > 127)) {
        return { compatible: false, reason: "day_of_week_pattern must be an integer from 1 to 127." };
      }

      return { compatible: true, reason: "" };
    }

    function populateAdvancedPricingForm(rule) {
      const form = document.getElementById("pricing-form-advanced");
      form.elements.namedItem("rule_uuid").value = rule.rule_uuid || "";
      form.elements.namedItem("operation_code").value = rule.operation_code || "";
      form.elements.namedItem("property_id").value = rule.property_id ?? "";
      form.elements.namedItem("platform_id").value = rule.platform_id ?? "";
      form.elements.namedItem("platform_property_lookup_id").value = rule.platform_property_lookup_id ?? "";
      form.elements.namedItem("priority").value = rule.priority ?? "";
      form.elements.namedItem("status").value = rule.status || "";
      form.elements.namedItem("rule_config").value = rule.rule_config ? JSON.stringify(rule.rule_config, null, 2) : "";
      form.elements.namedItem("applicable_dates").value = Array.isArray(rule.applicable_dates) ? JSON.stringify(rule.applicable_dates, null, 2) : "";
      form.elements.namedItem("start_date").value = normalizeDateValue(rule.start_date);
      form.elements.namedItem("end_date").value = normalizeDateValue(rule.end_date);
      form.elements.namedItem("day_of_week_pattern").value = rule.day_of_week_pattern ?? "";
      document.getElementById("pricing-advanced-edit-state").textContent = rule.rule_uuid
        ? `Editing rule ${rule.rule_uuid}.`
        : "Create a new rule or click a row to load one for editing.";
    }

    async function populateSimplePricingForm(rule) {
      const compatibility = getSimpleCompatibility(rule);
      if (!compatibility.compatible) return compatibility;
      const conditionState = getSimpleConditionCompatibility(rule.rule_config, "Simple");
      const targetMode = getPricingTargetModeFromRule(rule) || "property_platform";

      document.getElementById("pricing-simple-rule-uuid").value = rule.rule_uuid || "";
      document.getElementById("pricing-simple-edit-state").textContent = rule.rule_uuid
        ? `Editing compatible rule ${rule.rule_uuid}.`
        : "Creating a new pricing rule.";
      document.getElementById("pricing-simple-target-scope").value = targetMode;
      document.getElementById("pricing-simple-property").value = String(rule.property_id ?? rule.lookup_property_id ?? "");
      document.getElementById("pricing-simple-platform").value = String(
        targetMode === "listing" ? (rule.lookup_platform_id ?? "") : (rule.platform_id ?? "")
      );
      await syncPricingTargetScope("pricing-simple", { selectedLookupId: rule.platform_property_lookup_id });
      document.getElementById("pricing-simple-operation").value = rule.operation_code;
      syncSimpleOperationFields();
      document.getElementById("pricing-simple-listing").value = rule.platform_property_lookup_id ? String(rule.platform_property_lookup_id) : "";
      document.getElementById("pricing-simple-amount-type").value = rule.rule_config.operation.type;
      document.getElementById("pricing-simple-amount").value = String(rule.rule_config.operation.amount ?? "");
      document.getElementById("pricing-simple-duration-days").value = String(rule.rule_config.apply_window.duration_days ?? 1);
      document.getElementById("pricing-simple-offset-days").value = String(rule.rule_config.apply_window.offset_days ?? 0);
      document.getElementById("pricing-simple-applies-from").value = rule.rule_config.apply_window.applies_from;
      document.getElementById("pricing-simple-status").value = rule.status || "active";
      document.getElementById("pricing-simple-priority").value = String(rule.priority ?? 50);
      setSimpleCategories(conditionState.classes || []);
      setPricingStayLengthFields("pricing-simple", conditionState.stayLength);

      if (Array.isArray(rule.applicable_dates) && rule.applicable_dates.length) {
        setSimpleDateScope("exact");
        setSimpleExactDates(rule.applicable_dates);
        document.getElementById("pricing-simple-start-date").value = "";
        document.getElementById("pricing-simple-end-date").value = "";
      } else {
        setSimpleDateScope("range");
        document.getElementById("pricing-simple-start-date").value = normalizeDateValue(rule.start_date);
        document.getElementById("pricing-simple-end-date").value = normalizeDateValue(rule.end_date);
        setSimpleExactDates([]);
      }

      return compatibility;
    }

    async function populateModeratePricingForm(rule) {
      const compatibility = getModerateCompatibility(rule);
      if (!compatibility.compatible) return compatibility;
      const moderateConditionState = parseModerateRuleConditionState(rule.rule_config);
      if (!moderateConditionState.compatible) return moderateConditionState;
      const classState = moderateConditionState.state.classState;
      const stayState = moderateConditionState.state.stayState;

      const config = getModerateOperationConfig(rule.operation_code);
      const targetMode = getPricingTargetModeFromRule(rule) || "property_platform";
      document.getElementById("pricing-moderate-rule-uuid").value = rule.rule_uuid || "";
      document.getElementById("pricing-moderate-edit-state").textContent = rule.rule_uuid
        ? `Editing compatible rule ${rule.rule_uuid}.`
        : "Creating a new pricing rule.";
      document.getElementById("pricing-moderate-target-scope").value = targetMode;
      document.getElementById("pricing-moderate-property").value = String(rule.property_id ?? rule.lookup_property_id ?? "");
      document.getElementById("pricing-moderate-platform").value = String(
        targetMode === "listing" ? (rule.lookup_platform_id ?? "") : (rule.platform_id ?? "")
      );
      await syncPricingTargetScope("pricing-moderate", { selectedLookupId: rule.platform_property_lookup_id });
      document.getElementById("pricing-moderate-operation").value = rule.operation_code;
      syncModerateOperationFields();
      document.getElementById("pricing-moderate-listing").value = rule.platform_property_lookup_id ? String(rule.platform_property_lookup_id) : "";
      document.getElementById("pricing-moderate-status").value = rule.status || "active";
      document.getElementById("pricing-moderate-priority").value = String(rule.priority ?? 50);
      setModerateBookingClassOperator(classState.operator);
      setModerateCategories(classState.classes || [], buildModerateClassPositionMap(classState));
      setModerateStayAdjustmentFields(stayState || null);
      setModerateTargetRateType(String(rule.rule_config.operation.target_rate_type || "base").toLowerCase());

      document.getElementById("pricing-moderate-amount-type").value = rule.rule_config.operation.type || "";
      document.getElementById("pricing-moderate-amount").value = config.requiresAmount
        ? String(rule.rule_config.operation.amount ?? "")
        : "";

      if (config.requiresApplyWindow) {
        document.getElementById("pricing-moderate-applies-from").value = rule.rule_config.apply_window.applies_from;
        document.getElementById("pricing-moderate-duration-days").value = String(rule.rule_config.apply_window.duration_days ?? 1);
        document.getElementById("pricing-moderate-offset-days").value = String(rule.rule_config.apply_window.offset_days ?? 0);
      } else {
        document.getElementById("pricing-moderate-applies-from").value = "departure";
        document.getElementById("pricing-moderate-duration-days").value = "1";
        document.getElementById("pricing-moderate-offset-days").value = "0";
      }

      if (Array.isArray(rule.applicable_dates) && rule.applicable_dates.length) {
        setModerateDateScope("exact");
        setModerateExactDates(rule.applicable_dates);
        document.getElementById("pricing-moderate-start-date").value = "";
        document.getElementById("pricing-moderate-end-date").value = "";
        setModerateDayOfWeekPattern(0);
      } else if (rule.day_of_week_pattern !== null && rule.day_of_week_pattern !== undefined) {
        setModerateDateScope("dow");
        setModerateDayOfWeekPattern(rule.day_of_week_pattern);
        document.getElementById("pricing-moderate-start-date").value = "";
        document.getElementById("pricing-moderate-end-date").value = "";
        setModerateExactDates([]);
      } else {
        setModerateDateScope("range");
        document.getElementById("pricing-moderate-start-date").value = normalizeDateValue(rule.start_date);
        document.getElementById("pricing-moderate-end-date").value = normalizeDateValue(rule.end_date);
        setModerateExactDates([]);
        setModerateDayOfWeekPattern(0);
      }
      setModerateSeasonWindow(rule.rule_config.season_window || null);

      return compatibility;
    }

    async function editPricingRule(ruleUuid) {
      try {
        const rule = await requestJSON(`/pwsadmin/api/pricing/rules/${ruleUuid}`);
        markPricingSelection(rule.rule_uuid);
        if (getPricingMode() === "simple") {
          const compatibility = await populateSimplePricingForm(rule);
          if (compatibility.compatible) {
            setStatus(`Loaded pricing rule ${rule.rule_uuid} in Simple mode.`, false);
            return;
          }
          const moderateCompatibility = await populateModeratePricingForm(rule);
          if (moderateCompatibility.compatible) {
            setPricingMode("moderate");
            setStatus("Switched to Moderate mode: this rule uses fields that Simple mode does not expose.", false);
            return;
          }
          setPricingMode("advanced");
          populateAdvancedPricingForm(rule);
          setStatus(`Switched to Advanced mode: ${compatibility.reason}`, false);
          return;
        }
        if (getPricingMode() === "moderate") {
          const compatibility = await populateModeratePricingForm(rule);
          if (compatibility.compatible) {
            setStatus(`Loaded pricing rule ${rule.rule_uuid} in Moderate mode.`, false);
            return;
          }
          setPricingMode("advanced");
          populateAdvancedPricingForm(rule);
          setStatus(`Switched to Advanced mode: ${compatibility.reason}`, false);
          return;
        }
        populateAdvancedPricingForm(rule);
        setStatus(`Loaded pricing rule ${rule.rule_uuid} in Advanced mode.`, false);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    function buildAdvancedPricingPayload(formData) {
      const payload = {
        operation_code: formData.get("operation_code"),
        property_id: formData.get("property_id") ? Number(formData.get("property_id")) : null,
        platform_id: formData.get("platform_id") ? Number(formData.get("platform_id")) : null,
        platform_property_lookup_id: formData.get("platform_property_lookup_id") ? Number(formData.get("platform_property_lookup_id")) : null,
        priority: formData.get("priority") ? Number(formData.get("priority")) : null,
        status: formData.get("status") || null,
      };
      payload.rule_config = formData.get("rule_config") ? JSON.parse(formData.get("rule_config")) : {};
      payload.applicable_dates = formData.get("applicable_dates") ? JSON.parse(formData.get("applicable_dates")) : null;
      payload.start_date = formData.get("start_date") || null;
      payload.end_date = formData.get("end_date") || null;
      payload.day_of_week_pattern = formData.get("day_of_week_pattern") ? Number(formData.get("day_of_week_pattern")) : null;
      return payload;
    }

    function validateSimplePricingForm() {
      const targetScopeEl = document.getElementById("pricing-simple-target-scope");
      const propertyEl = document.getElementById("pricing-simple-property");
      const platformEl = document.getElementById("pricing-simple-platform");
      const listingEl = document.getElementById("pricing-simple-listing");
      const operationEl = document.getElementById("pricing-simple-operation");
      const amountTypeEl = document.getElementById("pricing-simple-amount-type");
      const amountEl = document.getElementById("pricing-simple-amount");
      const durationEl = document.getElementById("pricing-simple-duration-days");
      const offsetEl = document.getElementById("pricing-simple-offset-days");
      const appliesFromEl = document.getElementById("pricing-simple-applies-from");
      const statusFieldEl = document.getElementById("pricing-simple-status");
      const priorityEl = document.getElementById("pricing-simple-priority");
      const targetMode = getPricingTargetMode("pricing-simple");

      if (!validateControls([
        targetScopeEl,
        operationEl,
        amountTypeEl,
        durationEl,
        offsetEl,
        appliesFromEl,
        statusFieldEl,
        priorityEl,
      ])) {
        return false;
      }

      if (targetMode === "property_platform" && !validateControls([propertyEl, platformEl])) return false;
      if (targetMode === "property" && !validateControls([propertyEl])) return false;
      if (targetMode === "platform" && !validateControls([platformEl])) return false;
      if (targetMode === "listing" && !validateControls([platformEl, listingEl])) return false;

      const amountValue = amountEl.value.trim();
      let amountError = null;
      if (!amountValue) {
        amountError = "This field is required";
      } else if (operationEl.value === "multiplier") {
        amountError = validateNumericMinimum(amountValue, 0, false);
      } else {
        amountError = validateNumericMinimum(amountValue, 0);
      }
      setControlErrorState(amountEl, amountError);
      if (amountError) {
        setStatus(`pricing-simple-amount: ${amountError}`, true);
        amountEl.focus();
        return false;
      }

      if (!getSimpleCategories().length) {
        setStatus("Select at least one trigger category.", true);
        return false;
      }
      if (!validatePricingStayLengthControls("pricing-simple")) return false;

      if (getSimpleDateScope() === "range") {
        const startEl = document.getElementById("pricing-simple-start-date");
        const endEl = document.getElementById("pricing-simple-end-date");
        if (!validateControls([startEl, endEl], { required: true })) return false;
        if (startEl.value > endEl.value) {
          setStatus("Start date must be on or before end date.", true);
          endEl.focus();
          return false;
        }
      } else {
        const exactInputs = Array.from(document.querySelectorAll(".pricing-simple-exact-date"));
        const filledValues = [];
        for (const input of exactInputs) {
          const value = input.value.trim();
          if (!value) continue;
          const error = validateIsoDate(value);
          setControlErrorState(input, error);
          if (error) {
            setStatus(`exact date: ${error}`, true);
            input.focus();
            return false;
          }
          filledValues.push(value);
        }
        if (!filledValues.length) {
          setStatus("Add at least one exact date.", true);
          exactInputs[0]?.focus();
          return false;
        }
      }

      return true;
    }

    function buildSimplePricingPayload() {
      const operationCode = document.getElementById("pricing-simple-operation").value;
      const amountType = document.getElementById("pricing-simple-amount-type").value;
      const exactDates = Array.from(new Set(getSimpleExactDates())).sort();
      const targetPayload = buildPricingTargetPayload("pricing-simple");
      const payload = {
        operation_code: operationCode,
        property_id: targetPayload.property_id,
        platform_id: targetPayload.platform_id,
        platform_property_lookup_id: targetPayload.platform_property_lookup_id,
        priority: Number(document.getElementById("pricing-simple-priority").value),
        status: document.getElementById("pricing-simple-status").value,
        rule_config: {
          subject: "price",
          operation: {
            type: amountType,
            amount: Number(document.getElementById("pricing-simple-amount").value),
          },
          apply_window: buildPricingApplyWindow("pricing-simple"),
          conditions_version: 2,
          condition_tree: buildSimpleConditionTree(getSimpleCategories()),
        },
        applicable_dates: null,
        start_date: null,
        end_date: null,
      };

      if (getSimpleDateScope() === "exact") {
        payload.applicable_dates = exactDates;
      } else {
        payload.start_date = document.getElementById("pricing-simple-start-date").value;
        payload.end_date = document.getElementById("pricing-simple-end-date").value;
      }

      return payload;
    }

    function validateModeratePricingForm() {
      const targetScopeEl = document.getElementById("pricing-moderate-target-scope");
      const propertyEl = document.getElementById("pricing-moderate-property");
      const platformEl = document.getElementById("pricing-moderate-platform");
      const listingEl = document.getElementById("pricing-moderate-listing");
      const operationEl = document.getElementById("pricing-moderate-operation");
      const statusFieldEl = document.getElementById("pricing-moderate-status");
      const priorityEl = document.getElementById("pricing-moderate-priority");
      const amountTypeEl = document.getElementById("pricing-moderate-amount-type");
      const targetRateTypeEl = document.getElementById("pricing-moderate-target-rate-type");
      const amountEl = document.getElementById("pricing-moderate-amount");
      const appliesFromEl = document.getElementById("pricing-moderate-applies-from");
      const durationEl = document.getElementById("pricing-moderate-duration-days");
      const offsetEl = document.getElementById("pricing-moderate-offset-days");
      const config = getModerateOperationConfig(operationEl.value);
      const targetMode = getPricingTargetMode("pricing-moderate");

      if (!validateControls([targetScopeEl, operationEl, targetRateTypeEl, statusFieldEl, priorityEl])) {
        return false;
      }

      if (targetMode === "property_platform" && !validateControls([propertyEl, platformEl])) return false;
      if (targetMode === "property" && !validateControls([propertyEl])) return false;
      if (targetMode === "platform" && !validateControls([platformEl])) return false;
      if (targetMode === "listing" && !validateControls([platformEl, listingEl])) return false;

      if (config.amountTypeOptions && !validateControls([amountTypeEl])) {
        return false;
      }

      if (config.requiresAmount) {
        const amountValue = amountEl.value.trim();
        let amountError = null;
        if (!amountValue) {
          amountError = "This field is required";
        } else if (config.amountMode === "integer") {
          amountError = validateIntegerRange(amountValue, config.amountMin);
        } else {
          amountError = validateNumericMinimum(amountValue, config.amountMin, config.allowEqualMin !== false);
        }
        setControlErrorState(amountEl, amountError);
        if (amountError) {
          setStatus(`pricing-moderate-amount: ${amountError}`, true);
          amountEl.focus();
          return false;
        }
      } else {
        setControlErrorState(amountEl, null);
      }

      if (config.requiresApplyWindow && !validateControls([appliesFromEl, durationEl, offsetEl])) {
        return false;
      }

      if (!validateModerateBookingClassInputs()) return false;
      if (!validateModerateStayAdjustmentFields()) return false;

      if (getModerateDateScope() === "range") {
        const startEl = document.getElementById("pricing-moderate-start-date");
        const endEl = document.getElementById("pricing-moderate-end-date");
        if (!validateControls([startEl, endEl], { required: true })) return false;
        if (startEl.value > endEl.value) {
          setStatus("Start date must be on or before end date.", true);
          endEl.focus();
          return false;
        }
      } else if (getModerateDateScope() === "exact") {
        const exactInputs = Array.from(document.querySelectorAll(".pricing-moderate-exact-date"));
        const filledValues = [];
        for (const input of exactInputs) {
          const value = input.value.trim();
          if (!value) continue;
          const error = validateIsoDate(value);
          setControlErrorState(input, error);
          if (error) {
            setStatus(`exact date: ${error}`, true);
            input.focus();
            return false;
          }
          filledValues.push(value);
        }
        if (!filledValues.length) {
          setStatus("Add at least one exact date.", true);
          exactInputs[0]?.focus();
          return false;
        }
      } else if (getModerateDateScope() === "dow" && !getModerateDayOfWeekPattern()) {
        setStatus("Select at least one day of week.", true);
        return false;
      }

      if (isModerateSeasonWindowEnabled()) {
        const seasonStartEl = document.getElementById("pricing-moderate-season-start-mmdd");
        const seasonEndEl = document.getElementById("pricing-moderate-season-end-mmdd");
        const seasonAppliesToEl = document.getElementById("pricing-moderate-season-applies-to");
        if (!validateControls([seasonStartEl, seasonEndEl, seasonAppliesToEl], { required: true })) return false;
        const startError = validateMonthDay(seasonStartEl.value.trim());
        setControlErrorState(seasonStartEl, startError);
        if (startError) {
          setStatus(`season start: ${startError}`, true);
          seasonStartEl.focus();
          return false;
        }
        const endError = validateMonthDay(seasonEndEl.value.trim());
        setControlErrorState(seasonEndEl, endError);
        if (endError) {
          setStatus(`season end: ${endError}`, true);
          seasonEndEl.focus();
          return false;
        }
      }

      return true;
    }

    function buildModeratePricingPayload() {
      const operationCode = document.getElementById("pricing-moderate-operation").value;
      const config = getModerateOperationConfig(operationCode);
      const targetPayload = buildPricingTargetPayload("pricing-moderate");
      const operationPayload = {
        type: config.amountTypeOptions
          ? document.getElementById("pricing-moderate-amount-type").value
          : config.fixedType,
        target_rate_type: getModerateTargetRateType(),
      };
      if (config.requiresAmount) {
        operationPayload.amount = Number(document.getElementById("pricing-moderate-amount").value);
      }

      const payload = {
        operation_code: operationCode,
        property_id: targetPayload.property_id,
        platform_id: targetPayload.platform_id,
        platform_property_lookup_id: targetPayload.platform_property_lookup_id,
        priority: Number(document.getElementById("pricing-moderate-priority").value),
        status: document.getElementById("pricing-moderate-status").value,
        rule_config: {
          subject: config.subject,
          operation: operationPayload,
          conditions_version: 2,
          condition_tree: null,
        },
        applicable_dates: null,
        start_date: null,
        end_date: null,
        day_of_week_pattern: null,
      };

      const classState = getModerateClassSelectionState();
      const conditionNodes = [];
      if (classState.classes.length) {
        conditionNodes.push({
          type: "condition",
          condition_name: "booking_class",
          comparison_operator: getModerateBookingClassOperator(),
          value: classState.classes,
          pos: classState.positions,
        });
      }
      conditionNodes.push(...buildModerateStayConditionNodes());
      if (conditionNodes.length === 1) {
        payload.rule_config.condition_tree = conditionNodes[0];
      } else if (conditionNodes.length > 1) {
        payload.rule_config.condition_tree = {
          type: "group",
          evaluation_operator: "and",
          members: conditionNodes,
        };
      }

      if (config.requiresApplyWindow) {
        payload.rule_config.apply_window = buildPricingApplyWindow("pricing-moderate");
      }

      if (getModerateDateScope() === "exact") {
        payload.applicable_dates = Array.from(new Set(getModerateExactDates())).sort();
      } else if (getModerateDateScope() === "dow") {
        payload.day_of_week_pattern = getModerateDayOfWeekPattern();
      } else {
        payload.start_date = document.getElementById("pricing-moderate-start-date").value;
        payload.end_date = document.getElementById("pricing-moderate-end-date").value;
      }
      if (isModerateSeasonWindowEnabled()) {
        payload.rule_config.season_window = getModerateSeasonWindow();
      }

      return payload;
    }

    async function submitPricingPayload(payload, ruleUuid) {
      if (ruleUuid) {
        await requestJSON(`/pwsadmin/api/pricing/rules/${ruleUuid}`, { method: "PATCH", body: JSON.stringify(payload) });
      } else {
        await requestJSON("/pwsadmin/api/pricing/rules", { method: "POST", body: JSON.stringify(payload) });
      }
    }

    function normalizeTaskPayloadValue(value) {
      if (isObjectLike(value) || Array.isArray(value)) return value;
      if (typeof value === "string" && value.trim()) {
        try {
          return JSON.parse(value);
        } catch {
          return value;
        }
      }
      return value ?? null;
    }

    function formatTaskPayloadYmf(value) {
      return renderYmf(normalizeTaskPayloadValue(value));
    }

    function buildTaskPayloadExcerpt(value, maxLength = 110) {
      const text = String(value ?? "").replace(/\s+/g, " ").trim();
      if (!text) return "-";
      if (text.length <= maxLength) return text;
      return `${text.slice(0, maxLength - 3)}...`;
    }

    function closeTaskPayloadModal() {
      document.getElementById("task-payload-modal").classList.add("hidden");
      document.getElementById("task-payload-modal").classList.remove("flex");
      document.getElementById("task-payload-title").textContent = "Task Payload";
      document.getElementById("task-payload-body").textContent = "Select a task payload to view details.";
    }

    async function getTaskDetail(taskId) {
      const normalizedTaskId = Number.parseInt(String(taskId ?? ""), 10);
      if (!Number.isInteger(normalizedTaskId)) {
        throw new Error("Task details are unavailable for this row.");
      }
      if (taskDetailCache.has(normalizedTaskId)) {
        return taskDetailCache.get(normalizedTaskId);
      }
      const details = await requestJSON(`/pwsadmin/api/tasks/${normalizedTaskId}`);
      taskDetailCache.set(normalizedTaskId, details || {});
      return details || {};
    }

    async function openTaskPayloadModal(taskId, payloadKey, payloadLabel) {
      const modal = document.getElementById("task-payload-modal");
      const titleEl = document.getElementById("task-payload-title");
      const bodyEl = document.getElementById("task-payload-body");
      titleEl.textContent = `${payloadLabel} for Task #${taskId}`;
      bodyEl.textContent = "Loading...";
      modal.classList.remove("hidden");
      modal.classList.add("flex");
      try {
        const details = await getTaskDetail(taskId);
        bodyEl.textContent = formatTaskPayloadYmf(details?.[payloadKey]);
      } catch (error) {
        bodyEl.textContent = `Unable to load ${payloadLabel.toLowerCase()}.`;
        setStatus(error.message || `Failed to load ${payloadLabel.toLowerCase()}.`, true);
      }
    }

    function buildTaskPayloadButton(taskId, payloadKey, payloadLabel, excerpt) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "secondary-btn max-w-[320px] overflow-hidden text-ellipsis whitespace-nowrap rounded border px-2 py-1 text-left text-xs";
      button.title = `View full ${payloadLabel.toLowerCase()} in YML`;
      button.textContent = buildTaskPayloadExcerpt(excerpt);
      button.addEventListener("click", () => {
        openTaskPayloadModal(taskId, payloadKey, payloadLabel);
      });
      return button;
    }

    function setTaskEnqueueStatus(message, err = false) {
      const statusEl = document.getElementById("task-enqueue-status");
      statusEl.textContent = message || "";
      statusEl.className = err
        ? "mt-3 min-h-5 text-sm text-rose-600 dark:text-rose-300"
        : "mt-3 min-h-5 text-sm text-slate-600 dark:text-slate-300";
    }

    function isTaskEnqueueAdmin() {
      return Boolean(currentUserProfile?.is_admin);
    }

    function updateTaskEnqueueFormState() {
      const form = document.getElementById("task-enqueue-form");
      const disabled = !isTaskEnqueueAdmin();
      Array.from(form.elements).forEach((element) => {
        element.disabled = disabled;
      });
      if (disabled) {
        setTaskEnqueueStatus("Read-only: admin access is required to enqueue tasks.", true);
      } else if (!document.getElementById("task-enqueue-status").textContent) {
        setTaskEnqueueStatus("Ready to enqueue a scheduled task.");
      }
    }

    function formatDateTimeLocalValue(date = new Date()) {
      const pad = (value) => String(value).padStart(2, "0");
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
    }

    function resetTaskEnqueueForm() {
      document.getElementById("task-enqueue-action").value = "";
      document.getElementById("task-enqueue-priority").value = "0";
      document.getElementById("task-enqueue-max-attempts").value = "3";
      document.getElementById("task-enqueue-scheduled-at").value = formatDateTimeLocalValue();
      document.getElementById("task-enqueue-payload").value = `{
  "limit": 25
}`;
      renderTaskEnqueueWorkers();
      setTaskEnqueueStatus(isTaskEnqueueAdmin() ? "Ready to enqueue a scheduled task." : "Read-only: admin access is required to enqueue tasks.", !isTaskEnqueueAdmin());
    }

    function getWorkerSubscribedQueues(worker) {
      const raw = worker?.subscribed_queues;
      if (Array.isArray(raw)) return raw.map((item) => String(item));
      if (typeof raw === "string") {
        try {
          const parsed = JSON.parse(raw);
          return Array.isArray(parsed) ? parsed.map((item) => String(item)) : [];
        } catch (_) {
          return [];
        }
      }
      return [];
    }

    function renderTaskEnqueueWorkers() {
      const queueName = document.getElementById("task-enqueue-queue").value;
      const workerSelect = document.getElementById("task-enqueue-worker");
      const previous = workerSelect.value;
      const workers = (taskEnqueueOptions.workers || []).filter((worker) => getWorkerSubscribedQueues(worker).includes(queueName));
      workerSelect.innerHTML = "";
      if (!workers.length) {
        const option = document.createElement("option");
        option.value = "";
        option.textContent = queueName ? "No subscribed workers" : "Select a queue first";
        workerSelect.appendChild(option);
        return;
      }
      workers.forEach((worker) => {
        const option = document.createElement("option");
        option.value = worker.worker_id;
        const load = `${worker.current_load ?? 0}/${worker.max_capacity ?? "-"}`;
        option.textContent = `${worker.worker_name || worker.worker_id} (${worker.worker_id}, ${worker.is_active ? "active" : "inactive"}, load ${load})`;
        workerSelect.appendChild(option);
      });
      if (previous && workers.some((worker) => worker.worker_id === previous)) {
        workerSelect.value = previous;
      }
    }

    function renderTaskEnqueueOptions() {
      const queueSelect = document.getElementById("task-enqueue-queue");
      const previousQueue = queueSelect.value;
      queueSelect.innerHTML = "";
      (taskEnqueueOptions.queues || []).forEach((queue) => {
        const option = document.createElement("option");
        option.value = queue.queue_name;
        option.textContent = `${queue.queue_name} (${queue.active_worker_count ?? 0} active workers)`;
        queueSelect.appendChild(option);
      });
      if (previousQueue && (taskEnqueueOptions.queues || []).some((queue) => queue.queue_name === previousQueue)) {
        queueSelect.value = previousQueue;
      }
      renderTaskEnqueueWorkers();
    }

    async function loadTaskEnqueueOptions() {
      try {
        taskEnqueueOptions = await requestJSON("/pwsadmin/api/tasks/enqueue-options");
        renderTaskEnqueueOptions();
        updateTaskEnqueueFormState();
      } catch (error) {
        setTaskEnqueueStatus(error.message, true);
      }
    }

    function buildTaskEnqueuePayload() {
      const queueEl = document.getElementById("task-enqueue-queue");
      const workerEl = document.getElementById("task-enqueue-worker");
      const actionEl = document.getElementById("task-enqueue-action");
      const scheduledEl = document.getElementById("task-enqueue-scheduled-at");
      const priorityEl = document.getElementById("task-enqueue-priority");
      const maxAttemptsEl = document.getElementById("task-enqueue-max-attempts");
      const payloadEl = document.getElementById("task-enqueue-payload");
      if (!validateControls([queueEl, workerEl, actionEl, priorityEl, maxAttemptsEl, payloadEl])) return null;
      const parsedPayload = JSON.parse(payloadEl.value);
      const scheduledValue = scheduledEl.value ? new Date(scheduledEl.value).toISOString() : null;
      return {
        queue_name: queueEl.value,
        worker_id: workerEl.value,
        action: actionEl.value.trim(),
        payload: parsedPayload,
        scheduled_at: scheduledValue,
        priority: Number.parseInt(priorityEl.value, 10),
        max_attempts: Number.parseInt(maxAttemptsEl.value, 10),
      };
    }

    async function submitTaskEnqueue(event) {
      event.preventDefault();
      if (!isTaskEnqueueAdmin()) {
        setTaskEnqueueStatus("Admin access is required to enqueue tasks.", true);
        return;
      }
      const payload = buildTaskEnqueuePayload();
      if (!payload) return;
      try {
        const result = await requestJSON("/pwsadmin/api/tasks/enqueue", {
          method: "POST",
          body: JSON.stringify(payload),
        });
        taskDetailCache.clear();
        await loadTasks(false);
        setTaskEnqueueStatus(`Enqueued task #${result.id} (${result.task_uuid}) with status ${result.status}.`);
      } catch (error) {
        setTaskEnqueueStatus(error.message, true);
      }
    }

    function appendTaskCell(tr, value, className = "") {
      const td = document.createElement("td");
      if (className) td.className = className;
      td.textContent = value === null || value === undefined || value === "" ? "-" : String(value);
      tr.appendChild(td);
    }

    async function loadTasks(next = false) {
      const statusEl = document.getElementById("task-status");
      const queueEl = document.getElementById("task-queue");
      const limitEl = document.getElementById("task-limit");
      if (!validateControls([statusEl, queueEl, limitEl])) return;
      const status = statusEl.value.trim();
      const queue = queueEl.value.trim();
      const limit = limitEl.value || 25;
      const cursor = next && taskCursor ? `&cursor=${taskCursor}` : "";
      const url = `/pwsadmin/api/tasks?limit=${limit}${status ? `&status=${status}` : ""}${queue ? `&queue=${queue}` : ""}${cursor}`;
      try {
        const res = await requestJSON(url);
        const tbody = document.getElementById("task-rows");
        tbody.innerHTML = "";
        (res.items || []).forEach((r) => {
          const tr = document.createElement("tr");
          appendTaskCell(tr, r.id);
          appendTaskCell(tr, r.task_name || "-");
          appendTaskCell(tr, r.status);
          appendTaskCell(tr, r.queue_name || "-");
          const taskDataCell = document.createElement("td");
          taskDataCell.appendChild(buildTaskPayloadButton(r.id, "task_data", "Task Data", r.task_data_excerpt));
          tr.appendChild(taskDataCell);
          const taskMetadataCell = document.createElement("td");
          taskMetadataCell.appendChild(buildTaskPayloadButton(r.id, "task_metadata", "Task Metadata", r.task_metadata_excerpt));
          tr.appendChild(taskMetadataCell);
          appendTaskCell(tr, r.priority ?? "-");
          appendTaskCell(tr, r.worker_id || "-");
          appendTaskCell(tr, r.updated_at || r.created_at, "font-mono text-xs");
          tbody.appendChild(tr);
        });
        taskCursor = res.next_cursor;
        setStatus(`Tasks: ${(res.items || []).length}`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    async function loadLogs(next = false) {
      const levelEl = document.getElementById("log-level");
      const sourceEl = document.getElementById("log-source");
      const workflowEl = document.getElementById("log-workflow");
      const limitEl = document.getElementById("log-limit");
      if (!validateControls([levelEl, sourceEl, workflowEl, limitEl])) return;
      const level = levelEl.value.trim();
      const source = sourceEl.value.trim();
      const wf = workflowEl.value.trim();
      const limit = limitEl.value || 50;
      const cursor = next && logCursor ? `&cursor=${logCursor}` : "";
      const url = `/pwsadmin/api/logs?limit=${limit}${level ? `&level=${level}` : ""}${source ? `&source=${source}` : ""}${wf ? `&workflow_name=${wf}` : ""}${cursor}`;
      try {
        const res = await requestJSON(url);
        const tbody = document.getElementById("log-rows");
        tbody.innerHTML = "";
        (res.items || []).forEach((r) => {
          const tr = document.createElement("tr");
          tr.innerHTML = `<td class="font-mono text-xs">${r.created_at}</td><td>${r.level}</td><td>${r.source || "-"}</td><td>${r.workflow_name || "-"}</td><td>${r.message || "-"}</td>`;
          tbody.appendChild(tr);
        });
        logCursor = res.next_cursor;
        setStatus(`Logs: ${(res.items || []).length}`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    function formatWorkerQueueList(value) {
      if (!Array.isArray(value) || !value.length) return "-";
      return value
        .map((item) => String(item || "").trim())
        .filter(Boolean)
        .join(", ");
    }

    function formatWorkerAvailabilityRatio(value) {
      const numeric = Number(value);
      if (!Number.isFinite(numeric)) return "-";
      return `${(numeric * 100).toFixed(1)}%`;
    }

    function formatWorkerLastSeen(value) {
      const numeric = Number(value);
      if (!Number.isFinite(numeric) || numeric < 0) return "-";
      if (numeric < 60) return `${Math.round(numeric)}s ago`;
      if (numeric < 3600) return `${Math.floor(numeric / 60)}m ago`;
      if (numeric < 86400) return `${Math.floor(numeric / 3600)}h ago`;
      return `${Math.floor(numeric / 86400)}d ago`;
    }

    function renderWorkerSummary(summary) {
      const summaryEl = document.getElementById("worker-summary");
      const cards = [
        { label: "Registered", value: summary.total_workers ?? 0 },
        { label: "Active", value: summary.active_workers ?? 0 },
        { label: "Busy", value: summary.busy_workers ?? 0 },
        { label: "Pending Tasks", value: summary.pending_tasks ?? 0 },
      ];
      summaryEl.innerHTML = cards.map((card) => `
        <div class="rounded-xl border border-slate-200 bg-slate-50/90 p-3 shadow-sm dark:border-slate-600 dark:bg-slate-900/70">
          <p class="text-xs uppercase tracking-wide text-slate-500 dark:text-slate-400">${escapeHtml(card.label)}</p>
          <p class="mt-1 text-2xl font-semibold text-slate-900 dark:text-slate-100">${escapeHtml(String(card.value))}</p>
        </div>
      `).join("");
    }

    function renderWorkerRows(items) {
      const tbody = document.getElementById("worker-rows");
      tbody.innerHTML = "";
      if (!items.length) {
        tbody.innerHTML = `<tr><td colspan="9" class="text-sm text-slate-500 dark:text-slate-300">No worker registrations found.</td></tr>`;
        return;
      }
      items.forEach((item) => {
        const tr = document.createElement("tr");
        const statusLabel = item.is_active ? "Active" : "Inactive";
        const statusClass = item.is_active
          ? "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-500/30 dark:bg-emerald-500/10 dark:text-emerald-200"
          : "border-slate-300 bg-slate-100 text-slate-600 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-300";
        tr.innerHTML = `
          <td>
            <div class="font-semibold text-slate-800 dark:text-slate-100">${escapeHtml(item.worker_name || "-")}</div>
            <div class="text-xs text-slate-500 dark:text-slate-400">${escapeHtml(item.worker_type || "worker")}</div>
          </td>
          <td class="font-mono text-xs">${escapeHtml(item.worker_id || "-")}</td>
          <td><span class="inline-flex rounded-full border px-2 py-0.5 text-xs font-semibold ${statusClass}">${escapeHtml(statusLabel)}</span></td>
          <td>${escapeHtml(String(item.current_load ?? 0))} / ${escapeHtml(String(item.max_capacity ?? "-"))}</td>
          <td>${escapeHtml(formatWorkerQueueList(item.subscribed_queues))}</td>
          <td>${escapeHtml(String(item.tasks_completed ?? 0))}</td>
          <td>${escapeHtml(String(item.tasks_failed ?? 0))}</td>
          <td>${escapeHtml(formatWorkerAvailabilityRatio(item.availability_ratio))}</td>
          <td>${escapeHtml(formatWorkerLastSeen(item.last_seen_seconds))}</td>
        `;
        tbody.appendChild(tr);
      });
    }

    function renderWorkerQueueRows(items) {
      const tbody = document.getElementById("worker-queue-rows");
      tbody.innerHTML = "";
      if (!items.length) {
        tbody.innerHTML = `<tr><td colspan="8" class="text-sm text-slate-500 dark:text-slate-300">No queue activity found.</td></tr>`;
        return;
      }
      items.forEach((item) => {
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td>${escapeHtml(item.queue_name || "-")}</td>
          <td>${escapeHtml(String(item.total_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.pending_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.processing_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.scheduled_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.retrying_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.completed_tasks ?? 0))}</td>
          <td>${escapeHtml(String(item.failed_tasks ?? 0))}</td>
        `;
        tbody.appendChild(tr);
      });
    }

    async function loadWorkers(next = false) {
      const activeOnly = document.getElementById("worker-active-only").checked;
      const limitEl = document.getElementById("worker-limit");
      if (!validateControls([limitEl])) return;
      const limit = limitEl.value || 25;
      if (!next) {
        workerCursor = null;
      } else if (!workerCursor) {
        return;
      }
      const params = [`limit=${encodeURIComponent(limit)}`];
      if (activeOnly) params.push("active_only=true");
      if (next && workerCursor) params.push(`cursor=${encodeURIComponent(workerCursor)}`);
      const url = `/pwsadmin/api/workers?${params.join("&")}`;
      try {
        const res = await requestJSON(url);
        renderWorkerSummary(res.summary || {});
        renderWorkerRows(res.items || []);
        renderWorkerQueueRows(res.queues || []);
        workerCursor = res.next_cursor ?? null;
        const nextButton = document.getElementById("worker-next");
        nextButton.disabled = !workerCursor;
        nextButton.classList.toggle("cursor-not-allowed", nextButton.disabled);
        setStatus(`Workers: ${(res.items || []).length} registrations across ${res.summary?.total_queues ?? 0} queues.`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    async function loadPricing() {
      const scopeEl = document.getElementById("pricing-scope");
      const propEl = document.getElementById("pricing-property");
      const platEl = document.getElementById("pricing-platform");
      const lookupEl = document.getElementById("pricing-lookup");
      const opEl = document.getElementById("pricing-operation");
      const statusEl = document.getElementById("pricing-status");
      if (!validateControls([propEl, platEl, lookupEl, opEl, statusEl])) return;
      const params = [];
      const scope = scopeEl.value.trim();
      const prop = propEl.value.trim();
      const plat = platEl.value.trim();
      const lookup = lookupEl.value.trim();
      const op = opEl.value.trim();
      const st = statusEl.value.trim();
      if (scope) params.push(`scope=${encodeURIComponent(scope)}`);
      if (prop) params.push(`property_id=${prop}`);
      if (plat) params.push(`platform_id=${plat}`);
      if (lookup) params.push(`platform_property_lookup_id=${lookup}`);
      if (op) params.push(`operation_code=${op}`);
      if (st) params.push(`status=${st}`);
      const url = `/pwsadmin/api/pricing/rules?${params.join("&")}`;
      try {
        const res = await requestJSON(url);
        const tbody = document.getElementById("pricing-rows");
        tbody.innerHTML = "";
        (res.items || []).forEach((r) => {
          const tr = document.createElement("tr");
          tr.className = "cursor-pointer transition hover:bg-slate-50 dark:hover:bg-slate-800/70";
          tr.dataset.ruleUuid = r.rule_uuid;
          tr.innerHTML = `
            <td class="font-mono text-xs">${escapeHtml(r.rule_uuid || "-")}</td>
            <td>${escapeHtml(r.scope || "-")}</td>
            <td>${escapeHtml(buildPricingRuleTargetLabel(r))}</td>
            <td>${escapeHtml(r.operation_code || "-")}</td>
            <td>${escapeHtml(r.status || "-")}</td>
            <td>${escapeHtml(String(r.priority ?? "-"))}</td>
          `;
          tr.addEventListener("click", () => editPricingRule(r.rule_uuid));
          tbody.appendChild(tr);
        });
        markPricingSelection(selectedPricingRuleUuid);
        setStatus(`Pricing rules: ${(res.items || []).length}`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    function applyListingTargetToPricingEditor(prefix, row) {
      document.getElementById(`${prefix}-target-scope`).value = "listing";
      document.getElementById(`${prefix}-platform`).value = String(row.platform_id || "");
      return syncPricingTargetScope(prefix, { selectedLookupId: row.lookup_id });
    }

    async function startPricingRuleForListing(row) {
      resetPricingEditor();
      setPricingSubtab("rules");
      document.getElementById("pricing-scope").value = "listing";
      document.getElementById("pricing-lookup").value = String(row.lookup_id || "");
      await applyListingTargetToPricingEditor("pricing-simple", row);
      await applyListingTargetToPricingEditor("pricing-moderate", row);
      document.getElementById("pricing-simple-listing").value = String(row.lookup_id || "");
      document.getElementById("pricing-moderate-listing").value = String(row.lookup_id || "");
      const advancedForm = document.getElementById("pricing-form-advanced");
      advancedForm.elements.namedItem("property_id").value = "";
      advancedForm.elements.namedItem("platform_id").value = "";
      advancedForm.elements.namedItem("platform_property_lookup_id").value = String(row.lookup_id || "");
      setPricingMode("simple");
      await loadPricing();
      setStatus(`Prepared a new listing-scoped rule for ${buildPricingListingLabel(row)}.`, false);
    }

    async function loadPricingListings() {
      const platformId = String(document.getElementById("pricing-listings-platform-filter").value || "").trim();
      const propertyId = String(document.getElementById("pricing-listings-property-filter").value || "").trim();
      const params = ["limit=500"];
      if (platformId) params.push(`platform_id=${encodeURIComponent(platformId)}`);
      if (propertyId) params.push(`property_id=${encodeURIComponent(propertyId)}`);
      const res = await requestJSON(`/pwsadmin/api/pricing/listings?${params.join("&")}`);
      pricingListingRows = Array.isArray(res.items) ? res.items : [];
      const tbody = document.getElementById("pricing-listings-rows");
      tbody.innerHTML = "";
      pricingListingRows.forEach((row) => {
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td class="font-mono text-xs">${escapeHtml(String(row.lookup_id ?? "-"))}</td>
          <td>${escapeHtml(row.platform_name || "-")} (${escapeHtml(row.platform_type || "-")})</td>
          <td class="font-mono text-xs">${escapeHtml(row.platform_property_id || "-")}</td>
          <td>${escapeHtml(row.listing_name || "-")}</td>
          <td>${escapeHtml(row.property_name || `Property #${row.property_id ?? "-"}`)}</td>
          <td><button type="button" class="secondary-btn rounded border px-2 py-1 text-xs font-semibold" data-action="pricing-use-listing" data-lookup-id="${escapeHtml(String(row.lookup_id || ""))}">Start Rule</button></td>
        `;
        tbody.appendChild(tr);
      });
      setStatus(`Pricing listings: ${pricingListingRows.length}`);
    }

    async function loadPricingProperties() {
      const res = await requestJSON("/pwsadmin/api/properties?limit=200");
      pricingPropertiesCache = res.items || [];
      setBookingPropertyNameLookup(pricingPropertiesCache);
      [document.getElementById("pricing-simple-property"), document.getElementById("pricing-moderate-property")].forEach((select) => {
        populateSelect(select, pricingPropertiesCache, {
          placeholder: "Select property",
          getValue: (item) => String(item.id),
          getLabel: (item) => `${extractPropertyName(item)} (#${item.id})`,
        });
      });
      populateSelect(document.getElementById("pricing-listings-property-filter"), pricingPropertiesCache, {
        placeholder: "All properties",
        getValue: (item) => String(item.id),
        getLabel: (item) => `${extractPropertyName(item)} (#${item.id})`,
      });
    }

    function isMessageClassAdmin() {
      return Boolean(currentUserProfile?.is_admin);
    }

    function getVisibleMessageClasses() {
      return isMessageClassAdmin() ? messageClassAdminCache : messageClassesCache;
    }

    function setMessageClassStatus(message, err = false) {
      const el = document.getElementById("message-class-status");
      el.textContent = message || "";
      el.className = err
        ? "mt-3 text-xs text-rose-600 dark:text-rose-300"
        : "mt-3 text-xs text-slate-600 dark:text-slate-300";
    }

    function updateMessageClassFormState() {
      const isAdmin = isMessageClassAdmin();
      const nameEl = document.getElementById("message-class-name");
      const descriptionEl = document.getElementById("message-class-description");
      const activeEl = document.getElementById("message-class-is-active");
      const saveEl = document.getElementById("message-class-save");
      const resetEl = document.getElementById("message-class-reset");
      const newEl = document.getElementById("message-class-new");
      const titleEl = document.getElementById("message-class-form-title");

      [nameEl, descriptionEl, activeEl, saveEl, resetEl, newEl].forEach((el) => {
        if (el) el.disabled = !isAdmin;
      });

      if (!isAdmin) {
        titleEl.textContent = "Read Only";
        saveEl.textContent = "Admin Required";
        return;
      }

      titleEl.textContent = selectedMessageClassId ? "Edit Message Class" : "Add Message Class";
      saveEl.textContent = selectedMessageClassId ? "Save Changes" : "Create Class";
    }

    function resetMessageClassForm(options = {}) {
      const { keepStatus = false } = options;
      selectedMessageClassId = null;
      document.getElementById("message-class-id").value = "";
      document.getElementById("message-class-name").value = "";
      document.getElementById("message-class-description").value = "";
      document.getElementById("message-class-is-active").checked = true;
      setControlErrorState(document.getElementById("message-class-name"), null);
      setControlErrorState(document.getElementById("message-class-description"), null);
      updateMessageClassFormState();
      renderMessageClassTable();
      if (!keepStatus) {
        if (isMessageClassAdmin()) {
          setMessageClassStatus("Ready to create a new message class.", false);
        } else {
          setMessageClassStatus("Read-only: admin access is required to manage message classes.", false);
        }
      }
    }

    function populateMessageClassForm(item, options = {}) {
      const { updateStatus = true } = options;
      if (!item) {
        resetMessageClassForm({ keepStatus: !updateStatus });
        return;
      }
      selectedMessageClassId = item.id;
      document.getElementById("message-class-id").value = String(item.id || "");
      document.getElementById("message-class-name").value = item.name || "";
      document.getElementById("message-class-description").value = item.description || "";
      document.getElementById("message-class-is-active").checked = item.is_active !== false;
      setControlErrorState(document.getElementById("message-class-name"), null);
      setControlErrorState(document.getElementById("message-class-description"), null);
      updateMessageClassFormState();
      renderMessageClassTable();
      if (updateStatus) {
        setMessageClassStatus(`Editing message class "${item.name || ""}".`, false);
      }
    }

    function renderMessageClassTable() {
      const isAdmin = isMessageClassAdmin();
      const items = Array.isArray(messageClassTableItems) ? messageClassTableItems : [];
      const tbody = document.getElementById("message-class-rows");
      const summaryEl = document.getElementById("message-class-summary");
      tbody.innerHTML = "";

      const activeCount = items.filter((item) => item.is_active !== false).length;
      const inactiveCount = items.length - activeCount;
      summaryEl.textContent = isAdmin
        ? `Showing ${items.length} of ${messageClassTotalCount} class(es) - page: ${activeCount} active - ${inactiveCount} inactive`
        : `Showing ${items.length} of ${messageClassTotalCount} active class(es). Admin access is required to view inactive entries or make changes.`;

      if (!items.length) {
        tbody.innerHTML = "<tr><td colspan='6' class='py-4 text-sm text-slate-600 dark:text-slate-300'>No message classes found.</td></tr>";
        return;
      }

      items.forEach((item) => {
        const tr = document.createElement("tr");
        const selected = String(item.id ?? "") === String(selectedMessageClassId ?? "");
        if (selected) {
          tr.className = "bg-brand-50/70 dark:bg-brand-500/10";
        }

        const isLocked = String(item.name || "").trim().toLowerCase() === "unclassified";
        const usageCount = Number(item.usage_count || 0);
        const statusBadge = item.is_active !== false
          ? '<span class="inline-flex rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Active</span>'
          : '<span class="inline-flex rounded-full bg-slate-200 px-2 py-0.5 text-xs font-semibold text-slate-700 dark:bg-slate-700 dark:text-slate-200">Inactive</span>';
        const deleteDisabled = !isAdmin || isLocked || usageCount > 0;
        const deleteTitle = isLocked
          ? "The required unclassified class cannot be deleted"
          : (usageCount > 0 ? "This class is already assigned to messages" : "Delete this class");
        const actionMarkup = isAdmin
          ? `
            <div class="flex flex-wrap gap-2">
              <button type="button" class="secondary-btn rounded border px-2 py-1 text-xs font-semibold" data-action="edit-message-class" data-class-id="${escapeHtml(String(item.id || ""))}">Edit</button>
              <button type="button" class="secondary-btn rounded border px-2 py-1 text-xs font-semibold ${deleteDisabled ? "opacity-60" : "text-rose-700 dark:text-rose-200"}" data-action="delete-message-class" data-class-id="${escapeHtml(String(item.id || ""))}" title="${escapeHtml(deleteTitle)}" ${deleteDisabled ? "disabled" : ""}>Delete</button>
            </div>
          `
          : '<span class="text-xs text-slate-500 dark:text-slate-400">Read-only</span>';

        tr.innerHTML = `
          <td class="font-semibold text-slate-800 dark:text-slate-100">${escapeHtml(item.name || "-")}</td>
          <td>${statusBadge}</td>
          <td class="max-w-[320px]">${escapeHtml(item.description || "-")}</td>
          <td class="text-center font-mono text-xs">${escapeHtml(String(usageCount))}</td>
          <td class="font-mono text-xs">${escapeHtml(item.updated_at || item.created_at || "-")}</td>
          <td>${actionMarkup}</td>
        `;
        tbody.appendChild(tr);
      });
    }

    async function loadMessageClasses(options = {}) {
      const includeInactive = options.includeInactive === true;
      const preserveSelectionId = options.preserveSelectionId ?? selectedMessageClassId;
      const next = options.next === true;
      const limitEl = document.getElementById("message-class-limit");
      if (!validateControls([limitEl])) return [];
      const limit = limitEl.value || 25;
      if (!next) {
        messageClassCursor = null;
      } else if (!messageClassCursor) {
        return [];
      }

      const cacheQuery = includeInactive ? "?include_inactive=true" : "";
      const cacheRes = await requestJSON(`/pwsadmin/api/message-classes${cacheQuery}`);
      const cacheItems = Array.isArray(cacheRes.items) ? cacheRes.items : [];
      messageClassesCache = cacheItems.filter((item) => item.is_active !== false);
      messageClassAdminCache = includeInactive ? cacheItems : messageClassesCache;

      const tableParams = [`limit=${encodeURIComponent(limit)}`];
      if (includeInactive) tableParams.push("include_inactive=true");
      if (next && messageClassCursor) tableParams.push(`cursor=${encodeURIComponent(messageClassCursor)}`);
      const tableRes = await requestJSON(`/pwsadmin/api/message-classes?${tableParams.join("&")}`);
      const items = Array.isArray(tableRes.items) ? tableRes.items : [];
      messageClassTableItems = items;
      messageClassCursor = tableRes.next_cursor ?? null;
      messageClassTotalCount = Number(tableRes.total_count || 0);
      const nextButton = document.getElementById("message-class-next");
      nextButton.disabled = !messageClassCursor;
      nextButton.classList.toggle("cursor-not-allowed", nextButton.disabled);

      if (isMessageClassAdmin() && preserveSelectionId !== null && preserveSelectionId !== undefined) {
        const matched = messageClassAdminCache.find((item) => String(item.id ?? "") === String(preserveSelectionId));
        selectedMessageClassId = matched ? matched.id : null;
      } else if (!isMessageClassAdmin()) {
        selectedMessageClassId = null;
      }

      renderSimpleCategoryOptions();
      renderModerateCategoryOptions();
      window.requestAnimationFrame(refreshPricingCategoryViewportLimits);
      renderMessageClassTable();

      if (isMessageClassAdmin()) {
        if (selectedMessageClassId) {
          const selectedItem = messageClassAdminCache.find((item) => String(item.id ?? "") === String(selectedMessageClassId));
          if (selectedItem) {
            populateMessageClassForm(selectedItem, { updateStatus: false });
          } else {
            resetMessageClassForm({ keepStatus: true });
          }
        } else {
          updateMessageClassFormState();
        }
      } else {
        resetMessageClassForm({ keepStatus: true });
      }
      return items;
    }

    document.getElementById("message-class-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!isMessageClassAdmin()) {
        setMessageClassStatus("Admin access is required to manage message classes.", true);
        return;
      }

      const nameEl = document.getElementById("message-class-name");
      const descriptionEl = document.getElementById("message-class-description");
      if (!validateControls([nameEl, descriptionEl], { required: true })) return;

      const payload = {
        name: nameEl.value.trim(),
        description: descriptionEl.value.trim(),
        is_active: document.getElementById("message-class-is-active").checked,
      };
      const classId = selectedMessageClassId;

      try {
        const saved = classId
          ? await requestJSON(`/pwsadmin/api/message-classes/${classId}`, {
              method: "PUT",
              body: JSON.stringify(payload),
            })
          : await requestJSON("/pwsadmin/api/message-classes", {
              method: "POST",
              body: JSON.stringify(payload),
            });

        await loadMessageClasses({
          includeInactive: true,
          preserveSelectionId: saved?.id ?? classId ?? null,
        });
        const refreshed = messageClassAdminCache.find((item) => String(item.id ?? "") === String(saved?.id ?? classId ?? ""));
        if (refreshed) {
          populateMessageClassForm(refreshed, { updateStatus: false });
        }
        const successMessage = classId
          ? `Updated message class "${payload.name}".`
          : `Created message class "${payload.name}".`;
        setMessageClassStatus(successMessage, false);
        setStatus(successMessage, false);
      } catch (error) {
        setMessageClassStatus(error.message, true);
        setStatus(error.message, true);
      }
    });

    document.getElementById("message-class-reset").addEventListener("click", () => {
      resetMessageClassForm();
    });

    document.getElementById("message-class-new").addEventListener("click", () => {
      resetMessageClassForm();
    });

    document.getElementById("message-class-refresh").addEventListener("click", () => {
      loadMessageClasses({ includeInactive: isMessageClassAdmin(), next: false })
        .then(() => {
          setMessageClassStatus("Reloaded message classes.", false);
          setStatus("Reloaded message classes.", false);
        })
        .catch((error) => {
          setMessageClassStatus(error.message, true);
          setStatus(error.message, true);
        });
    });
    document.getElementById("message-class-next").addEventListener("click", () => {
      loadMessageClasses({ includeInactive: isMessageClassAdmin(), next: true })
        .then(() => {
          setMessageClassStatus("Loaded next page of message classes.", false);
        })
        .catch((error) => {
          setMessageClassStatus(error.message, true);
          setStatus(error.message, true);
        });
    });

    document.getElementById("message-class-rows").addEventListener("click", async (event) => {
      const button = event.target.closest("button[data-action]");
      if (!button) return;

      const classIdRaw = String(button.dataset.classId || "").trim();
      if (!classIdRaw) return;
      const item = messageClassAdminCache.find((row) => String(row.id ?? "") === classIdRaw);
      if (!item) return;

      if (button.dataset.action === "edit-message-class") {
        populateMessageClassForm(item);
        return;
      }

      if (button.dataset.action !== "delete-message-class") return;
      if (!window.confirm(`Delete message class "${item.name || classIdRaw}"?`)) return;

      try {
        if (String(selectedMessageClassId ?? "") === classIdRaw) {
          selectedMessageClassId = null;
        }
        await requestJSON(`/pwsadmin/api/message-classes/${classIdRaw}`, { method: "DELETE" });
        await loadMessageClasses({ includeInactive: true, preserveSelectionId: null });
        resetMessageClassForm({ keepStatus: true });
        const successMessage = `Deleted message class "${item.name || classIdRaw}".`;
        setMessageClassStatus(successMessage, false);
        setStatus(successMessage, false);
      } catch (error) {
        setMessageClassStatus(error.message, true);
        setStatus(error.message, true);
      }
    });

    document.getElementById("pricing-simple-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        if (!validateSimplePricingForm()) return;
        const payload = buildSimplePricingPayload();
        const ruleUuid = document.getElementById("pricing-simple-rule-uuid").value.trim();
        await submitPricingPayload(payload, ruleUuid);
        await loadPricing();
        if (ruleUuid) {
          await editPricingRule(ruleUuid);
          setStatus(`Updated pricing rule ${ruleUuid} in Simple mode.`, false);
        } else {
          resetPricingEditor();
          setPricingMode("simple");
          setStatus("Created pricing rule from the Simple editor.", false);
        }
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    document.getElementById("pricing-moderate-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        if (!validateModeratePricingForm()) return;
        const payload = buildModeratePricingPayload();
        const ruleUuid = document.getElementById("pricing-moderate-rule-uuid").value.trim();
        await submitPricingPayload(payload, ruleUuid);
        await loadPricing();
        if (ruleUuid) {
          await editPricingRule(ruleUuid);
          setStatus(`Updated pricing rule ${ruleUuid} in Moderate mode.`, false);
        } else {
          resetPricingEditor();
          setPricingMode("moderate");
          setStatus("Created pricing rule from the Moderate editor.", false);
        }
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    document.getElementById("pricing-form-advanced").addEventListener("submit", async (e) => {
      e.preventDefault();
      const formControls = Array.from(e.target.querySelectorAll("input, textarea"));
      if (!validateControls(formControls)) return;
      const formData = new FormData(e.target);
      try {
        const payload = buildAdvancedPricingPayload(formData);
        const ruleUuid = (formData.get("rule_uuid") || "").trim();
        await submitPricingPayload(payload, ruleUuid);
        await loadPricing();
        if (ruleUuid) {
          await editPricingRule(ruleUuid);
          setStatus(`Updated pricing rule ${ruleUuid} in Advanced mode.`, false);
        } else {
          resetPricingEditor();
          setPricingMode("advanced");
          setStatus("Created pricing rule from the Advanced editor.", false);
        }
      } catch (error) {
        if (error instanceof SyntaxError) {
          setStatus("Invalid JSON in rule_config or applicable_dates.", true);
          return;
        }
        setStatus(error.message, true);
      }
    });

    document.getElementById("subtab-pricing-rules-trigger").addEventListener("click", () => setPricingSubtab("rules"));
    document.getElementById("subtab-pricing-listings-trigger").addEventListener("click", () => setPricingSubtab("listings"));
    document.getElementById("pricing-mode-simple").addEventListener("click", () => setPricingMode("simple"));
    document.getElementById("pricing-mode-moderate").addEventListener("click", () => setPricingMode("moderate"));
    document.getElementById("pricing-mode-advanced").addEventListener("click", () => setPricingMode("advanced"));
    document.getElementById("pricing-reset-editor").addEventListener("click", () => {
      resetPricingEditor();
      setStatus("Pricing editor reset. You can create a new rule now.", false);
    });
    document.getElementById("pricing-listings-load").addEventListener("click", () => {
      loadPricingListings().catch((error) => setStatus(error.message, true));
    });
    document.getElementById("pricing-listings-rows").addEventListener("click", (event) => {
      const button = event.target.closest('button[data-action="pricing-use-listing"]');
      if (!button) return;
      const lookupId = normalizeLookupId(button.dataset.lookupId);
      if (lookupId === null) return;
      const row = pricingListingRows.find((item) => normalizeLookupId(item.lookup_id) === lookupId);
      if (!row) return;
      startPricingRuleForListing(row).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("pricing-simple-add-date").addEventListener("click", () => {
      document.getElementById("pricing-simple-exact-dates").appendChild(buildSimpleExactDateRow());
      setSimpleDateScope("exact");
    });
    document.querySelectorAll('input[name="pricing_simple_date_scope"]').forEach((radio) => {
      radio.addEventListener("change", () => setSimpleDateScope(radio.value));
    });
    document.getElementById("pricing-simple-operation").addEventListener("change", syncSimpleOperationFields);
    document.getElementById("pricing-simple-longer-stay-enabled").addEventListener("change", () => {
      syncPricingStayLengthFields("pricing-simple");
    });
    document.getElementById("pricing-simple-stay-length-op").addEventListener("change", () => {
      syncPricingStayLengthFields("pricing-simple");
    });
    document.getElementById("pricing-simple-target-scope").addEventListener("change", () => {
      syncPricingTargetScope("pricing-simple").catch((error) => setStatus(error.message, true));
    });
    document.getElementById("pricing-simple-platform").addEventListener("change", () => {
      if (getPricingTargetMode("pricing-simple") !== "listing") return;
      syncPricingTargetScope("pricing-simple", { forceReload: true }).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("pricing-moderate-add-date").addEventListener("click", () => {
      document.getElementById("pricing-moderate-exact-dates").appendChild(buildModerateExactDateRow());
      setModerateDateScope("exact");
    });
    document.querySelectorAll('input[name="pricing_moderate_date_scope"]').forEach((radio) => {
      radio.addEventListener("change", () => setModerateDateScope(radio.value));
    });
    document.getElementById("pricing-moderate-season-enabled")?.addEventListener("change", () => {
      setModerateSeasonWindowEnabled(isModerateSeasonWindowEnabled());
    });
    document.getElementById("pricing-moderate-operation").addEventListener("change", syncModerateOperationFields);
    [
      "pricing-moderate-stay-length-op",
      "pricing-moderate-stay-extended-op",
      "pricing-moderate-stay-contracted-op",
    ].forEach((id) => {
      document.getElementById(id).addEventListener("change", syncModerateStayConditionFields);
    });
    document.getElementById("pricing-moderate-target-scope").addEventListener("change", () => {
      syncPricingTargetScope("pricing-moderate").catch((error) => setStatus(error.message, true));
    });
    document.getElementById("pricing-moderate-platform").addEventListener("change", () => {
      if (getPricingTargetMode("pricing-moderate") !== "listing") return;
      syncPricingTargetScope("pricing-moderate", { forceReload: true }).catch((error) => setStatus(error.message, true));
    });
    window.addEventListener("resize", () => {
      window.requestAnimationFrame(refreshPricingCategoryViewportLimits);
    });

    function normalizeBsoInstruction(value) {
      if (isObjectLike(value) || Array.isArray(value)) return value;
      if (typeof value === "string" && value.trim()) {
        try {
          return JSON.parse(value);
        } catch {
          return value;
        }
      }
      return value ?? {};
    }

    function formatBsoInstructionYmf(value) {
      return renderYmf(normalizeBsoInstruction(value));
    }

    function buildBsoInstructionExcerpt(value, maxLength = 110) {
      const ymf = formatBsoInstructionYmf(value).replace(/\s+/g, " ").trim();
      if (!ymf) return "-";
      if (ymf.length <= maxLength) return ymf;
      return `${ymf.slice(0, maxLength - 3)}...`;
    }

    function closeBsoInstructionModal() {
      document.getElementById("bso-instruction-modal").classList.add("hidden");
      document.getElementById("bso-instruction-modal").classList.remove("flex");
      document.getElementById("bso-instruction-title").textContent = "Instruction";
      document.getElementById("bso-instruction-body").textContent = "Select an instruction to view details.";
    }

    function openBsoInstructionModal(rowId, instruction) {
      document.getElementById("bso-instruction-title").textContent = `Instruction for row #${rowId}`;
      document.getElementById("bso-instruction-body").textContent = formatBsoInstructionYmf(instruction);
      const modal = document.getElementById("bso-instruction-modal");
      modal.classList.remove("hidden");
      modal.classList.add("flex");
    }

    function setBsoPaginationState(nextCursor) {
      bsoCursor = nextCursor ?? null;
      bsoHasNext = Boolean(bsoCursor);
      const nextButton = document.getElementById("bso-next");
      if (!nextButton) return;
      nextButton.disabled = !bsoHasNext;
      nextButton.classList.toggle("cursor-not-allowed", !bsoHasNext);
      nextButton.classList.toggle("opacity-60", !bsoHasNext);
    }

    async function loadBsoAudit(next = false) {
      const bookingEntryEl = document.getElementById("bso-booking-entry-id");
      const statusEl = document.getElementById("bso-status");
      const updatedFromEl = document.getElementById("bso-updated-from");
      const updatedToEl = document.getElementById("bso-updated-to");
      const limitEl = document.getElementById("bso-limit");
      if (!validateControls([bookingEntryEl, statusEl, updatedFromEl, updatedToEl, limitEl])) return;

      const bookingEntryId = bookingEntryEl.value.trim();
      const statusValue = statusEl.value.trim();
      const updatedFrom = updatedFromEl.value.trim();
      const updatedTo = updatedToEl.value.trim();
      const limit = limitEl.value || "50";

      if (updatedFrom && updatedTo && updatedFrom > updatedTo) {
        setStatus("updated_from must be on or before updated_to.", true);
        return;
      }

      if (!next) {
        setBsoPaginationState(null);
      } else if (!bsoCursor) {
        setBsoPaginationState(null);
        return;
      }

      const params = [`limit=${encodeURIComponent(limit)}`];
      if (bookingEntryId) params.push(`booking_entry_id=${encodeURIComponent(bookingEntryId)}`);
      if (statusValue) params.push(`status=${encodeURIComponent(statusValue)}`);
      if (updatedFrom) params.push(`updated_from=${encodeURIComponent(updatedFrom)}`);
      if (updatedTo) params.push(`updated_to=${encodeURIComponent(updatedTo)}`);
      if (next && bsoCursor) params.push(`cursor=${encodeURIComponent(bsoCursor)}`);

      const url = `/pwsadmin/api/bso/applied-rules?${params.join("&")}`;
      try {
        const res = await requestJSON(url);
        const tbody = document.getElementById("bso-rows");
        tbody.innerHTML = "";
        (res.items || []).forEach((row) => {
          const tr = document.createElement("tr");
          [row.id, row.booking_entry_id, row.status].forEach((value) => {
            const td = document.createElement("td");
            td.textContent = value === null || value === undefined ? "-" : String(value);
            tr.appendChild(td);
          });

          const instructionCell = document.createElement("td");
          const instructionButton = document.createElement("button");
          instructionButton.type = "button";
          instructionButton.className = "secondary-btn max-w-[320px] rounded border px-2 py-1 text-left text-xs";
          instructionButton.textContent = buildBsoInstructionExcerpt(row.instruction);
          instructionButton.addEventListener("click", () => {
            openBsoInstructionModal(row.id ?? "-", row.instruction);
          });
          instructionCell.appendChild(instructionButton);
          tr.appendChild(instructionCell);

          [row.updated_at, row.applied_at, row.removed_at].forEach((value) => {
            const td = document.createElement("td");
            td.textContent = formatDateTimeInBrowserTimezone(value);
            tr.appendChild(td);
          });
          tbody.appendChild(tr);
        });
        setBsoPaginationState(res.next_cursor ?? null);
        setStatus(`BSO audit rows: ${(res.items || []).length}`);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    function setBookingPaginationState(nextCursor) {
      bookingCursor = nextCursor ?? null;
      bookingHasNext = Boolean(bookingCursor);
      const nextButton = document.getElementById("booking-next");
      if (!nextButton) return;
      nextButton.disabled = !bookingHasNext;
      nextButton.classList.toggle("cursor-not-allowed", !bookingHasNext);
      nextButton.classList.toggle("opacity-60", !bookingHasNext);
    }

    async function loadBookings(next = false) {
      const propertyEl = document.getElementById("booking-property");
      const platformEl = document.getElementById("booking-platform");
      const fromEl = document.getElementById("booking-from");
      const toEl = document.getElementById("booking-to");
      const limitEl = document.getElementById("booking-limit");
      if (!validateControls([propertyEl, platformEl, fromEl, toEl, limitEl])) return;
      const p = propertyEl.value.trim();
      const plat = platformEl.value.trim();
      const af = fromEl.value.trim();
      const at = toEl.value.trim();
      const limit = limitEl.value || "50";

      if (!next) {
        setBookingPaginationState(null);
      } else if (!bookingCursor) {
        setBookingPaginationState(null);
        return;
      }

      const params = [`limit=${encodeURIComponent(limit)}`];
      if (p) params.push(`property_id=${encodeURIComponent(p)}`);
      if (plat) params.push(`platform_id=${encodeURIComponent(plat)}`);
      if (af) params.push(`arrival_from=${encodeURIComponent(af)}`);
      if (at) params.push(`arrival_to=${encodeURIComponent(at)}`);
      if (next && bookingCursor) params.push(`cursor=${encodeURIComponent(bookingCursor)}`);
      const url = `/pwsadmin/api/bookings?${params.join("&")}`;
      try {
        const res = await requestJSON(url);
        const tbody = document.getElementById("booking-rows");
        tbody.innerHTML = "";
        (res.items || []).forEach((r) => {
          const tr = document.createElement("tr");
          tr.className = "cursor-pointer transition hover:bg-slate-50 dark:hover:bg-slate-800/70";
          [
            r.id,
            r.arrival,
            r.departure,
            resolveBookingPropertyName(r.property_id),
            resolveBookingPlatformName(r.platform_id),
          ].forEach((value, index) => {
            const td = document.createElement("td");
            if (index >= 3) td.className = "max-w-[220px] break-words";
            td.textContent = value === null || value === undefined ? "-" : String(value);
            tr.appendChild(td);
          });
          tr.addEventListener("click", () => loadBookingDetail(r.id));
          tbody.appendChild(tr);
        });
        setBookingPaginationState(res.next_cursor ?? null);
        setStatus(`Bookings: ${(res.items || []).length}`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    async function loadBookingDetail(id) {
      try {
        const res = await requestJSON(`/pwsadmin/api/bookings/${id}`);
        renderBookingThreadList(res);
        document.getElementById("booking-detail").textContent = formatBookingDetailYmf(res);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    function getPlatformsForPropertyStage(stage) {
      return pricingPlatformsCache.filter((item) => String(item.type || "").toLowerCase() === stage && item.is_active !== false);
    }

    function resetPropertyStageCompletion() {
      propertyStageCompleted = { ...EMPTY_PROPERTY_STAGE_COMPLETION };
    }

    function hydratePropertyStageCompletion(stageStatus) {
      resetPropertyStageCompletion();
      const stages = isObjectLike(stageStatus?.stages) ? stageStatus.stages : {};
      PROPERTY_STAGE_ORDER.forEach((stage) => {
        const details = stages[stage];
        if (isObjectLike(details) && details.completed === true) {
          propertyStageCompleted[stage] = true;
        }
      });
    }

    function getPropertyStageIndex(stage) {
      return PROPERTY_STAGE_ORDER.indexOf(stage);
    }

    function getPreviousRequiredStageLabel(stage) {
      const stageIndex = getPropertyStageIndex(stage);
      if (stageIndex <= 0) return null;
      for (let idx = stageIndex - 1; idx >= 0; idx -= 1) {
        const previousStage = PROPERTY_STAGE_ORDER[idx];
        if (getPlatformsForPropertyStage(previousStage).length > 0 && !propertyStageCompleted[previousStage]) {
          return PROPERTY_STAGE_LABELS[previousStage] || previousStage.toUpperCase();
        }
      }
      return null;
    }

    function isPropertyStageUnlocked(stage) {
      return getPreviousRequiredStageLabel(stage) === null;
    }

    function applyPropertyStageDefaults() {
      PROPERTY_STAGE_ORDER.forEach((stage) => {
        if (getPlatformsForPropertyStage(stage).length === 0) {
          propertyStageCompleted[stage] = true;
        }
      });
      if (!isPropertyStageUnlocked(activePropertyStage)) {
        const firstUnlocked = PROPERTY_STAGE_ORDER.find((stage) => isPropertyStageUnlocked(stage)) || PROPERTY_STAGE_ORDER[0];
        activePropertyStage = firstUnlocked;
      }
    }

    function renderPropertyStageButtons() {
      document.querySelectorAll(".property-stage-btn").forEach((button) => {
        const stage = button.dataset.stage;
        const label = PROPERTY_STAGE_LABELS[stage] || String(stage || "").toUpperCase();
        const stageIndex = getPropertyStageIndex(stage);
        const unlocked = isPropertyStageUnlocked(stage);
        const selected = stage === activePropertyStage;
        const hasPlatforms = getPlatformsForPropertyStage(stage).length > 0;
        const completed = propertyStageCompleted[stage];
        const suffix = completed ? " [done]" : (!hasPlatforms ? " (none)" : "");
        button.textContent = `${stageIndex + 1}. ${label}${suffix}`;
        button.disabled = !unlocked;
        button.classList.toggle("cursor-not-allowed", !unlocked);
        button.classList.toggle("opacity-60", !unlocked);
        button.classList.toggle("nav-btn-active", selected);
      });
    }

    function updatePropertyStageHint() {
      const hintEl = document.getElementById("property-stage-hint");
      const stageLabel = PROPERTY_STAGE_LABELS[activePropertyStage] || activePropertyStage.toUpperCase();
      const platforms = getPlatformsForPropertyStage(activePropertyStage);
      const previousBlocked = getPreviousRequiredStageLabel(activePropertyStage);
      if (previousBlocked) {
        hintEl.textContent = `Complete ${previousBlocked} import first, then continue with ${stageLabel}.`;
        return;
      }
      if (!platforms.length) {
        hintEl.textContent = `No active ${stageLabel} platforms configured. This step is marked complete.`;
        return;
      }
      const selectedPlatformId = propertyStagePlatformByType[activePropertyStage] || "";
      const selectedPlatform = platforms.find((item) => String(item.id) === selectedPlatformId);
      if (!selectedPlatform) {
        hintEl.textContent = `Select a ${stageLabel} platform, fetch all properties, then import selected rows.`;
        return;
      }
      hintEl.textContent = `${stageLabel} stage platform: ${selectedPlatform.name}. Rows with matching lat/lon are highlighted; matched rows either choose a listing chain or confirm the first listing on an existing property before import.`;
    }

    function refreshPropertyStageSelector() {
      const platformEl = document.getElementById("platform-select");
      const stagePlatforms = getPlatformsForPropertyStage(activePropertyStage);
      const stageLabel = PROPERTY_STAGE_LABELS[activePropertyStage] || activePropertyStage.toUpperCase();
      populateSelect(platformEl, stagePlatforms, {
        placeholder: stagePlatforms.length ? `Select ${stageLabel} platform` : `No ${stageLabel} platforms`,
        getValue: (item) => String(item.id),
        getLabel: (item) => `${item.name} (${item.type})`,
      });
      const rememberedId = propertyStagePlatformByType[activePropertyStage];
      if (rememberedId && stagePlatforms.some((item) => String(item.id) === rememberedId)) {
        platformEl.value = rememberedId;
      } else if (stagePlatforms.length > 0) {
        platformEl.value = String(stagePlatforms[0].id);
        propertyStagePlatformByType[activePropertyStage] = platformEl.value;
      } else {
        platformEl.value = "";
        propertyStagePlatformByType[activePropertyStage] = "";
      }
      updatePropertyStageHint();
      renderPropertyStageButtons();
      refreshRemoteTableColumns();
    }

    function getSelectedPropertyStagePlatform() {
      const platformId = String(document.getElementById("platform-select").value || "");
      return pricingPlatformsCache.find((item) => String(item.id) === platformId) || null;
    }

    function getRemotePlatformKind(platform) {
      const platformName = String(platform?.name || "").toLowerCase();
      if (platformName.includes("ownerrez")) return "ownerrez";
      if (platformName.includes("pricelabs") || platformName.includes("plab")) return "pricelabs";
      if (platformName.includes("wheelhouse")) return "wheelhouse";
      return "generic";
    }

    function getRemoteColumnDefinitions(platform) {
      const kind = getRemotePlatformKind(platform);
      const selectColumn = { key: "__select__", label: '<input type="checkbox" id="remote-select-all">' };
      const linkColumn = { key: "__link_to__", label: "Link To", className: "min-w-[260px]" };
      const autoColumn = { key: "__auto__", label: "Auto", className: "" };
      if (kind === "ownerrez") {
        return [
          selectColumn,
          { key: "name", label: "Name" },
          { key: "platform_property_id", label: "ID" },
          { key: "city", label: "City" },
          { key: "state", label: "State" },
          { key: "country", label: "Country" },
          { key: "timezone", label: "Timezone" },
          { key: "currency_code", label: "Currency" },
          { key: "public_url", label: "Public URL", className: "max-w-[320px] break-words" },
          { key: "__latlon__", label: "Lat/Lon", className: "font-mono text-xs" },
          linkColumn,
          autoColumn,
        ];
      }
      if (kind === "pricelabs") {
        return [
          selectColumn,
          { key: "name", label: "Name" },
          { key: "platform_property_id", label: "ID" },
          { key: "city", label: "City" },
          { key: "state", label: "State" },
          { key: "country", label: "Country" },
          { key: "__latlon__", label: "Lat/Lon", className: "font-mono text-xs" },
          { key: "__push_enabled__", label: "Push Enabled" },
          linkColumn,
          autoColumn,
        ];
      }
      if (kind === "wheelhouse") {
        return [
          selectColumn,
          { key: "name", label: "Name" },
          { key: "platform_property_id", label: "ID" },
          { key: "__latlon__", label: "Lat/Lon", className: "font-mono text-xs" },
          linkColumn,
          autoColumn,
        ];
      }
      return [
        selectColumn,
        { key: "name", label: "Name" },
        { key: "platform_property_id", label: "ID" },
        { key: "city", label: "City" },
        { key: "state", label: "State" },
        { key: "country", label: "Country" },
        { key: "__latlon__", label: "Lat/Lon", className: "font-mono text-xs" },
        linkColumn,
        autoColumn,
      ];
    }

    function bindRemoteSelectAllHandler() {
      const selectAll = document.getElementById("remote-select-all");
      if (!selectAll || selectAll.dataset.bound === "1") return;
      selectAll.addEventListener("change", (event) => {
        const pageItems = getRemoteCurrentPageItems().filter((item) => !isRemoteRowSelectionDisabled(item));
        pageItems.forEach((item) => {
          const propertyId = String(item.platform_property_id || "");
          if (!propertyId) return;
          if (event.target.checked) {
            remoteSelectedIds.add(propertyId);
          } else {
            remoteSelectedIds.delete(propertyId);
          }
        });
        renderRemoteRowsPage();
      });
      selectAll.dataset.bound = "1";
    }

    function refreshRemoteTableColumns() {
      const selectedPlatform = getSelectedPropertyStagePlatform();
      remoteColumnDefs = getRemoteColumnDefinitions(selectedPlatform);
      const headerHtml = remoteColumnDefs.map((column) => `<th>${column.label}</th>`).join("");
      document.getElementById("remote-columns-head").innerHTML = `<tr>${headerHtml}</tr>`;
      bindRemoteSelectAllHandler();
      renderRemoteRowsPage();
    }

    function getRemoteTotalPages() {
      return Math.max(1, Math.ceil(remoteCache.length / REMOTE_PAGE_SIZE));
    }

    function getRemoteCurrentPageItems() {
      const start = (remoteCurrentPage - 1) * REMOTE_PAGE_SIZE;
      return remoteCache.slice(start, start + REMOTE_PAGE_SIZE);
    }

    function updateRemotePaginationControls() {
      const total = remoteCache.length;
      const totalPages = getRemoteTotalPages();
      const statusText = `Page ${remoteCurrentPage} of ${totalPages} - ${total} properties`;
      document.getElementById("remote-pagination-status").textContent = statusText;
      const prevButton = document.getElementById("remote-page-prev");
      const nextButton = document.getElementById("remote-page-next");
      prevButton.disabled = remoteCurrentPage <= 1;
      nextButton.disabled = remoteCurrentPage >= totalPages;
      prevButton.classList.toggle("opacity-60", prevButton.disabled);
      nextButton.classList.toggle("opacity-60", nextButton.disabled);
      prevButton.classList.toggle("cursor-not-allowed", prevButton.disabled);
      nextButton.classList.toggle("cursor-not-allowed", nextButton.disabled);
    }

    function updateRemoteSelectAllState() {
      const selectAll = document.getElementById("remote-select-all");
      if (!selectAll) return;
      const pageItems = getRemoteCurrentPageItems().filter((item) => String(item.platform_property_id || "") && !isRemoteRowSelectionDisabled(item));
      if (!pageItems.length) {
        selectAll.checked = false;
        selectAll.indeterminate = false;
        return;
      }
      const selectedCount = pageItems.filter((item) => remoteSelectedIds.has(String(item.platform_property_id || ""))).length;
      selectAll.checked = selectedCount > 0 && selectedCount === pageItems.length;
      selectAll.indeterminate = selectedCount > 0 && selectedCount < pageItems.length;
    }

    function setRemotePage(pageNumber) {
      const totalPages = getRemoteTotalPages();
      remoteCurrentPage = Math.min(totalPages, Math.max(1, pageNumber));
      renderRemoteRowsPage();
    }

    function renderRemoteRowsPage() {
      const tbody = document.getElementById("remote-rows");
      if (!tbody) return;
      tbody.innerHTML = "";
      getRemoteCurrentPageItems().forEach((row) => {
        tbody.appendChild(renderRemoteRow(row));
      });
      updateRemotePaginationControls();
      updateRemoteSelectAllState();
    }

    function normalizeLookupId(value) {
      if (value === null || value === undefined || value === "") return null;
      const parsed = Number.parseInt(String(value), 10);
      return Number.isNaN(parsed) ? null : parsed;
    }

    function getRemoteLinkCandidates(row) {
      return Array.isArray(row.link_candidates) ? row.link_candidates : [];
    }

    function getRemoteSelectedLinkToLookupId(row) {
      const explicitValue = normalizeLookupId(row.selected_link_to_lookup_id);
      if (explicitValue !== null) return explicitValue;
      return normalizeLookupId(row.default_link_to_lookup_id);
    }

    function isRemoteRowSelectionDisabled(row) {
      return Boolean(row.link_problem) && !Boolean(row.existing_property_without_listings);
    }

    function isRemoteLinkSelectionMissing(row) {
      return Boolean(row.link_selection_required) && getRemoteSelectedLinkToLookupId(row) === null;
    }

    function isRemoteSamePlatformMatchWithoutLink(row) {
      return Boolean(row.same_platform_match_without_link);
    }

    function isRemoteExistingPropertyWithoutListings(row) {
      return Boolean(row.existing_property_without_listings);
    }

    function buildExistingPropertyTargetLabel(row) {
      const propertyId = row.existing_property_id ?? "-";
      const propertyName = row.existing_property_name ? ` | ${row.existing_property_name}` : "";
      return `Property #${propertyId}${propertyName}`;
    }

    function buildRemoteLinkCandidateLabel(candidate) {
      const platformName = candidate?.platform_name || `Platform #${candidate?.platform_id ?? "-"}`;
      const platformType = candidate?.platform_type ? ` (${candidate.platform_type})` : "";
      const listingName = candidate?.listing_name ? ` | ${candidate.listing_name}` : "";
      const platformPropertyId = candidate?.platform_property_id || "-";
      return `${platformName}${platformType}${listingName} | ${platformPropertyId}`;
    }

    function getCurrentRemoteLinkCandidate(row) {
      const selectedLookupId = getRemoteSelectedLinkToLookupId(row);
      const candidates = getRemoteLinkCandidates(row);
      const selectedCandidate = candidates.find((candidate) => normalizeLookupId(candidate.lookup_id) === selectedLookupId);
      if (selectedCandidate) return selectedCandidate;
      const selectedPlatform = getSelectedPropertyStagePlatform();
      return {
        lookup_id: selectedLookupId,
        platform_id: selectedPlatform?.id,
        platform_name: selectedPlatform?.name,
        platform_type: selectedPlatform?.type,
        listing_name: row.name,
        platform_property_id: row.platform_property_id,
      };
    }

    function renderRemoteLinkCell(row) {
      if (isRemoteRowSelectionDisabled(row)) {
        return '<span class="text-rose-700 dark:text-rose-300">Import blocked for this coordinate match</span>';
      }
      if (row.is_linked_on_platform) {
        const candidate = getCurrentRemoteLinkCandidate(row);
        return `<span class="text-xs font-medium text-slate-700 dark:text-slate-200">${escapeHtml(buildRemoteLinkCandidateLabel(candidate))}</span>`;
      }
      if (isRemoteExistingPropertyWithoutListings(row)) {
        return `<span class="text-xs font-medium text-sky-700 dark:text-sky-200">Use ${escapeHtml(buildExistingPropertyTargetLabel(row))} as first listing</span>`;
      }
      if (isRemoteSamePlatformMatchWithoutLink(row)) {
        return '<span class="text-slate-500 dark:text-slate-400">Same platform match - no link</span>';
      }
      if (!row.existing_property_id) {
        return '<span class="text-slate-500 dark:text-slate-400">Create new chain</span>';
      }
      const candidates = getRemoteLinkCandidates(row);
      const selectedLookupId = getRemoteSelectedLinkToLookupId(row);
      const selectClasses = [
        "control-surface",
        "remote-link-select",
        "w-full",
        "rounded",
        "border",
        "px-2",
        "py-1",
        "text-xs",
      ];
      if (isRemoteLinkSelectionMissing(row)) {
        selectClasses.push("border-rose-300", "text-rose-700", "dark:border-rose-500", "dark:text-rose-200");
      }
      const options = [];
      if (candidates.length > 1 || isRemoteLinkSelectionMissing(row)) {
        const placeholderSelected = selectedLookupId === null ? " selected" : "";
        options.push(`<option value=""${placeholderSelected}>Select listing</option>`);
      }
      candidates.forEach((candidate) => {
        const lookupId = normalizeLookupId(candidate.lookup_id);
        const selectedAttr = lookupId !== null && lookupId === selectedLookupId ? " selected" : "";
        options.push(
          `<option value="${escapeHtml(String(lookupId ?? ""))}"${selectedAttr}>${escapeHtml(buildRemoteLinkCandidateLabel(candidate))}</option>`
        );
      });
      return `<select class="${selectClasses.join(" ")}" data-id="${escapeHtml(row.platform_property_id || "")}">${options.join("")}</select>`;
    }

    function getRemoteAutoBadge(row) {
      const badges = [];
      if (row.is_linked_on_platform) {
        badges.push("Linked");
      } else if (isRemoteExistingPropertyWithoutListings(row)) {
        badges.push(`${buildExistingPropertyTargetLabel(row)} has no listings yet`);
      } else if (isRemoteSamePlatformMatchWithoutLink(row)) {
        badges.push("Same-platform match");
      } else if (row.is_auto_selected) {
        badges.push(`Lat/Lon match #${row.existing_property_id ?? "-"}`);
      }
      if (isRemoteLinkSelectionMissing(row)) badges.push("Select listing");
      if (!row.is_linked_on_platform && getRemoteSelectedLinkToLookupId(row) !== null) badges.push("Preselected");
      if (row.is_coordinate_duplicate) badges.push("Duplicate in fetched list");
      return badges.length ? badges.join(" | ") : "-";
    }

    function getRemoteColumnCellHtml(row, column) {
      if (column.key === "__select__") {
        const propertyIdRaw = String(row.platform_property_id || "");
        const checked = remoteSelectedIds.has(propertyIdRaw) ? "checked" : "";
        const propertyId = escapeHtml(row.platform_property_id || "");
        const disabled = isRemoteRowSelectionDisabled(row) ? "disabled" : "";
        const title = isRemoteExistingPropertyWithoutListings(row)
          ? `Check to confirm attaching this listing to ${buildExistingPropertyTargetLabel(row)} as its first listing`
          : "Check to include this property in import";
        return `<input type="checkbox" class="remote-row" data-id="${propertyId}" title="${escapeHtml(title)}" ${checked} ${disabled}>`;
      }
      if (column.key === "__latlon__") {
        const latitude = escapeHtml(row.latitude || "-");
        const longitude = escapeHtml(row.longitude || "-");
        return `${latitude}, ${longitude}`;
      }
      if (column.key === "__link_to__") {
        return renderRemoteLinkCell(row);
      }
      if (column.key === "__auto__") {
        return escapeHtml(getRemoteAutoBadge(row));
      }
      if (column.key === "__push_enabled__") {
        const pushEnabled = row?.raw && Object.prototype.hasOwnProperty.call(row.raw, "push_enabled")
          ? row.raw.push_enabled
          : null;
        return pushEnabled === null || pushEnabled === undefined ? "-" : escapeHtml(String(pushEnabled));
      }
      if (column.key === "public_url") {
        const rawValue = row.public_url || "";
        const safeValue = escapeHtml(rawValue || "-");
        if (!rawValue) return "-";
        return `<a href="${safeValue}" target="_blank" rel="noopener noreferrer" class="text-brand-700 underline dark:text-brand-200">${safeValue}</a>`;
      }
      return escapeHtml(row[column.key] || "-");
    }

    function renderRemoteRow(row) {
      const tr = document.createElement("tr");
      if (isRemoteRowSelectionDisabled(row)) {
        tr.className = "bg-rose-50/70 dark:bg-rose-900/10";
      } else if (isRemoteExistingPropertyWithoutListings(row)) {
        tr.className = "bg-sky-50/60 dark:bg-sky-900/10";
      } else if (isRemoteLinkSelectionMissing(row)) {
        tr.className = "bg-amber-50/60 dark:bg-amber-900/10";
      } else if (row.is_auto_selected) {
        tr.className = "bg-emerald-50/50 dark:bg-emerald-900/10";
      } else if (row.is_coordinate_duplicate) {
        tr.className = "bg-amber-50/60 dark:bg-amber-900/10";
      }
      tr.innerHTML = remoteColumnDefs.map((column) => {
        const className = column.className ? ` class="${column.className}"` : "";
        return `<td${className}>${getRemoteColumnCellHtml(row, column)}</td>`;
      }).join("");
      return tr;
    }

    function clearRemoteRows() {
      remoteCache = [];
      remoteSelectedIds = new Set();
      remoteCurrentPage = 1;
      renderRemoteRowsPage();
    }

    function setExistingPropertyLinksStatus(message, isError = false) {
      const status = document.getElementById("existing-property-links-status");
      status.textContent = message || "";
      status.className = isError
        ? "mt-3 text-xs text-rose-600 dark:text-rose-300"
        : "mt-3 text-xs text-slate-600 dark:text-slate-300";
    }

    function closeExistingPropertyLinksModal() {
      document.getElementById("existing-property-links-modal").classList.add("hidden");
      document.getElementById("existing-property-links-modal").classList.remove("flex");
      existingPropertyLinksModalState = { lookupId: null, items: [], propertyName: "", listingLabel: "", selectedTargetsByLookupId: {} };
      document.getElementById("existing-property-links-rows").innerHTML = "";
      setExistingPropertyLinksStatus("");
    }

    function buildLinkedListingStatus(item) {
      if (item.is_chain_head) return "Chain head";
      const targetPlatform = item.linked_to_platform_name || `Platform #${item.linked_to_platform_id ?? "-"}`;
      const targetListingName = item.linked_to_listing_name ? ` | ${item.linked_to_listing_name}` : "";
      const targetListingId = item.linked_to_platform_property_id || "-";
      return `Linked to ${targetPlatform}${targetListingName} | ${targetListingId}`;
    }

    function buildExistingPropertyLinkGraphInfo() {
      const items = Array.isArray(existingPropertyLinksModalState.items) ? existingPropertyLinksModalState.items : [];
      const byId = new Map();
      const adjacency = new Map();
      const incomingIds = new Set();

      items.forEach((item) => {
        const lookupId = normalizeLookupId(item.lookup_id);
        if (lookupId === null) return;
        byId.set(lookupId, item);
        adjacency.set(lookupId, new Set());
      });

      items.forEach((item) => {
        const lookupId = normalizeLookupId(item.lookup_id);
        const linkedToLookupId = normalizeLookupId(item.linked_to_lookup_id);
        if (lookupId === null || linkedToLookupId === null) return;
        if (!adjacency.has(linkedToLookupId)) {
          adjacency.set(linkedToLookupId, new Set());
        }
        adjacency.get(lookupId)?.add(linkedToLookupId);
        adjacency.get(linkedToLookupId)?.add(lookupId);
        incomingIds.add(linkedToLookupId);
      });

      const componentByLookupId = new Map();
      let nextComponentId = 1;
      adjacency.forEach((_, startLookupId) => {
        if (componentByLookupId.has(startLookupId)) return;
        const pending = [startLookupId];
        while (pending.length > 0) {
          const currentLookupId = pending.pop();
          if (currentLookupId === undefined || componentByLookupId.has(currentLookupId)) continue;
          componentByLookupId.set(currentLookupId, nextComponentId);
          const neighbors = adjacency.get(currentLookupId);
          if (!neighbors) continue;
          neighbors.forEach((neighborLookupId) => {
            if (!componentByLookupId.has(neighborLookupId)) {
              pending.push(neighborLookupId);
            }
          });
        }
        nextComponentId += 1;
      });

      const tailByComponentId = new Map();
      byId.forEach((item, lookupId) => {
        const componentId = componentByLookupId.get(lookupId);
        if (componentId === undefined || incomingIds.has(lookupId)) return;
        if (!tailByComponentId.has(componentId)) {
          tailByComponentId.set(componentId, item);
        }
      });

      return { byId, componentByLookupId, tailByComponentId };
    }

    function buildExistingPropertyLinkTargetLabel(item) {
      const platformName = item.platform_name || `Platform #${item.platform_id ?? "-"}`;
      const platformType = item.platform_type ? ` (${item.platform_type})` : "";
      const listingName = item.listing_name ? ` | ${item.listing_name}` : "";
      const listingId = item.platform_property_id || "-";
      return `${platformName}${platformType}${listingName} | ${listingId}`;
    }

    function getExistingPropertyLinkTargetOptions(sourceItem) {
      if (!sourceItem || !sourceItem.is_chain_head) return [];
      const sourceLookupId = normalizeLookupId(sourceItem.lookup_id);
      const sourcePlatformId = normalizeLookupId(sourceItem.platform_id);
      if (sourceLookupId === null || sourcePlatformId === null) return [];

      const graph = buildExistingPropertyLinkGraphInfo();
      const sourceComponentId = graph.componentByLookupId.get(sourceLookupId);
      const options = [];
      graph.tailByComponentId.forEach((tailItem, componentId) => {
        const tailLookupId = normalizeLookupId(tailItem.lookup_id);
        const tailPlatformId = normalizeLookupId(tailItem.platform_id);
        if (tailLookupId === null || tailPlatformId === null) return;
        if (componentId === sourceComponentId) return;
        if (tailPlatformId === sourcePlatformId) return;
        options.push(tailItem);
      });
      options.sort((left, right) => buildExistingPropertyLinkTargetLabel(left).localeCompare(buildExistingPropertyLinkTargetLabel(right)));
      return options;
    }

    function getExistingPropertySelectedTargetLookupId(sourceItem) {
      const sourceLookupId = normalizeLookupId(sourceItem?.lookup_id);
      if (sourceLookupId === null) return null;
      const storedValue = normalizeLookupId(existingPropertyLinksModalState.selectedTargetsByLookupId[String(sourceLookupId)]);
      if (storedValue !== null) return storedValue;
      const options = getExistingPropertyLinkTargetOptions(sourceItem);
      return options.length ? normalizeLookupId(options[0]?.lookup_id) : null;
    }

    function renderExistingPropertyLinksModalRows() {
      const tbody = document.getElementById("existing-property-links-rows");
      tbody.innerHTML = "";
      existingPropertyLinksModalState.items.forEach((item) => {
        const tr = document.createElement("tr");
        const canUnlink = !item.is_chain_head;
        const canLink = Boolean(item.is_chain_head);
        const unlinkDisabled = canUnlink ? "" : "disabled";
        const unlinkClasses = canUnlink
          ? "rounded border border-rose-200 bg-white/95 px-3 py-1 text-rose-700 transition hover:border-rose-300 hover:text-rose-800 dark:border-rose-400 dark:bg-slate-800 dark:text-rose-300 dark:hover:border-rose-300 dark:hover:text-rose-100"
          : "rounded border px-3 py-1 opacity-60 cursor-not-allowed";
        const linkOptions = getExistingPropertyLinkTargetOptions(item);
        const selectedTargetLookupId = getExistingPropertySelectedTargetLookupId(item);
        const linkDisabled = !canLink || selectedTargetLookupId === null ? "disabled" : "";
        const linkClasses = canLink && selectedTargetLookupId !== null
          ? "rounded border border-emerald-200 bg-white/95 px-3 py-1 text-emerald-700 transition hover:border-emerald-300 hover:text-emerald-800 dark:border-emerald-400 dark:bg-slate-800 dark:text-emerald-300 dark:hover:border-emerald-300 dark:hover:text-emerald-100"
          : "rounded border px-3 py-1 opacity-60 cursor-not-allowed";
        const linkSelectHtml = canLink
          ? (
              linkOptions.length > 0
                ? `<select class="control-surface existing-property-link-target-select w-full rounded border px-2 py-1 text-xs" data-source-lookup-id="${escapeHtml(item.lookup_id || "")}">${linkOptions
                    .map((targetItem) => {
                      const targetLookupId = normalizeLookupId(targetItem.lookup_id);
                      const selectedAttr = targetLookupId !== null && targetLookupId === selectedTargetLookupId ? " selected" : "";
                      return `<option value="${escapeHtml(String(targetLookupId ?? ""))}"${selectedAttr}>${escapeHtml(buildExistingPropertyLinkTargetLabel(targetItem))}</option>`;
                    })
                    .join("")}</select>`
                : '<span class="text-xs text-slate-400 dark:text-slate-500">No valid link targets</span>'
            )
          : '<span class="text-xs text-slate-400 dark:text-slate-500">Unlink first to link elsewhere</span>';
        tr.innerHTML = `
          <td>${escapeHtml(item.platform_name || `Platform #${item.platform_id ?? "-"}`)} (${escapeHtml(item.platform_type || "-")})</td>
          <td>${escapeHtml(item.listing_name || "-")}</td>
          <td class="font-mono text-xs">${escapeHtml(item.platform_property_id || "-")}</td>
          <td>${escapeHtml(buildLinkedListingStatus(item))}</td>
          <td>${linkSelectHtml}</td>
          <td><div class="flex flex-wrap items-center gap-2"><button type="button" class="${linkClasses}" data-action="link-chain-row" data-lookup-id="${escapeHtml(item.lookup_id || "")}" ${linkDisabled}>Link</button><button type="button" class="${unlinkClasses}" data-action="unlink-chain-row" data-lookup-id="${escapeHtml(item.lookup_id || "")}" ${unlinkDisabled}>Unlink</button></div></td>
        `;
        tbody.appendChild(tr);
      });
    }

    async function openExistingPropertyLinksModal({ lookupId, propertyName, listingLabel }) {
      const modal = document.getElementById("existing-property-links-modal");
      document.getElementById("existing-property-links-title").textContent = "Property Listings";
      document.getElementById("existing-property-links-subtitle").textContent = `${propertyName || "Property"} - ${listingLabel || "Listing"}`;
      setExistingPropertyLinksStatus("Loading property listings...");
      modal.classList.remove("hidden");
      modal.classList.add("flex");
      try {
        const res = await requestJSON(`/pwsadmin/api/platform-property-links/${lookupId}`);
        existingPropertyLinksModalState = {
          lookupId,
          items: Array.isArray(res.items) ? res.items : [],
          propertyName: propertyName || "",
          listingLabel: listingLabel || "",
          selectedTargetsByLookupId: {},
        };
        renderExistingPropertyLinksModalRows();
        setExistingPropertyLinksStatus(`Loaded ${existingPropertyLinksModalState.items.length} property listings.`);
      } catch (error) {
        existingPropertyLinksModalState = {
          lookupId,
          items: [],
          propertyName: propertyName || "",
          listingLabel: listingLabel || "",
          selectedTargetsByLookupId: {},
        };
        document.getElementById("existing-property-links-rows").innerHTML = "";
        setExistingPropertyLinksStatus(error.message, true);
      }
    }

    async function linkExistingPropertyLink(lookupId) {
      const sourceItem = existingPropertyLinksModalState.items.find((item) => normalizeLookupId(item.lookup_id) === lookupId);
      const targetLookupId = sourceItem ? getExistingPropertySelectedTargetLookupId(sourceItem) : null;
      if (targetLookupId === null) {
        setExistingPropertyLinksStatus("Choose a valid target listing first.", true);
        return;
      }
      try {
        await requestJSON(`/pwsadmin/api/platform-property-links/${lookupId}/link`, {
          method: "POST",
          body: JSON.stringify({ target_lookup_id: targetLookupId }),
        });
        setExistingPropertyLinksStatus("Listing linked.");
        await openExistingPropertyLinksModal({
          lookupId: existingPropertyLinksModalState.lookupId,
          propertyName: existingPropertyLinksModalState.propertyName,
          listingLabel: existingPropertyLinksModalState.listingLabel,
        });
      } catch (error) {
        setExistingPropertyLinksStatus(error.message, true);
      }
    }

    async function unlinkExistingPropertyLink(lookupId) {
      try {
        const res = await requestJSON(`/pwsadmin/api/platform-property-links/${lookupId}/unlink`, { method: "POST" });
        if (res && res.unlinked === false) {
          setExistingPropertyLinksStatus("That listing is already the chain head.");
          return;
        }
        setExistingPropertyLinksStatus("Listing unlinked.");
        await openExistingPropertyLinksModal({
          lookupId: existingPropertyLinksModalState.lookupId,
          propertyName: existingPropertyLinksModalState.propertyName,
          listingLabel: existingPropertyLinksModalState.listingLabel,
        });
      } catch (error) {
        setExistingPropertyLinksStatus(error.message, true);
      }
    }

    function setPropertiesSubtab(tab) {
      const nextTab = tab === "existing" ? "existing" : "import";
      activePropertiesSubtab = nextTab;
      activateSubtab("properties", nextTab, { syncUrl: sharedState.activeTab === "properties" });
      if (nextTab === "existing") {
        loadExistingPropertiesCoverage().catch((error) => setStatus(error.message, true));
      }
    }

    function setActivePropertyStage(stage) {
      if (!PROPERTY_STAGE_ORDER.includes(stage)) return;
      if (!isPropertyStageUnlocked(stage)) {
        const previousBlocked = getPreviousRequiredStageLabel(stage);
        setStatus(`Complete ${previousBlocked || "previous stage"} first.`, true);
        return;
      }
      activePropertyStage = stage;
      clearRemoteRows();
      refreshPropertyStageSelector();
    }

    async function loadPlatforms() {
      const res = await requestJSON("/pwsadmin/api/platforms");
      pricingPlatformsCache = res.items || [];
      const nonLlmPlatforms = pricingPlatformsCache.filter((item) => String(item.type || "").toLowerCase() !== "llm");
      setBookingPlatformNameLookup(pricingPlatformsCache);
      [document.getElementById("pricing-simple-platform"), document.getElementById("pricing-moderate-platform")].forEach((select) => {
        populateSelect(select, nonLlmPlatforms, {
          placeholder: "Select platform",
          getValue: (item) => String(item.id),
          getLabel: (item) => `${item.name} (${item.type})`,
        });
      });
      populateSelect(document.getElementById("pricing-listings-platform-filter"), nonLlmPlatforms, {
        placeholder: "All platforms",
        getValue: (item) => String(item.id),
        getLabel: (item) => `${item.name} (${item.type})`,
      });
      populateSelect(document.getElementById("platform-token-select"), pricingPlatformsCache, {
        placeholder: null,
        getValue: (item) => String(item.id),
        getLabel: (item) => `${item.name} (${item.type})`,
      });
      const stageStatus = await requestJSON("/pwsadmin/api/properties/stage-status");
      hydratePropertyStageCompletion(stageStatus);
      applyPropertyStageDefaults();
      refreshPropertyStageSelector();
      await syncPricingTargetScope("pricing-simple");
      await syncPricingTargetScope("pricing-moderate");
    }

    function setExistingPropertiesPaginationState(currentCount = 0) {
      const pageStatusEl = document.getElementById("existing-properties-pagination-status");
      const prevButton = document.getElementById("existing-properties-page-prev");
      const nextButton = document.getElementById("existing-properties-page-next");
      const totalPages = existingPropertiesTotalCount > 0
        ? Math.max(1, Math.ceil(existingPropertiesTotalCount / EXISTING_PROPERTIES_PAGE_SIZE))
        : 1;

      pageStatusEl.textContent = `Page ${existingPropertiesPage} of ${totalPages} - Showing ${currentCount} of ${existingPropertiesTotalCount} properties`;
      prevButton.disabled = existingPropertiesPage <= 1;
      nextButton.disabled = !existingPropertiesNextCursor;
      prevButton.classList.toggle("opacity-60", prevButton.disabled);
      prevButton.classList.toggle("cursor-not-allowed", prevButton.disabled);
      nextButton.classList.toggle("opacity-60", nextButton.disabled);
      nextButton.classList.toggle("cursor-not-allowed", nextButton.disabled);
    }

    async function loadExistingPropertiesCoverage({ page = 1, reset = false } = {}) {
      if (reset) {
        existingPropertiesPage = 1;
        existingPropertiesPageCursors = [null];
        existingPropertiesNextCursor = null;
      }

      const requestedPage = Math.max(1, Number(page) || 1);
      const requestedCursor = existingPropertiesPageCursors[requestedPage - 1];
      if (requestedCursor === undefined) {
        return;
      }

      const query = [`limit=${EXISTING_PROPERTIES_PAGE_SIZE}`];
      if (requestedCursor !== null) {
        query.push(`cursor=${encodeURIComponent(requestedCursor)}`);
      }
      const res = await requestJSON(`/pwsadmin/api/properties/coverage?${query.join("&")}`);
      const items = Array.isArray(res.items) ? res.items : [];
      const tbody = document.getElementById("existing-properties-rows");
      tbody.innerHTML = "";
      items.forEach((row) => {
        const listings = Array.isArray(row.listings) ? row.listings : [];
        const listingHtml = listings.length
          ? listings
              .map((item) => {
                const platformName = escapeHtml(item.platform_name || `Platform #${item.platform_id ?? "-"}`);
                const platformType = escapeHtml(item.platform_type || "-");
                const listingName = escapeHtml(item.listing_name || "");
                const platformPropertyId = escapeHtml(item.platform_property_id || "-");
                const lookupId = escapeHtml(item.lookup_id || "");
                const listingNameHtml = listingName
                  ? `<br><span class="font-medium">${listingName}</span>`
                  : "";
                const listingLabel = item.listing_name
                  ? `${item.listing_name} | ${item.platform_property_id || "-"}`
                  : `${item.platform_property_id || "-"}`;
                return `${platformName} (${platformType})${listingNameHtml}<br><button type="button" class="existing-property-chain-link font-mono text-xs text-brand-700 underline dark:text-brand-200" data-lookup-id="${lookupId}" data-property-name="${escapeHtml(row.property_name || "-")}" data-listing-label="${escapeHtml(listingLabel)}">${platformPropertyId}</button>`;
              })
              .join("<hr class=\"my-2 border-slate-200 dark:border-slate-700\">")
          : "<span class=\"text-slate-400 dark:text-slate-500\">Not linked</span>";
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td>${row.property_id ?? "-"}</td>
          <td>${escapeHtml(row.property_name || "-")}</td>
          <td class="font-mono text-xs">${escapeHtml(row.latitude || "-")}, ${escapeHtml(row.longitude || "-")}</td>
          <td>${listingHtml}</td>
        `;
        tbody.appendChild(tr);
      });

      existingPropertiesPage = requestedPage;
      existingPropertiesNextCursor = res.next_cursor ?? null;
      existingPropertiesTotalCount = Number(res.total_count || 0);
      if (existingPropertiesNextCursor !== null) {
        existingPropertiesPageCursors[requestedPage] = existingPropertiesNextCursor;
      } else if (existingPropertiesPageCursors.length > requestedPage) {
        existingPropertiesPageCursors = existingPropertiesPageCursors.slice(0, requestedPage);
      }
      setExistingPropertiesPaginationState(items.length);
      setStatus(`Existing properties: page ${existingPropertiesPage}, showing ${items.length} of ${existingPropertiesTotalCount}.`);
    }

    async function fetchRemote() {
      const platformEl = document.getElementById("platform-select");
      if (!isPropertyStageUnlocked(activePropertyStage)) {
        const previousBlocked = getPreviousRequiredStageLabel(activePropertyStage);
        setStatus(`Complete ${previousBlocked || "previous stage"} first.`, true);
        return;
      }
      if (!validateControl(platformEl, { required: true })) return;
      const pid = platformEl.value;
      try {
        const res = await requestJSON(`/pwsadmin/api/platforms/${pid}/properties/remote?fetch_all=true&per_page=100`);
        refreshRemoteTableColumns();
        const fetchedItems = Array.isArray(res.items) ? res.items : [];
        const annotatedItems = fetchedItems.map((item) => ({ ...item, is_coordinate_duplicate: false }));
        remoteCache = annotatedItems.map((item) => ({
          ...item,
          selected_link_to_lookup_id: normalizeLookupId(item.default_link_to_lookup_id),
        }));
        remoteSelectedIds = new Set();
        remoteCurrentPage = 1;
        renderRemoteRowsPage();
        const highlightedCount = remoteCache.filter((item) => Boolean(item.is_auto_selected)).length;
        const duplicateRowsCount = remoteCache.filter((item) => Boolean(item.is_coordinate_duplicate)).length;
        const selectionRequiredCount = remoteCache.filter((item) => isRemoteLinkSelectionMissing(item)).length;
        const blockedCount = remoteCache.filter((item) => isRemoteRowSelectionDisabled(item)).length;
        const firstListingCount = remoteCache.filter((item) => isRemoteExistingPropertyWithoutListings(item)).length;
        if (remoteCache.length === 0) {
          propertyStageCompleted[activePropertyStage] = true;
          renderPropertyStageButtons();
          updatePropertyStageHint();
        }
        const duplicateSuffix = duplicateRowsCount > 0
          ? ` Duplicate-coordinate rows in fetched list: ${duplicateRowsCount}.`
          : "";
        const selectionSuffix = selectionRequiredCount > 0
          ? ` Need listing choice: ${selectionRequiredCount}.`
          : "";
        const firstListingSuffix = firstListingCount > 0
          ? ` Existing properties without listings yet: ${firstListingCount}.`
          : "";
        const blockedSuffix = blockedCount > 0
          ? ` Blocked coordinate matches: ${blockedCount}.`
          : "";
        setStatus(`Fetched ${remoteCache.length} properties from ${PROPERTY_STAGE_LABELS[activePropertyStage]}. Highlighted ${highlightedCount}.${duplicateSuffix}${selectionSuffix}${firstListingSuffix}${blockedSuffix}`);
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    async function importRemote() {
      const platformEl = document.getElementById("platform-select");
      if (!isPropertyStageUnlocked(activePropertyStage)) {
        const previousBlocked = getPreviousRequiredStageLabel(activePropertyStage);
        setStatus(`Complete ${previousBlocked || "previous stage"} first.`, true);
        return;
      }
      if (!validateControl(platformEl, { required: true })) return;
      const pid = platformEl.value;
      const selected = Array.from(remoteSelectedIds);
      if (!selected.length) {
        setStatus("Select properties first", true);
        return;
      }
      const items = remoteCache.filter((r) => selected.includes(r.platform_property_id));
      const blockedRows = items.filter((row) => isRemoteRowSelectionDisabled(row));
      if (blockedRows.length > 0) {
        setStatus("Some selected rows cannot be imported because they are in a blocked coordinate-match state.", true);
        return;
      }
      const missingLinkSelections = items.filter((row) => isRemoteLinkSelectionMissing(row));
      if (missingLinkSelections.length > 0) {
        setStatus("Choose a listing in the Link To column for every matched row before importing.", true);
        return;
      }
      try {
        const payloadItems = items.map((row) => ({
          ...row,
          link_to_lookup_id: getRemoteSelectedLinkToLookupId(row),
        }));
        const result = await requestJSON(`/pwsadmin/api/platforms/${pid}/properties/import`, { method: "POST", body: JSON.stringify({ items: payloadItems }) });
        const importedCount = Array.isArray(result?.imported) ? result.imported.length : 0;
        const errorCount = Array.isArray(result?.errors) ? result.errors.length : 0;
        if (importedCount > 0 && errorCount === 0) {
          propertyStageCompleted[activePropertyStage] = true;
        }
        renderPropertyStageButtons();
        updatePropertyStageHint();
        setStatus(`Imported ${importedCount} properties (${errorCount} errors).`, errorCount > 0);
        const currentIndex = getPropertyStageIndex(activePropertyStage);
        const nextStage = PROPERTY_STAGE_ORDER.find((stage, index) => index > currentIndex && isPropertyStageUnlocked(stage));
        if (nextStage && nextStage !== activePropertyStage) {
          setActivePropertyStage(nextStage);
        }
      } catch (e) {
        setStatus(e.message, true);
      }
    }

    function escapeHtml(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
    }

    function normalizeHeaderName(value) {
      return String(value || "").trim().toLowerCase();
    }

    function humanizePropertyName(value) {
      const text = String(value || "").trim();
      if (!text) return "";
      return text
        .replaceAll("_", " ")
        .replaceAll("-", " ")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/\b\w/g, (ch) => ch.toUpperCase());
    }

    function humanizeObjectKeys(value) {
      if (Array.isArray(value)) return value.map((item) => humanizeObjectKeys(item));
      if (!isObjectLike(value)) return value;
      const next = {};
      Object.entries(value).forEach(([key, child]) => {
        next[humanizePropertyName(key)] = humanizeObjectKeys(child);
      });
      return next;
    }

    function setPlatformTokenStatus(data) {
      const statusEl = document.getElementById("platform-token-status");
      statusEl.textContent = renderYmf(humanizeObjectKeys(data));
    }

    function formatInteger(value) {
      if (value === null || value === undefined || value === "") return "-";
      const number = Number(value);
      if (!Number.isFinite(number)) return "-";
      return new Intl.NumberFormat().format(number);
    }

    function formatLatency(value) {
      if (value === null || value === undefined || value === "") return "-";
      const number = Number(value);
      if (!Number.isFinite(number)) return "-";
      return number >= 1000 ? `${(number / 1000).toFixed(1)}s` : `${Math.round(number)}ms`;
    }

    function formatEstimatedCost(value, status, currency = "USD") {
      if (status === "unknown_tokens") return "-";
      if (status === "not_priced") return "Not priced";
      if (value === null || value === undefined || value === "") return "-";
      const number = Number(value);
      if (!Number.isFinite(number)) return "-";
      return `${currency === "USD" ? "$" : `${currency} `}${number.toFixed(number < 0.01 ? 6 : 4)}`;
    }

    function todayIsoDate() {
      return new Date().toISOString().slice(0, 10);
    }

    function daysAgoIsoDate(days) {
      const date = new Date();
      date.setUTCDate(date.getUTCDate() - days);
      return date.toISOString().slice(0, 10);
    }

    function getTokenInputLabel(item) {
      const headerName = normalizeHeaderName(item?.header_name);
      if (headerName === "x-integration-api-key") return "RM API Key";
      if (headerName === "x-user-access-key") return "Access Key";
      if (headerName === "x-user-api-key") return "API Key";
      return String(item?.title || item?.token_key || "Token");
    }

    function findTokenCard(tokenKey) {
      return Array.from(document.querySelectorAll("[data-token-key]")).find((row) => row.dataset.tokenKey === tokenKey) || null;
    }

    function getRequiredTokenItems() {
      return platformTokenItems.filter((item) => item && item.required !== false);
    }

    function getMissingRequiredTokenLabels() {
      const requiredItems = getRequiredTokenItems();
      if (requiredItems.length <= 1) return [];
      return requiredItems
        .filter((item) => {
          const tokenKey = String(item.token_key || "");
          const card = findTokenCard(tokenKey);
          const input = card?.querySelector('input[name="secret"]');
          const hasInputValue = Boolean(input && input.value.trim());
          return !hasInputValue && !item.configured;
        })
        .map((item) => getTokenInputLabel(item));
    }

    function collectEnteredTokenSecrets() {
      const entered = {};
      getRequiredTokenItems().forEach((item) => {
        const tokenKey = String(item.token_key || "");
        if (!tokenKey) return;
        const card = findTokenCard(tokenKey);
        const input = card?.querySelector('input[name="secret"]');
        const value = input ? input.value.trim() : "";
        if (value) entered[tokenKey] = value;
      });
      return entered;
    }

    function updatePlatformTokenSaveButtons(options = {}) {
      const { showStatus = false } = options;
      const missingRequired = getMissingRequiredTokenLabels();
      const saveButtons = Array.from(document.querySelectorAll('#platform-token-list button[data-action="save"]'));
      saveButtons.forEach((button) => {
        const card = button.closest("[data-token-key]");
        const input = card?.querySelector('input[name="secret"]');
        const hasValue = Boolean(input && input.value.trim());
        const shouldDisable = missingRequired.length > 0 || !hasValue;
        button.disabled = shouldDisable;
        button.classList.toggle("cursor-not-allowed", shouldDisable);
        button.classList.toggle("opacity-60", shouldDisable);
      });
      if (showStatus && missingRequired.length > 0) {
        setStatus(`Enter all required keys before saving: ${missingRequired.join(", ")}`, true);
      }
      return missingRequired.length === 0;
    }

    function renderPlatformTokenList(items) {
      const listEl = document.getElementById("platform-token-list");
      listEl.innerHTML = "";
      if (!items.length) {
        listEl.innerHTML = `<div class="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-700 dark:bg-amber-900/40 dark:text-amber-100">No API token slots are configured in platform metadata.</div>`;
        return;
      }
      items.forEach((item) => {
        const tokenKey = String(item.token_key || "");
        const card = document.createElement("div");
        card.className = "control-surface rounded border p-3";
        card.dataset.tokenKey = tokenKey;
        const isRequired = item.required !== false;
        const tokenLabel = getTokenInputLabel(item);
        const headerLabel = item.header_name ? `Header: ${escapeHtml(item.header_name)}` : "Header: (not set)";
        const authType = item.auth_type ? `Type: ${escapeHtml(item.auth_type)}` : "Type: (not set)";
        const requirementLabel = isRequired ? "Required" : "Optional";
        const secretIdText = item.secret_id ? `secret_id: ${item.secret_id}` : "secret_id: -";
        const statusText = item.configured ? "Configured" : "Not configured";
        card.innerHTML = `
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div>
              <p class="text-sm font-semibold text-slate-800 dark:text-slate-100">${escapeHtml(tokenLabel)}</p>
              <p class="text-xs text-slate-500 dark:text-slate-300">${headerLabel} | ${authType} | ${requirementLabel}</p>
            </div>
            <div class="text-right text-xs text-slate-600 dark:text-slate-300">
              <div>${statusText}</div>
              <div>${secretIdText}</div>
            </div>
          </div>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <input name="secret" type="password" placeholder="Enter ${escapeHtml(tokenLabel)}" class="control-surface min-w-[260px] flex-1 rounded border px-2 py-1" ${isRequired ? "required" : ""} />
            <button type="button" data-action="save" class="rounded bg-brand-600 px-3 py-1 text-white">Save</button>
            <button type="button" data-action="delete" class="rounded border border-rose-200 bg-white/95 px-3 py-1 text-rose-700 transition hover:border-rose-300 hover:text-rose-800 dark:border-rose-400 dark:bg-slate-800 dark:text-rose-300 dark:hover:border-rose-300 dark:hover:text-rose-100">Delete</button>
          </div>
        `;
        listEl.appendChild(card);
      });
    }

    async function loadPlatformTokens() {
      const platformEl = document.getElementById("platform-token-select");
      if (!validateControl(platformEl, { required: true })) return;
      const platformId = platformEl.value.trim();
      try {
        const res = await requestJSON(`/pwsadmin/api/platforms/${platformId}/api-tokens`);
        platformTokenItems = res.items || [];
        renderPlatformTokenList(platformTokenItems);
        updatePlatformTokenSaveButtons();
        setPlatformTokenStatus(res);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    async function savePlatformToken(tokenKey) {
      const platformEl = document.getElementById("platform-token-select");
      if (!validateControl(platformEl, { required: true })) return;
      const card = Array.from(document.querySelectorAll("[data-token-key]")).find((row) => row.dataset.tokenKey === tokenKey);
      if (!card) return;
      const secretInput = card.querySelector('input[name="secret"]');
      if (!secretInput) return;
      if (!updatePlatformTokenSaveButtons({ showStatus: true })) return;
      const trimmed = secretInput.value.trim();
      if (!trimmed) {
        setStatus("Blank token ignored. Enter a value to save.", false);
        return;
      }
      if (!validateControl(secretInput)) return;
      const platformId = platformEl.value.trim();
      const enteredSecrets = collectEnteredTokenSecrets();
      enteredSecrets[tokenKey] = trimmed;
      const tokenKeysToSave = [tokenKey, ...Object.keys(enteredSecrets).filter((key) => key !== tokenKey)];
      try {
        let lastResponse = null;
        for (const keyToSave of tokenKeysToSave) {
          const value = enteredSecrets[keyToSave];
          if (!value) continue;
          lastResponse = await requestJSON(
            `/pwsadmin/api/platforms/${platformId}/api-tokens/${encodeURIComponent(keyToSave)}`,
            {
              method: "PUT",
              body: JSON.stringify({ secret: value, validation_overrides: enteredSecrets }),
            },
          );
        }
        const res = lastResponse || null;
        if (res) {
          setPlatformTokenStatus(res);
        }
        await loadPlatformTokens();
        const validation = res && typeof res === "object" ? res.validation : null;
        if (validation) {
          const suffix = validation.status_code ? ` (status ${validation.status_code})` : "";
          const pendingSuffix = validation.checked ? "" : " (validation pending)";
          setStatus(`${validation.message || "Token validation complete"}${suffix}${pendingSuffix}`, !validation.ok);
          return;
        }
        if (tokenKeysToSave.length > 1) {
          setStatus(`Saved tokens for ${tokenKeysToSave.join(", ")}.`, false);
          return;
        }
        setStatus(`Saved token for ${tokenKey}.`, false);
      } catch (error) {
        if (error?.responseBody) {
          setPlatformTokenStatus(error.responseBody);
        }
        setStatus(error.message, true);
      }
    }

    async function deletePlatformToken(tokenKey) {
      const platformEl = document.getElementById("platform-token-select");
      if (!validateControl(platformEl, { required: true })) return;
      const platformId = platformEl.value.trim();
      try {
        await requestJSON(
          `/pwsadmin/api/platforms/${platformId}/api-tokens/${encodeURIComponent(tokenKey)}`,
          { method: "DELETE" },
        );
        await loadPlatformTokens();
        setStatus(`Deleted token pointer for ${tokenKey}.`, false);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    function getSelectedLlmProvider() {
      const providerId = String(document.getElementById("llm-provider-settings-select").value || "");
      return llmProviderItems.find((item) => String(item.id) === providerId) || null;
    }

    function getSelectedLlmProviderModel() {
      const customEl = document.getElementById("llm-provider-model-custom");
      const modelEl = document.getElementById("llm-provider-model");
      return (customEl.value || "").trim() || (modelEl.value || "").trim();
    }

    function setLlmProviderStatus(message, isError = false) {
      const statusEl = document.getElementById("llm-provider-settings-status");
      statusEl.textContent = message;
      statusEl.classList.toggle("text-red-600", Boolean(isError));
      statusEl.classList.toggle("dark:text-red-300", Boolean(isError));
    }

    function renderLlmProviderSettings(provider) {
      const statusEl = document.getElementById("llm-provider-settings-status");
      const modelEl = document.getElementById("llm-provider-model");
      const customModelEl = document.getElementById("llm-provider-model-custom");
      const timeoutEl = document.getElementById("llm-provider-timeout");
      const enabledEl = document.getElementById("llm-provider-enabled");
      const keyEl = document.getElementById("llm-provider-api-key");
      if (!provider) {
        modelEl.innerHTML = '<option value="">No models</option>';
        customModelEl.value = "";
        timeoutEl.value = "";
        enabledEl.checked = false;
        keyEl.value = "";
        keyEl.disabled = false;
        setLlmProviderStatus("No LLM provider configured.");
        return;
      }
      const allowedModels = Array.isArray(provider.allowed_models) ? provider.allowed_models : [];
      const selectedModel = provider.selected_model || "gpt-5-nano";
      const modelOptions = allowedModels.includes(selectedModel) ? allowedModels : allowedModels;
      modelEl.innerHTML = modelOptions.map((model) => `<option value="${escapeHtml(model)}">${escapeHtml(model)}</option>`).join("");
      if (modelOptions.includes(selectedModel)) {
        modelEl.value = selectedModel;
        customModelEl.value = "";
      } else {
        modelEl.value = modelOptions[0] || "";
        customModelEl.value = selectedModel;
      }
      timeoutEl.value = provider.timeout_seconds || 60;
      enabledEl.checked = Boolean(provider.enabled);
      keyEl.value = "";
      keyEl.disabled = !Boolean(provider.requires_api_key);
      keyEl.placeholder = provider.requires_api_key ? "Enter API key" : "No API key required";
      const keyStatus = provider.requires_api_key
        ? `API key: ${provider.api_key_configured ? "Configured" : "Not configured"}.`
        : "No API key required.";
      setLlmProviderStatus(`${provider.display_name || provider.provider_key} ${keyStatus}`);
    }

    async function loadLlmProviders() {
      if (!currentUserProfile?.is_admin) {
        document.getElementById("llm-provider-settings-panel").classList.add("hidden");
        document.getElementById("llm-provider-settings-status").textContent = "Admin access required to manage LLM providers.";
        return;
      }
      document.getElementById("llm-provider-settings-panel").classList.remove("hidden");
      const res = await requestJSON("/pwsadmin/api/llm-providers");
      llmProviderItems = res.items || [];
      populateSelect(document.getElementById("llm-provider-settings-select"), llmProviderItems, {
        placeholder: null,
        getValue: (item) => String(item.id),
        getLabel: (item) => `${item.display_name || item.provider_key}${item.enabled ? " (enabled)" : ""}`,
      });
      renderLlmProviderSettings(getSelectedLlmProvider());
    }

    async function saveLlmProviderApiKey() {
      const provider = getSelectedLlmProvider();
      const keyEl = document.getElementById("llm-provider-api-key");
      if (!provider || !validateControl(document.getElementById("llm-provider-settings-select"), { required: true })) return;
      if (!provider.requires_api_key) {
        setLlmProviderStatus("This provider does not require an API key.");
        return;
      }
      const secret = keyEl.value.trim();
      if (!secret) {
        setStatus("Enter an API key before saving.", true);
        return;
      }
      try {
        const updated = await requestJSON(`/pwsadmin/api/llm-providers/${provider.id}/api-key`, {
          method: "PUT",
          body: JSON.stringify({ secret }),
        });
        const index = llmProviderItems.findIndex((item) => String(item.id) === String(updated.id));
        if (index >= 0) llmProviderItems[index] = updated;
        renderLlmProviderSettings(updated);
        setStatus("Saved LLM provider API key.", false);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    async function checkLlmProviderHealth() {
      const provider = getSelectedLlmProvider();
      const providerEl = document.getElementById("llm-provider-settings-select");
      const modelEl = document.getElementById("llm-provider-model");
      const customModelEl = document.getElementById("llm-provider-model-custom");
      const timeoutEl = document.getElementById("llm-provider-timeout");
      const keyEl = document.getElementById("llm-provider-api-key");
      if (!provider || !validateControls([providerEl, timeoutEl], { required: true })) return null;
      if (customModelEl.value.trim() && !validateControl(customModelEl, { required: true })) return null;
      if (!customModelEl.value.trim() && !validateControl(modelEl, { required: true })) return null;
      const payload = {
        model: getSelectedLlmProviderModel(),
        timeout_seconds: Number(timeoutEl.value),
      };
      if (provider.requires_api_key && keyEl.value.trim()) payload.api_key = keyEl.value.trim();
      try {
        setLlmProviderStatus("Checking LLM provider...");
        const res = await requestJSON(`/pwsadmin/api/llm-providers/${provider.id}/health-check`, {
          method: "POST",
          body: JSON.stringify(payload),
        });
        const suffix = res.latency_ms === null || res.latency_ms === undefined ? "" : ` (${res.latency_ms} ms)`;
        if (res.accessible) {
          setLlmProviderStatus(`Provider check passed for ${res.provider_key}/${res.model}${suffix}.`);
        } else {
          setLlmProviderStatus(`Provider check failed: ${res.error_message || res.error_code || "unknown error"}`, true);
        }
        return res;
      } catch (error) {
        setLlmProviderStatus(error.message, true);
        return null;
      }
    }

    async function saveLlmProviderSettings() {
      const provider = getSelectedLlmProvider();
      const providerEl = document.getElementById("llm-provider-settings-select");
      const modelEl = document.getElementById("llm-provider-model");
      const customModelEl = document.getElementById("llm-provider-model-custom");
      const timeoutEl = document.getElementById("llm-provider-timeout");
      const enabledEl = document.getElementById("llm-provider-enabled");
      if (!provider || !validateControls([providerEl, timeoutEl], { required: true })) return;
      if (customModelEl.value.trim() && !validateControl(customModelEl, { required: true })) return;
      if (!customModelEl.value.trim() && !validateControl(modelEl, { required: true })) return;
      const selectedModel = getSelectedLlmProviderModel();
      const allowedModels = Array.isArray(provider.allowed_models) ? [...provider.allowed_models] : [];
      if (selectedModel && !allowedModels.includes(selectedModel)) allowedModels.push(selectedModel);
      const payload = {
        selected_model: selectedModel,
        timeout_seconds: Number(timeoutEl.value),
        enabled: Boolean(enabledEl.checked),
        allowed_models: allowedModels,
      };
      try {
        if (payload.enabled) setLlmProviderStatus("Activating provider after accessibility check...");
        const updated = await requestJSON(`/pwsadmin/api/llm-providers/${provider.id}/settings`, {
          method: "PUT",
          body: JSON.stringify(payload),
        });
        const index = llmProviderItems.findIndex((item) => String(item.id) === String(updated.id));
        if (index >= 0) llmProviderItems[index] = updated;
        llmProviderItems = llmProviderItems.map((item) => (
          String(item.id) === String(updated.id) ? updated : { ...item, enabled: payload.enabled ? false : item.enabled }
        ));
        await loadLlmProviders();
        setLlmProviderStatus(payload.enabled ? "Saved and activated LLM provider." : "Saved LLM provider settings.");
        setStatus(payload.enabled ? "Saved and activated LLM provider." : "Saved LLM provider settings.", false);
      } catch (error) {
        const health = error.responseBody?.detail?.health;
        if (health) {
          setLlmProviderStatus(`Activation failed: ${health.error_message || health.error_code || error.message}`, true);
        } else {
          setLlmProviderStatus(error.message, true);
        }
        setStatus(error.message, true);
      }
    }

    function setLlmSubtab(tab) {
      const nextTab = ["usage", "providers", "pricing"].includes(tab) ? tab : "usage";
      activeLlmSubtab = nextTab;
      activateSubtab("llm-usage", nextTab, { syncUrl: sharedState.activeTab === "llm-usage" });
      if (nextTab === "providers" && currentUserProfile?.is_admin) {
        loadLlmProviders().catch((error) => setStatus(error.message, true));
      } else if (nextTab === "providers") {
        document.getElementById("llm-provider-settings-panel").classList.add("hidden");
        setStatus("Admin access required to manage LLM providers.", true);
      }
      if (nextTab === "pricing") {
        loadLlmPricing().catch((error) => setStatus(error.message, true));
      }
    }

    function setLlmPricingStatus(message, isError = false) {
      const statusEl = document.getElementById("llm-pricing-status");
      statusEl.textContent = message;
      statusEl.classList.toggle("text-red-600", Boolean(isError));
      statusEl.classList.toggle("dark:text-red-300", Boolean(isError));
    }

    function resetLlmPricingForm() {
      document.getElementById("llm-pricing-provider").value = "";
      document.getElementById("llm-pricing-model").value = "";
      document.getElementById("llm-pricing-input").value = "0";
      document.getElementById("llm-pricing-output").value = "0";
      document.getElementById("llm-pricing-currency").value = "USD";
      document.getElementById("llm-pricing-active").checked = true;
      setLlmPricingStatus("");
    }

    function populateLlmPricingForm(item) {
      document.getElementById("llm-pricing-provider").value = item.provider || "";
      document.getElementById("llm-pricing-model").value = item.model || "";
      document.getElementById("llm-pricing-input").value = item.input_price_per_1m_tokens ?? 0;
      document.getElementById("llm-pricing-output").value = item.output_price_per_1m_tokens ?? 0;
      document.getElementById("llm-pricing-currency").value = item.currency || "USD";
      document.getElementById("llm-pricing-active").checked = item.is_active !== false;
      setLlmSubtab("pricing");
      setLlmPricingStatus(`Editing pricing for ${item.provider || "-"} / ${item.model || "-"}.`);
    }

    async function openLlmPricingForProviderModel(item) {
      setLlmSubtab("pricing");
      await loadLlmPricing();
      const match = llmPricingItems.find((row) => row.provider === item.provider && row.model === item.model);
      populateLlmPricingForm(match || item);
    }

    function renderLlmPricingRows(rows) {
      const tbody = document.getElementById("llm-pricing-rows");
      if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="9" class="py-4 text-center text-slate-500">No LLM pricing or usage models found.</td></tr>`;
        return;
      }
      tbody.innerHTML = rows.map((row) => {
        const configured = Boolean(row.pricing_configured);
        const isActive = Boolean(row.is_active);
        const statusText = configured ? (isActive ? "Active" : "Inactive") : "Not priced";
        const editPayload = encodeURIComponent(JSON.stringify(row));
        const deactivateButton = configured && isActive && currentUserProfile?.is_admin
          ? `<button type="button" class="secondary-btn rounded border px-2 py-0.5 text-xs" data-llm-pricing-deactivate="${editPayload}">Deactivate</button>`
          : "";
        const editButton = currentUserProfile?.is_admin
          ? `<button type="button" class="secondary-btn rounded border px-2 py-0.5 text-xs" data-llm-pricing-edit="${editPayload}">${configured ? "Edit" : "Set Price"}</button>`
          : "-";
        return `
          <tr>
            <td>${escapeHtml(row.provider || "-")}</td>
            <td>${escapeHtml(row.model || "-")}</td>
            <td>${configured ? escapeHtml(String(row.input_price_per_1m_tokens ?? 0)) : "-"}</td>
            <td>${configured ? escapeHtml(String(row.output_price_per_1m_tokens ?? 0)) : "-"}</td>
            <td>${escapeHtml(row.currency || "USD")}</td>
            <td>${escapeHtml(statusText)}</td>
            <td>${formatInteger(row.usage_count || 0)}</td>
            <td>${escapeHtml(row.last_used_at ? formatDateTimeInBrowserTimezone(row.last_used_at) : "-")}</td>
            <td><div class="flex flex-wrap gap-2">${editButton}${deactivateButton}</div></td>
          </tr>
        `;
      }).join("");
    }

    async function loadLlmPricing() {
      const adminPanel = document.getElementById("llm-pricing-admin-panel");
      adminPanel.classList.toggle("hidden", !currentUserProfile?.is_admin);
      const res = await requestJSON("/pwsadmin/api/llm-model-pricing");
      llmPricingItems = res.items || [];
      renderLlmPricingRows(llmPricingItems);
      setLlmPricingStatus(currentUserProfile?.is_admin ? `Loaded ${llmPricingItems.length} pricing row(s).` : "Admin access required to edit pricing.");
    }

    async function saveLlmPricing() {
      const controls = ["llm-pricing-provider", "llm-pricing-model", "llm-pricing-input", "llm-pricing-output", "llm-pricing-currency"].map((id) => document.getElementById(id));
      if (!validateControls(controls, { required: true })) return;
      const provider = document.getElementById("llm-pricing-provider").value.trim();
      const model = document.getElementById("llm-pricing-model").value.trim();
      const payload = {
        input_price_per_1m_tokens: Number(document.getElementById("llm-pricing-input").value),
        output_price_per_1m_tokens: Number(document.getElementById("llm-pricing-output").value),
        currency: document.getElementById("llm-pricing-currency").value.trim().toUpperCase() || "USD",
        is_active: Boolean(document.getElementById("llm-pricing-active").checked),
      };
      try {
        await requestJSON(`/pwsadmin/api/llm-model-pricing/${encodeURIComponent(provider)}/${encodeURIComponent(model)}`, {
          method: "PUT",
          body: JSON.stringify(payload),
        });
        setLlmPricingStatus(`Saved pricing for ${provider} / ${model}.`);
        await loadLlmPricing();
        await loadLlmUsage(false);
      } catch (error) {
        setLlmPricingStatus(error.message, true);
        setStatus(error.message, true);
      }
    }

    async function deactivateLlmPricing(item) {
      if (!item?.provider || !item?.model) return;
      try {
        await requestJSON(`/pwsadmin/api/llm-model-pricing/${encodeURIComponent(item.provider)}/${encodeURIComponent(item.model)}`, {
          method: "DELETE",
        });
        setLlmPricingStatus(`Deactivated pricing for ${item.provider} / ${item.model}.`);
        await loadLlmPricing();
        await loadLlmUsage(false);
      } catch (error) {
        setLlmPricingStatus(error.message, true);
        setStatus(error.message, true);
      }
    }

    function populateSimpleSelect(select, values, placeholder) {
      const current = select.value;
      const options = [`<option value="">${escapeHtml(placeholder)}</option>`];
      (values || []).forEach((value) => {
        options.push(`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`);
      });
      select.innerHTML = options.join("");
      if (current && (values || []).includes(current)) select.value = current;
    }

    function renderLlmSummary(summary) {
      const el = document.getElementById("llm-summary");
      const cards = [
        ["Requests", formatInteger(summary.request_count)],
        ["Successful", formatInteger(summary.success_count)],
        ["Failed", formatInteger(summary.failure_count)],
        ["Total Tokens", formatInteger(summary.total_tokens)],
        ["Prompt Tokens", formatInteger(summary.prompt_tokens)],
        ["Completion Tokens", formatInteger(summary.completion_tokens)],
        ["Estimated Cost", formatEstimatedCost(summary.estimated_cost, "estimated")],
        ["Avg Latency", formatLatency(summary.avg_latency_ms)],
      ];
      el.innerHTML = cards.map(([label, value]) => `
        <div class="control-surface rounded border p-3">
          <div class="text-xs uppercase text-slate-500 dark:text-slate-400">${escapeHtml(label)}</div>
          <div class="mt-1 text-lg font-semibold text-slate-900 dark:text-slate-100">${escapeHtml(value)}</div>
        </div>
      `).join("");
    }

    function renderLlmBreakdown(rows) {
      const tbody = document.getElementById("llm-breakdown-rows");
      if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="11" class="py-4 text-center text-slate-500">No LLM usage found for these filters.</td></tr>`;
        return;
      }
      tbody.innerHTML = rows.map((row) => {
        const pricingItem = {
          provider: row.provider || "",
          model: row.model || "",
          input_price_per_1m_tokens: 0,
          output_price_per_1m_tokens: 0,
          currency: "USD",
          is_active: true,
          pricing_configured: false,
        };
        const pricingButton = currentUserProfile?.is_admin
          ? `<button type="button" class="secondary-btn rounded border px-2 py-0.5 text-xs" data-llm-set-price="${encodeURIComponent(JSON.stringify(pricingItem))}">${row.unpriced_count ? "Set Price" : "Edit Price"}</button>`
          : "-";
        return `
          <tr>
            <td>${escapeHtml(row.action_name || "-")}</td>
            <td>${escapeHtml(row.provider || "-")}</td>
            <td>${escapeHtml(row.model || "-")}</td>
            <td>${formatInteger(row.request_count)}</td>
            <td>${formatInteger(row.total_tokens)}</td>
            <td>${formatInteger(row.prompt_tokens)}</td>
            <td>${formatInteger(row.completion_tokens)}</td>
            <td>${row.unpriced_count ? "Not priced" : formatEstimatedCost(row.estimated_cost, "estimated")}</td>
            <td>${pricingButton}</td>
            <td>${formatLatency(row.avg_latency_ms)}</td>
            <td>${formatInteger(row.failure_count)}</td>
          </tr>
        `;
      }).join("");
    }

    function llmDetailMarkup(row) {
      return `
        <tr class="hidden bg-slate-50 text-xs dark:bg-slate-950/40" data-llm-detail="${escapeHtml(String(row.id))}">
          <td></td>
          <td colspan="12">
            <pre class="whitespace-pre-wrap">${escapeHtml(renderYmf(humanizeObjectKeys({
              usage_id: row.id,
              worker_name: row.worker_name,
              task_uuid: row.task_uuid,
              response_id: row.response_id,
              error_message: row.error_message,
              metadata: row.metadata || {},
            })))}</pre>
          </td>
        </tr>
      `;
    }

    function renderLlmUsageRows(rows) {
      const tbody = document.getElementById("llm-usage-rows");
      if (!rows.length) {
        tbody.innerHTML = `<tr><td colspan="13" class="py-4 text-center text-slate-500">No LLM usage found for these filters.</td></tr>`;
        return;
      }
      tbody.innerHTML = rows.map((row) => {
        const statusText = row.success ? "Success" : "Failed";
        const statusClass = row.success ? "text-emerald-700 dark:text-emerald-300" : "text-rose-700 dark:text-rose-300";
        return `
          <tr class="${row.success ? "" : "bg-rose-50/60 dark:bg-rose-950/20"}">
            <td><button type="button" class="secondary-btn rounded border px-2 py-0.5 text-xs" data-llm-toggle="${escapeHtml(String(row.id))}">Details</button></td>
            <td>${escapeHtml(formatDateTimeInBrowserTimezone(row.created_at))}</td>
            <td class="font-mono text-xs">${escapeHtml(row.task_uuid || "-")}</td>
            <td>${escapeHtml(row.action_name || "-")}</td>
            <td>${escapeHtml(row.provider || "-")}</td>
            <td>${escapeHtml(row.model || "-")}</td>
            <td>${formatInteger(row.prompt_tokens)}</td>
            <td>${formatInteger(row.completion_tokens)}</td>
            <td>${formatInteger(row.total_tokens)}</td>
            <td>${escapeHtml(formatEstimatedCost(row.estimated_cost, row.cost_status, row.currency || "USD"))}</td>
            <td>${formatLatency(row.latency_ms)}</td>
            <td class="${statusClass}">${statusText}</td>
            <td>${escapeHtml(row.error_code || "-")}</td>
          </tr>
          ${llmDetailMarkup(row)}
        `;
      }).join("");
    }

    function buildLlmUsageQuery(next = false) {
      const params = [];
      const fields = [
        ["from", "llm-from"],
        ["to", "llm-to"],
        ["provider", "llm-provider"],
        ["model", "llm-model"],
        ["action", "llm-action"],
        ["success", "llm-success"],
        ["task_uuid", "llm-task-uuid"],
        ["min_tokens", "llm-min-tokens"],
      ];
      fields.forEach(([key, id]) => {
        const value = document.getElementById(id).value.trim();
        if (value) params.push(`${key}=${encodeURIComponent(value)}`);
      });
      if (next && llmUsageCursor) params.push(`cursor=${encodeURIComponent(llmUsageCursor)}`);
      params.push("limit=100");
      return params.join("&");
    }

    async function loadLlmUsage(next = false) {
      const controls = ["llm-from", "llm-to", "llm-min-tokens"].map((id) => document.getElementById(id));
      if (!validateControls(controls)) return;
      try {
        const res = await requestJSON(`/pwsadmin/api/llm-usage?${buildLlmUsageQuery(next)}`);
        renderLlmSummary(res.summary || {});
        renderLlmBreakdown(res.breakdown?.by_model_action || []);
        renderLlmUsageRows(res.items || []);
        populateSimpleSelect(document.getElementById("llm-provider"), res.filters?.providers || [], "All providers");
        populateSimpleSelect(document.getElementById("llm-model"), res.filters?.models || [], "All models");
        populateSimpleSelect(document.getElementById("llm-action"), res.filters?.actions || [], "All actions");
        llmUsageCursor = res.next_cursor || null;
        llmUsageHasNext = Boolean(llmUsageCursor);
        document.getElementById("llm-next").disabled = !llmUsageHasNext;
        setStatus(`Loaded ${(res.items || []).length} LLM usage row(s).`, false);
      } catch (error) {
        setStatus(error.message, true);
      }
    }

    function resetLlmUsageFilters() {
      document.getElementById("llm-from").value = daysAgoIsoDate(7);
      document.getElementById("llm-to").value = todayIsoDate();
      ["llm-provider", "llm-model", "llm-action", "llm-success", "llm-task-uuid", "llm-min-tokens"].forEach((id) => {
        document.getElementById(id).value = "";
      });
      llmUsageCursor = null;
    }

    document.getElementById("task-apply").addEventListener("click", () => loadTasks(false));
    document.getElementById("task-next").addEventListener("click", () => loadTasks(true));
    document.getElementById("task-enqueue-form").addEventListener("submit", submitTaskEnqueue);
    document.getElementById("task-enqueue-refresh").addEventListener("click", loadTaskEnqueueOptions);
    document.getElementById("task-enqueue-reset").addEventListener("click", resetTaskEnqueueForm);
    document.getElementById("task-enqueue-queue").addEventListener("change", renderTaskEnqueueWorkers);
    document.getElementById("log-apply").addEventListener("click", () => loadLogs(false));
    document.getElementById("log-next").addEventListener("click", () => loadLogs(true));
    document.getElementById("worker-refresh").addEventListener("click", () => loadWorkers(false));
    document.getElementById("worker-next").addEventListener("click", () => loadWorkers(true));
    document.getElementById("worker-active-only").addEventListener("change", () => loadWorkers(false));
    document.getElementById("pricing-apply").addEventListener("click", loadPricing);
    document.getElementById("booking-apply").addEventListener("click", () => loadBookings(false));
    document.getElementById("booking-next").addEventListener("click", () => loadBookings(true));
    document.getElementById("bso-apply").addEventListener("click", () => loadBsoAudit(false));
    document.getElementById("bso-next").addEventListener("click", () => loadBsoAudit(true));
    document.getElementById("remote-fetch").addEventListener("click", fetchRemote);
    document.getElementById("remote-import").addEventListener("click", importRemote);
    document.getElementById("subtab-properties-import-trigger").addEventListener("click", () => setPropertiesSubtab("import"));
    document.getElementById("subtab-properties-existing-trigger").addEventListener("click", () => setPropertiesSubtab("existing"));
    document.getElementById("existing-properties-refresh").addEventListener("click", () => {
      loadExistingPropertiesCoverage({ reset: true }).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("existing-properties-page-prev").addEventListener("click", () => {
      if (existingPropertiesPage <= 1) return;
      loadExistingPropertiesCoverage({ page: existingPropertiesPage - 1 }).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("existing-properties-page-next").addEventListener("click", () => {
      if (!existingPropertiesNextCursor) return;
      loadExistingPropertiesCoverage({ page: existingPropertiesPage + 1 }).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("existing-properties-rows").addEventListener("click", (event) => {
      const trigger = event.target.closest(".existing-property-chain-link");
      if (!trigger) return;
      const lookupId = Number.parseInt(String(trigger.dataset.lookupId || ""), 10);
      if (!Number.isInteger(lookupId)) return;
      openExistingPropertyLinksModal({
        lookupId,
        propertyName: String(trigger.dataset.propertyName || ""),
        listingLabel: String(trigger.dataset.listingLabel || ""),
      });
    });
    document.getElementById("existing-property-links-close").addEventListener("click", closeExistingPropertyLinksModal);
    document.getElementById("task-payload-close").addEventListener("click", closeTaskPayloadModal);
    document.getElementById("bso-instruction-close").addEventListener("click", closeBsoInstructionModal);
    document.getElementById("booking-thread-messages-close").addEventListener("click", closeBookingThreadMessagesModal);
    document.getElementById("existing-property-links-modal").addEventListener("change", (event) => {
      const targetSelect = event.target.closest(".existing-property-link-target-select");
      if (!targetSelect) return;
      const sourceLookupId = Number.parseInt(String(targetSelect.dataset.sourceLookupId || ""), 10);
      if (!Number.isInteger(sourceLookupId)) return;
      existingPropertyLinksModalState.selectedTargetsByLookupId[String(sourceLookupId)] = normalizeLookupId(targetSelect.value);
    });
    document.getElementById("existing-property-links-modal").addEventListener("click", (event) => {
      if (event.target.id === "existing-property-links-modal") {
        closeExistingPropertyLinksModal();
      }
      const linkButton = event.target.closest('button[data-action="link-chain-row"]');
      if (linkButton) {
        const lookupId = Number.parseInt(String(linkButton.dataset.lookupId || ""), 10);
        if (!Number.isInteger(lookupId)) return;
        linkExistingPropertyLink(lookupId);
        return;
      }
      const unlinkButton = event.target.closest('button[data-action="unlink-chain-row"]');
      if (!unlinkButton) return;
      const lookupId = Number.parseInt(String(unlinkButton.dataset.lookupId || ""), 10);
      if (!Number.isInteger(lookupId)) return;
      unlinkExistingPropertyLink(lookupId);
    });
    document.getElementById("task-payload-modal").addEventListener("click", (event) => {
      if (event.target.id === "task-payload-modal") {
        closeTaskPayloadModal();
      }
    });
    document.getElementById("bso-instruction-modal").addEventListener("click", (event) => {
      if (event.target.id === "bso-instruction-modal") {
        closeBsoInstructionModal();
      }
    });
    document.getElementById("booking-thread-messages-modal").addEventListener("click", (event) => {
      if (event.target.id === "booking-thread-messages-modal") {
        closeBookingThreadMessagesModal();
      }
    });
    document.getElementById("property-stage-buttons").addEventListener("click", (event) => {
      const button = event.target.closest(".property-stage-btn");
      if (!button) return;
      const stage = button.dataset.stage;
      if (!stage) return;
      setActivePropertyStage(stage);
    });
    document.getElementById("platform-select").addEventListener("change", () => {
      const selectedPlatformId = document.getElementById("platform-select").value || "";
      propertyStagePlatformByType[activePropertyStage] = selectedPlatformId;
      clearRemoteRows();
      refreshRemoteTableColumns();
      updatePropertyStageHint();
    });
    document.getElementById("remote-rows").addEventListener("change", (event) => {
      if (event.target.matches(".remote-link-select")) {
        const propertyId = String(event.target.dataset.id || "");
        const row = remoteCache.find((item) => String(item.platform_property_id || "") === propertyId);
        if (!row) return;
        row.selected_link_to_lookup_id = normalizeLookupId(event.target.value);
        renderRemoteRowsPage();
        return;
      }
      if (!event.target.matches(".remote-row")) return;
      const propertyId = String(event.target.dataset.id || "");
      if (!propertyId) return;
      if (event.target.checked) {
        remoteSelectedIds.add(propertyId);
      } else {
        remoteSelectedIds.delete(propertyId);
      }
      updateRemoteSelectAllState();
    });
    document.getElementById("remote-page-prev").addEventListener("click", () => {
      setRemotePage(remoteCurrentPage - 1);
    });
    document.getElementById("remote-page-next").addEventListener("click", () => {
      setRemotePage(remoteCurrentPage + 1);
    });
    document.getElementById("platform-token-refresh").addEventListener("click", loadPlatformTokens);
    document.getElementById("platform-token-select").addEventListener("change", loadPlatformTokens);
    document.getElementById("platform-token-list").addEventListener("input", (event) => {
      if (event.target.matches('input[name="secret"]')) updatePlatformTokenSaveButtons();
    });
    document.getElementById("platform-token-list").addEventListener("click", (event) => {
      const button = event.target.closest("button[data-action]");
      if (!button) return;
      const card = button.closest("[data-token-key]");
      if (!card || !card.dataset.tokenKey) return;
      const tokenKey = card.dataset.tokenKey;
      if (button.dataset.action === "save") {
        savePlatformToken(tokenKey);
        return;
      }
      if (button.dataset.action === "delete") {
        deletePlatformToken(tokenKey);
      }
    });
    document.getElementById("llm-provider-settings-select").addEventListener("change", () => {
      renderLlmProviderSettings(getSelectedLlmProvider());
    });
    document.getElementById("llm-provider-api-key-save").addEventListener("click", saveLlmProviderApiKey);
    document.getElementById("llm-provider-health-check").addEventListener("click", checkLlmProviderHealth);
    document.getElementById("llm-provider-settings-save").addEventListener("click", saveLlmProviderSettings);
    document.getElementById("subtab-llm-usage-usage-trigger").addEventListener("click", () => setLlmSubtab("usage"));
    document.getElementById("subtab-llm-usage-providers-trigger").addEventListener("click", () => setLlmSubtab("providers"));
    document.getElementById("subtab-llm-usage-pricing-trigger").addEventListener("click", () => setLlmSubtab("pricing"));
    document.getElementById("llm-pricing-save").addEventListener("click", saveLlmPricing);
    document.getElementById("llm-pricing-reset").addEventListener("click", resetLlmPricingForm);
    document.getElementById("llm-pricing-rows").addEventListener("click", (event) => {
      const editButton = event.target.closest("[data-llm-pricing-edit]");
      if (editButton) {
        populateLlmPricingForm(JSON.parse(decodeURIComponent(editButton.dataset.llmPricingEdit)));
        return;
      }
      const deactivateButton = event.target.closest("[data-llm-pricing-deactivate]");
      if (deactivateButton) {
        deactivateLlmPricing(JSON.parse(decodeURIComponent(deactivateButton.dataset.llmPricingDeactivate)));
      }
    });
    document.getElementById("llm-breakdown-rows").addEventListener("click", (event) => {
      const button = event.target.closest("[data-llm-set-price]");
      if (!button) return;
      openLlmPricingForProviderModel(JSON.parse(decodeURIComponent(button.dataset.llmSetPrice))).catch((error) => setStatus(error.message, true));
    });
    document.getElementById("llm-apply").addEventListener("click", () => loadLlmUsage(false));
    document.getElementById("llm-next").addEventListener("click", () => loadLlmUsage(true));
    document.getElementById("llm-reset").addEventListener("click", () => {
      resetLlmUsageFilters();
      loadLlmUsage(false);
    });
    document.getElementById("llm-usage-rows").addEventListener("click", (event) => {
      const button = event.target.closest("[data-llm-toggle]");
      if (!button) return;
      const detail = document.querySelector(`[data-llm-detail="${button.dataset.llmToggle}"]`);
      if (detail) detail.classList.toggle("hidden");
    });
    document.getElementById("logout-btn").addEventListener("click", async () => {
      try {
        await fetch("/pwsadmin/api/auth/logout", {
          method: "POST",
          credentials: "same-origin",
        });
      } catch (error) {
        // Ignore logout transport failures; local cleanup still runs.
      }
      sessionStorage.removeItem("pwsadmin_token");
      localStorage.removeItem("pwsadmin_token");
      localStorage.removeItem(SIMPLE_PRICING_MODE_KEY);
      document.cookie = "pwsadmin_token=; Max-Age=0; path=/;";
      window.location.replace("/pwsadmin/home");
    });

    const initialSubtabs = dashboardManifest.initial_subtabs || {};

    normalizeLegacyHosts();
    initControlTooltipsAndValidation();
    setPricingSubtab(initialSubtabs.pricing || "rules");
    setPricingMode(getPricingMode(), { persist: false });
    setPropertiesSubtab(initialSubtabs.properties || "import");
    setExistingPropertiesPaginationState(0);
    refreshRemoteTableColumns();
    resetPricingEditor();
    resetMessageClassForm({ keepStatus: true });
    resetTaskEnqueueForm();
    resetLlmUsageFilters();
    resetLlmPricingForm();
    setLlmSubtab(initialSubtabs["llm-usage"] || "usage");
    showPanel(dashboardManifest.initial_tab || "tasks");
    loadTasks();
    loadTaskEnqueueOptions();
    loadLogs();
    loadWorkers();
    loadLlmUsage();
    loadPricing();
    Promise.all([loadCurrentUserProfile(), loadPlatforms(), loadPricingProperties()])
      .then(() => loadMessageClasses({ includeInactive: isMessageClassAdmin() }))
      .then(() => {
        if (currentUserProfile?.is_admin) {
          loadLlmProviders();
          loadPlatformTokens();
        } else {
          document.getElementById("llm-provider-settings-panel").classList.add("hidden");
          renderLlmProviderSettings(null);
          renderPlatformTokenList([]);
          setPlatformTokenStatus({ detail: "Admin access required to manage platform tokens." });
        }
        loadBookings();
        loadBsoAudit();
      })
      .catch((error) => setStatus(error.message, true));
