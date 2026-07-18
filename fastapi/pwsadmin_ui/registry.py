from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


TEMPLATES_ROOT = Path(__file__).resolve().parents[1] / "templates" / "pwsadmin"
STATIC_ROOT = Path(__file__).resolve().parents[1] / "static" / "pwsadmin"
STATIC_URL_PREFIX = "/pwsadmin/static/pwsadmin"


@dataclass(frozen=True)
class SubtabDefinition:
    key: str
    label: str
    template: str
    css_files: tuple[str, ...]
    js_module: str | None

    def to_manifest(self) -> dict[str, object]:
        return {
            "key": self.key,
            "label": self.label,
            "template": self.template,
            "css_files": list(self.css_files),
            "js_module": self.js_module,
        }


@dataclass(frozen=True)
class TabDefinition:
    key: str
    label: str
    order: int
    template: str
    css_files: tuple[str, ...]
    js_module: str | None
    default_subtab: str | None
    subtabs: tuple[SubtabDefinition, ...]

    def to_manifest(self) -> dict[str, object]:
        return {
            "key": self.key,
            "label": self.label,
            "order": self.order,
            "template": self.template,
            "css_files": list(self.css_files),
            "js_module": self.js_module,
            "default_subtab": self.default_subtab,
            "subtabs": [item.to_manifest() for item in self.subtabs],
        }


def _css_url(*parts: str) -> str:
    return f"{STATIC_URL_PREFIX}/css/" + "/".join(parts)


def _js_url(*parts: str) -> str:
    return f"{STATIC_URL_PREFIX}/js/" + "/".join(parts)


def _subtab(tab_key: str, subtab_key: str, label: str) -> SubtabDefinition:
    return SubtabDefinition(
        key=subtab_key,
        label=label,
        template=f"pwsadmin/tabs/{tab_key}/subtabs/{subtab_key}.html",
        css_files=(_css_url("subtabs", tab_key, f"{subtab_key}.css"),),
        js_module=_js_url("subtabs", tab_key, f"{subtab_key}.js"),
    )


def _tab(
    *,
    key: str,
    label: str,
    order: int,
    template_dir: str | None = None,
    default_subtab: str | None = None,
    subtabs: tuple[SubtabDefinition, ...] = (),
) -> TabDefinition:
    template_segment = template_dir or key
    return TabDefinition(
        key=key,
        label=label,
        order=order,
        template=f"pwsadmin/tabs/{template_segment}/panel.html",
        css_files=(_css_url("tabs", f"{key}.css"),),
        js_module=_js_url("tabs", f"{key}.js"),
        default_subtab=default_subtab,
        subtabs=subtabs,
    )


PWS_ADMIN_TABS: tuple[TabDefinition, ...] = tuple(
    sorted(
        (
            _tab(key="tasks", label="Tasks", order=10),
            _tab(key="enqueue-task", label="Enqueue Task", order=20),
            _tab(key="workers", label="Workers", order=30),
            _tab(key="worker-manager", label="Worker Manager", order=35),
            _tab(key="logs", label="Logs", order=40, template_dir="logs_tab"),
            _tab(
                key="pricing",
                label="Pricing",
                order=50,
                default_subtab="rules",
                subtabs=(
                    _subtab("pricing", "rules", "Rules"),
                    _subtab("pricing", "listings", "Listings"),
                ),
            ),
            _tab(key="bookings", label="Bookings", order=60),
            _tab(key="bso-audit", label="BSO Audit", order=70),
            _tab(key="message-classes", label="Message Classes", order=80),
            _tab(
                key="properties",
                label="Properties",
                order=90,
                default_subtab="import",
                subtabs=(
                    _subtab("properties", "import", "Import / Sync"),
                    _subtab("properties", "existing", "Existing Properties"),
                ),
            ),
            _tab(key="platforms", label="Platforms", order=100),
            _tab(
                key="llm-usage",
                label="LLM Usage",
                order=110,
                default_subtab="usage",
                subtabs=(
                    _subtab("llm-usage", "usage", "Usage"),
                    _subtab("llm-usage", "providers", "Providers"),
                    _subtab("llm-usage", "pricing", "Pricing"),
                ),
            ),
        ),
        key=lambda item: item.order,
    )
)


def get_dashboard_tabs() -> tuple[TabDefinition, ...]:
    return PWS_ADMIN_TABS


def get_tab_definition(tab_key: str | None) -> TabDefinition | None:
    normalized = str(tab_key or "").strip().lower()
    for tab in PWS_ADMIN_TABS:
        if tab.key == normalized:
            return tab
    return None


def resolve_tab_and_subtab(
    requested_tab: str | None,
    requested_subtab: str | None,
) -> tuple[TabDefinition, str | None]:
    tab = get_tab_definition(requested_tab) or PWS_ADMIN_TABS[0]
    normalized_subtab = str(requested_subtab or "").strip().lower()
    allowed_subtabs = {item.key for item in tab.subtabs}
    if not allowed_subtabs:
        return tab, None
    if normalized_subtab in allowed_subtabs:
        return tab, normalized_subtab
    return tab, tab.default_subtab or next(iter(allowed_subtabs))


def iter_dashboard_asset_urls(tabs: tuple[TabDefinition, ...] | None = None) -> tuple[str, ...]:
    seen: set[str] = set()
    ordered: list[str] = [_css_url("base.css")]
    for url in ordered:
        seen.add(url)
    for tab in tabs or PWS_ADMIN_TABS:
        for css_file in tab.css_files:
            if css_file not in seen:
                ordered.append(css_file)
                seen.add(css_file)
        for subtab in tab.subtabs:
            for css_file in subtab.css_files:
                if css_file not in seen:
                    ordered.append(css_file)
                    seen.add(css_file)
    return tuple(ordered)


def dashboard_manifest(initial_tab: str, initial_subtab: str | None) -> dict[str, object]:
    active_subtabs = {
        tab.key: (
            initial_subtab
            if tab.key == initial_tab and initial_subtab and any(item.key == initial_subtab for item in tab.subtabs)
            else tab.default_subtab
        )
        for tab in PWS_ADMIN_TABS
        if tab.subtabs
    }
    return {
        "tabs": [tab.to_manifest() for tab in PWS_ADMIN_TABS],
        "initial_tab": initial_tab,
        "initial_subtabs": active_subtabs,
    }


def expected_template_file(path: str) -> Path:
    return TEMPLATES_ROOT / path.removeprefix("pwsadmin/")


def expected_static_file(url: str) -> Path:
    return STATIC_ROOT / url.removeprefix(STATIC_URL_PREFIX).lstrip("/")
