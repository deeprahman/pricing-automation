# PWS Admin UI Tab and Subtab Specification

This document defines the reusable contract for adding dashboard tabs and
subtabs to the FastAPI PWS Admin Console. It is based on the current registry,
templates, static assets, and dashboard bootstrap code.

## 1. Source Of Truth

All dashboard tabs and subtabs are declared in
`fastapi/pwsadmin_ui/registry.py`.

The registry is responsible for:

- tab order and labels
- tab and subtab template paths
- tab and subtab CSS asset paths
- tab and subtab JavaScript module paths
- default subtab selection
- URL resolution for `tab` and `subtab`
- the JSON manifest consumed by the browser

Do not hard-code new dashboard tabs in `dashboard.html`. Add them to
`PWS_ADMIN_TABS` through `_tab(...)` and, when needed, `_subtab(...)`.

## 2. Naming Rules

Use these names consistently across Python, templates, CSS, JavaScript, tests,
DOM ids, data attributes, and URLs.

- `tab.key`: lowercase kebab-case, for example `message-classes`.
- `subtab.key`: lowercase kebab-case, for example `existing`.
- `tab.label` and `subtab.label`: short human-readable UI text.
- Template folder names should match the tab key unless `template_dir` is
  required for an existing legacy folder.
- Static asset names should match the key exactly.

Reserved generated DOM ids:

- `tab-<tab-key>-trigger`
- `tab-<tab-key>-panel`
- `subtab-<tab-key>-<subtab-key>-trigger`
- `subtab-<tab-key>-<subtab-key>-panel`

Avoid creating other elements with those ids.

## 3. Tab Contract

A normal tab has this file layout:

```text
fastapi/templates/pwsadmin/tabs/<tab-key>/panel.html
fastapi/static/pwsadmin/css/tabs/<tab-key>.css
fastapi/static/pwsadmin/js/tabs/<tab-key>.js
```

Registry entry:

```python
_tab(key="<tab-key>", label="<Label>", order=<number>)
```

The tab `panel.html` is included inside a dashboard-owned section:

```html
<section
  id="tab-<tab-key>-panel"
  data-registry-panel
  data-panel="<tab-key>"
  data-tab-key="<tab-key>"
>
  ...
</section>
```

The tab template should render only the tab body. The outer dashboard page owns
the main navigation, active tab visibility, status element, global modals,
manifest script, and core module bootstrap.

## 4. Subtab Contract

A tab with subtabs has this file layout:

```text
fastapi/templates/pwsadmin/tabs/<tab-key>/panel.html
fastapi/templates/pwsadmin/tabs/<tab-key>/subtabs/<subtab-key>.html
fastapi/static/pwsadmin/css/tabs/<tab-key>.css
fastapi/static/pwsadmin/css/subtabs/<tab-key>/<subtab-key>.css
fastapi/static/pwsadmin/js/tabs/<tab-key>.js
fastapi/static/pwsadmin/js/subtabs/<tab-key>/<subtab-key>.js
```

Registry entry:

```python
_tab(
    key="<tab-key>",
    label="<Label>",
    order=<number>,
    default_subtab="<first-subtab-key>",
    subtabs=(
        _subtab("<tab-key>", "<first-subtab-key>", "<First Label>"),
        _subtab("<tab-key>", "<second-subtab-key>", "<Second Label>"),
    ),
)
```

The tab `panel.html` must render subtab triggers and subtab panels from the
registry-provided `tab.subtabs` collection:

```html
<div class="panel rounded-xl border border-slate-200 bg-white/90 p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900/80">
  <div class="flex flex-wrap items-center gap-2 text-sm">
    {% for subtab in tab.subtabs %}
    <button
      id="subtab-{{ tab.key }}-{{ subtab.key }}-trigger"
      type="button"
      data-subtab-parent="{{ tab.key }}"
      data-subtab-key="{{ subtab.key }}"
      data-subtab-trigger
      class="secondary-btn rounded border px-3 py-1{% if active_subtabs.get(tab.key) == subtab.key %} nav-btn-active{% endif %}"
    >{{ subtab.label }}</button>
    {% endfor %}
  </div>

  {% for subtab in tab.subtabs %}
  <div
    id="subtab-{{ tab.key }}-{{ subtab.key }}-panel"
    data-subtab-parent="{{ tab.key }}"
    data-subtab-key="{{ subtab.key }}"
    data-subtab-panel
    class="{% if active_subtabs.get(tab.key) != subtab.key %}hidden {% endif %}subtab-panel-host"
  >
    {% include subtab.template %}
  </div>
  {% endfor %}
</div>
```

Each subtab template should render only its own content. The parent tab owns
the subtab navigation and the subtab panel hosts.

## 5. JavaScript Module Contract

Every tab and subtab JavaScript file is an ES module. The dashboard lazily
imports modules from the registry manifest.

Supported exports:

```javascript
export function mount(context) {
  // Called once, when this tab or subtab module is first loaded.
}

export function onShow(context) {
  // Called whenever the tab or subtab becomes active.
}

export function onHide(context) {
  // Called when the active tab or subtab changes away from this module.
}
```

`context` contains:

- `root`: the tab panel or subtab panel element.
- `tabKey`: active tab key.
- `subtabKey`: active subtab key, or `null` for tab modules.
- `requestJSON`: authenticated JSON helper from `core/http.js`.
- `setStatus(message, isError = false)`: writes to the dashboard status line.
- `getCurrentUser()`: returns the loaded user profile when available.
- `sharedState`: shared dashboard state from `core/state.js`.

Use `context.root.querySelector(...)` for tab-local elements instead of global
selectors when possible. This keeps new tabs isolated from existing tabs.

## 6. CSS Contract

Dashboard-wide shared styling lives in:

```text
fastapi/static/pwsadmin/css/base.css
```

Tab-specific styling lives in:

```text
fastapi/static/pwsadmin/css/tabs/<tab-key>.css
```

Subtab-specific styling lives in:

```text
fastapi/static/pwsadmin/css/subtabs/<tab-key>/<subtab-key>.css
```

The registry includes all dashboard CSS files in deterministic tab order. Keep
selectors scoped to a tab or subtab class when possible to avoid accidental
cross-tab changes.

Use existing shared classes where they fit:

- `control-surface`
- `secondary-btn`
- `nav-btn-active`
- `panel-table`
- `category-scroll-panel`

## 7. Routing And State Contract

The dashboard supports URL-driven activation:

```text
/pwsadmin/dashboard?tab=<tab-key>
/pwsadmin/dashboard?tab=<tab-key>&subtab=<subtab-key>
```

Server-side behavior:

- `resolve_tab_and_subtab(...)` normalizes request parameters.
- Unknown tab keys fall back to the first registered tab.
- Unknown subtab keys fall back to the tab default subtab.
- `dashboard_manifest(...)` emits the initial tab and default subtabs.

Browser behavior:

- `core/app.js` reads `#pwsadmin-dashboard-manifest`.
- `showPanel(...)` activates tab panels and tab modules.
- `activateSubtab(...)` activates subtab panels and subtab modules.
- The current URL is updated with the active `tab` and `subtab`.
- `window.PwsAdminApp.activateTab(...)` and
  `window.PwsAdminApp.activateSubtab(...)` are available for existing code.

## 8. Backward Compatibility

Some older tab behavior still lives in `fastapi/static/pwsadmin/js/core/app.js`.
New tabs and subtabs should use dedicated modules under `js/tabs/` and
`js/subtabs/`.

If an existing tab still depends on legacy functions in `core/app.js`, do not
remove those functions until the tab has been fully migrated to its own module
and covered by tests.

Legacy template files named `legacy-section.html`, `*-legacy.html`, or
`*-body.html` are compatibility artifacts. New tabs should prefer the registry
template contract above.

## 9. Required Tests

At minimum, run:

```powershell
pytest tests/test_fastapi_dashboard_registry.py
```

This verifies:

- every registered tab key is unique
- every tab template exists
- every tab CSS file exists
- every tab JavaScript module exists
- every subtab key is unique within its parent tab
- every subtab template, CSS file, and JavaScript module exists
- each tab with subtabs has a valid `default_subtab`
- the dashboard template uses the registry manifest and module bootstrap

For user-visible behavior, add or update a focused UI test in `tests/` that
renders or exercises the new tab.

## 10. Checklist For A New Tab

1. Choose a unique lowercase kebab-case `tab.key`.
2. Add `fastapi/templates/pwsadmin/tabs/<tab-key>/panel.html`.
3. Add `fastapi/static/pwsadmin/css/tabs/<tab-key>.css`.
4. Add `fastapi/static/pwsadmin/js/tabs/<tab-key>.js`.
5. Register the tab in `PWS_ADMIN_TABS` with a unique `order`.
6. Keep element ids unique and preferably prefixed with the tab key.
7. Use `context.root` and `requestJSON` inside the JS module.
8. Run the dashboard registry test.
9. Add a focused UI test if the tab has behavior beyond static markup.

## 11. Checklist For A New Subtab

1. Choose a unique lowercase kebab-case `subtab.key` within the parent tab.
2. Add `fastapi/templates/pwsadmin/tabs/<tab-key>/subtabs/<subtab-key>.html`.
3. Add `fastapi/static/pwsadmin/css/subtabs/<tab-key>/<subtab-key>.css`.
4. Add `fastapi/static/pwsadmin/js/subtabs/<tab-key>/<subtab-key>.js`.
5. Add `_subtab("<tab-key>", "<subtab-key>", "<Label>")` to the parent tab.
6. Set or update `default_subtab` if this should be the first active subtab.
7. Make sure the parent `panel.html` renders `tab.subtabs` instead of hard-coded
   subtab buttons.
8. Run the dashboard registry test.
9. Add or update a UI test for the subtab flow if it has behavior.

## 12. Minimal Module Examples

Tab module:

```javascript
export function mount(context) {
  context.root.dataset.moduleMounted = "true";
}

export function onShow(context) {
  context.sharedState.activeTab = context.tabKey;
}

export function onHide(context) {
  context.root.dataset.moduleHidden = "true";
}
```

Subtab module:

```javascript
export function mount(context) {
  context.root.dataset.subtabMounted = "true";
}

export function onShow(context) {
  context.sharedState.activeSubtabs[context.tabKey] = context.subtabKey;
}

export function onHide(context) {
  context.root.dataset.subtabHidden = "true";
}
```

