import json
import os
import time
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from functools import lru_cache
from typing import Any
from urllib.parse import urljoin
from uuid import UUID

import httpx
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pathlib import Path
from sqlalchemy.orm import Session
from starlette_admin.contrib.sqla import Admin

from admin_auth import JWTAuthBackend, SESSION_REMEMBER_ME_KEY
from admin_views import UserAdmin
from auth import (
    ACCESS_TOKEN_REMEMBER_DAYS,
    create_access_token,
    get_current_user,
    get_login_expires_delta,
    get_user_from_token,
)
from database_dual_existing_auto import (
    admin_engine,
    check_admin_connection,
    check_auto_connection,
    execute_auto_query,
    execute_auto_write,
    execute_auto_function,
    get_admin_db,
    init_admin_db,
)
from models_admin import User
try:
    from .pwsadmin_ui.registry import (
        dashboard_manifest,
        get_dashboard_tabs,
        iter_dashboard_asset_urls,
        resolve_tab_and_subtab,
    )
except ImportError:  # pragma: no cover - supports direct module execution
    from pwsadmin_ui.registry import (
        dashboard_manifest,
        get_dashboard_tabs,
        iter_dashboard_asset_urls,
        resolve_tab_and_subtab,
    )
from remember_aware_session import RememberAwareSessionMiddleware
try:
    from .property_linking import build_remote_link_annotations, coordinate_key, resolve_import_link_choice
    from .property_metadata import build_listing_metadata, build_property_details
except ImportError:  # pragma: no cover - supports direct module execution
    from property_linking import build_remote_link_annotations, coordinate_key, resolve_import_link_choice
    from property_metadata import build_listing_metadata, build_property_details
from schemas import (
    ApiTokenUpsert,
    LLMModelPricingUpsert,
    LLMProviderHealthCheck,
    LLMSettingsUpdate,
    MessageClassCreate,
    MessageClassUpdate,
    PlatformPropertyLinkRequest,
    PlatformPropertyImportRequest,
    PricingBulkDelete,
    PricingRuleCreate,
    PricingRuleUpdate,
    SecretUpsert,
    TaskEnqueueCreate,
    TokenResponse,
    UserLogin,
    UserRegister,
    UserResponse,
    WorkerManagerCleanupRequest,
)
from user_service import UserService

PWSADMIN_TEMPLATE_DIR = Path(__file__).parent / "templates"
PWSADMIN_STATIC_DIR = Path(__file__).parent / "static"
PWSADMIN_TEMPLATES = Jinja2Templates(directory=str(PWSADMIN_TEMPLATE_DIR))

HOME_HTML = """\
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Password Safe Admin</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: "class",
      theme: {
        extend: {
          fontFamily: {
            sans: ["Segoe UI", "Tahoma", "Geneva", "Verdana", "sans-serif"],
          },
          colors: {
            brand: {
              50: "#ecfdf5",
              100: "#d1fae5",
              500: "#0f766e",
              600: "#0d6861",
              700: "#0b5c56",
            },
          },
        },
      },
    };

    (function setInitialTheme() {
      try {
        const savedTheme = localStorage.getItem("pwsadmin_theme");
        const hasSavedPreference = savedTheme === "dark" || savedTheme === "light";
        if (savedTheme && !hasSavedPreference) {
          localStorage.removeItem("pwsadmin_theme");
        }
        const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        const nextTheme = hasSavedPreference ? savedTheme : (prefersDark ? "dark" : "light");
        document.documentElement.classList.toggle("dark", nextTheme === "dark");
        document.documentElement.dataset.theme = nextTheme;
      } catch (_) {}
    })();
  </script>
</head>
<body class="h-full bg-slate-100 text-slate-900 antialiased dark:bg-slate-950 dark:text-slate-100">
  <div class="relative min-h-full overflow-hidden">
    <div class="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_20%_5%,rgba(13,104,97,0.18),transparent_45%),radial-gradient(circle_at_85%_20%,rgba(14,116,144,0.12),transparent_48%)] dark:bg-[radial-gradient(circle_at_20%_5%,rgba(45,212,191,0.18),transparent_45%),radial-gradient(circle_at_85%_20%,rgba(34,211,238,0.12),transparent_48%)]"></div>
    <div class="relative mx-auto flex w-full max-w-6xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
      <header class="rounded-2xl border border-slate-200/80 bg-white/85 p-5 shadow-xl shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/75 dark:shadow-black/30 sm:p-7">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p class="mb-2 inline-flex rounded-full border border-brand-100 bg-brand-50 px-3 py-1 text-xs font-semibold uppercase tracking-[0.16em] text-brand-700 dark:border-brand-500/30 dark:bg-brand-500/10 dark:text-brand-100">
              PWS Admin
            </p>
            <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-white sm:text-3xl">Password Safe Admin</h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600 dark:text-slate-300">
              FastAPI dashboard (<code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">/pwsadmin</code>) and Starlette-Admin
              (<code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">/pwsadmin/admin</code>) secured by JWT.
            </p>
          </div>
          <button
            id="theme-toggle"
            type="button"
            class="inline-flex items-center justify-center rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:border-brand-500 hover:text-brand-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:border-brand-400 dark:hover:text-brand-300"
          >
            Toggle theme
          </button>
        </div>
      </header>

      <main class="grid gap-4 lg:grid-cols-2">
        <section class="rounded-2xl border border-slate-200/80 bg-white/90 p-5 shadow-lg shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/70 sm:p-6">
          <h2 class="text-xl font-semibold text-slate-900 dark:text-white">Login</h2>
          <form id="login-form" class="mt-4 space-y-3">
            <label for="login-email" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Email</label>
            <input
              id="login-email"
              name="email"
              type="email"
              required
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <label for="login-password" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Password</label>
            <input
              id="login-password"
              name="password"
              type="password"
              required
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <label for="login-remember-me" class="inline-flex items-center gap-2 text-sm text-slate-600 dark:text-slate-300">
              <input
                id="login-remember-me"
                name="remember_me"
                type="checkbox"
                class="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600 dark:bg-slate-800"
              />
              <span>Remember me</span>
            </label>
            <button
              type="submit"
              class="mt-2 inline-flex w-full items-center justify-center rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500/30"
            >
              Sign In
            </button>
          </form>
          <p class="mt-3 text-sm text-slate-600 dark:text-slate-300">On success, you will be redirected to <code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">/pwsadmin/dashboard</code>.</p>
        </section>

        <section class="rounded-2xl border border-slate-200/80 bg-white/90 p-5 shadow-lg shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/70 sm:p-6">
          <h2 class="text-xl font-semibold text-slate-900 dark:text-white">Register</h2>
          <form id="register-form" class="mt-4 space-y-3">
            <label for="reg-email" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Email</label>
            <input
              id="reg-email"
              name="email"
              type="email"
              required
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <label for="reg-username" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Username</label>
            <input
              id="reg-username"
              name="username"
              type="text"
              minlength="3"
              required
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <label for="reg-fullname" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Full name</label>
            <input
              id="reg-fullname"
              name="full_name"
              type="text"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <label for="reg-password" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">Password</label>
            <input
              id="reg-password"
              name="password"
              type="password"
              minlength="8"
              required
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/20 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100 dark:placeholder:text-slate-500 dark:focus:border-brand-400 dark:focus:ring-brand-400/20"
            />
            <button
              type="submit"
              class="mt-2 inline-flex w-full items-center justify-center rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500/30"
            >
              Create Account
            </button>
          </form>
          <p class="mt-3 text-sm leading-6 text-slate-600 dark:text-slate-300">
            New accounts stay pending until an admin manually sets <code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">is_active=true</code>. The first registered user is marked as admin, but still needs activation.
          </p>
        </section>
      </main>

      <p id="status" class="min-h-6 text-sm font-medium text-slate-600 dark:text-slate-300"></p>

      <footer class="flex flex-wrap items-center gap-3 rounded-2xl border border-slate-200/80 bg-white/90 px-5 py-4 text-sm text-slate-600 shadow-lg shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/70 dark:text-slate-300">
        <span>Admin panel:</span>
        <a class="font-semibold text-brand-700 hover:text-brand-600 dark:text-brand-300 dark:hover:text-brand-200" href="/pwsadmin/admin" target="_blank" rel="noopener">/pwsadmin/admin</a>
        <span class="text-slate-400 dark:text-slate-500">|</span>
        <span>API health:</span>
        <a class="font-semibold text-brand-700 hover:text-brand-600 dark:text-brand-300 dark:hover:text-brand-200" href="/pwsadmin/api/health" target="_blank" rel="noopener">/pwsadmin/api/health</a>
      </footer>
    </div>
  </div>
  <script>
    const statusEl = document.getElementById("status");
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

    function initThemeToggle() {
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
      themeToggleButton.addEventListener("click", () => {
        const nextTheme = document.documentElement.classList.contains("dark") ? "light" : "dark";
        applyTheme(nextTheme, { persist: true });
      });
    }

    function setStatus(message, ok = false) {
      statusEl.textContent = message;
      statusEl.className = ok
        ? "min-h-6 text-sm font-medium text-emerald-600 dark:text-emerald-400"
        : "min-h-6 text-sm font-medium text-rose-600 dark:text-rose-400";
    }

    function getStoredToken() {
      return sessionStorage.getItem("pwsadmin_token") || localStorage.getItem("pwsadmin_token");
    }

    async function redirectToDashboardIfAuthenticated() {
      const token = getStoredToken();
      const headers = token ? { Authorization: `Bearer ${token}` } : {};
      try {
        const res = await fetch("/pwsadmin/api/auth/me", {
          headers,
          credentials: "same-origin",
        });
        if (res.ok) {
          window.location.replace("/pwsadmin/dashboard");
        }
      } catch (error) {
        // Ignore startup auth probe failures and let manual login continue.
      }
    }

    initThemeToggle();
    redirectToDashboardIfAuthenticated();

    document.getElementById("register-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.target);
      const payload = {
        email: form.get("email"),
        username: form.get("username"),
        full_name: form.get("full_name") || null,
        password: form.get("password"),
      };

      const res = await fetch("/pwsadmin/api/auth/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });

      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        setStatus(data.detail || "Registration failed");
        return;
      }

      setStatus("Registration submitted. An admin must activate your account before you can sign in.", true);
      event.target.reset();
    });

    document.getElementById("login-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      const form = new FormData(event.target);
      const payload = {
        email: form.get("email"),
        password: form.get("password"),
        remember_me: form.get("remember_me") === "on",
      };

      const res = await fetch("/pwsadmin/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        credentials: "same-origin",
      });

      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        setStatus(data.detail || "Login failed");
        return;
      }

      const data = await res.json();
      if (payload.remember_me) {
        localStorage.setItem("pwsadmin_token", data.access_token);
        sessionStorage.removeItem("pwsadmin_token");
      } else {
        sessionStorage.setItem("pwsadmin_token", data.access_token);
        localStorage.removeItem("pwsadmin_token");
      }
      window.location.replace("/pwsadmin/dashboard");
    });
  </script>
</body>
</html>
"""

DASHBOARD_TEMPLATE_PATH = Path(__file__).parent / "dashboard.html"
DASHBOARD_HTML_FALLBACK = """\
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Password Safe Dashboard</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: "class",
      theme: {
        extend: {
          fontFamily: {
            sans: ["Segoe UI", "Tahoma", "Geneva", "Verdana", "sans-serif"],
            mono: ["Consolas", "Courier New", "monospace"],
          },
          colors: {
            brand: {
              50: "#ecfdf5",
              100: "#d1fae5",
              500: "#0f766e",
              600: "#0d6861",
              700: "#0b5c56",
            },
          },
        },
      },
    };

    (function setInitialTheme() {
      try {
        const savedTheme = localStorage.getItem("pwsadmin_theme");
        const hasSavedPreference = savedTheme === "dark" || savedTheme === "light";
        if (savedTheme && !hasSavedPreference) {
          localStorage.removeItem("pwsadmin_theme");
        }
        const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        const nextTheme = hasSavedPreference ? savedTheme : (prefersDark ? "dark" : "light");
        document.documentElement.classList.toggle("dark", nextTheme === "dark");
        document.documentElement.dataset.theme = nextTheme;
      } catch (_) {}
    })();
  </script>
</head>
<body class="h-full bg-slate-100 text-slate-900 antialiased dark:bg-slate-950 dark:text-slate-100">
  <div class="relative min-h-full overflow-hidden">
    <div class="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_0%_0%,rgba(13,104,97,0.2),transparent_38%),radial-gradient(circle_at_100%_10%,rgba(14,116,144,0.14),transparent_45%)] dark:bg-[radial-gradient(circle_at_0%_0%,rgba(45,212,191,0.2),transparent_38%),radial-gradient(circle_at_100%_10%,rgba(34,211,238,0.12),transparent_45%)]"></div>
    <div class="relative mx-auto flex w-full max-w-7xl flex-col gap-5 px-4 py-6 sm:px-6 lg:px-8">
      <section class="rounded-2xl border border-slate-200/80 bg-white/90 p-5 shadow-xl shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/70 dark:shadow-black/30 sm:p-6">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p class="mb-2 inline-flex rounded-full border border-brand-100 bg-brand-50 px-3 py-1 text-xs font-semibold uppercase tracking-[0.16em] text-brand-700 dark:border-brand-500/30 dark:bg-brand-500/10 dark:text-brand-100">
              Dashboard
            </p>
            <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-white sm:text-3xl">PWS Dashboard</h1>
            <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
              Signed in as <strong>__DISPLAY_NAME__</strong> (<code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">__EMAIL__</code>)
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              id="theme-toggle"
              type="button"
              class="inline-flex items-center justify-center rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:border-brand-500 hover:text-brand-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:border-brand-400 dark:hover:text-brand-300"
            >
              Toggle theme
            </button>
            <a
              class="inline-flex items-center justify-center rounded-xl border border-slate-300 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-brand-500 hover:text-brand-700 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:border-brand-400 dark:hover:text-brand-300"
              href="/pwsadmin/admin"
              target="_blank"
              rel="noopener"
            >
              Open /pwsadmin/admin
            </a>
            <button
              id="refresh-btn"
              class="inline-flex items-center justify-center rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white transition hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500/30"
            >
              Refresh Tasks
            </button>
            <button
              id="logout-btn"
              class="inline-flex items-center justify-center rounded-xl border border-slate-300 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-slate-400 hover:text-slate-900 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:border-slate-500 dark:hover:text-white"
            >
              Logout
            </button>
          </div>
        </div>
        <div class="mt-3 flex flex-wrap gap-3 text-sm text-slate-600 dark:text-slate-300">
          <span>API: <code class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">/pwsadmin/api/tasks</code></span>
          <span class="text-slate-400 dark:text-slate-500">|</span>
          <span>Auth: JWT bearer token</span>
        </div>
        <p id="status" class="mt-3 min-h-5 text-sm font-medium text-slate-600 dark:text-slate-300">Loading profile and tasks...</p>
      </section>

      <section class="rounded-2xl border border-slate-200/80 bg-white/90 p-5 shadow-xl shadow-slate-900/5 backdrop-blur dark:border-slate-700/70 dark:bg-slate-900/70 dark:shadow-black/30 sm:p-6">
        <h2 class="text-xl font-semibold text-slate-900 dark:text-white">Latest Tasks</h2>
        <div class="mt-4 overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-700">
          <table class="min-w-full divide-y divide-slate-200 text-sm dark:divide-slate-700">
            <thead class="bg-slate-50 text-left text-xs uppercase tracking-[0.08em] text-slate-600 dark:bg-slate-800/70 dark:text-slate-300">
              <tr>
                <th class="px-3 py-3 font-semibold">ID</th>
                <th class="px-3 py-3 font-semibold">Name</th>
                <th class="px-3 py-3 font-semibold">Status</th>
                <th class="px-3 py-3 font-semibold">Queue</th>
                <th class="px-3 py-3 font-semibold">Priority</th>
                <th class="px-3 py-3 font-semibold">Worker</th>
                <th class="px-3 py-3 font-semibold">Updated</th>
              </tr>
            </thead>
            <tbody id="task-rows" class="divide-y divide-slate-200 bg-white text-slate-700 dark:divide-slate-800 dark:bg-slate-900/30 dark:text-slate-200"></tbody>
          </table>
        </div>
      </section>
    </div>
  </div>
  <script>
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

    function initThemeToggle() {
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
      themeToggleButton.addEventListener("click", () => {
        const nextTheme = document.documentElement.classList.contains("dark") ? "light" : "dark";
        applyTheme(nextTheme, { persist: true });
      });
    }

    initThemeToggle();
  </script>
  <script>
    const statusEl = document.getElementById("status");
    const rowsEl = document.getElementById("task-rows");

    function setStatus(message, isError = false) {
      statusEl.textContent = message;
      statusEl.className = isError
        ? "mt-3 min-h-5 text-sm font-medium text-rose-600 dark:text-rose-400"
        : "mt-3 min-h-5 text-sm font-medium text-slate-600 dark:text-slate-300";
    }

    function getToken() {
      const url = new URL(window.location.href);
      const tokenInQuery = url.searchParams.get("token");
      if (tokenInQuery) {
        sessionStorage.setItem("pwsadmin_token", tokenInQuery);
        localStorage.removeItem("pwsadmin_token");
        url.searchParams.delete("token");
        window.history.replaceState({}, "", url.toString());
        return tokenInQuery;
      }
      return sessionStorage.getItem("pwsadmin_token") || localStorage.getItem("pwsadmin_token");
    }

    async function requestJSON(path, options = {}) {
      const token = getToken();
      const headers = new Headers(options.headers || {});
      if (token) {
        headers.set("Authorization", `Bearer ${token}`);
      }
      const response = await fetch(path, {
        ...options,
        headers,
        credentials: "same-origin",
      });
      if (!response.ok) {
        const body = await response.json().catch(() => ({}));
        const error = new Error(body.detail || `Request failed: ${response.status}`);
        error.status = response.status;
        throw error;
      }
      return response.json();
    }

    async function loadDashboard() {
      try {
        await requestJSON("/pwsadmin/api/auth/me");
        const taskResult = await requestJSON("/pwsadmin/api/tasks?limit=25");
        const items = taskResult.items || [];
        rowsEl.innerHTML = "";
        for (const item of items) {
          const tr = document.createElement("tr");
          tr.className = "align-top";
          tr.innerHTML = `
            <td class="px-3 py-3">${item.id}</td>
            <td class="px-3 py-3">${item.task_name || "-"}</td>
            <td class="px-3 py-3">${item.status || "-"}</td>
            <td class="px-3 py-3">${item.queue_name || "-"}</td>
            <td class="px-3 py-3">${item.priority ?? "-"}</td>
            <td class="px-3 py-3">${item.worker_id || "-"}</td>
            <td class="px-3 py-3 font-mono text-xs text-slate-600 dark:text-slate-300">${item.updated_at || item.created_at || "-"}</td>
          `;
          rowsEl.appendChild(tr);
        }
        if (items.length === 0) {
          rowsEl.innerHTML = "<tr><td class='px-3 py-4 text-sm text-slate-600 dark:text-slate-300' colspan='7'>No tasks found in auto_pws.task_queue</td></tr>";
        }
        setStatus(`Loaded ${items.length} task(s).`, false);
      } catch (error) {
        if (error.status === 401) {
          sessionStorage.removeItem("pwsadmin_token");
          localStorage.removeItem("pwsadmin_token");
          window.location.replace("/pwsadmin/home");
          return;
        }
        setStatus(error.message || "Failed to load dashboard", true);
      }
    }

    document.getElementById("refresh-btn").addEventListener("click", loadDashboard);
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
      document.cookie = "pwsadmin_token=; Max-Age=0; path=/;";
      window.location.replace("/pwsadmin/home");
    });

    loadDashboard();
  </script>
</body>
</html>
"""


def _client_ip(request: Request) -> str | None:
    if request.client is None:
        return None
    return request.client.host


def _extract_bearer_token(request: Request) -> str | None:
    auth_header = request.headers.get("Authorization", "")
    if auth_header.lower().startswith("bearer "):
        return auth_header.split(" ", 1)[1].strip()
    return None


def _build_dashboard_template_context(
    request: Request,
    user: User,
    requested_tab: str | None = None,
    requested_subtab: str | None = None,
) -> dict[str, Any]:
    tabs = get_dashboard_tabs()
    active_tab_def, active_subtab = resolve_tab_and_subtab(requested_tab, requested_subtab)
    active_subtabs = {
        tab.key: (
            active_subtab
            if tab.key == active_tab_def.key and active_subtab is not None
            else tab.default_subtab
        )
        for tab in tabs
        if tab.subtabs
    }
    return {
        "request": request,
        "display_name": user.full_name or user.username or user.email,
        "email": user.email,
        "tabs": tabs,
        "active_tab": active_tab_def.key,
        "active_subtabs": active_subtabs,
        "asset_css_files": iter_dashboard_asset_urls(tabs),
        "dashboard_manifest_json": json.dumps(
            dashboard_manifest(active_tab_def.key, active_subtab),
            ensure_ascii=False,
        ),
    }


def _render_dashboard_page(
    request: Request,
    user: User,
    requested_tab: str | None = None,
    requested_subtab: str | None = None,
) -> HTMLResponse:
    return PWSADMIN_TEMPLATES.TemplateResponse(
        "pwsadmin/dashboard.html",
        _build_dashboard_template_context(request, user, requested_tab, requested_subtab),
    )


def _require_admin_user(current_user: User) -> None:
    if not current_user.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin access required")


MAX_TASK_DATA_SIZE_BYTES = 100 * 1024


def _normalize_task_scheduled_at(value: datetime | None) -> datetime:
    if value is None:
        return datetime.now(timezone.utc)
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _build_admin_task_data(payload: TaskEnqueueCreate) -> dict[str, Any]:
    task_data = dict(payload.payload or {})
    existing_action = task_data.get("action")
    if existing_action is not None and str(existing_action).strip() != payload.action:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="payload.action must match the selected action",
        )
    task_data["action"] = payload.action

    encoded = json.dumps(task_data, separators=(",", ":"), default=str).encode("utf-8")
    if len(encoded) > MAX_TASK_DATA_SIZE_BYTES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Task data exceeds 100 KB")
    return task_data


REQUIRED_MESSAGE_CLASS_NAME = "unclassified"


def _is_required_message_class_name(value: Any) -> bool:
    return str(value or "").strip().lower() == REQUIRED_MESSAGE_CLASS_NAME


def _list_message_class_rows(
    *,
    include_inactive: bool,
    limit: int | None = None,
    cursor: int | None = None,
) -> list[dict[str, Any]]:
    where_sql = "" if include_inactive else "WHERE mc.is_active = TRUE"
    params: dict[str, Any] = {}
    if cursor is not None:
        where_sql = f"{where_sql} {'AND' if where_sql else 'WHERE'} mc.id < :cursor"
        params["cursor"] = cursor
    order_sql = "ORDER BY mc.id DESC" if limit is not None else "ORDER BY LOWER(mc.name), mc.id"
    limit_sql = "LIMIT :limit" if limit is not None else ""
    if limit is not None:
        params["limit"] = limit
    rows = execute_auto_query(
        f"""
        SELECT
            mc.id,
            mc.name,
            mc.description,
            mc.parent_id,
            mc.is_active,
            mc.created_at,
            mc.updated_at,
            COALESCE(usage_stats.usage_count, 0)::int AS usage_count
        FROM message_classes mc
        LEFT JOIN (
            SELECT class_id, COUNT(*)::int AS usage_count
            FROM message_class_lookup
            GROUP BY class_id
        ) AS usage_stats ON usage_stats.class_id = mc.id
        {where_sql}
        {order_sql}
        {limit_sql}
        """
        ,
        params=params or None,
    )
    return rows or []


def _get_message_class_row(class_id: int) -> dict[str, Any] | None:
    return execute_auto_query(
        """
        SELECT
            mc.id,
            mc.name,
            mc.description,
            mc.parent_id,
            mc.is_active,
            mc.created_at,
            mc.updated_at,
            COALESCE(usage_stats.usage_count, 0)::int AS usage_count
        FROM message_classes mc
        LEFT JOIN (
            SELECT class_id, COUNT(*)::int AS usage_count
            FROM message_class_lookup
            GROUP BY class_id
        ) AS usage_stats ON usage_stats.class_id = mc.id
        WHERE mc.id = :class_id
        LIMIT 1
        """,
        params={"class_id": class_id},
        fetch_one=True,
    )


def _get_message_class_or_404(class_id: int) -> dict[str, Any]:
    row = _get_message_class_row(class_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message class not found")
    return row


def _assert_message_class_name_available(name: str, *, exclude_id: int | None = None) -> None:
    query = """
        SELECT id
        FROM message_classes
        WHERE LOWER(name) = LOWER(:name)
    """
    params: dict[str, Any] = {"name": name}
    if exclude_id is not None:
        query += " AND id <> :exclude_id"
        params["exclude_id"] = exclude_id
    query += " LIMIT 1"
    existing = execute_auto_query(query, params=params, fetch_one=True)
    if existing is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Message class name already exists")


def _assert_message_class_mutation_allowed(
    current_row: dict[str, Any],
    *,
    next_name: str | None = None,
    next_is_active: bool | None = None,
    deleting: bool = False,
) -> None:
    if not _is_required_message_class_name(current_row.get("name")):
        return
    if deleting:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The required 'unclassified' message class cannot be deleted",
        )
    if next_name is not None and not _is_required_message_class_name(next_name):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The required 'unclassified' message class cannot be renamed",
        )
    if next_is_active is False:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The required 'unclassified' message class cannot be deactivated",
        )


def _assert_required_message_class_is_active(name: str, is_active: bool) -> None:
    if _is_required_message_class_name(name) and not is_active:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The required 'unclassified' message class must stay active",
        )


def _coerce_secret_id(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _coerce_bool(value: Any, *, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off"}:
            return False
    return default


def _parse_platform_api_token_slots(metadata: Any) -> list[dict[str, Any]]:
    if not isinstance(metadata, dict):
        return []
    secret_section = metadata.get("secret")
    if not isinstance(secret_section, dict):
        return []

    slots: list[dict[str, Any]] = []
    for token_key, token_config in secret_section.items():
        if not isinstance(token_config, dict):
            continue
        secret_id = _coerce_secret_id(token_config.get("secret_table_ptr"))
        slots.append(
            {
                "token_key": str(token_key),
                "title": str(token_key),
                "header_name": token_config.get("Name"),
                "auth_type": token_config.get("type"),
                "required": _coerce_bool(token_config.get("required"), default=True),
                "secret_id": secret_id,
                "configured": secret_id is not None,
            }
        )
    return slots


WHEELHOUSE_RM_TOKEN_KEY = "RM API Key"
WHEELHOUSE_RM_HEADER_NAME = "X-Integration-Api-Key"


def _is_wheelhouse_platform_name(value: Any) -> bool:
    return "wheelhouse" in str(value or "").strip().lower()


def _wheelhouse_slot_role(slot: dict[str, Any]) -> str | None:
    header_name = str(slot.get("header_name") or "").strip().lower()
    token_key = str(slot.get("token_key") or "").strip().lower()
    title = str(slot.get("title") or "").strip().lower()

    if header_name in {"x-integration-api-key", "x-integration-apikey"}:
        return "integration"
    if header_name in {"x-user-access-key", "x-user-accesskey"}:
        return "access"
    if header_name in {"x-user-api-key", "x-user-apikey"}:
        return "user"
    if "integration" in token_key or "rm api key" in token_key:
        return "integration"
    if "access key" in token_key:
        return "access"
    if token_key in {"api key", "user api key"} or "user api" in token_key:
        return "user"
    if "integration" in title or "rm api key" in title:
        return "integration"
    if "access key" in title:
        return "access"
    if title in {"api key", "user api key"} or "user api" in title:
        return "user"
    return None


def _resolve_wheelhouse_canonical_secret_id(slots: list[dict[str, Any]]) -> int | None:
    def _first_secret_id_for_roles(roles: set[str]) -> int | None:
        for slot in slots:
            role = _wheelhouse_slot_role(slot)
            secret_id = _coerce_secret_id(slot.get("secret_id"))
            if role in roles and secret_id is not None:
                return secret_id
        return None

    selected_secret_id = _first_secret_id_for_roles({"integration", "access"})
    if selected_secret_id is not None:
        return selected_secret_id
    selected_secret_id = _first_secret_id_for_roles({"user"})
    if selected_secret_id is not None:
        return selected_secret_id
    for slot in slots:
        secret_id = _coerce_secret_id(slot.get("secret_id"))
        if secret_id is not None:
            return secret_id
    return None


def _canonicalize_wheelhouse_token_slots(slots: list[dict[str, Any]]) -> list[dict[str, Any]]:
    secret_id = _resolve_wheelhouse_canonical_secret_id(slots)
    return [
        {
            "token_key": WHEELHOUSE_RM_TOKEN_KEY,
            "title": WHEELHOUSE_RM_TOKEN_KEY,
            "header_name": WHEELHOUSE_RM_HEADER_NAME,
            "auth_type": "API Key",
            "required": True,
            "secret_id": secret_id,
            "configured": secret_id is not None,
        }
    ]


def _canonicalize_wheelhouse_secret_section(metadata: Any) -> dict[str, Any]:
    slots = _parse_platform_api_token_slots(metadata)
    canonical_slot = _canonicalize_wheelhouse_token_slots(slots)[0]
    return {
        WHEELHOUSE_RM_TOKEN_KEY: {
            "Name": WHEELHOUSE_RM_HEADER_NAME,
            "type": "API Key",
            "required": True,
            "secret_table_ptr": canonical_slot.get("secret_id"),
        }
    }


def _normalize_wheelhouse_token_key(token_key: str) -> str:
    candidate = str(token_key or "").strip()
    if not candidate:
        return candidate
    if candidate.lower() == WHEELHOUSE_RM_TOKEN_KEY.lower():
        return WHEELHOUSE_RM_TOKEN_KEY
    role = _wheelhouse_slot_role(
        {"token_key": candidate, "title": candidate, "header_name": candidate}
    )
    if role in {"integration", "access", "user"}:
        return WHEELHOUSE_RM_TOKEN_KEY
    return candidate


def _migrate_wheelhouse_platform_metadata(
    platform: dict[str, Any],
    *,
    persist: bool = True,
) -> dict[str, Any]:
    if not _is_wheelhouse_platform_name(platform.get("name")):
        return platform

    raw_metadata = platform.get("metadata")
    metadata = raw_metadata if isinstance(raw_metadata, dict) else {}
    canonical_secret_section = _canonicalize_wheelhouse_secret_section(metadata)
    current_secret_section = metadata.get("secret")
    if isinstance(current_secret_section, dict) and current_secret_section == canonical_secret_section:
        return platform

    next_metadata = dict(metadata)
    next_metadata["secret"] = canonical_secret_section
    if persist:
        execute_auto_write(
            """
            UPDATE platforms
            SET metadata = CAST(:metadata AS jsonb)
            WHERE id = :platform_id
            """,
            params={
                "platform_id": int(platform.get("id") or 0),
                "metadata": json.dumps(next_metadata),
            },
        )
    normalized_platform = dict(platform)
    normalized_platform["metadata"] = next_metadata
    return normalized_platform


def _find_platform_api_token_slot(metadata: Any, token_key: str) -> dict[str, Any] | None:
    for slot in _parse_platform_api_token_slots(metadata):
        if slot["token_key"] == token_key:
            return slot
    return None


def _normalize_platform_token_key(platform: dict[str, Any], token_key: str) -> str:
    if _is_wheelhouse_platform_name(platform.get("name")):
        return _normalize_wheelhouse_token_key(token_key)
    return str(token_key or "").strip()


def _find_platform_api_token_slot_with_aliases(
    platform: dict[str, Any],
    metadata: Any,
    token_key: str,
) -> dict[str, Any] | None:
    normalized_token_key = _normalize_platform_token_key(platform, token_key)
    return _find_platform_api_token_slot(metadata, normalized_token_key)


def _canonicalize_platform_metadata_for_token_management(platform: dict[str, Any]) -> dict[str, Any]:
    if _is_wheelhouse_platform_name(platform.get("name")):
        return _migrate_wheelhouse_platform_metadata(platform, persist=True)
    return platform


def _canonicalize_platform_metadata_for_read(platform: dict[str, Any]) -> dict[str, Any]:
    if _is_wheelhouse_platform_name(platform.get("name")):
        return _migrate_wheelhouse_platform_metadata(platform, persist=False)
    return platform


def _first_platform_api_token_slot(metadata: Any) -> dict[str, Any] | None:
    slots = _parse_platform_api_token_slots(metadata)
    if not slots:
        return None
    return slots[0]


def _get_platform_row(platform_id: int) -> dict[str, Any]:
    platform = execute_auto_query(
        "SELECT id, name, type::text AS type, metadata FROM platforms WHERE id = :pid",
        params={"pid": platform_id},
        fetch_one=True,
    )
    if platform is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Platform not found")
    return platform


def _sanitize_platform_metadata(metadata: Any, *, include_secret_status: bool = False) -> dict[str, Any]:
    if not isinstance(metadata, dict):
        return {}
    sanitized = dict(metadata)
    secret_section = sanitized.get("secret")
    if isinstance(secret_section, dict):
        if include_secret_status:
            slots: dict[str, Any] = {}
            for token_key, token_config in secret_section.items():
                if not isinstance(token_config, dict):
                    continue
                secret_id = _coerce_secret_id(token_config.get("secret_table_ptr"))
                slots[str(token_key)] = {
                    "Name": token_config.get("Name"),
                    "type": token_config.get("type"),
                    "required": _coerce_bool(token_config.get("required"), default=True),
                    "secret_table_ptr": secret_id,
                    "configured": secret_id is not None,
                }
            sanitized["secret"] = slots
        else:
            sanitized.pop("secret", None)
    return sanitized


DEFAULT_LLM_ALLOWED_MODELS = ["gpt-5-nano", "gpt-5-mini", "gpt-5.1-mini"]
DEFAULT_LLM_PROVIDER_KEY = "openai"
DEFAULT_LLM_PROVIDER_DISPLAY_NAME = "OpenAI"
DEFAULT_LLM_PROVIDER_MODEL = os.getenv("OPENAI_LLM_MODEL", "gpt-5-nano").strip() or "gpt-5-nano"
DEFAULT_OPENAI_API_BASE_URL = "https://api.openai.com"
DEFAULT_OLLAMA_PROVIDER_KEY = "ollama"
DEFAULT_OLLAMA_PROVIDER_DISPLAY_NAME = "Ollama"
DEFAULT_OLLAMA_PROVIDER_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2:3b").strip() or "llama3.2:3b"
DEFAULT_OLLAMA_ALLOWED_MODELS = ["llama3.2:3b", "llama3.2:1b"]
DEFAULT_OLLAMA_API_BASE_URL = (
    os.getenv("OLLAMA_API_URL")
    or os.getenv("OLLAMA_BASE_URL")
    or "http://host.docker.internal:11550"
)


def _normalize_allowed_models(value: Any, *, selected_model: str) -> list[str]:
    allowed_models: list[str] = []
    if isinstance(value, list):
        for item in value:
            model = str(item or "").strip()
            if model and model not in allowed_models:
                allowed_models.append(model)
    if not allowed_models:
        allowed_models = list(DEFAULT_LLM_ALLOWED_MODELS)
    if selected_model and selected_model not in allowed_models:
        allowed_models.append(selected_model)
    return allowed_models


def _llm_provider_requires_api_key(provider_key: str | None) -> bool:
    return str(provider_key or "").strip().lower() == DEFAULT_LLM_PROVIDER_KEY


def _get_llm_provider_row(provider_id: int) -> dict[str, Any]:
    provider = execute_auto_query(
        """
        SELECT
            id,
            provider_key,
            display_name,
            is_active,
            enabled,
            use_case,
            api_base_url,
            api_key_secret_id,
            selected_model,
            allowed_models,
            timeout_seconds,
            metadata,
            created_at,
            updated_at
        FROM llm_providers
        WHERE id = :provider_id
        """,
        params={"provider_id": provider_id},
        fetch_one=True,
    )
    if provider is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="LLM provider not found")
    return provider


def _ensure_default_llm_provider() -> None:
    allowed_models = _normalize_allowed_models(DEFAULT_LLM_ALLOWED_MODELS, selected_model=DEFAULT_LLM_PROVIDER_MODEL)
    execute_auto_write(
        """
        INSERT INTO llm_providers (
            provider_key,
            display_name,
            is_active,
            enabled,
            use_case,
            api_base_url,
            api_key_secret_id,
            selected_model,
            allowed_models,
            timeout_seconds,
            metadata
        ) VALUES (
            :provider_key,
            :display_name,
            TRUE,
            TRUE,
            'message_classifier',
            'https://api.openai.com',
            NULL,
            :selected_model,
            CAST(:allowed_models AS jsonb),
            60,
            '{"credential": {"label": "API Key", "auth_type": "Bearer Token"}}'::jsonb
        )
        ON CONFLICT (provider_key) DO NOTHING
        """,
        params={
            "provider_key": DEFAULT_LLM_PROVIDER_KEY,
            "display_name": DEFAULT_LLM_PROVIDER_DISPLAY_NAME,
            "selected_model": DEFAULT_LLM_PROVIDER_MODEL,
            "allowed_models": json.dumps(allowed_models),
        },
    )
    ollama_allowed_models = _normalize_allowed_models(
        DEFAULT_OLLAMA_ALLOWED_MODELS,
        selected_model=DEFAULT_OLLAMA_PROVIDER_MODEL,
    )
    execute_auto_write(
        """
        INSERT INTO llm_providers (
            provider_key,
            display_name,
            is_active,
            enabled,
            use_case,
            api_base_url,
            api_key_secret_id,
            selected_model,
            allowed_models,
            timeout_seconds,
            metadata
        ) VALUES (
            :provider_key,
            :display_name,
            TRUE,
            FALSE,
            'message_classifier',
            :api_base_url,
            NULL,
            :selected_model,
            CAST(:allowed_models AS jsonb),
            120,
            '{"credential": {"required": false, "label": "No API key required", "auth_type": "none"}}'::jsonb
        )
        ON CONFLICT (provider_key) DO UPDATE
        SET
            display_name = EXCLUDED.display_name,
            is_active = EXCLUDED.is_active,
            use_case = EXCLUDED.use_case,
            api_base_url = COALESCE(NULLIF(llm_providers.api_base_url, ''), EXCLUDED.api_base_url),
            selected_model = COALESCE(NULLIF(llm_providers.selected_model, ''), EXCLUDED.selected_model),
            allowed_models = CASE
                WHEN jsonb_array_length(llm_providers.allowed_models) = 0 THEN EXCLUDED.allowed_models
                ELSE llm_providers.allowed_models
            END,
            timeout_seconds = COALESCE(llm_providers.timeout_seconds, EXCLUDED.timeout_seconds),
            metadata = llm_providers.metadata || EXCLUDED.metadata
        """,
        params={
            "provider_key": DEFAULT_OLLAMA_PROVIDER_KEY,
            "display_name": DEFAULT_OLLAMA_PROVIDER_DISPLAY_NAME,
            "api_base_url": DEFAULT_OLLAMA_API_BASE_URL,
            "selected_model": DEFAULT_OLLAMA_PROVIDER_MODEL,
            "allowed_models": json.dumps(ollama_allowed_models),
        },
    )


def _serialize_llm_provider(row: dict[str, Any]) -> dict[str, Any]:
    selected_model = str(row.get("selected_model") or DEFAULT_LLM_PROVIDER_MODEL).strip() or DEFAULT_LLM_PROVIDER_MODEL
    allowed_models = _normalize_allowed_models(row.get("allowed_models"), selected_model=selected_model)
    return {
        "id": row.get("id"),
        "provider_key": row.get("provider_key"),
        "display_name": row.get("display_name"),
        "is_active": bool(row.get("is_active")),
        "enabled": bool(row.get("enabled")),
        "use_case": row.get("use_case") or "message_classifier",
        "api_base_url": row.get("api_base_url"),
        "api_key_secret_id": row.get("api_key_secret_id"),
        "api_key_configured": row.get("api_key_secret_id") is not None,
        "requires_api_key": _llm_provider_requires_api_key(row.get("provider_key")),
        "selected_model": selected_model,
        "allowed_models": allowed_models,
        "timeout_seconds": int(row.get("timeout_seconds") or 60),
        "metadata": row.get("metadata") if isinstance(row.get("metadata"), dict) else {},
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
    }


def _normalize_llm_api_base_url(provider_key: str, value: Any) -> str:
    raw = str(value or "").strip()
    if provider_key == DEFAULT_OLLAMA_PROVIDER_KEY:
        return (raw or DEFAULT_OLLAMA_API_BASE_URL).rstrip("/")
    if provider_key == DEFAULT_LLM_PROVIDER_KEY:
        return (raw or os.getenv("OPENAI_API_BASE_URL") or DEFAULT_OPENAI_API_BASE_URL).rstrip("/")
    return raw.rstrip("/")


def _openai_chat_completions_url(api_base_url: str) -> str:
    base = api_base_url.rstrip("/")
    if base == DEFAULT_OPENAI_API_BASE_URL:
        base = f"{base}/v1"
    return f"{base}/chat/completions"


def _llm_health_result(
    *,
    provider_id: int,
    provider_key: str,
    model: str,
    accessible: bool,
    started_at: float,
    error_code: str | None = None,
    error_message: str | None = None,
    status_code: int | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "provider_id": provider_id,
        "provider_key": provider_key,
        "model": model,
        "accessible": accessible,
        "latency_ms": int((time.monotonic() - started_at) * 1000),
        "error_code": error_code,
        "error_message": error_message,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }
    if status_code is not None:
        result["status_code"] = status_code
    return result


def _check_openai_llm_provider(
    provider: dict[str, Any],
    *,
    model: str,
    timeout_seconds: int,
    api_key_override: str | None = None,
) -> dict[str, Any]:
    started_at = time.monotonic()
    provider_id = int(provider.get("id"))
    provider_key = str(provider.get("provider_key") or DEFAULT_LLM_PROVIDER_KEY)
    api_key = (
        api_key_override
        or _get_secret_value(provider.get("api_key_secret_id"))
        or os.getenv("OPENAI_API_KEY")
        or ""
    ).strip()
    if not api_key:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="MISSING_API_KEY",
            error_message="OpenAI API key is required.",
        )

    url = _openai_chat_completions_url(
        _normalize_llm_api_base_url(provider_key, provider.get("api_base_url"))
    )
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Reply with JSON only."},
            {"role": "user", "content": '{"health_check":true}'},
        ],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 16,
    }
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    try:
        with httpx.Client(timeout=float(timeout_seconds)) as client:
            response = client.post(url, headers=headers, json=payload)
    except httpx.TimeoutException:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="TIMEOUT",
            error_message=f"OpenAI health check timed out after {timeout_seconds}s.",
        )
    except httpx.HTTPError as exc:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="NETWORK_ERROR",
            error_message=f"OpenAI health check request failed: {exc}",
        )

    if response.status_code in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN):
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="INVALID_API_KEY",
            error_message="OpenAI API key was rejected.",
            status_code=response.status_code,
        )
    if response.status_code == status.HTTP_404_NOT_FOUND:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="MODEL_NOT_FOUND",
            error_message=f"OpenAI model '{model}' was not found or is not available.",
            status_code=response.status_code,
        )
    if response.status_code >= status.HTTP_400_BAD_REQUEST:
        detail = response.text[:300]
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="PROVIDER_ERROR",
            error_message=f"OpenAI health check failed: {detail}",
            status_code=response.status_code,
        )

    return _llm_health_result(
        provider_id=provider_id,
        provider_key=provider_key,
        model=model,
        accessible=True,
        started_at=started_at,
        status_code=response.status_code,
    )


def _check_ollama_llm_provider(
    provider: dict[str, Any],
    *,
    model: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    started_at = time.monotonic()
    provider_id = int(provider.get("id"))
    provider_key = str(provider.get("provider_key") or DEFAULT_OLLAMA_PROVIDER_KEY)
    base_url = _normalize_llm_api_base_url(provider_key, provider.get("api_base_url"))
    try:
        with httpx.Client(timeout=float(timeout_seconds)) as client:
            response = client.get(f"{base_url}/api/tags")
    except httpx.TimeoutException:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="TIMEOUT",
            error_message=f"Ollama health check timed out after {timeout_seconds}s.",
        )
    except httpx.HTTPError as exc:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="NETWORK_ERROR",
            error_message=f"Ollama health check request failed: {exc}",
        )

    if response.status_code >= status.HTTP_400_BAD_REQUEST:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="PROVIDER_ERROR",
            error_message=f"Ollama health check failed with HTTP {response.status_code}.",
            status_code=response.status_code,
        )

    try:
        payload = response.json()
    except ValueError:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="INVALID_RESPONSE",
            error_message="Ollama tags response was not valid JSON.",
            status_code=response.status_code,
        )

    available_models: set[str] = set()
    model_items = payload.get("models") if isinstance(payload, dict) else []
    for item in model_items or []:
        if not isinstance(item, dict):
            continue
        for key in ("name", "model"):
            value = str(item.get(key) or "").strip()
            if value:
                available_models.add(value)
    if model not in available_models:
        return _llm_health_result(
            provider_id=provider_id,
            provider_key=provider_key,
            model=model,
            accessible=False,
            started_at=started_at,
            error_code="MODEL_NOT_FOUND",
            error_message=f"Ollama model '{model}' is not installed.",
            status_code=response.status_code,
        )

    return _llm_health_result(
        provider_id=provider_id,
        provider_key=provider_key,
        model=model,
        accessible=True,
        started_at=started_at,
        status_code=response.status_code,
    )


def _check_llm_provider_accessibility(
    provider: dict[str, Any],
    *,
    model: str,
    timeout_seconds: int,
    api_key_override: str | None = None,
) -> dict[str, Any]:
    provider_key = str(provider.get("provider_key") or "").strip().lower()
    if provider_key == DEFAULT_LLM_PROVIDER_KEY:
        return _check_openai_llm_provider(
            provider,
            model=model,
            timeout_seconds=timeout_seconds,
            api_key_override=api_key_override,
        )
    if provider_key == DEFAULT_OLLAMA_PROVIDER_KEY:
        return _check_ollama_llm_provider(
            provider,
            model=model,
            timeout_seconds=timeout_seconds,
        )
    return _llm_health_result(
        provider_id=int(provider.get("id")),
        provider_key=provider_key or "unknown",
        model=model,
        accessible=False,
        started_at=time.monotonic(),
        error_code="UNSUPPORTED_PROVIDER",
        error_message=f"Unsupported LLM provider '{provider_key}'.",
    )


def _get_secret_value(secret_id: int) -> str | None:
    if secret_id is None:
        return None
    return execute_auto_function(
        "get_secret",
        params={"p_id": secret_id},
        fetch_one=True,
        expect_scalar=True,
    )


def _get_secret_description(secret_id: int) -> str | None:
    if secret_id is None:
        return None
    row = execute_auto_query(
        "SELECT description FROM secrets WHERE id = :sid",
        params={"sid": secret_id},
        fetch_one=True,
    )
    if not row:
        return None
    description = row.get("description")
    return str(description) if description is not None else None


def _build_platform_auth_headers(
    metadata: Any,
    *,
    override_secrets: dict[str, str] | None = None,
    override_token_key: str | None = None,
    override_secret: str | None = None,
) -> dict[str, str]:
    headers: dict[str, str] = {}
    for slot in _parse_platform_api_token_slots(metadata):
        slot_token_key = str(slot.get("token_key") or "")
        secret_value: str | None
        if override_secrets and slot_token_key in override_secrets:
            secret_value = override_secrets.get(slot_token_key)
        elif override_token_key is not None and slot_token_key == override_token_key:
            secret_value = override_secret
        else:
            secret_id = slot.get("secret_id")
            if secret_id is None:
                continue
            secret_value = _get_secret_value(secret_id)
        if not secret_value:
            continue
        header_name = str(slot.get("header_name") or slot.get("token_key") or "").strip()
        if not header_name:
            continue
        auth_type = str(slot.get("auth_type") or "").strip().lower()
        if auth_type == "bearer token":
            headers[header_name] = f"Bearer {secret_value}"
        else:
            headers[header_name] = secret_value
    return headers


def _select_ownerrez_token_slot(metadata: Any) -> dict[str, Any] | None:
    slots = _parse_platform_api_token_slots(metadata)
    fallback_slot: dict[str, Any] | None = None
    for slot in slots:
        header_name = str(slot.get("header_name") or "").strip().lower()
        if fallback_slot is None:
            fallback_slot = slot
        if header_name == "authorization":
            return slot
    return fallback_slot


def _resolve_ownerrez_platform_auth_headers(
    platform: dict[str, Any],
    *,
    allow_env_fallback: bool = False,
) -> dict[str, str]:
    platform_id = int(platform.get("id") or 0)
    metadata = platform.get("metadata") or {}
    slot = _select_ownerrez_token_slot(metadata)
    fallback_secret = str(os.getenv("OWNERREZ_BEARER_TOKEN") or "").strip() if allow_env_fallback else ""

    if slot is None:
        if fallback_secret:
            return {"Authorization": f"Bearer {fallback_secret}"}
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"OwnerRez platform {platform_id} is missing platform secret binding "
                "(platforms.metadata.secret.*.secret_table_ptr)"
            ),
        )

    token_key = str(slot.get("token_key") or "Authorization")
    secret_id = slot.get("secret_id")
    if secret_id is None:
        if fallback_secret:
            return {"Authorization": f"Bearer {fallback_secret}"}
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"OwnerRez platform {platform_id} missing secret_table_ptr at "
                f"platforms.metadata.secret.{token_key}.secret_table_ptr"
            ),
        )

    secret_value = _get_secret_value(int(secret_id))
    if not secret_value:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"OwnerRez platform {platform_id} secret_table_ptr {secret_id} does not resolve to a secret value",
        )

    header_name = str(slot.get("header_name") or "Authorization").strip() or "Authorization"
    auth_type = str(slot.get("auth_type") or "").strip().lower()
    if auth_type == "bearer token" and not secret_value.lower().startswith("bearer "):
        return {header_name: f"Bearer {secret_value}"}
    return {header_name: secret_value}


def _resolve_platform_auth_headers_for_remote_fetch(platform: dict[str, Any]) -> dict[str, str]:
    metadata = platform.get("metadata") or {}
    platform_name = str(platform.get("name") or "").strip().lower()
    if "ownerrez" in platform_name:
        return _resolve_ownerrez_platform_auth_headers(platform, allow_env_fallback=False)
    return _build_platform_auth_headers(metadata)


def _token_validation_result(
    *,
    provider: str,
    endpoint: str,
    checked: bool = True,
    ok: bool,
    message: str,
    status_code: int | None = None,
    reason: str | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "checked": checked,
        "provider": provider,
        "endpoint": endpoint,
        "ok": ok,
        "message": message,
    }
    if status_code is not None:
        result["status_code"] = status_code
    if reason:
        result["reason"] = reason
    return result


def _validate_ownerrez_auth_headers(headers: dict[str, str]) -> dict[str, Any]:
    authorization = headers.get("Authorization")
    if not authorization:
        return _token_validation_result(
            provider="OwnerRez",
            endpoint="/v2/properties",
            ok=False,
            message="OwnerRez Authorization header is missing",
            reason="missing_header",
        )

    base_url = os.getenv("OWNERREZ_API_BASE_URL", "https://api.ownerrez.com/v2").rstrip("/")
    url = f"{base_url}/properties"
    params = {"active": "true", "page": 1, "pageSize": 1}
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.get(url, headers={"Authorization": authorization}, params=params)
    except httpx.TimeoutException:
        return _token_validation_result(
            provider="OwnerRez",
            endpoint="/v2/properties",
            ok=False,
            message="OwnerRez token validation timed out",
            reason="timeout",
        )
    except httpx.HTTPError:
        return _token_validation_result(
            provider="OwnerRez",
            endpoint="/v2/properties",
            ok=False,
            message="OwnerRez token validation request failed",
            reason="network_error",
        )

    if resp.status_code in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN):
        return _token_validation_result(
            provider="OwnerRez",
            endpoint="/v2/properties",
            ok=False,
            message="OwnerRez token is invalid",
            status_code=resp.status_code,
            reason="invalid_token",
        )
    if resp.status_code >= status.HTTP_400_BAD_REQUEST:
        return _token_validation_result(
            provider="OwnerRez",
            endpoint="/v2/properties",
            ok=False,
            message="OwnerRez API validation failed",
            status_code=resp.status_code,
            reason="platform_error",
        )

    return _token_validation_result(
        provider="OwnerRez",
        endpoint="/v2/properties",
        ok=True,
        message="OwnerRez token validated successfully",
        status_code=resp.status_code,
    )


def _validate_ownerrez_token(secret: str) -> dict[str, Any]:
    return _validate_ownerrez_auth_headers({"Authorization": f"Bearer {secret}"})


def _validate_pricelabs_auth_headers(headers: dict[str, str]) -> dict[str, Any]:
    api_key = headers.get("X-API-Key")
    if not api_key:
        return _token_validation_result(
            provider="PriceLabs",
            endpoint="/v1/listings",
            ok=False,
            message="PriceLabs X-API-Key header is missing",
            reason="missing_header",
        )

    base_url = os.getenv("PRICELABS_API_BASE_URL", "https://api.pricelabs.co").rstrip("/")
    url = f"{base_url}/v1/listings"
    params = {"skip_hidden": "true", "only_syncing_listings": "false"}
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.get(url, headers={"X-API-Key": api_key}, params=params)
    except httpx.TimeoutException:
        return _token_validation_result(
            provider="PriceLabs",
            endpoint="/v1/listings",
            ok=False,
            message="PriceLabs token validation timed out",
            reason="timeout",
        )
    except httpx.HTTPError:
        return _token_validation_result(
            provider="PriceLabs",
            endpoint="/v1/listings",
            ok=False,
            message="PriceLabs token validation request failed",
            reason="network_error",
        )

    if resp.status_code in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN):
        return _token_validation_result(
            provider="PriceLabs",
            endpoint="/v1/listings",
            ok=False,
            message="PriceLabs API key is invalid",
            status_code=resp.status_code,
            reason="invalid_token",
        )
    if resp.status_code >= status.HTTP_400_BAD_REQUEST:
        return _token_validation_result(
            provider="PriceLabs",
            endpoint="/v1/listings",
            ok=False,
            message="PriceLabs API validation failed",
            status_code=resp.status_code,
            reason="platform_error",
        )

    return _token_validation_result(
        provider="PriceLabs",
        endpoint="/v1/listings",
        ok=True,
        message="PriceLabs API key validated successfully",
        status_code=resp.status_code,
    )


def _validate_wheelhouse_integration_key(integration_key: str | None) -> dict[str, Any]:
    if not integration_key:
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse validation requires an RM API key in X-Integration-Api-Key.",
            reason="missing_required_token",
        )

    base_url = os.getenv("WHEELHOUSE_API_BASE_URL", "https://api.usewheelhouse.com/ss_api/v1").rstrip("/")
    url = f"{base_url}/listings"
    params = {"per_page": 1, "page": 1}
    headers = {
        "X-Integration-Api-Key": integration_key,
        "Accept": "application/json",
    }
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.get(url, headers=headers, params=params)
    except httpx.TimeoutException:
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse RM API key validation timed out",
            reason="timeout",
        )
    except httpx.HTTPError:
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse RM API key validation request failed",
            reason="network_error",
        )

    if resp.status_code in (status.HTTP_401_UNAUTHORIZED, status.HTTP_403_FORBIDDEN):
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse RM API key is invalid",
            status_code=resp.status_code,
            reason="invalid_token",
        )
    if resp.status_code >= status.HTTP_400_BAD_REQUEST:
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse RM API key validation failed",
            status_code=resp.status_code,
            reason="platform_error",
        )

    return _token_validation_result(
        provider="Wheelhouse",
        endpoint="/ss_api/v1/listings",
        ok=True,
        message="Wheelhouse RM API key validated successfully",
        status_code=resp.status_code,
    )


def _validate_platform_api_token(
    platform: dict[str, Any],
    *,
    metadata: Any,
    slot: dict[str, Any],
    secret: str,
    validation_overrides: dict[str, str] | None = None,
) -> dict[str, Any]:
    overrides: dict[str, str] = {}
    if validation_overrides:
        for key, value in validation_overrides.items():
            token_key = str(key or "").strip()
            secret_value = str(value or "").strip()
            if token_key and secret_value:
                overrides[token_key] = secret_value
    slot_token_key = str(slot.get("token_key") or "").strip()
    if slot_token_key and secret:
        overrides[slot_token_key] = secret
    headers = _build_platform_auth_headers(
        metadata,
        override_secrets=overrides or None,
        override_token_key=slot_token_key or None,
        override_secret=secret,
    )
    platform_name = str(platform.get("name") or "").lower()
    if "ownerrez" in platform_name:
        if "Authorization" not in headers and not overrides:
            headers = _resolve_ownerrez_platform_auth_headers(platform, allow_env_fallback=False)
        return _validate_ownerrez_auth_headers(headers)
    if "pricelabs" in platform_name:
        return _validate_pricelabs_auth_headers(headers)
    if "wheelhouse" in platform_name:
        token_header = str(slot.get("header_name") or "").strip().lower()
        integration_key = _resolve_wheelhouse_integration_key(headers)
        if token_header in {
            "x-integration-api-key",
            "x-integration-apikey",
            "x-user-access-key",
            "x-user-accesskey",
            "x-user-api-key",
            "x-user-apikey",
        }:
            return _validate_wheelhouse_integration_key(integration_key)
        return _token_validation_result(
            provider="Wheelhouse",
            endpoint="/ss_api/v1/listings",
            ok=False,
            message="Wheelhouse token slot has unsupported header mapping",
            reason="unsupported_slot",
        )
    return {
        "checked": False,
        "provider": platform.get("name") or "Unknown",
        "ok": True,
        "message": "Validation not configured for this platform",
    }


def _platform_token_validation_error(validation: dict[str, Any]) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail={"message": validation.get("message") or "Token validation failed", "validation": validation},
    )


def _upsert_platform_api_token(
    platform_id: int,
    token_key: str,
    *,
    secret: str,
    description: str | None = None,
    validation_overrides: dict[str, str] | None = None,
) -> dict[str, Any]:
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    metadata = platform.get("metadata") or {}
    normalized_token_key = _normalize_platform_token_key(platform, token_key)
    slot = _find_platform_api_token_slot_with_aliases(platform, metadata, normalized_token_key)
    if slot is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="API token slot not found")
    canonical_token_key = str(slot.get("token_key") or normalized_token_key)

    current_secret_id = slot.get("secret_id")
    next_secret_id = current_secret_id
    action = "updated"
    previous_secret: str | None = None
    previous_description: str | None = None

    if current_secret_id is None:
        next_secret_id = execute_auto_function(
            "set_secret",
            params={"p_secret": secret, "p_description": description},
            fetch_one=True,
            write=True,
            expect_scalar=True,
        )
        action = "created"
    else:
        previous_secret = _get_secret_value(current_secret_id)
        previous_description = _get_secret_description(current_secret_id)
        if not previous_secret:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Unable to read existing platform token for rollback",
            )
        updated = execute_auto_function(
            "update_secret",
            params={"p_id": current_secret_id, "p_secret": secret, "p_description": description},
            fetch_one=True,
            write=True,
            expect_scalar=True,
        )
        if not updated:
            next_secret_id = execute_auto_function(
                "set_secret",
                params={"p_secret": secret, "p_description": description},
                fetch_one=True,
                write=True,
                expect_scalar=True,
            )
            action = "created"

    if next_secret_id is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to persist token")

    if next_secret_id != current_secret_id:
        execute_auto_write(
            """
            UPDATE platforms
            SET metadata = jsonb_set(
                COALESCE(metadata, '{}'::jsonb),
                ARRAY['secret', :token_key, 'secret_table_ptr'],
                to_jsonb(CAST(:secret_id AS BIGINT)),
                true
            )
            WHERE id = :platform_id
            """,
            params={
                "platform_id": platform_id,
                "token_key": canonical_token_key,
                "secret_id": next_secret_id,
            },
        )

    validation = _validate_platform_api_token(
        platform,
        metadata=metadata,
        slot=slot,
        secret=secret,
        validation_overrides=validation_overrides,
    )
    if not validation.get("ok"):
        try:
            if action == "created":
                _delete_platform_api_token(platform_id, canonical_token_key)
            elif current_secret_id is not None and previous_secret:
                execute_auto_function(
                    "update_secret",
                    params={
                        "p_id": current_secret_id,
                        "p_secret": previous_secret,
                        "p_description": previous_description,
                    },
                    fetch_one=True,
                    write=True,
                    expect_scalar=True,
                )
            else:
                raise RuntimeError("Rollback preconditions not met")
        except Exception as exc:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail={
                    "message": "Token validation failed and rollback failed",
                    "validation": validation,
                    "rollback_error": str(exc),
                },
            ) from exc
        raise _platform_token_validation_error(validation)

    return {
        "platform_id": platform_id,
        "platform_name": platform.get("name"),
        "token_key": canonical_token_key,
        "secret_id": next_secret_id,
        "configured": True,
        "action": action,
        "validation": validation,
    }


def _delete_platform_api_token(platform_id: int, token_key: str) -> dict[str, Any]:
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    metadata = platform.get("metadata") or {}
    normalized_token_key = _normalize_platform_token_key(platform, token_key)
    slot = _find_platform_api_token_slot_with_aliases(platform, metadata, normalized_token_key)
    if slot is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="API token slot not found")
    canonical_token_key = str(slot.get("token_key") or normalized_token_key)

    secret_id = slot.get("secret_id")
    if secret_id is not None:
        execute_auto_function("delete_secret", params={"p_id": secret_id}, fetch_one=True, write=True)

    execute_auto_write(
        """
        UPDATE platforms
        SET metadata = jsonb_set(
            COALESCE(metadata, '{}'::jsonb),
            ARRAY['secret', :token_key, 'secret_table_ptr'],
            'null'::jsonb,
            true
        )
        WHERE id = :platform_id
        """,
        params={"platform_id": platform_id, "token_key": canonical_token_key},
    )
    return {
        "platform_id": platform_id,
        "token_key": canonical_token_key,
        "secret_id": secret_id,
        "configured": False,
    }


_PROPERTY_FIELD_ALIASES: dict[str, tuple[str, ...]] = {
    "platform_property_id": ("platform_property_id", "id", "property_id", "listing_id"),
    "name": ("name", "title", "external_name"),
    "pms": ("pms",),
    "latitude": ("latitude", "lat", "location.latitude", "address.latitude"),
    "longitude": ("longitude", "lon", "lng", "location.longitude", "address.longitude"),
    "city": ("city", "city_name", "address.city", "location.city"),
    "state": ("state", "province", "address.state", "address.province", "location.state"),
    "country": ("country", "address.country", "location.country"),
    "timezone": ("timezone", "time_zone", "tz"),
    "currency_code": ("currency_code", "currency"),
    "public_url": ("public_url", "url", "listing_url", "links.calendar"),
}


def _extract_path_value(payload: Any, path: str) -> Any:
    if path == "":
        return payload
    current = payload
    for segment in path.split("."):
        if isinstance(current, dict):
            if segment not in current:
                return None
            current = current[segment]
            continue
        if isinstance(current, list) and segment.isdigit():
            index = int(segment)
            if index < 0 or index >= len(current):
                return None
            current = current[index]
            continue
        return None
    return current


def _normalize_coordinate_text(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    try:
        numeric = Decimal(text)
    except InvalidOperation:
        return ""
    if not numeric.is_finite():
        return ""
    normalized = format(numeric.normalize(), "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    if normalized in {"", "-0"}:
        return "0"
    return normalized


def _string_or_none(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def _normalize_property_row(
    raw: dict[str, Any],
    *,
    field_map: dict[str, str] | None = None,
) -> dict[str, Any]:
    def pick(canonical_key: str) -> Any:
        mapped_path = (field_map or {}).get(canonical_key)
        if mapped_path:
            mapped_value = _extract_path_value(raw, str(mapped_path))
            if mapped_value is not None and str(mapped_value).strip() != "":
                return mapped_value
        for alias in _PROPERTY_FIELD_ALIASES.get(canonical_key, ()):
            value = _extract_path_value(raw, alias)
            if value is not None and str(value).strip() != "":
                return value
        return None

    platform_property_id = _string_or_none(pick("platform_property_id")) or ""
    latitude = _normalize_coordinate_text(pick("latitude"))
    longitude = _normalize_coordinate_text(pick("longitude"))
    return {
        "platform_property_id": platform_property_id,
        "name": _string_or_none(pick("name")),
        "pms": _string_or_none(pick("pms")),
        "latitude": latitude,
        "longitude": longitude,
        "city": _string_or_none(pick("city")),
        "state": _string_or_none(pick("state")),
        "country": _string_or_none(pick("country")),
        "timezone": _string_or_none(pick("timezone")),
        "currency_code": _string_or_none(pick("currency_code")),
        "public_url": _string_or_none(pick("public_url")),
        "raw": raw,
    }


def _is_active_property_row(raw: dict[str, Any]) -> bool:
    active_value = raw.get("active")
    if active_value is None:
        return True
    return _coerce_bool(active_value, default=True)


def _coerce_query_params(raw_params: Any) -> dict[str, Any]:
    if not isinstance(raw_params, dict):
        return {}
    cleaned: dict[str, Any] = {}
    for key, value in raw_params.items():
        if value is None:
            continue
        if isinstance(value, bool | int | float):
            cleaned[str(key)] = value
            continue
        if isinstance(value, str):
            text_value = value.strip()
            if not text_value:
                continue
            if text_value.startswith("<") and text_value.endswith(">"):
                continue
            lowered = text_value.lower()
            if lowered in {"true", "false"}:
                cleaned[str(key)] = lowered == "true"
                continue
            if lowered in {"null", "none"}:
                continue
            if text_value.isdigit() or (text_value.startswith("-") and text_value[1:].isdigit()):
                cleaned[str(key)] = int(text_value)
                continue
            cleaned[str(key)] = text_value
            continue
        cleaned[str(key)] = value
    return cleaned


def _merge_query_params(defaults: dict[str, Any], overrides: Any) -> dict[str, Any]:
    merged = dict(defaults)
    merged.update(_coerce_query_params(overrides))
    return merged


def _ensure_api_base(base_url: str) -> str:
    candidate = base_url.strip()
    if not candidate:
        return candidate
    if "://" not in candidate:
        return f"https://{candidate}"
    return candidate


def _compose_api_url(base_url: str, path: str) -> str:
    base = _ensure_api_base(base_url).rstrip("/")
    return f"{base}/{path.lstrip('/')}"


def _fetch_ownerrez_properties(
    page: int,
    per_page: int,
    headers: dict[str, str],
    base_url: str,
    *,
    field_map: dict[str, str] | None = None,
    params_override: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], str | None]:
    url = _compose_api_url(base_url, "/properties")
    params = _merge_query_params(
        {
            "active": True,
            "page": page,
            "pageSize": per_page,
            "limit": per_page,
            "offset": max(page - 1, 0) * per_page,
        },
        params_override or {},
    )
    with httpx.Client(timeout=20.0) as client:
        resp = client.get(url, headers=headers, params=params)
        if resp.status_code >= status.HTTP_400_BAD_REQUEST:
            raise HTTPException(status_code=resp.status_code, detail="OwnerRez fetch failed")
        data = resp.json()
    if isinstance(data, dict):
        items = data.get("items")
        if not isinstance(items, list):
            items = data.get("properties")
        if not isinstance(items, list):
            items = data.get("data")
        if not isinstance(items, list):
            items = []
        next_page_url = data.get("next_page_url")
        next_page_url = str(next_page_url).strip() if next_page_url else None
    else:
        items = data
        next_page_url = None
    if not isinstance(items, list):
        items = []
    normalized: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if not _is_active_property_row(item):
            continue
        normalized.append(_normalize_property_row(dict(item), field_map=field_map))
    return normalized, next_page_url


def _fetch_pricelabs_properties(
    headers: dict[str, str],
    base_url: str,
    *,
    page: int,
    per_page: int,
    params_override: dict[str, Any] | None = None,
    exclude_push_enabled: bool,
) -> list[dict[str, Any]]:
    url = _compose_api_url(base_url, "/v1/listings")
    params = _merge_query_params(
        {"skip_hidden": True, "only_syncing_listings": False, "page": page, "per_page": per_page},
        params_override or {},
    )
    with httpx.Client(timeout=20.0) as client:
        resp = client.get(url, headers=headers, params=params)
        if resp.status_code >= status.HTTP_400_BAD_REQUEST:
            raise HTTPException(status_code=resp.status_code, detail="PriceLabs fetch failed")
        data = resp.json()
    items = data.get("listings") if isinstance(data, dict) else data
    if not isinstance(items, list):
        items = []

    field_map = {
        "platform_property_id": "id",
        "name": "name",
        "latitude": "latitude",
        "longitude": "longitude",
        "city": "city_name",
        "state": "state",
        "country": "country",
    }
    normalized: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if exclude_push_enabled and _coerce_bool(item.get("push_enabled"), default=False):
            continue
        normalized.append(_normalize_property_row(dict(item), field_map=field_map))
    return normalized


def _fetch_wheelhouse_properties(
    headers: dict[str, str],
    base_url: str,
    *,
    page: int,
    per_page: int,
    params_override: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    url = _compose_api_url(base_url, "/listings")
    params = _merge_query_params(
        {"page": page, "per_page": per_page, "offset": 0, "exclude_inactive": True},
        params_override or {},
    )
    with httpx.Client(timeout=20.0) as client:
        resp = client.get(url, headers=headers, params=params)
        if resp.status_code >= status.HTTP_400_BAD_REQUEST:
            raise HTTPException(status_code=resp.status_code, detail="Wheelhouse fetch failed")
        data = resp.json()

    if isinstance(data, list):
        items = data
    elif isinstance(data, dict):
        candidate_items = data.get("listings")
        items = candidate_items if isinstance(candidate_items, list) else []
    else:
        items = []

    field_map = {
        "platform_property_id": "id",
        "name": "title",
        "latitude": "location.latitude",
        "longitude": "location.longitude",
        "city": "location.city",
        "state": "location.state",
        "country": "location.country",
        "currency_code": "currency",
        "public_url": "links.calendar",
    }
    return [
        _normalize_property_row(dict(item), field_map=field_map)
        for item in items
        if isinstance(item, dict)
    ]


def _header_value(headers: dict[str, str], *names: str) -> str | None:
    for header_name in names:
        if header_name in headers and headers[header_name]:
            return headers[header_name]
    lowered = {str(key).lower(): value for key, value in headers.items() if value}
    for header_name in names:
        value = lowered.get(header_name.lower())
        if value:
            return value
    return None


def _resolve_wheelhouse_integration_key(headers: dict[str, str]) -> str | None:
    return _header_value(
        headers,
        "X-Integration-Api-Key",
        "X-Integration-API-Key",
        "X-User-Access-Key",
        "X-User-AccessKey",
        "X-User-Api-Key",
        "X-User-API-Key",
    )


def _coerce_wheelhouse_request_headers(headers: dict[str, str]) -> tuple[dict[str, str], str | None]:
    integration_key = _resolve_wheelhouse_integration_key(headers)
    auth_aliases = {
        "x-integration-api-key",
        "x-integration-apikey",
        "x-user-access-key",
        "x-user-accesskey",
        "x-user-api-key",
        "x-user-apikey",
    }
    normalized_headers = {
        str(key): value
        for key, value in headers.items()
        if str(key).strip().lower() not in auth_aliases
    }
    if integration_key:
        normalized_headers[WHEELHOUSE_RM_HEADER_NAME] = integration_key
    return normalized_headers, integration_key


def _dedupe_remote_properties(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in items:
        platform_property_id = str(item.get("platform_property_id") or "").strip()
        if not platform_property_id:
            continue
        if platform_property_id in seen:
            continue
        seen.add(platform_property_id)
        deduped.append(item)
    return deduped


def _find_property_by_coordinates(latitude: str, longitude: str) -> dict[str, Any] | None:
    if not latitude or not longitude:
        return None
    return execute_auto_query(
        """
        SELECT
            id AS property_id,
            descrp->>'latitude' AS latitude,
            descrp->>'longitude' AS longitude
        FROM properties
        WHERE (descrp->>'latitude')::numeric = CAST(:latitude AS numeric)
          AND (descrp->>'longitude')::numeric = CAST(:longitude AS numeric)
        ORDER BY id ASC
        LIMIT 1
        """,
        params={"latitude": latitude, "longitude": longitude},
        fetch_one=True,
    )


@lru_cache(maxsize=1)
def _platform_property_lookup_columns() -> tuple[str, ...]:
    rows = execute_auto_query(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = 'platform_property_lookup'
          AND column_name IN ('platform_property_id', 'listing_id', 'name', 'metadata')
        ORDER BY CASE column_name
            WHEN 'platform_property_id' THEN 0
            WHEN 'listing_id' THEN 1
            WHEN 'name' THEN 2
            WHEN 'metadata' THEN 3
            ELSE 4
        END
        """
    )
    return tuple(
        str(row.get("column_name") or "").strip()
        for row in rows or []
        if str(row.get("column_name") or "").strip()
    )


def _platform_property_lookup_has_column(column_name: str) -> bool:
    return column_name in _platform_property_lookup_columns()


def _platform_property_lookup_id_column() -> str:
    columns = set(_platform_property_lookup_columns())
    if "platform_property_id" in columns:
        return "platform_property_id"
    if "listing_id" in columns:
        return "listing_id"
    return "platform_property_id"


def _platform_property_lookup_id_sql(alias: str = "ppl") -> str:
    return f"{alias}.{_platform_property_lookup_id_column()}"


def _platform_property_lookup_listing_name_sql(alias: str = "ppl") -> str:
    parts: list[str] = []
    if _platform_property_lookup_has_column("name"):
        parts.append(f"{alias}.name")
    if _platform_property_lookup_has_column("metadata"):
        parts.append(f"{alias}.metadata->>'name'")
    if not parts:
        return "NULL"
    if len(parts) == 1:
        return parts[0]
    return f"COALESCE({', '.join(parts)})"


def _property_name_sql(alias: str = "p") -> str:
    return (
        f"COALESCE({alias}.descrp->>'name', {alias}.descrp->>'title', "
        f"{alias}.descrp->>'label', 'Property ' || {alias}.id::text)"
    )


def _serialize_applicable_dates(values: list[date] | None) -> str | None:
    if not values:
        return None
    return json.dumps([item.isoformat() for item in values])


def _get_platform_property_lookup_row(lookup_id: int) -> dict[str, Any] | None:
    return execute_auto_query(
        """
        SELECT id, properties_ptr AS property_id, platform_id
        FROM platform_property_lookup
        WHERE id = :lookup_id
        LIMIT 1
        """,
        params={"lookup_id": lookup_id},
        fetch_one=True,
    )


@lru_cache(maxsize=1)
def _property_link_write_mode() -> str:
    rows = execute_auto_query(
        """
        SELECT proname, oidvectortypes(proargtypes) AS argtypes
        FROM pg_proc
        WHERE proname IN ('link_platform_property', 'find_or_create_property')
        ORDER BY proname, oidvectortypes(proargtypes)
        """
    )
    signatures = {
        (
            str(row.get("proname") or "").strip(),
            str(row.get("argtypes") or "").strip(),
        )
        for row in rows or []
    }
    if any(name == "link_platform_property" for name, _ in signatures):
        return "link_platform_property"
    if ("find_or_create_property", "text, text, jsonb, integer, text, text, integer") in signatures:
        return "find_or_create_property_7"
    if ("find_or_create_property", "text, text, jsonb, integer, text, integer") in signatures:
        return "find_or_create_property_6"
    raise RuntimeError("No compatible property-linking database function found")


def _execute_property_link_write(function_params: dict[str, Any]) -> Any:
    write_mode = _property_link_write_mode()
    if write_mode == "link_platform_property":
        params = dict(function_params)
        if params.get("link_to_lookup_id") is None:
            params.pop("link_to_lookup_id", None)
        return execute_auto_function(
            "link_platform_property",
            params=params,
            fetch_one=True,
            write=True,
            expect_scalar=True,
        )

    prop_details = function_params.get("prop_details")
    details_obj: dict[str, Any] = {}
    if isinstance(prop_details, dict):
        details_obj = prop_details
    elif isinstance(prop_details, str):
        try:
            loaded = json.loads(prop_details)
        except json.JSONDecodeError:
            loaded = {}
        if isinstance(loaded, dict):
            details_obj = loaded

    base_params = {
        "prop_latitude": function_params["prop_latitude"],
        "prop_longitude": function_params["prop_longitude"],
        "prop_details": prop_details,
        "input_platform_id": function_params["input_platform_id"],
        "input_platform_property_id": function_params["input_platform_property_id"],
        "link_to_lookup_id": function_params.get("link_to_lookup_id"),
    }
    if write_mode == "find_or_create_property_7":
        base_params["listing_name"] = (
            str(
                details_obj.get("name")
                or details_obj.get("title")
                or details_obj.get("label")
                or ""
            ).strip()
            or None
        )
        row = execute_auto_write(
            """
            SELECT find_or_create_property(
                :prop_latitude,
                :prop_longitude,
                CAST(:prop_details AS jsonb),
                :input_platform_id,
                :input_platform_property_id,
                :listing_name,
                :link_to_lookup_id
            ) AS lookup_id
            """,
            params=base_params,
            fetch_one=True,
        )
    else:
        row = execute_auto_write(
            """
            SELECT find_or_create_property(
                :prop_latitude,
                :prop_longitude,
                CAST(:prop_details AS jsonb),
                :input_platform_id,
                :input_platform_property_id,
                :link_to_lookup_id
            ) AS lookup_id
            """,
            params=base_params,
            fetch_one=True,
        )
    return row.get("lookup_id") if isinstance(row, dict) else row


def _persist_platform_listing_metadata(
    lookup_id: int | None,
    *,
    listing_name: str | None,
    listing_metadata: dict[str, Any],
) -> None:
    if lookup_id is None:
        return

    set_parts: list[str] = []
    params: dict[str, Any] = {"lookup_id": lookup_id}

    if _platform_property_lookup_has_column("name") and listing_name:
        set_parts.append("name = :listing_name")
        params["listing_name"] = listing_name

    if _platform_property_lookup_has_column("metadata") and listing_metadata:
        set_parts.append("metadata = COALESCE(metadata, '{}'::jsonb) || CAST(:listing_metadata AS jsonb)")
        params["listing_metadata"] = json.dumps(listing_metadata)

    if not set_parts:
        return

    execute_auto_write(
        f"""
        UPDATE platform_property_lookup
        SET {", ".join(set_parts)},
            updated_at = CURRENT_TIMESTAMP
        WHERE id = :lookup_id
        """,
        params=params,
    )


def _fetch_linked_listings_for_lookup_id(lookup_id: int) -> list[dict[str, Any]]:
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    parent_lookup_id_sql = _platform_property_lookup_id_sql("parent")
    parent_listing_name_sql = _platform_property_lookup_listing_name_sql("parent")
    rows = execute_auto_query(
        f"""
        WITH selected_property AS (
            SELECT properties_ptr
            FROM platform_property_lookup
            WHERE id = :lookup_id
        )
        SELECT
            ppl.id AS lookup_id,
            ppl.platform_id,
            plat.name AS platform_name,
            plat.type::text AS platform_type,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            ppl.properties_ptr AS property_id,
            COALESCE(
                p.descrp->>'name',
                p.descrp->>'title',
                p.descrp->>'label',
                'Property ' || p.id::text
            ) AS property_name,
            ppl.self AS linked_to_lookup_id,
            parent.platform_id AS linked_to_platform_id,
            parent_plat.name AS linked_to_platform_name,
            {parent_lookup_id_sql} AS linked_to_platform_property_id,
            {parent_listing_name_sql} AS linked_to_listing_name,
            (ppl.self IS NULL) AS is_chain_head
        FROM selected_property sp
        JOIN platform_property_lookup ppl ON ppl.properties_ptr = sp.properties_ptr
        JOIN properties p ON p.id = ppl.properties_ptr
        JOIN platforms plat ON plat.id = ppl.platform_id
        LEFT JOIN platform_property_lookup parent ON parent.id = ppl.self
        LEFT JOIN platforms parent_plat ON parent_plat.id = parent.platform_id
        ORDER BY
            plat.name,
            {lookup_id_sql},
            ppl.id
        """
        ,
        params={"lookup_id": lookup_id},
    )
    return rows or []


def _build_property_lookup_components(rows: list[dict[str, Any]]) -> dict[int, int]:
    adjacency: dict[int, set[int]] = {}
    for row in rows:
        lookup_id = row.get("lookup_id")
        if lookup_id is None:
            continue
        lookup_id_int = int(lookup_id)
        adjacency.setdefault(lookup_id_int, set())

    for row in rows:
        lookup_id = row.get("lookup_id")
        linked_to_lookup_id = row.get("linked_to_lookup_id")
        if lookup_id is None or linked_to_lookup_id is None:
            continue
        lookup_id_int = int(lookup_id)
        linked_to_lookup_id_int = int(linked_to_lookup_id)
        adjacency.setdefault(lookup_id_int, set()).add(linked_to_lookup_id_int)
        adjacency.setdefault(linked_to_lookup_id_int, set()).add(lookup_id_int)

    component_by_lookup_id: dict[int, int] = {}
    component_id = 0
    for lookup_id in adjacency:
        if lookup_id in component_by_lookup_id:
            continue
        pending = [lookup_id]
        while pending:
            current_lookup_id = pending.pop()
            if current_lookup_id in component_by_lookup_id:
                continue
            component_by_lookup_id[current_lookup_id] = component_id
            pending.extend(
                neighbor_lookup_id
                for neighbor_lookup_id in adjacency.get(current_lookup_id, set())
                if neighbor_lookup_id not in component_by_lookup_id
            )
        component_id += 1
    return component_by_lookup_id


def _build_property_lookup_chain_tails(rows: list[dict[str, Any]]) -> dict[int, int]:
    component_by_lookup_id = _build_property_lookup_components(rows)
    incoming_lookup_ids = {
        int(row["linked_to_lookup_id"])
        for row in rows
        if row.get("linked_to_lookup_id") is not None
    }
    tail_by_component_id: dict[int, int] = {}
    for row in rows:
        lookup_id = row.get("lookup_id")
        if lookup_id is None:
            continue
        lookup_id_int = int(lookup_id)
        component_id = component_by_lookup_id.get(lookup_id_int)
        if component_id is None or lookup_id_int in incoming_lookup_ids:
            continue
        tail_by_component_id.setdefault(component_id, lookup_id_int)
    return tail_by_component_id


def _coordinate_key(latitude: str, longitude: str) -> str:
    return coordinate_key(latitude, longitude)


def _fetch_platform_property_linked_rows(platform_id: int) -> dict[str, dict[str, Any]]:
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    linked_rows = execute_auto_query(
        f"""
        SELECT
            ppl.id AS lookup_id,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            ppl.properties_ptr AS property_id,
            ppl.self,
            p.descrp->>'latitude' AS latitude,
            p.descrp->>'longitude' AS longitude
        FROM platform_property_lookup ppl
        JOIN properties p ON p.id = ppl.properties_ptr
        WHERE ppl.platform_id = :platform_id
        """,
        params={"platform_id": platform_id},
    )
    return {
        str(row.get("platform_property_id") or "").strip(): row
        for row in linked_rows or []
        if str(row.get("platform_property_id") or "").strip()
    }


def _fetch_coordinate_link_candidates(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    requested_coordinates: list[tuple[str, str]] = []
    seen_keys: set[str] = set()
    for item in items:
        latitude = _normalize_coordinate_text(item.get("latitude"))
        longitude = _normalize_coordinate_text(item.get("longitude"))
        coordinate_key = _coordinate_key(latitude, longitude)
        if not coordinate_key or coordinate_key in seen_keys:
            continue
        seen_keys.add(coordinate_key)
        requested_coordinates.append((latitude, longitude))

    if not requested_coordinates:
        return {}

    params: dict[str, Any] = {}
    values_sql_parts: list[str] = []
    for index, (latitude, longitude) in enumerate(requested_coordinates):
        lat_key = f"lat_{index}"
        lon_key = f"lon_{index}"
        params[lat_key] = latitude
        params[lon_key] = longitude
        values_sql_parts.append(f"(:{lat_key}, :{lon_key})")

    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    rows = execute_auto_query(
        f"""
        WITH requested(latitude, longitude) AS (
            VALUES {", ".join(values_sql_parts)}
        )
        SELECT
            req.latitude AS requested_latitude,
            req.longitude AS requested_longitude,
            p.id AS property_id,
            COALESCE(
                p.descrp->>'name',
                p.descrp->>'title',
                p.descrp->>'label',
                'Property ' || p.id::text
            ) AS property_name,
            p.descrp->>'latitude' AS property_latitude,
            p.descrp->>'longitude' AS property_longitude,
            ppl.id AS lookup_id,
            ppl.platform_id,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            plat.name AS platform_name,
            plat.type::text AS platform_type
        FROM requested req
        LEFT JOIN properties p
          ON (p.descrp->>'latitude')::numeric = CAST(req.latitude AS numeric)
         AND (p.descrp->>'longitude')::numeric = CAST(req.longitude AS numeric)
        LEFT JOIN platform_property_lookup ppl ON ppl.properties_ptr = p.id
        LEFT JOIN platforms plat ON plat.id = ppl.platform_id
        ORDER BY
            req.latitude,
            req.longitude,
            plat.name NULLS LAST,
            {lookup_id_sql} NULLS LAST,
            ppl.id NULLS LAST
        """,
        params=params,
    )

    by_coordinate_key: dict[str, dict[str, Any]] = {}
    for row in rows or []:
        latitude = str(row.get("requested_latitude") or "").strip()
        longitude = str(row.get("requested_longitude") or "").strip()
        coordinate_key = _coordinate_key(latitude, longitude)
        if not coordinate_key:
            continue
        entry = by_coordinate_key.setdefault(
            coordinate_key,
            {
                "property_id": None,
                "property_name": None,
                "latitude": None,
                "longitude": None,
                "link_candidates": [],
            },
        )
        property_id = row.get("property_id")
        if property_id is not None and entry["property_id"] is None:
            entry["property_id"] = property_id
            entry["property_name"] = row.get("property_name")
            entry["latitude"] = row.get("property_latitude")
            entry["longitude"] = row.get("property_longitude")
        lookup_id = row.get("lookup_id")
        if lookup_id is None:
            continue
        entry["link_candidates"].append(
            {
                "lookup_id": lookup_id,
                "property_id": property_id,
                "platform_id": row.get("platform_id"),
                "platform_name": row.get("platform_name"),
                "platform_type": row.get("platform_type"),
                "platform_property_id": row.get("platform_property_id"),
                "listing_name": row.get("listing_name"),
            }
        )
    return by_coordinate_key


def _annotate_remote_properties(
    platform_id: int,
    items: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    normalized_items = []
    for item in items:
        row = dict(item)
        latitude = _normalize_coordinate_text(row.get("latitude"))
        longitude = _normalize_coordinate_text(row.get("longitude"))
        if latitude:
            row["latitude"] = latitude
        if longitude:
            row["longitude"] = longitude
        normalized_items.append(row)

    return build_remote_link_annotations(
        normalized_items,
        current_platform_id=platform_id,
        linked_rows_by_platform_property_id=_fetch_platform_property_linked_rows(platform_id),
        coordinate_candidates_by_key=_fetch_coordinate_link_candidates(normalized_items),
    )


def _fetch_remote_platform_properties(
    platform: dict[str, Any],
    *,
    auth_headers: dict[str, str],
    page: int,
    per_page: int,
    fetch_all: bool,
) -> list[dict[str, Any]]:
    metadata = platform.get("metadata") if isinstance(platform.get("metadata"), dict) else {}
    endpoints = metadata.get("endpoints") if isinstance(metadata.get("endpoints"), dict) else {}
    platform_name = str(platform.get("name") or "").strip().lower()

    if "ownerrez" in platform_name:
        if "Authorization" not in auth_headers:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="OwnerRez platform Authorization header is missing; configure platforms.metadata.secret.*.secret_table_ptr",
            )

        ownerrez_base_url = (
            os.getenv("OWNERREZ_API_BASE_URL")
            or _compose_api_url(str(metadata.get("domain") or "https://api.ownerrez.com"), "/v2")
        )
        ownerrez_endpoint = endpoints.get("properties") if isinstance(endpoints.get("properties"), dict) else {}
        field_map = (
            ownerrez_endpoint.get("required_property_fields")
            if isinstance(ownerrez_endpoint.get("required_property_fields"), dict)
            else None
        )
        endpoint_params = ownerrez_endpoint.get("params") if isinstance(ownerrez_endpoint.get("params"), dict) else {}

        current_page = page
        next_page_url: str | None = None
        collected: list[dict[str, Any]] = []
        while True:
            if next_page_url:
                resolved_next_page_url = urljoin(_ensure_api_base(ownerrez_base_url).rstrip("/") + "/", next_page_url)
                with httpx.Client(timeout=20.0) as client:
                    resp = client.get(resolved_next_page_url, headers=auth_headers)
                    if resp.status_code >= status.HTTP_400_BAD_REQUEST:
                        raise HTTPException(status_code=resp.status_code, detail="OwnerRez fetch failed")
                    payload = resp.json()
                if isinstance(payload, dict):
                    batch_items = payload.get("items")
                    if not isinstance(batch_items, list):
                        batch_items = payload.get("properties")
                    if not isinstance(batch_items, list):
                        batch_items = payload.get("data")
                    if not isinstance(batch_items, list):
                        batch_items = []
                    next_page_url = str(payload.get("next_page_url") or "").strip() or None
                elif isinstance(payload, list):
                    batch_items = payload
                    next_page_url = None
                else:
                    batch_items = []
                    next_page_url = None
                batch = [
                    _normalize_property_row(dict(item), field_map=field_map)
                    for item in batch_items
                    if isinstance(item, dict) and _is_active_property_row(item)
                ]
            else:
                batch, next_page_url = _fetch_ownerrez_properties(
                    page=current_page,
                    per_page=per_page,
                    headers=auth_headers,
                    base_url=ownerrez_base_url,
                    field_map=field_map,
                    params_override=endpoint_params,
                )
            collected.extend(batch)
            if not fetch_all:
                break
            if next_page_url:
                if current_page - page > 100:
                    break
                current_page += 1
                continue
            if len(batch) < per_page:
                break
            current_page += 1
            if current_page - page > 100:
                break
        return _dedupe_remote_properties(collected)

    if "pricelabs" in platform_name:
        if "X-API-Key" not in auth_headers:
            fallback_api_key = os.getenv("PRICELABS_API_KEY")
            if fallback_api_key:
                auth_headers["X-API-Key"] = fallback_api_key
        if "X-API-Key" not in auth_headers:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="PriceLabs API key missing")

        pricelabs_base_url = _ensure_api_base(
            os.getenv("PRICELABS_API_BASE_URL") or str(metadata.get("domain") or "https://api.pricelabs.co")
        )
        pricelabs_endpoint = endpoints.get("listings") if isinstance(endpoints.get("listings"), dict) else {}
        endpoint_params = pricelabs_endpoint.get("params") if isinstance(pricelabs_endpoint.get("params"), dict) else {}
        listing_filters = metadata.get("listing_filters") if isinstance(metadata.get("listing_filters"), dict) else {}
        exclude_push_enabled = _coerce_bool(listing_filters.get("exclude_push_enabled"), default=False)

        collected = _fetch_pricelabs_properties(
            headers=auth_headers,
            base_url=pricelabs_base_url,
            page=page,
            per_page=per_page,
            params_override=endpoint_params,
            exclude_push_enabled=exclude_push_enabled,
        )
        return _dedupe_remote_properties(collected)

    if "wheelhouse" in platform_name:
        wheelhouse_headers, integration_key = _coerce_wheelhouse_request_headers(auth_headers)
        if not integration_key:
            fallback_integration_key = (
                os.getenv("WHEELHOUSE_RM_API_KEY")
                or os.getenv("WHEELHOUSE_INTEGRATION_KEY")
                or os.getenv("WHEELHOUSE_ACCESS_KEY")
                or os.getenv("WHEELHOUSE_API_KEY")
                or os.getenv("WHEELHOUSE_USER_ACCESS_TOKEN")
                or os.getenv("WHEELHOUSE_USER_API_KEY")
                or os.getenv("WHEELHOUSE_X_USER_ACCESS_KEY")
            )
            if fallback_integration_key:
                wheelhouse_headers[WHEELHOUSE_RM_HEADER_NAME] = fallback_integration_key
                integration_key = fallback_integration_key

        if not integration_key:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Wheelhouse RM API Key is required. Configure X-Integration-Api-Key in Platforms tab.",
            )

        wheelhouse_base_url = (
            os.getenv("WHEELHOUSE_API_BASE_URL")
            or _compose_api_url(str(metadata.get("domain") or "https://api.usewheelhouse.com"), "/ss_api/v1")
        )
        wheelhouse_endpoint = endpoints.get("listings") if isinstance(endpoints.get("listings"), dict) else {}
        endpoint_params = wheelhouse_endpoint.get("params") if isinstance(wheelhouse_endpoint.get("params"), dict) else {}

        current_page = page
        collected: list[dict[str, Any]] = []
        while True:
            batch = _fetch_wheelhouse_properties(
                headers=wheelhouse_headers,
                base_url=wheelhouse_base_url,
                page=current_page,
                per_page=per_page,
                params_override=endpoint_params,
            )
            collected.extend(batch)
            if not fetch_all or len(batch) < per_page:
                break
            current_page += 1
            if current_page - page > 100:
                break
        return _dedupe_remote_properties(collected)

    raise HTTPException(
        status_code=status.HTTP_501_NOT_IMPLEMENTED,
        detail="Remote property fetch is not implemented for this platform",
    )


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_admin_db()
    admin_ok, admin_detail = check_admin_connection()
    auto_ok, auto_detail = check_auto_connection()
    if not admin_ok or not auto_ok:
        raise RuntimeError(
            "Database startup checks failed: "
            f"admin_pws={admin_detail}; auto_pws={auto_detail}"
        )
    yield


app = FastAPI(title="Password Safe Admin Dashboard", lifespan=lifespan)
app.add_middleware(
    RememberAwareSessionMiddleware,
    secret_key=os.getenv("SESSION_SECRET_KEY", os.getenv("SECRET_KEY", "session-secret")),
    same_site="lax",
    max_age=ACCESS_TOKEN_REMEMBER_DAYS * 24 * 60 * 60,
    remember_flag_key=SESSION_REMEMBER_ME_KEY,
)
app.mount("/pwsadmin/static", StaticFiles(directory=str(PWSADMIN_STATIC_DIR)), name="pwsadmin-static")

pages_router = APIRouter(prefix="/pwsadmin", tags=["pages"])
api_router = APIRouter(prefix="/pwsadmin/api", tags=["api"])


@pages_router.get("", include_in_schema=False)
@pages_router.get("/", include_in_schema=False)
def pwsadmin_root() -> RedirectResponse:
    return RedirectResponse(url="/pwsadmin/home", status_code=status.HTTP_307_TEMPORARY_REDIRECT)


@pages_router.get("/home", response_class=HTMLResponse)
@pages_router.get("/home/", response_class=HTMLResponse)
def home_page() -> str:
    return HOME_HTML


@pages_router.get("/dashboard", response_class=HTMLResponse)
def dashboard_page(
    request: Request,
    token: str | None = Query(default=None),
    tab: str | None = Query(default=None),
    subtab: str | None = Query(default=None),
    db: Session = Depends(get_admin_db),
) -> Response:
    access_token = token or _extract_bearer_token(request) or request.cookies.get("pwsadmin_token")
    if not access_token:
        return RedirectResponse(url="/pwsadmin/home", status_code=status.HTTP_307_TEMPORARY_REDIRECT)

    try:
        user = get_user_from_token(access_token, db)
    except HTTPException:
        return RedirectResponse(url="/pwsadmin/home", status_code=status.HTTP_307_TEMPORARY_REDIRECT)

    return _render_dashboard_page(request, user, tab, subtab)


@api_router.post(
    "/auth/register",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
)
def register_user(payload: UserRegister, db: Session = Depends(get_admin_db)) -> User:
    user_service = UserService(db)
    try:
        return user_service.create_user(payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@api_router.post("/auth/login", response_model=TokenResponse)
def login_user(
    payload: UserLogin,
    request: Request,
    response: Response,
    db: Session = Depends(get_admin_db),
) -> TokenResponse:
    user_service = UserService(db)
    auth_result = user_service.authenticate_user(
        payload.email,
        payload.password,
        ip_address=_client_ip(request),
    )
    user = auth_result.user
    if user is None:
        detail = (
            "Account pending admin approval"
            if auth_result.failure_reason == "inactive"
            else "Incorrect email or password"
        )
        status_code = (
            status.HTTP_403_FORBIDDEN
            if auth_result.failure_reason == "inactive"
            else status.HTTP_401_UNAUTHORIZED
        )
        raise HTTPException(
            status_code=status_code,
            detail=detail,
            headers={"WWW-Authenticate": "Bearer"},
        )

    expires_delta = get_login_expires_delta(remember_me=payload.remember_me)
    expires_in = int(expires_delta.total_seconds())
    access_token = create_access_token(
        data={
            "sub": user.email,
            "user_id": user.id,
            "is_admin": user.is_admin,
        },
        expires_delta=expires_delta,
    )
    response.set_cookie(
        key="pwsadmin_token",
        value=access_token,
        httponly=True,
        samesite="lax",
        max_age=expires_in if payload.remember_me else None,
    )
    return TokenResponse(access_token=access_token, expires_in=expires_in)


@api_router.post("/auth/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout_user(response: Response) -> Response:
    response.delete_cookie(
        key="pwsadmin_token",
        path="/",
        httponly=True,
        samesite="lax",
    )
    response.status_code = status.HTTP_204_NO_CONTENT
    return response


@api_router.get("/auth/me", response_model=UserResponse)
def get_me(current_user: User = Depends(get_current_user)) -> User:
    return current_user


@api_router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@api_router.get("/health/databases")
def database_health() -> JSONResponse:
    admin_ok, admin_detail = check_admin_connection()
    auto_ok, auto_detail = check_auto_connection()

    status_code = status.HTTP_200_OK if admin_ok and auto_ok else status.HTTP_503_SERVICE_UNAVAILABLE
    return JSONResponse(
        status_code=status_code,
        content={
            "status": "ok" if admin_ok and auto_ok else "degraded",
            "checked_at": datetime.now(timezone.utc).isoformat(),
            "databases": {
                "admin_pws": {"connected": admin_ok, "detail": admin_detail},
                "auto_pws": {"connected": auto_ok, "detail": auto_detail},
            },
        },
    )


@api_router.get("/workers")
def list_workers(
    current_user: User = Depends(get_current_user),
    active_only: bool = Query(default=False),
    limit: int = Query(default=25, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user

    where_clauses = ["(NOT :active_only OR wr.is_active = TRUE)"]
    params: dict[str, object] = {"active_only": active_only, "limit": limit}
    if cursor:
        where_clauses.append("wr.id < :cursor")
        params["cursor"] = cursor
    where_sql = f"WHERE {' AND '.join(where_clauses)}"

    worker_rows = execute_auto_query(
        f"""
        SELECT
            wr.id,
            wr.worker_id,
            COALESCE(NULLIF(wr.worker_name, ''), wr.worker_id) AS worker_name,
            wr.worker_type,
            wr.is_active,
            wr.current_load,
            wr.max_concurrent_tasks AS max_capacity,
            COALESCE(wr.subscribed_queues, '[]'::jsonb) AS subscribed_queues,
            wr.tasks_completed,
            wr.tasks_failed,
            CASE
                WHEN wr.tasks_completed + wr.tasks_failed > 0
                THEN wr.tasks_completed::float / (wr.tasks_completed + wr.tasks_failed)
                ELSE 1.0
            END AS availability_ratio,
            EXTRACT(EPOCH FROM (NOW() - wr.last_seen_at))::INTEGER AS last_seen_seconds
        FROM worker_registry wr
        {where_sql}
        ORDER BY wr.id DESC
        LIMIT :limit
        """,
        params=params,
    )

    queue_rows = execute_auto_query(
        """
        SELECT
            queue_name,
            COUNT(*)::int AS total_tasks,
            COUNT(*) FILTER (WHERE status = 'pending')::int AS pending_tasks,
            COUNT(*) FILTER (WHERE status = 'processing')::int AS processing_tasks,
            COUNT(*) FILTER (WHERE status = 'scheduled')::int AS scheduled_tasks,
            COUNT(*) FILTER (WHERE status = 'retrying')::int AS retrying_tasks,
            COUNT(*) FILTER (WHERE status = 'completed')::int AS completed_tasks,
            COUNT(*) FILTER (WHERE status = 'failed')::int AS failed_tasks
        FROM task_queue
        GROUP BY queue_name
        ORDER BY queue_name
        """
    )

    worker_summary_rows = execute_auto_query(
        """
        SELECT
            COUNT(*)::int AS total_workers,
            COUNT(*) FILTER (WHERE wr.is_active = TRUE)::int AS active_workers,
            COUNT(*) FILTER (WHERE wr.is_active = FALSE)::int AS inactive_workers,
            COUNT(*) FILTER (WHERE COALESCE(wr.current_load, 0) > 0)::int AS busy_workers
        FROM worker_registry wr
        WHERE (NOT :active_only OR wr.is_active = TRUE)
        """,
        params={"active_only": active_only},
    )
    worker_summary = worker_summary_rows[0] if worker_summary_rows else {}

    summary = {
        "total_workers": int(worker_summary.get("total_workers") or 0),
        "active_workers": int(worker_summary.get("active_workers") or 0),
        "inactive_workers": int(worker_summary.get("inactive_workers") or 0),
        "busy_workers": int(worker_summary.get("busy_workers") or 0),
        "total_queues": len(queue_rows),
        "pending_tasks": sum(int(row.get("pending_tasks") or 0) for row in queue_rows),
        "processing_tasks": sum(int(row.get("processing_tasks") or 0) for row in queue_rows),
    }
    next_cursor = worker_rows[-1]["id"] if worker_rows and len(worker_rows) == limit else None
    return {
        "items": worker_rows,
        "count": len(worker_rows),
        "next_cursor": next_cursor,
        "queues": queue_rows,
        "summary": summary,
        "active_only": active_only,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@api_router.get("/worker-manager/state")
def get_worker_manager_state(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    checked_at = datetime.now(timezone.utc)
    manager_state_table = execute_auto_query(
        "SELECT to_regclass('public.worker_manager_state') IS NOT NULL AS exists",
        fetch_one=True,
    ) or {}
    manager_state_installed = bool(manager_state_table.get("exists"))

    manager_state = None
    if manager_state_installed:
        manager_state = execute_auto_query(
            """
            SELECT
                manager_id,
                supervisor_status,
                supervisor_pid,
                supervisor_started_at,
                supervisor_last_seen_at,
                CASE
                    WHEN supervisor_last_seen_at IS NULL THEN NULL
                    ELSE EXTRACT(EPOCH FROM (NOW() - supervisor_last_seen_at))::int
                END AS supervisor_last_seen_seconds,
                (supervisor_last_seen_at >= NOW() - INTERVAL '2 minutes') AS supervisor_recent,
                database_available,
                database_error,
                managed_workers_expected,
                managed_workers_running,
                COALESCE(managed_worker_names, '[]'::jsonb) AS managed_worker_names,
                COALESCE(started_workers, '[]'::jsonb) AS started_workers,
                COALESCE(stopped_workers, '[]'::jsonb) AS stopped_workers,
                seed_check_interval_seconds,
                last_seed_check_at,
                last_seed_success,
                last_seed_error,
                maintenance_enabled,
                maintenance_status,
                maintenance_pid,
                maintenance_started_at,
                maintenance_last_seen_at,
                CASE
                    WHEN maintenance_last_seen_at IS NULL THEN NULL
                    ELSE EXTRACT(EPOCH FROM (NOW() - maintenance_last_seen_at))::int
                END AS maintenance_last_seen_seconds,
                (maintenance_last_seen_at >= NOW() - INTERVAL '3 minutes') AS maintenance_recent,
                maintenance_interval_seconds,
                maintenance_action_count,
                COALESCE(maintenance_actions, '[]'::jsonb) AS maintenance_actions,
                last_promote_count,
                last_reset_count,
                last_maintenance_action_at,
                last_maintenance_action_name,
                last_maintenance_action_success,
                last_maintenance_action_rows,
                last_maintenance_action_duration_seconds,
                last_maintenance_action_error,
                last_maintenance_loop_error,
                manifest_path,
                db_name,
                log_dir,
                created_at,
                updated_at
            FROM worker_manager_state
            WHERE manager_id = 'default'
            LIMIT 1
            """,
            fetch_one=True,
        )

    worker_summary = execute_auto_query(
        """
        SELECT
            COUNT(*)::int AS total_workers,
            COUNT(*) FILTER (WHERE wr.is_active = TRUE)::int AS active_workers,
            COUNT(*) FILTER (
                WHERE wr.is_active = TRUE
                  AND (wr.expected_next_heartbeat IS NULL OR wr.expected_next_heartbeat >= NOW())
            )::int AS heartbeat_current_workers,
            COUNT(*) FILTER (
                WHERE wr.is_active = TRUE
                  AND wr.expected_next_heartbeat IS NOT NULL
                  AND wr.expected_next_heartbeat < NOW()
            )::int AS heartbeat_late_workers,
            COUNT(*) FILTER (WHERE COALESCE(wr.current_load, 0) > 0)::int AS busy_workers,
            COALESCE(SUM(COALESCE(wr.current_load, 0)), 0)::int AS current_load
        FROM worker_registry wr
        WHERE wr.worker_id <> :seed_worker_id
        """,
        params={"seed_worker_id": "worker-manager-seeder"},
        fetch_one=True,
    ) or {}

    seed_worker = execute_auto_query(
        """
        SELECT
            worker_id,
            is_active,
            last_seen_at,
            expected_next_heartbeat,
            CASE
                WHEN last_seen_at IS NULL THEN NULL
                ELSE EXTRACT(EPOCH FROM (NOW() - last_seen_at))::int
            END AS last_seen_seconds,
            (expected_next_heartbeat IS NOT NULL AND expected_next_heartbeat >= NOW()) AS heartbeat_current
        FROM worker_registry
        WHERE worker_id = :seed_worker_id
        LIMIT 1
        """,
        params={"seed_worker_id": "worker-manager-seeder"},
        fetch_one=True,
    )

    maintenance_functions = execute_auto_query(
        """
        SELECT
            EXISTS (
                SELECT 1
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = 'small_server_disk_maintenance_run'
            ) AS small_server_disk_maintenance_installed,
            EXISTS (
                SELECT 1
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = 'cleanup_audit_log'
            ) AS audit_cleanup_installed
        """,
        fetch_one=True,
    ) or {}

    audit_log_stats = execute_auto_query(
        """
        SELECT
            COUNT(*)::bigint AS row_count,
            MIN(created_at) AS oldest_created_at,
            MAX(created_at) AS newest_created_at,
            pg_total_relation_size('public.audit_log'::regclass)::bigint AS total_size_bytes,
            pg_size_pretty(pg_total_relation_size('public.audit_log'::regclass)) AS total_size
        FROM audit_log
        """,
        fetch_one=True,
    ) or {}

    audit_noise = execute_auto_query(
        """
        SELECT
            operation::text AS operation,
            COUNT(*)::int AS count_1h,
            COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '5 minutes')::int AS count_5m
        FROM audit_log
        WHERE created_at >= NOW() - INTERVAL '1 hour'
        GROUP BY operation
        ORDER BY count_1h DESC, operation
        LIMIT 12
        """
    ) or []

    growth_monitor_row = execute_auto_query(
        "SELECT to_regclass('public.table_growth_monitor') IS NOT NULL AS exists",
        fetch_one=True,
    ) or {}
    growth_rows = []
    if growth_monitor_row.get("exists"):
        growth_rows = execute_auto_query(
            """
            SELECT
                tablename,
                total_size,
                total_size_bytes,
                live_rows,
                dead_rows,
                dead_row_pct,
                last_autovacuum,
                last_autoanalyze
            FROM table_growth_monitor
            WHERE tablename IN (
                'audit_log',
                'app_logs',
                'task_queue',
                'task_metadata_history',
                'worker_registry',
                'worker_manager_state'
            )
            ORDER BY total_size_bytes DESC
            """
        ) or []

    return {
        "checked_at": checked_at.isoformat(),
        "state_table_installed": manager_state_installed,
        "state": manager_state,
        "workers": worker_summary,
        "seed_worker": seed_worker,
        "maintenance": maintenance_functions,
        "disk": {
            "audit_log": audit_log_stats,
            "growth_monitor": growth_rows,
        },
        "audit_noise": audit_noise,
    }


def _cleanup_scalar_count(
    query: str,
    *,
    params: dict[str, object] | None = None,
    column: str = "rows_affected",
) -> int:
    row = execute_auto_write(query, params=params, fetch_one=True) or {}
    return int(row.get(column) or 0)


def _record_worker_manager_cleanup(
    *,
    action: str,
    rows_affected: int,
    details: dict[str, Any],
    current_user: User,
) -> None:
    try:
        execute_auto_write(
            """
            INSERT INTO app_logs (
                level,
                message,
                source,
                workflow_name,
                metadata,
                user_id
            ) VALUES (
                'INFO',
                :message,
                'pwsadmin',
                'worker-manager-cleanup',
                CAST(:metadata AS jsonb),
                :user_id
            )
            """,
            params={
                "message": f"Worker manager cleanup action completed: {action}",
                "metadata": json.dumps(
                    {
                        "action": action,
                        "rows_affected": rows_affected,
                        "details": details,
                        "user_email": current_user.email,
                    },
                    default=str,
                ),
                "user_id": str(current_user.id),
            },
        )
    except Exception:
        # Cleanup should not be reported as failed only because the secondary log write failed.
        return


@api_router.post("/worker-manager/cleanup/{action}")
def run_worker_manager_cleanup(
    action: str,
    payload: WorkerManagerCleanupRequest | None = None,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    normalized_action = action.strip().lower()
    executed_at = datetime.now(timezone.utc)
    details: dict[str, Any] = {}

    if normalized_action == "clear-audit-log":
        rows_affected = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM audit_log
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """
        )

    elif normalized_action == "shrink-unclassified-messages":
        row = execute_auto_write(
            """
            WITH unclassified AS (
                SELECT m.id
                FROM messages m
                JOIN message_class_lookup mcl
                  ON mcl.message_id = m.id
                 AND mcl.is_primary = TRUE
                JOIN message_classes mc
                  ON mc.id = mcl.class_id
                WHERE mc.name = 'unclassified'
                  AND m.deleted_at IS NULL
            ),
            updated_messages AS (
                UPDATE messages m
                SET content = ''
                FROM unclassified u
                WHERE m.id = u.id
                  AND m.content <> ''
                RETURNING m.id
            ),
            restored_status AS (
                UPDATE message_processing_status mps
                SET status = 'completed'::message_processing_state,
                    last_error = NULL
                FROM unclassified u
                JOIN messages m
                  ON m.id = u.id
                WHERE mps.message_id = u.id
                  AND btrim(m.content) = ''
                RETURNING mps.message_id
            )
            SELECT
                (SELECT COUNT(*) FROM updated_messages)::bigint AS rows_affected,
                (SELECT COUNT(*) FROM restored_status)::bigint AS restored_status_rows
            """,
            fetch_one=True,
        ) or {}
        rows_affected = int(row.get("rows_affected") or 0)
        details["restored_status_rows"] = int(row.get("restored_status_rows") or 0)

    elif normalized_action == "clear-inactive-workers":
        metadata_exists = execute_auto_query(
            "SELECT to_regclass('public.worker_metadata') IS NOT NULL AS exists",
            fetch_one=True,
        ) or {}
        metadata_rows = 0
        if metadata_exists.get("exists"):
            metadata_rows = _cleanup_scalar_count(
                """
                WITH deleted AS (
                    DELETE FROM worker_metadata
                    WHERE worker_id IN (
                        SELECT worker_id FROM worker_registry WHERE is_active = FALSE
                    )
                    RETURNING 1
                )
                SELECT COUNT(*)::bigint AS rows_affected FROM deleted
                """
            )
        api_key_rows = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM worker_api_keys
                WHERE worker_id IN (
                    SELECT worker_id FROM worker_registry WHERE is_active = FALSE
                )
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """
        )
        worker_rows = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM worker_registry
                WHERE is_active = FALSE
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """
        )
        details = {
            "deleted_workers": worker_rows,
            "deleted_api_keys": api_key_rows,
            "deleted_metadata": metadata_rows,
        }
        rows_affected = worker_rows + api_key_rows + metadata_rows

    elif normalized_action == "clear-inactive-worker-metadata":
        metadata_exists = execute_auto_query(
            "SELECT to_regclass('public.worker_metadata') IS NOT NULL AS exists",
            fetch_one=True,
        ) or {}
        if metadata_exists.get("exists"):
            rows_affected = _cleanup_scalar_count(
                """
                WITH deleted AS (
                    DELETE FROM worker_metadata
                    WHERE worker_id IN (
                        SELECT worker_id FROM worker_registry WHERE is_active = FALSE
                    )
                    RETURNING 1
                )
                SELECT COUNT(*)::bigint AS rows_affected FROM deleted
                """
            )
        else:
            rows_affected = 0

    elif normalized_action == "clear-completed-failed-tasks":
        rows_affected = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM task_queue
                WHERE status IN ('completed', 'failed')
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """
        )

    elif normalized_action == "clear-task-metadata-history":
        history_exists = execute_auto_query(
            "SELECT to_regclass('public.task_metadata_history') IS NOT NULL AS exists",
            fetch_one=True,
        ) or {}
        if history_exists.get("exists"):
            rows_affected = _cleanup_scalar_count(
                """
                WITH deleted AS (
                    DELETE FROM task_metadata_history
                    RETURNING 1
                )
                SELECT COUNT(*)::bigint AS rows_affected FROM deleted
                """
            )
        else:
            rows_affected = 0

    elif normalized_action == "clear-logs-before-date":
        if payload is None or payload.before_date is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="before_date is required for clearing logs by date",
            )
        cutoff = datetime.combine(payload.before_date, datetime.min.time(), tzinfo=timezone.utc)
        rows_affected = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM app_logs
                WHERE created_at < :cutoff
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """,
            params={"cutoff": cutoff},
        )
        details["before_date"] = payload.before_date.isoformat()

    elif normalized_action == "clear-llm-usage":
        rows_affected = _cleanup_scalar_count(
            """
            WITH deleted AS (
                DELETE FROM llm_model_usage
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS rows_affected FROM deleted
            """
        )

    else:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Unknown worker manager cleanup action")

    _record_worker_manager_cleanup(
        action=normalized_action,
        rows_affected=rows_affected,
        details=details,
        current_user=current_user,
    )
    return {
        "action": normalized_action,
        "rows_affected": rows_affected,
        "details": details,
        "executed_at": executed_at.isoformat(),
    }


@api_router.get("/logs")
def list_logs(
    current_user: User = Depends(get_current_user),
    level: str | None = Query(default=None),
    source: str | None = Query(default=None),
    workflow_name: str | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    where: list[str] = []
    params: dict[str, object] = {"limit": limit}
    if level:
        where.append("level = :level")
        params["level"] = level.upper()
    if source:
        where.append("source = :source")
        params["source"] = source
    if workflow_name:
        where.append("workflow_name = :workflow_name")
        params["workflow_name"] = workflow_name
    if cursor:
        where.append("id < :cursor")
        params["cursor"] = cursor
    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    query = f"""
        SELECT
            id,
            level,
            message,
            source,
            workflow_name,
            metadata,
            created_at
        FROM app_logs
        {where_sql}
        ORDER BY id DESC
        LIMIT :limit
    """
    rows = execute_auto_query(query, params=params)
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "next_cursor": next_cursor}


def _parse_llm_usage_datetime(value: str | None, *, end_of_day: bool = False) -> datetime | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        if len(raw) == 10:
            parsed_date = date.fromisoformat(raw)
            if end_of_day:
                return datetime.combine(parsed_date, datetime.max.time(), tzinfo=timezone.utc)
            return datetime.combine(parsed_date, datetime.min.time(), tzinfo=timezone.utc)
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"Invalid datetime: {raw}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _json_number(value: Any) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    return value


@api_router.get("/llm-usage")
def list_llm_usage(
    current_user: User = Depends(get_current_user),
    from_raw: str | None = Query(default=None, alias="from"),
    to_raw: str | None = Query(default=None, alias="to"),
    provider: str | None = Query(default=None),
    model: str | None = Query(default=None),
    action: str | None = Query(default=None),
    success: bool | None = Query(default=None),
    task_uuid: str | None = Query(default=None),
    min_tokens: int | None = Query(default=None, ge=0),
    limit: int = Query(default=100, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    from_dt = _parse_llm_usage_datetime(from_raw) or (datetime.now(timezone.utc) - timedelta(days=7))
    to_dt = _parse_llm_usage_datetime(to_raw, end_of_day=True)

    where = ["u.created_at >= :from_dt"]
    params: dict[str, object] = {"from_dt": from_dt, "limit": limit}
    option_where = ["created_at >= :from_dt"]
    option_params: dict[str, object] = {"from_dt": from_dt}
    if to_dt is not None:
        where.append("u.created_at <= :to_dt")
        option_where.append("created_at <= :to_dt")
        params["to_dt"] = to_dt
        option_params["to_dt"] = to_dt
    if provider:
        where.append("u.provider = :provider")
        params["provider"] = provider
    if model:
        where.append("u.model = :model")
        params["model"] = model
    if action:
        where.append("u.action_name = :action")
        params["action"] = action
    if success is not None:
        where.append("u.success = :success")
        params["success"] = success
    if task_uuid:
        where.append("u.task_uuid ILIKE :task_uuid")
        params["task_uuid"] = f"%{task_uuid.strip()}%"
    if min_tokens is not None:
        where.append("COALESCE(u.total_tokens, 0) >= :min_tokens")
        params["min_tokens"] = min_tokens
    if cursor:
        where.append("u.id < :cursor")
        params["cursor"] = cursor

    where_sql = "WHERE " + " AND ".join(where)
    aggregate_where = [part for part in where if part != "u.id < :cursor"]
    aggregate_where_sql = "WHERE " + " AND ".join(aggregate_where)
    option_where_sql = "WHERE " + " AND ".join(option_where)

    items = execute_auto_query(
        f"""
        SELECT
            u.id,
            u.worker_name,
            u.action_name,
            u.task_uuid,
            u.provider,
            u.model,
            u.prompt_tokens,
            u.completion_tokens,
            u.total_tokens,
            u.success,
            u.error_code,
            u.error_message,
            u.latency_ms,
            u.response_id,
            u.metadata,
            u.created_at,
            p.currency,
            CASE
                WHEN u.prompt_tokens IS NULL AND u.completion_tokens IS NULL THEN NULL
                WHEN p.id IS NULL THEN NULL
                ELSE ROUND(
                    (
                        COALESCE(u.prompt_tokens, 0)::numeric * p.input_price_per_1m_tokens
                        + COALESCE(u.completion_tokens, 0)::numeric * p.output_price_per_1m_tokens
                    ) / 1000000,
                    8
                )
            END AS estimated_cost,
            CASE
                WHEN u.prompt_tokens IS NULL AND u.completion_tokens IS NULL THEN 'unknown_tokens'
                WHEN p.id IS NULL THEN 'not_priced'
                ELSE 'estimated'
            END AS cost_status
        FROM llm_model_usage u
        LEFT JOIN llm_model_pricing p
            ON p.provider = u.provider
           AND p.model = u.model
           AND p.is_active = TRUE
        {where_sql}
        ORDER BY u.id DESC
        LIMIT :limit
        """,
        params=params,
    ) or []

    aggregate_params = {key: value for key, value in params.items() if key not in {"limit", "cursor"}}
    summary = execute_auto_query(
        f"""
        SELECT
            COUNT(*)::int AS request_count,
            COUNT(*) FILTER (WHERE u.success = TRUE)::int AS success_count,
            COUNT(*) FILTER (WHERE u.success = FALSE)::int AS failure_count,
            COALESCE(SUM(COALESCE(u.prompt_tokens, 0)), 0)::bigint AS prompt_tokens,
            COALESCE(SUM(COALESCE(u.completion_tokens, 0)), 0)::bigint AS completion_tokens,
            COALESCE(SUM(COALESCE(u.total_tokens, 0)), 0)::bigint AS total_tokens,
            ROUND(AVG(u.latency_ms))::int AS avg_latency_ms,
            ROUND(
                COALESCE(SUM(
                    CASE
                        WHEN p.id IS NULL THEN 0
                        ELSE (
                            COALESCE(u.prompt_tokens, 0)::numeric * p.input_price_per_1m_tokens
                            + COALESCE(u.completion_tokens, 0)::numeric * p.output_price_per_1m_tokens
                        ) / 1000000
                    END
                ), 0),
                8
            ) AS estimated_cost,
            COUNT(*) FILTER (
                WHERE (u.prompt_tokens IS NOT NULL OR u.completion_tokens IS NOT NULL)
                  AND p.id IS NULL
            )::int AS unpriced_count
        FROM llm_model_usage u
        LEFT JOIN llm_model_pricing p
            ON p.provider = u.provider
           AND p.model = u.model
           AND p.is_active = TRUE
        {aggregate_where_sql}
        """,
        params=aggregate_params,
        fetch_one=True,
    ) or {}

    breakdown = execute_auto_query(
        f"""
        SELECT
            u.action_name,
            u.provider,
            u.model,
            COUNT(*)::int AS request_count,
            COUNT(*) FILTER (WHERE u.success = FALSE)::int AS failure_count,
            COALESCE(SUM(COALESCE(u.prompt_tokens, 0)), 0)::bigint AS prompt_tokens,
            COALESCE(SUM(COALESCE(u.completion_tokens, 0)), 0)::bigint AS completion_tokens,
            COALESCE(SUM(COALESCE(u.total_tokens, 0)), 0)::bigint AS total_tokens,
            ROUND(AVG(u.latency_ms))::int AS avg_latency_ms,
            ROUND(
                COALESCE(SUM(
                    CASE
                        WHEN p.id IS NULL THEN 0
                        ELSE (
                            COALESCE(u.prompt_tokens, 0)::numeric * p.input_price_per_1m_tokens
                            + COALESCE(u.completion_tokens, 0)::numeric * p.output_price_per_1m_tokens
                        ) / 1000000
                    END
                ), 0),
                8
            ) AS estimated_cost,
            COUNT(*) FILTER (
                WHERE (u.prompt_tokens IS NOT NULL OR u.completion_tokens IS NOT NULL)
                  AND p.id IS NULL
            )::int AS unpriced_count
        FROM llm_model_usage u
        LEFT JOIN llm_model_pricing p
            ON p.provider = u.provider
           AND p.model = u.model
           AND p.is_active = TRUE
        {aggregate_where_sql}
        GROUP BY u.action_name, u.provider, u.model
        ORDER BY total_tokens DESC, request_count DESC, u.action_name, u.provider, u.model
        LIMIT 100
        """,
        params=aggregate_params,
    ) or []

    option_rows = execute_auto_query(
        f"""
        SELECT
            COALESCE(jsonb_agg(DISTINCT provider) FILTER (WHERE provider IS NOT NULL), '[]'::jsonb) AS providers,
            COALESCE(jsonb_agg(DISTINCT model) FILTER (WHERE model IS NOT NULL), '[]'::jsonb) AS models,
            COALESCE(jsonb_agg(DISTINCT action_name) FILTER (WHERE action_name IS NOT NULL), '[]'::jsonb) AS actions
        FROM llm_model_usage
        {option_where_sql}
        """,
        params=option_params,
        fetch_one=True,
    ) or {}

    def normalize_row(row: dict[str, Any]) -> dict[str, Any]:
        return {key: _json_number(value) for key, value in row.items()}

    next_cursor = items[-1]["id"] if items and len(items) == limit else None
    return {
        "items": [normalize_row(dict(row)) for row in items],
        "summary": normalize_row(dict(summary)),
        "breakdown": {"by_model_action": [normalize_row(dict(row)) for row in breakdown]},
        "filters": {
            "from": from_dt.isoformat(),
            "to": to_dt.isoformat() if to_dt else None,
            "providers": sorted(option_rows.get("providers") or []),
            "models": sorted(option_rows.get("models") or []),
            "actions": sorted(option_rows.get("actions") or []),
        },
        "next_cursor": next_cursor,
    }


def _normalize_llm_pricing_key(value: str, *, field_name: str) -> str:
    normalized = str(value or "").strip()
    if not normalized:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} cannot be blank")
    if len(normalized) > 200:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"{field_name} is too long")
    return normalized


def _serialize_llm_pricing_row(row: dict[str, Any]) -> dict[str, Any]:
    return {key: _json_number(value) for key, value in row.items()}


@api_router.get("/llm-model-pricing")
def list_llm_model_pricing(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    rows = execute_auto_query(
        """
        WITH usage_pairs AS (
            SELECT
                provider,
                model,
                COUNT(*)::int AS usage_count,
                MAX(created_at) AS last_used_at
            FROM llm_model_usage
            GROUP BY provider, model
        )
        SELECT
            COALESCE(p.provider, u.provider) AS provider,
            COALESCE(p.model, u.model) AS model,
            p.id,
            p.input_price_per_1m_tokens,
            p.output_price_per_1m_tokens,
            COALESCE(p.currency, 'USD') AS currency,
            COALESCE(p.is_active, FALSE) AS is_active,
            p.created_at,
            p.updated_at,
            COALESCE(u.usage_count, 0)::int AS usage_count,
            u.last_used_at,
            (p.id IS NOT NULL) AS pricing_configured
        FROM usage_pairs u
        FULL OUTER JOIN llm_model_pricing p
            ON p.provider = u.provider
           AND p.model = u.model
        ORDER BY COALESCE(u.last_used_at, p.updated_at, p.created_at) DESC NULLS LAST,
                 COALESCE(p.provider, u.provider),
                 COALESCE(p.model, u.model)
        """
    ) or []
    return {"items": [_serialize_llm_pricing_row(dict(row)) for row in rows]}


@api_router.put("/llm-model-pricing/{provider}/{model:path}")
def upsert_llm_model_pricing(
    provider: str,
    model: str,
    payload: LLMModelPricingUpsert,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    provider_key = _normalize_llm_pricing_key(provider, field_name="provider")
    model_key = _normalize_llm_pricing_key(model, field_name="model")
    updated = execute_auto_write(
        """
        INSERT INTO llm_model_pricing (
            provider,
            model,
            input_price_per_1m_tokens,
            output_price_per_1m_tokens,
            currency,
            is_active
        ) VALUES (
            :provider,
            :model,
            :input_price_per_1m_tokens,
            :output_price_per_1m_tokens,
            :currency,
            :is_active
        )
        ON CONFLICT (provider, model) DO UPDATE
        SET
            input_price_per_1m_tokens = EXCLUDED.input_price_per_1m_tokens,
            output_price_per_1m_tokens = EXCLUDED.output_price_per_1m_tokens,
            currency = EXCLUDED.currency,
            is_active = EXCLUDED.is_active
        RETURNING
            id,
            provider,
            model,
            input_price_per_1m_tokens,
            output_price_per_1m_tokens,
            currency,
            is_active,
            created_at,
            updated_at
        """,
        params={
            "provider": provider_key,
            "model": model_key,
            "input_price_per_1m_tokens": str(payload.input_price_per_1m_tokens),
            "output_price_per_1m_tokens": str(payload.output_price_per_1m_tokens),
            "currency": payload.currency,
            "is_active": payload.is_active,
        },
        fetch_one=True,
    )
    if updated is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to save LLM pricing")
    return _serialize_llm_pricing_row(dict(updated))


@api_router.delete("/llm-model-pricing/{provider}/{model:path}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_llm_model_pricing(
    provider: str,
    model: str,
    current_user: User = Depends(get_current_user),
) -> Response:
    _require_admin_user(current_user)
    provider_key = _normalize_llm_pricing_key(provider, field_name="provider")
    model_key = _normalize_llm_pricing_key(model, field_name="model")
    execute_auto_write(
        """
        UPDATE llm_model_pricing
        SET is_active = FALSE
        WHERE provider = :provider
          AND model = :model
        """,
        params={"provider": provider_key, "model": model_key},
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@api_router.get("/llm-providers")
def list_llm_providers(current_user: User = Depends(get_current_user)) -> dict:
    _require_admin_user(current_user)
    _ensure_default_llm_provider()
    rows = execute_auto_query(
        """
        SELECT
            id,
            provider_key,
            display_name,
            is_active,
            enabled,
            use_case,
            api_base_url,
            api_key_secret_id,
            selected_model,
            allowed_models,
            timeout_seconds,
            metadata,
            created_at,
            updated_at
        FROM llm_providers
        ORDER BY display_name, provider_key
        """
    ) or []
    return {"items": [_serialize_llm_provider(dict(row)) for row in rows]}


@api_router.get("/llm-providers/{provider_id}")
def get_llm_provider(provider_id: int, current_user: User = Depends(get_current_user)) -> dict:
    _require_admin_user(current_user)
    return _serialize_llm_provider(_get_llm_provider_row(provider_id))


@api_router.post("/llm-providers/{provider_id}/health-check")
def check_llm_provider_health(
    provider_id: int,
    payload: LLMProviderHealthCheck,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    provider = _get_llm_provider_row(provider_id)
    return _check_llm_provider_accessibility(
        provider,
        model=payload.model,
        timeout_seconds=payload.timeout_seconds,
        api_key_override=payload.api_key,
    )


@api_router.put("/llm-providers/{provider_id}/settings")
def update_llm_provider_settings(
    provider_id: int,
    payload: LLMSettingsUpdate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    current = _serialize_llm_provider(_get_llm_provider_row(provider_id))
    allowed_models = payload.allowed_models if payload.allowed_models is not None else current["allowed_models"]
    if payload.selected_model not in allowed_models:
        allowed_models = [*allowed_models, payload.selected_model]
    if payload.enabled:
        health = _check_llm_provider_accessibility(
            _get_llm_provider_row(provider_id),
            model=payload.selected_model,
            timeout_seconds=payload.timeout_seconds,
        )
        if not health.get("accessible"):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail={"message": "LLM provider health check failed", "health": health},
            )
        updated = execute_auto_write(
            """
            WITH disabled AS (
                UPDATE llm_providers
                SET enabled = FALSE
                WHERE id <> :provider_id
                  AND use_case = :use_case
                  AND enabled = TRUE
                RETURNING id
            )
            UPDATE llm_providers
            SET
                enabled = TRUE,
                selected_model = :selected_model,
                timeout_seconds = :timeout_seconds,
                allowed_models = CAST(:allowed_models AS jsonb)
            WHERE id = :provider_id
            RETURNING
                id,
                provider_key,
                display_name,
                is_active,
                enabled,
                use_case,
                api_base_url,
                api_key_secret_id,
                selected_model,
                allowed_models,
                timeout_seconds,
                metadata,
                created_at,
                updated_at
            """,
            params={
                "provider_id": provider_id,
                "use_case": current["use_case"],
                "selected_model": payload.selected_model,
                "timeout_seconds": payload.timeout_seconds,
                "allowed_models": json.dumps(allowed_models),
            },
            fetch_one=True,
        )
        if updated is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="LLM provider not found")
        return _serialize_llm_provider(updated)

    updated = execute_auto_write(
        """
        UPDATE llm_providers
        SET
            enabled = :enabled,
            selected_model = :selected_model,
            timeout_seconds = :timeout_seconds,
            allowed_models = CAST(:allowed_models AS jsonb)
        WHERE id = :provider_id
        RETURNING
            id,
            provider_key,
            display_name,
            is_active,
            enabled,
            use_case,
            api_base_url,
            api_key_secret_id,
            selected_model,
            allowed_models,
            timeout_seconds,
            metadata,
            created_at,
            updated_at
        """,
        params={
            "provider_id": provider_id,
            "enabled": payload.enabled,
            "selected_model": payload.selected_model,
            "timeout_seconds": payload.timeout_seconds,
            "allowed_models": json.dumps(allowed_models),
        },
        fetch_one=True,
    )
    if updated is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="LLM provider not found")
    return _serialize_llm_provider(updated)


@api_router.put("/llm-providers/{provider_id}/api-key")
def upsert_llm_provider_api_key(
    provider_id: int,
    payload: SecretUpsert,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    provider = _get_llm_provider_row(provider_id)
    secret = payload.secret.strip()
    if not secret:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Secret cannot be blank")
    description = payload.description or f"{provider.get('display_name')} LLM API key"
    current_secret_id = provider.get("api_key_secret_id")
    if current_secret_id is None:
        secret_id = execute_auto_function(
            "set_secret",
            params={"p_secret": secret, "p_description": description},
            fetch_one=True,
            write=True,
            expect_scalar=True,
        )
    else:
        updated = execute_auto_function(
            "update_secret",
            params={"p_id": current_secret_id, "p_secret": secret, "p_description": description},
            fetch_one=True,
            write=True,
            expect_scalar=True,
        )
        if updated:
            secret_id = current_secret_id
        else:
            secret_id = execute_auto_function(
                "set_secret",
                params={"p_secret": secret, "p_description": description},
                fetch_one=True,
                write=True,
                expect_scalar=True,
            )
    if secret_id is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to persist API key")
    execute_auto_write(
        """
        UPDATE llm_providers
        SET api_key_secret_id = :secret_id
        WHERE id = :provider_id
        """,
        params={"provider_id": provider_id, "secret_id": secret_id},
    )
    provider = _get_llm_provider_row(provider_id)
    return _serialize_llm_provider(provider)


@api_router.delete("/llm-providers/{provider_id}/api-key", status_code=status.HTTP_204_NO_CONTENT)
def delete_llm_provider_api_key(
    provider_id: int,
    current_user: User = Depends(get_current_user),
) -> Response:
    _require_admin_user(current_user)
    provider = _get_llm_provider_row(provider_id)
    secret_id = provider.get("api_key_secret_id")
    if secret_id is not None:
        execute_auto_function("delete_secret", params={"p_id": secret_id}, fetch_one=True, write=True)
    execute_auto_write(
        """
        UPDATE llm_providers
        SET api_key_secret_id = NULL
        WHERE id = :provider_id
        """,
        params={"provider_id": provider_id},
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@api_router.get("/tasks")
def list_tasks(
    current_user: User = Depends(get_current_user),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: int | None = Query(default=None),
    status_filter: str | None = Query(default=None, alias="status"),
    queue: str | None = Query(default=None),
) -> dict:
    _ = current_user

    where_clauses: list[str] = []
    params: dict[str, object] = {"limit": limit}
    if status_filter:
        where_clauses.append("status::text = :status")
        params["status"] = status_filter
    if queue:
        where_clauses.append("queue_name = :queue")
        params["queue"] = queue
    if cursor:
        where_clauses.append("id < :cursor")
        params["cursor"] = cursor

    where_sql = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
    query = f"""
        SELECT
            id,
            task_uuid::text AS task_uuid,
            task_name,
            status::text AS status,
            queue_name,
            CASE
                WHEN task_data IS NULL THEN NULL
                WHEN LENGTH(task_data::text) > 220 THEN LEFT(task_data::text, 217) || '...'
                ELSE task_data::text
            END AS task_data_excerpt,
            CASE
                WHEN task_metadata IS NULL THEN NULL
                WHEN LENGTH(task_metadata::text) > 220 THEN LEFT(task_metadata::text, 217) || '...'
                ELSE task_metadata::text
            END AS task_metadata_excerpt,
            priority,
            attempts,
            max_attempts,
            worker_id,
            created_at,
            updated_at,
            scheduled_at,
            started_at,
            completed_at
        FROM task_queue
        {where_sql}
        ORDER BY created_at DESC, id DESC
        LIMIT :limit
    """
    rows = execute_auto_query(query, params=params)
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "next_cursor": next_cursor}


@api_router.get("/tasks/enqueue-options")
def get_task_enqueue_options(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    queues = execute_auto_query(
        """
        SELECT
            qr.queue_name,
            qr.description,
            COUNT(wr.worker_id)::int AS registered_worker_count,
            COUNT(wr.worker_id) FILTER (WHERE wr.is_active = TRUE)::int AS active_worker_count
        FROM queue_registry qr
        LEFT JOIN worker_registry wr
          ON EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(COALESCE(wr.subscribed_queues, '[]'::jsonb)) AS subscribed(queue_name)
              WHERE subscribed.queue_name = qr.queue_name
          )
        WHERE qr.is_active = TRUE
        GROUP BY qr.queue_name, qr.description
        ORDER BY qr.queue_name
        """
    ) or []
    workers = execute_auto_query(
        """
        SELECT
            wr.worker_id,
            COALESCE(NULLIF(wr.worker_name, ''), wr.worker_id) AS worker_name,
            wr.is_active,
            COALESCE(wr.subscribed_queues, '[]'::jsonb) AS subscribed_queues,
            wr.current_load,
            wr.max_concurrent_tasks AS max_capacity
        FROM worker_registry wr
        WHERE jsonb_array_length(COALESCE(wr.subscribed_queues, '[]'::jsonb)) > 0
        ORDER BY wr.is_active DESC, COALESCE(NULLIF(wr.worker_name, ''), wr.worker_id), wr.worker_id
        """
    ) or []
    return {
        "queues": queues,
        "workers": workers,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@api_router.post("/tasks/enqueue", status_code=status.HTTP_201_CREATED)
def enqueue_task_from_admin(
    payload: TaskEnqueueCreate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)

    queue_row = execute_auto_query(
        """
        SELECT queue_name
        FROM queue_registry
        WHERE queue_name = :queue_name
          AND is_active = TRUE
        LIMIT 1
        """,
        params={"queue_name": payload.queue_name},
        fetch_one=True,
    )
    if queue_row is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Queue does not exist or is inactive")

    worker_row = execute_auto_query(
        """
        SELECT
            worker_id,
            COALESCE(subscribed_queues, '[]'::jsonb) AS subscribed_queues
        FROM worker_registry wr
        WHERE worker_id = :worker_id
          AND EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(COALESCE(wr.subscribed_queues, '[]'::jsonb)) AS subscribed(queue_name)
              WHERE subscribed.queue_name = :queue_name
          )
        LIMIT 1
        """,
        params={"worker_id": payload.worker_id, "queue_name": payload.queue_name},
        fetch_one=True,
    )
    if worker_row is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Worker is not subscribed to the selected queue")

    task_data = _build_admin_task_data(payload)
    now_utc = datetime.now(timezone.utc)
    scheduled_at = now_utc if payload.scheduled_at is None else _normalize_task_scheduled_at(payload.scheduled_at)
    if scheduled_at > now_utc + timedelta(days=365):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Cannot schedule tasks more than 1 year in advance")

    is_future = scheduled_at > now_utc
    task_status = "scheduled" if is_future else "pending"
    task_type = "delayed" if is_future else "immediate"
    actor_id = f"pwsadmin:{current_user.id}"

    result = execute_auto_write(
        """
        WITH inserted_task AS (
            INSERT INTO task_queue (
                task_name,
                task_type,
                queue_name,
                task_data,
                status,
                priority,
                scheduled_at,
                max_attempts,
                next_run_at,
                created_by
            ) VALUES (
                :worker_id,
                CAST(:task_type AS task_type),
                :queue_name,
                CAST(:task_data AS jsonb),
                CAST(:task_status AS task_status),
                :priority,
                :scheduled_at,
                :max_attempts,
                :scheduled_at,
                :created_by
            )
            RETURNING
                id,
                task_uuid,
                task_name,
                task_type,
                queue_name,
                task_data,
                status,
                priority,
                scheduled_at,
                max_attempts,
                created_by,
                created_at
        ),
        audit_insert AS (
            INSERT INTO audit_log (
                operation,
                entity_type,
                entity_id,
                actor_id,
                old_values,
                new_values,
                success
            )
            SELECT
                'enqueue'::audit_operation,
                'task',
                inserted_task.id,
                :created_by,
                NULL,
                jsonb_build_object(
                    'source', 'pwsadmin',
                    'direct_insert', TRUE,
                    'user_id', :user_id,
                    'user_email', :user_email,
                    'task_uuid', inserted_task.task_uuid::text,
                    'task_name', inserted_task.task_name,
                    'queue_name', inserted_task.queue_name,
                    'action', :action,
                    'status', inserted_task.status::text
                ),
                TRUE
            FROM inserted_task
            RETURNING id
        )
        SELECT
            id,
            task_uuid::text AS task_uuid,
            task_name,
            task_type::text AS task_type,
            queue_name,
            task_data,
            status::text AS status,
            priority,
            scheduled_at,
            max_attempts,
            created_by,
            created_at
        FROM inserted_task
        """,
        params={
            "worker_id": payload.worker_id,
            "task_type": task_type,
            "queue_name": payload.queue_name,
            "task_data": json.dumps(task_data, default=str),
            "task_status": task_status,
            "priority": payload.priority,
            "scheduled_at": scheduled_at,
            "max_attempts": payload.max_attempts,
            "created_by": actor_id,
            "user_id": current_user.id,
            "user_email": current_user.email,
            "action": payload.action,
        },
        fetch_one=True,
    )
    return result or {}


@api_router.get("/tasks/{task_id}")
def get_task(task_id: int, current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user

    query = """
        SELECT
            id,
            task_uuid::text AS task_uuid,
            task_name,
            status::text AS status,
            queue_name,
            task_type::text AS task_type,
            priority,
            attempts,
            max_attempts,
            worker_id,
            task_data,
            task_metadata,
            last_error,
            created_at,
            updated_at,
            scheduled_at,
            started_at,
            completed_at
        FROM task_queue
        WHERE id = :task_id
        LIMIT 1
    """
    row = execute_auto_query(query, params={"task_id": task_id}, fetch_one=True)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
    return row


@api_router.get("/tasks/{task_id}/lineage")
def get_task_lineage(task_id: int, current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    # Lookup task UUID first
    task_row = execute_auto_query(
        "SELECT task_uuid::text AS task_uuid FROM task_queue WHERE id = :task_id LIMIT 1",
        params={"task_id": task_id},
        fetch_one=True,
    )
    if task_row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")

    lineage = execute_auto_query(
        "SELECT * FROM get_task_ancestors_descendants(:task_uuid)",
        params={"task_uuid": task_row["task_uuid"]},
    )
    return {"task_uuid": task_row["task_uuid"], "lineage": lineage or []}


@api_router.get("/pricing/rules")
def list_pricing_rules(
    current_user: User = Depends(get_current_user),
    property_id: int | None = Query(default=None),
    platform_id: int | None = Query(default=None),
    platform_property_lookup_id: int | None = Query(default=None),
    operation_code: str | None = Query(default=None),
    category: str | None = Query(default=None),
    scope_filter: str | None = Query(default=None, alias="scope"),
    status_filter: str | None = Query(default=None, alias="status"),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    if scope_filter and scope_filter not in {"global", "platform", "property", "listing"}:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid scope filter")

    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    rule_property_name_sql = _property_name_sql("rule_prop")
    lookup_property_name_sql = _property_name_sql("lookup_prop")
    where: list[str] = []
    params: dict[str, object] = {"limit": limit}
    if property_id:
        where.append("COALESCE(pr.property_id, ppl.properties_ptr) = :property_id")
        params["property_id"] = property_id
    if platform_id:
        where.append("COALESCE(pr.platform_id, ppl.platform_id) = :platform_id")
        params["platform_id"] = platform_id
    if platform_property_lookup_id:
        where.append("pr.platform_property_lookup_id = :platform_property_lookup_id")
        params["platform_property_lookup_id"] = platform_property_lookup_id
    if operation_code:
        where.append("pot.operation_code = :operation_code")
        params["operation_code"] = operation_code
    if category:
        where.append("pot.category::text = :category")
        params["category"] = category
    if scope_filter:
        where.append("pr.scope = :scope_filter")
        params["scope_filter"] = scope_filter
    if status_filter:
        where.append("pr.status::text = :status_filter")
        params["status_filter"] = status_filter
    if cursor:
        where.append("pr.id < :cursor")
        params["cursor"] = cursor
    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    query = f"""
        SELECT
            pr.id,
            pr.rule_uuid::text AS rule_uuid,
            pr.property_id,
            pr.platform_id,
            pr.platform_property_lookup_id,
            pr.scope,
            pr.rule_name,
            pr.priority,
            pr.status::text AS status,
            pr.start_date,
            pr.end_date,
            pr.day_of_week_pattern,
            pr.created_at,
            pr.updated_at,
            pot.operation_code,
            pot.category::text AS category,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            COALESCE(pr.property_id, ppl.properties_ptr) AS resolved_property_id,
            COALESCE(pr.platform_id, ppl.platform_id) AS resolved_platform_id,
            COALESCE({rule_property_name_sql}, {lookup_property_name_sql}) AS property_name,
            COALESCE(rule_plat.name, lookup_plat.name) AS platform_name,
            COALESCE(rule_plat.type::text, lookup_plat.type::text) AS platform_type
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pot.id = pr.operation_id
        LEFT JOIN platform_property_lookup ppl ON ppl.id = pr.platform_property_lookup_id
        LEFT JOIN properties rule_prop ON rule_prop.id = pr.property_id
        LEFT JOIN properties lookup_prop ON lookup_prop.id = ppl.properties_ptr
        LEFT JOIN platforms rule_plat ON rule_plat.id = pr.platform_id
        LEFT JOIN platforms lookup_plat ON lookup_plat.id = ppl.platform_id
        {where_sql}
        ORDER BY pr.id DESC
        LIMIT :limit
    """
    rows = execute_auto_query(query, params=params)
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "next_cursor": next_cursor}


@api_router.get("/pricing/listings")
def list_pricing_listings(
    current_user: User = Depends(get_current_user),
    platform_id: int | None = Query(default=None),
    property_id: int | None = Query(default=None),
    lookup_id: int | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=500),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    property_name_sql = _property_name_sql("p")
    where: list[str] = []
    params: dict[str, object] = {"limit": limit}
    if platform_id is not None:
        where.append("ppl.platform_id = :platform_id")
        params["platform_id"] = platform_id
    if property_id is not None:
        where.append("ppl.properties_ptr = :property_id")
        params["property_id"] = property_id
    if lookup_id is not None:
        where.append("ppl.id = :lookup_id")
        params["lookup_id"] = lookup_id
    if cursor:
        where.append("ppl.id < :cursor")
        params["cursor"] = cursor
    where_sql = f"WHERE {' AND '.join(where)}" if where else ""
    rows = execute_auto_query(
        f"""
        SELECT
            ppl.id AS lookup_id,
            ppl.platform_id,
            plat.name AS platform_name,
            plat.type::text AS platform_type,
            ppl.properties_ptr AS property_id,
            {property_name_sql} AS property_name,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            ppl.created_at
        FROM platform_property_lookup ppl
        JOIN platforms plat ON plat.id = ppl.platform_id
        JOIN properties p ON p.id = ppl.properties_ptr
        {where_sql}
        ORDER BY ppl.id DESC
        LIMIT :limit
        """,
        params=params,
    )
    next_cursor = rows[-1]["lookup_id"] if rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "next_cursor": next_cursor}


@api_router.get("/pricing/rules/{rule_uuid}")
def get_pricing_rule(
    rule_uuid: UUID,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    rule_property_name_sql = _property_name_sql("rule_prop")
    lookup_property_name_sql = _property_name_sql("lookup_prop")
    row = execute_auto_query(
        f"""
        SELECT
            pr.rule_uuid::text AS rule_uuid,
            pr.property_id,
            pr.platform_id,
            pr.platform_property_lookup_id,
            pr.scope,
            pr.priority,
            pr.status::text AS status,
            pr.rule_name,
            pr.rule_config,
            pr.applicable_dates,
            pr.start_date,
            pr.end_date,
            pr.day_of_week_pattern,
            pr.allow_override,
            pr.requires_approval,
            pot.operation_code,
            pot.category::text AS category,
            ppl.properties_ptr AS lookup_property_id,
            ppl.platform_id AS lookup_platform_id,
            COALESCE(pr.property_id, ppl.properties_ptr) AS resolved_property_id,
            COALESCE(pr.platform_id, ppl.platform_id) AS resolved_platform_id,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            COALESCE({rule_property_name_sql}, {lookup_property_name_sql}) AS property_name,
            COALESCE(rule_plat.name, lookup_plat.name) AS platform_name,
            COALESCE(rule_plat.type::text, lookup_plat.type::text) AS platform_type
        FROM pricing_rules pr
        JOIN pricing_operation_types pot ON pot.id = pr.operation_id
        LEFT JOIN platform_property_lookup ppl ON ppl.id = pr.platform_property_lookup_id
        LEFT JOIN properties rule_prop ON rule_prop.id = pr.property_id
        LEFT JOIN properties lookup_prop ON lookup_prop.id = ppl.properties_ptr
        LEFT JOIN platforms rule_plat ON rule_plat.id = pr.platform_id
        LEFT JOIN platforms lookup_plat ON lookup_plat.id = ppl.platform_id
        WHERE pr.rule_uuid = :rule_uuid
        LIMIT 1
        """,
        params={"rule_uuid": str(rule_uuid)},
        fetch_one=True,
    )
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Rule not found")
    return row


def _validate_rule_scope(payload: PricingRuleCreate | PricingRuleUpdate) -> None:
    has_dates = bool(payload.applicable_dates)
    has_range = payload.start_date is not None and payload.end_date is not None
    has_dow = payload.day_of_week_pattern is not None
    if not (has_dates or has_range or has_dow):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Provide applicable_dates, date range, or day_of_week_pattern. season_window is an optional filter and does not replace the base date scope.",
        )


def _validate_rule_target_scope(
    property_id: int | None,
    platform_id: int | None,
    platform_property_lookup_id: int | None,
) -> None:
    if platform_property_lookup_id is None:
        return
    if property_id is not None or platform_id is not None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Listing-scoped rule requires property_id and platform_id to be null",
        )
    if _get_platform_property_lookup_row(platform_property_lookup_id) is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="platform_property_lookup_id was not found",
        )


@api_router.post("/pricing/rules", status_code=status.HTTP_201_CREATED)
def create_pricing_rule(
    payload: PricingRuleCreate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    _validate_rule_scope(payload)
    _validate_rule_target_scope(payload.property_id, payload.platform_id, payload.platform_property_lookup_id)
    op_row = execute_auto_query(
        "SELECT id FROM pricing_operation_types WHERE operation_code = :code AND is_active = TRUE",
        params={"code": payload.operation_code},
        fetch_one=True,
    )
    if op_row is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid operation_code")

    params: dict[str, object] = {
        "operation_id": op_row["id"],
        "property_id": payload.property_id,
        "platform_id": payload.platform_id,
        "platform_property_lookup_id": payload.platform_property_lookup_id,
        "rule_config": json.dumps(payload.rule_config),
        "applicable_dates": _serialize_applicable_dates(payload.applicable_dates),
        "start_date": payload.start_date,
        "end_date": payload.end_date,
        "day_of_week_pattern": payload.day_of_week_pattern,
        "priority": payload.priority or 50,
        "rule_name": payload.rule_name or f"Rule {payload.operation_code}",
        "status": payload.status or "active",
        "allow_override": payload.allow_override if payload.allow_override is not None else True,
        "requires_approval": payload.requires_approval if payload.requires_approval is not None else False,
    }
    query = """
        INSERT INTO pricing_rules (
            property_id,
            platform_id,
            platform_property_lookup_id,
            operation_id,
            rule_config,
            applicable_dates,
            start_date,
            end_date,
            day_of_week_pattern,
            priority,
            rule_name,
            status,
            allow_override,
            requires_approval,
            created_by,
            created_via
        ) VALUES (
            :property_id,
            :platform_id,
            :platform_property_lookup_id,
            :operation_id,
            CAST(:rule_config AS jsonb),
            CAST(:applicable_dates AS jsonb),
            :start_date,
            :end_date,
            :day_of_week_pattern,
            :priority,
            :rule_name,
            CAST(:status AS rule_status),
            :allow_override,
            :requires_approval,
            :created_by,
            'pwsadmin'
        )
        RETURNING rule_uuid::text AS rule_uuid
    """
    params["created_by"] = current_user.email
    result = execute_auto_write(query, params=params, fetch_one=True)
    return result or {}


@api_router.patch("/pricing/rules/{rule_uuid}")
def update_pricing_rule(
    rule_uuid: UUID,
    payload: PricingRuleUpdate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    set_parts: list[str] = []
    params: dict[str, object] = {"rule_uuid": str(rule_uuid)}
    fields_set = payload.model_fields_set
    scope_fields = {"applicable_dates", "start_date", "end_date", "day_of_week_pattern"}
    target_fields = {"property_id", "platform_id", "platform_property_lookup_id"}
    current_rule = None
    if fields_set & (scope_fields | target_fields):
        current_rule = execute_auto_query(
            """
            SELECT
                applicable_dates,
                start_date,
                end_date,
                day_of_week_pattern,
                property_id,
                platform_id,
                platform_property_lookup_id
            FROM pricing_rules
            WHERE rule_uuid = :rule_uuid
            LIMIT 1
            """,
            params={"rule_uuid": str(rule_uuid)},
            fetch_one=True,
        )
        if current_rule is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Rule not found")
    if fields_set & scope_fields:
        next_applicable_dates = (
            payload.applicable_dates if "applicable_dates" in fields_set else current_rule["applicable_dates"]
        )
        next_start_date = payload.start_date if "start_date" in fields_set else current_rule["start_date"]
        next_end_date = payload.end_date if "end_date" in fields_set else current_rule["end_date"]
        next_day_of_week_pattern = (
            payload.day_of_week_pattern
            if "day_of_week_pattern" in fields_set
            else current_rule["day_of_week_pattern"]
        )
        if not (
            bool(next_applicable_dates)
            or (next_start_date is not None and next_end_date is not None)
            or next_day_of_week_pattern is not None
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Provide applicable_dates, date range, or day_of_week_pattern. season_window is an optional filter and does not replace the base date scope.",
            )
    if fields_set & target_fields:
        next_property_id = payload.property_id if "property_id" in fields_set else current_rule["property_id"]
        next_platform_id = payload.platform_id if "platform_id" in fields_set else current_rule["platform_id"]
        next_platform_property_lookup_id = (
            payload.platform_property_lookup_id
            if "platform_property_lookup_id" in fields_set
            else current_rule["platform_property_lookup_id"]
        )
        _validate_rule_target_scope(next_property_id, next_platform_id, next_platform_property_lookup_id)
    if payload.rule_config is not None:
        set_parts.append("rule_config = CAST(:rule_config AS jsonb)")
        params["rule_config"] = json.dumps(payload.rule_config)
    if "property_id" in fields_set:
        set_parts.append("property_id = :property_id")
        params["property_id"] = payload.property_id
    if "platform_id" in fields_set:
        set_parts.append("platform_id = :platform_id")
        params["platform_id"] = payload.platform_id
    if "platform_property_lookup_id" in fields_set:
        set_parts.append("platform_property_lookup_id = :platform_property_lookup_id")
        params["platform_property_lookup_id"] = payload.platform_property_lookup_id
    if "applicable_dates" in fields_set:
        set_parts.append("applicable_dates = CAST(:applicable_dates AS jsonb)")
        params["applicable_dates"] = _serialize_applicable_dates(payload.applicable_dates)
    if "start_date" in fields_set:
        set_parts.append("start_date = :start_date")
        params["start_date"] = payload.start_date
    if "end_date" in fields_set:
        set_parts.append("end_date = :end_date")
        params["end_date"] = payload.end_date
    if "day_of_week_pattern" in fields_set:
        set_parts.append("day_of_week_pattern = :day_of_week_pattern")
        params["day_of_week_pattern"] = payload.day_of_week_pattern
    if payload.priority is not None:
        set_parts.append("priority = :priority")
        params["priority"] = payload.priority
    if payload.rule_name is not None:
        set_parts.append("rule_name = :rule_name")
        params["rule_name"] = payload.rule_name
    if payload.status is not None:
        set_parts.append("status = CAST(:status AS rule_status)")
        params["status"] = payload.status
    if payload.allow_override is not None:
        set_parts.append("allow_override = :allow_override")
        params["allow_override"] = payload.allow_override
    if payload.requires_approval is not None:
        set_parts.append("requires_approval = :requires_approval")
        params["requires_approval"] = payload.requires_approval
    if payload.operation_code is not None:
        op_row = execute_auto_query(
            "SELECT id FROM pricing_operation_types WHERE operation_code = :code",
            params={"code": payload.operation_code},
            fetch_one=True,
        )
        if op_row is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid operation_code")
        set_parts.append("operation_id = :operation_id")
        params["operation_id"] = op_row["id"]

    if not set_parts:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No fields to update")

    query = f"""
        UPDATE pricing_rules
        SET {', '.join(set_parts)}, updated_at = NOW()
        WHERE rule_uuid = :rule_uuid
        RETURNING rule_uuid::text AS rule_uuid
    """
    result = execute_auto_write(query, params=params, fetch_one=True)
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Rule not found")
    return result


@api_router.delete("/pricing/rules")
def delete_pricing_rules(
    filters: PricingBulkDelete,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    if filters.property_id is None and filters.platform_id is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Provide property_id or platform_id")

    where: list[str] = []
    params: dict[str, object] = {}
    if filters.property_id is not None:
        where.append("property_id = :property_id")
        params["property_id"] = filters.property_id
    if filters.platform_id is not None:
        where.append("platform_id = :platform_id")
        params["platform_id"] = filters.platform_id
    if filters.operation_codes:
        where.append("operation_id IN (SELECT id FROM pricing_operation_types WHERE operation_code = ANY(:ops))")
        params["ops"] = filters.operation_codes
    if filters.statuses:
        where.append("status = ANY(:statuses)")
        params["statuses"] = filters.statuses
    where_sql = f"WHERE {' AND '.join(where)}"

    if filters.mode == "delete":
        query = f"DELETE FROM pricing_rules {where_sql} RETURNING rule_uuid::text AS rule_uuid"
    else:
        query = f"UPDATE pricing_rules SET status = 'inactive' {where_sql} RETURNING rule_uuid::text AS rule_uuid"

    rows = execute_auto_write(query, params=params)
    return {"deleted": len(rows or []), "rule_uuids": [r["rule_uuid"] for r in rows or []]}


@api_router.get("/platforms")
def list_platforms(current_user: User = Depends(get_current_user)) -> dict:
    rows = execute_auto_query(
        """
        SELECT id, name, type::text AS type, is_active, metadata, created_at, updated_at
        FROM platforms
        ORDER BY name
        """
    )
    items: list[dict[str, Any]] = []
    include_secret_status = bool(getattr(current_user, "is_admin", False))
    for row in rows or []:
        item = dict(row)
        item["metadata"] = _sanitize_platform_metadata(
            item.get("metadata"),
            include_secret_status=include_secret_status,
        )
        if include_secret_status:
            item["api_token_slots"] = _parse_platform_api_token_slots(row.get("metadata") or {})
        items.append(item)
    return {"items": items}


@api_router.get("/properties")
def list_properties(
    current_user: User = Depends(get_current_user),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    params = {"limit": limit}
    where = ""
    if cursor:
        where = "WHERE id < :cursor"
        params["cursor"] = cursor
    rows = execute_auto_query(
        f"""
        SELECT
            id,
            descrp,
            COALESCE(
                descrp->>'name',
                descrp->>'title',
                descrp->>'label',
                'Property ' || id::text
            ) AS name,
            created_at,
            updated_at
        FROM properties
        {where}
        ORDER BY id DESC
        LIMIT :limit
        """,
        params=params,
    )
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "next_cursor": next_cursor}


@api_router.get("/properties/coverage")
def list_properties_coverage(
    current_user: User = Depends(get_current_user),
    limit: int = Query(default=200, ge=1, le=1000),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    params: dict[str, Any] = {"limit": limit}
    where_sql = ""
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    if cursor:
        where_sql = "WHERE p.id < :cursor"
        params["cursor"] = cursor

    rows = execute_auto_query(
        f"""
        SELECT
            p.id AS property_id,
            COALESCE(
                p.descrp->>'name',
                p.descrp->>'title',
                p.descrp->>'label',
                'Property ' || p.id::text
            ) AS property_name,
            p.descrp->>'latitude' AS latitude,
            p.descrp->>'longitude' AS longitude,
            COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'lookup_id', ppl.id,
                        'platform_id', plat.id,
                        'platform_name', plat.name,
                        'platform_type', plat.type::text,
                        'platform_property_id', {lookup_id_sql},
                        'listing_name', {listing_name_sql}
                    )
                    ORDER BY plat.name, {lookup_id_sql}
                ) FILTER (WHERE ppl.id IS NOT NULL),
                '[]'::jsonb
            ) AS listings
        FROM properties p
        LEFT JOIN platform_property_lookup ppl ON ppl.properties_ptr = p.id
        LEFT JOIN platforms plat ON plat.id = ppl.platform_id
        {where_sql}
        GROUP BY p.id, p.descrp
        ORDER BY p.id DESC
        LIMIT :limit
        """,
        params=params,
    )
    total_rows = execute_auto_query("SELECT COUNT(*)::int AS total_count FROM properties")
    total_count = int(total_rows[0]["total_count"]) if total_rows else 0
    next_cursor = rows[-1]["property_id"] if rows and len(rows) == limit else None
    return {"items": rows, "next_cursor": next_cursor, "total_count": total_count}


@api_router.get("/properties/stage-status")
def get_property_stage_status(current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    rows = execute_auto_query(
        """
        SELECT
            LOWER(plat.type::text) AS stage,
            COUNT(ppl.id)::int AS listing_count
        FROM platforms plat
        LEFT JOIN platform_property_lookup ppl ON ppl.platform_id = plat.id
        WHERE plat.is_active = TRUE
          AND LOWER(plat.type::text) IN ('pms', 'ota', 'dpt')
        GROUP BY LOWER(plat.type::text)
        """
    )
    stages = {
        "pms": {"listing_count": 0, "completed": False},
        "ota": {"listing_count": 0, "completed": False},
        "dpt": {"listing_count": 0, "completed": False},
    }
    for row in rows or []:
        stage = str(row.get("stage") or "").strip().lower()
        if stage not in stages:
            continue
        listing_count = int(row.get("listing_count") or 0)
        stages[stage] = {"listing_count": listing_count, "completed": listing_count > 0}
    return {"stages": stages}


@api_router.get("/platform-property-links/{lookup_id}")
def get_platform_property_links(
    lookup_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    rows = _fetch_linked_listings_for_lookup_id(lookup_id)
    if not rows:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Listing chain not found")
    return {"lookup_id": lookup_id, "items": rows}


@api_router.post("/platform-property-links/{lookup_id}/link")
def link_platform_property_listing(
    lookup_id: int,
    payload: PlatformPropertyLinkRequest,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    target_lookup_id = int(payload.target_lookup_id)
    if target_lookup_id == lookup_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Source and target listing must be different")

    rows = _fetch_linked_listings_for_lookup_id(lookup_id)
    if not rows:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Listing not found")

    rows_by_lookup_id = {
        int(row["lookup_id"]): row
        for row in rows
        if row.get("lookup_id") is not None
    }
    source_row = rows_by_lookup_id.get(int(lookup_id))
    target_row = rows_by_lookup_id.get(target_lookup_id)
    if source_row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Listing not found")
    if target_row is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Target listing must belong to the same property",
        )
    if not source_row.get("is_chain_head"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unlink this listing first before linking it to another chain",
        )
    if int(source_row.get("platform_id") or 0) == int(target_row.get("platform_id") or 0):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot link listings on the same platform",
        )

    component_by_lookup_id = _build_property_lookup_components(rows)
    source_component_id = component_by_lookup_id.get(int(lookup_id))
    target_component_id = component_by_lookup_id.get(target_lookup_id)
    if source_component_id is None or target_component_id is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unable to resolve listing chains for this property",
        )
    if source_component_id == target_component_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Listings are already in the same chain",
        )

    target_tail_by_component_id = _build_property_lookup_chain_tails(rows)
    target_tail_lookup_id = target_tail_by_component_id.get(target_component_id)
    target_tail_row = rows_by_lookup_id.get(int(target_tail_lookup_id)) if target_tail_lookup_id is not None else None
    if target_tail_lookup_id is None or target_tail_row is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Unable to determine the target chain tail",
        )
    if int(source_row.get("platform_id") or 0) == int(target_tail_row.get("platform_id") or 0):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The target chain tail is on the same platform; choose another chain",
        )

    updated = execute_auto_write(
        """
        UPDATE platform_property_lookup
        SET self = :target_lookup_id,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = :lookup_id
        RETURNING id AS lookup_id, self AS target_lookup_id
        """,
        params={"lookup_id": lookup_id, "target_lookup_id": target_tail_lookup_id},
        fetch_one=True,
    )
    return {
        "lookup_id": updated.get("lookup_id") if isinstance(updated, dict) else lookup_id,
        "linked": True,
        "target_lookup_id": (
            updated.get("target_lookup_id") if isinstance(updated, dict) else target_tail_lookup_id
        ),
    }


@api_router.post("/platform-property-links/{lookup_id}/unlink")
def unlink_platform_property_listing(
    lookup_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    current_row = execute_auto_query(
        """
        SELECT id, self
        FROM platform_property_lookup
        WHERE id = :lookup_id
        """,
        params={"lookup_id": lookup_id},
        fetch_one=True,
    )
    if current_row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Listing not found")
    if current_row.get("self") is None:
        return {"lookup_id": lookup_id, "unlinked": False}

    updated = execute_auto_write(
        """
        UPDATE platform_property_lookup
        SET self = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = :lookup_id
        RETURNING id AS lookup_id
        """,
        params={"lookup_id": lookup_id},
        fetch_one=True,
    )
    return {"lookup_id": updated.get("lookup_id") if isinstance(updated, dict) else lookup_id, "unlinked": True}


@api_router.get("/message-classes")
def list_message_classes(
    include_inactive: bool = Query(default=False),
    limit: int | None = Query(default=None, ge=1, le=200),
    cursor: int | None = Query(default=None),
    current_user: User = Depends(get_current_user),
) -> dict:
    if include_inactive:
        _require_admin_user(current_user)
    rows = _list_message_class_rows(include_inactive=include_inactive, limit=limit, cursor=cursor)
    total_row = execute_auto_query(
        f"""
        SELECT COUNT(*)::int AS total_count
        FROM message_classes mc
        {"WHERE mc.is_active = TRUE" if not include_inactive else ""}
        """,
        fetch_one=True,
    )
    total_count = int(total_row.get("total_count") or 0) if isinstance(total_row, dict) else 0
    next_cursor = rows[-1]["id"] if limit is not None and rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "total_count": total_count, "next_cursor": next_cursor}


@api_router.post("/message-classes", status_code=status.HTTP_201_CREATED)
def create_message_class(
    payload: MessageClassCreate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    name = payload.name.strip()
    description = payload.description.strip()
    _assert_required_message_class_is_active(name, payload.is_active)
    _assert_message_class_name_available(name)
    created = execute_auto_write(
        """
        INSERT INTO message_classes (name, description, is_active)
        VALUES (:name, :description, :is_active)
        RETURNING id
        """,
        params={
            "name": name,
            "description": description,
            "is_active": payload.is_active,
        },
        fetch_one=True,
    )
    created_id = int(created.get("id")) if isinstance(created, dict) and created.get("id") is not None else None
    if created_id is None:  # pragma: no cover - defensive fallback
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Message class was not created")
    return _get_message_class_or_404(created_id)


@api_router.put("/message-classes/{class_id}")
def update_message_class(
    class_id: int,
    payload: MessageClassUpdate,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    current_row = _get_message_class_or_404(class_id)
    update_data = payload.model_dump(exclude_none=True)
    if not update_data:
        return current_row

    next_name = str(update_data.get("name") or current_row.get("name") or "").strip()
    next_description = str(update_data.get("description") or current_row.get("description") or "").strip()
    next_is_active = bool(update_data["is_active"]) if "is_active" in update_data else bool(current_row.get("is_active"))

    _assert_message_class_mutation_allowed(
        current_row,
        next_name=next_name,
        next_is_active=next_is_active,
    )
    _assert_required_message_class_is_active(next_name, next_is_active)
    _assert_message_class_name_available(next_name, exclude_id=class_id)

    execute_auto_write(
        """
        UPDATE message_classes
        SET name = :name,
            description = :description,
            is_active = :is_active
        WHERE id = :class_id
        RETURNING id
        """,
        params={
            "class_id": class_id,
            "name": next_name,
            "description": next_description,
            "is_active": next_is_active,
        },
        fetch_one=True,
    )
    return _get_message_class_or_404(class_id)


@api_router.delete("/message-classes/{class_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_message_class(
    class_id: int,
    current_user: User = Depends(get_current_user),
) -> Response:
    _require_admin_user(current_user)
    current_row = _get_message_class_or_404(class_id)
    _assert_message_class_mutation_allowed(current_row, deleting=True)
    if int(current_row.get("usage_count") or 0) > 0:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Cannot delete a message class that is already assigned to messages",
        )
    execute_auto_write(
        """
        DELETE FROM message_classes
        WHERE id = :class_id
        RETURNING id
        """,
        params={"class_id": class_id},
        fetch_one=True,
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@api_router.get("/platforms/{platform_id}/properties")
def list_platform_properties(
    platform_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    lookup_id_sql = _platform_property_lookup_id_sql("ppl")
    listing_name_sql = _platform_property_lookup_listing_name_sql("ppl")
    rows = execute_auto_query(
        f"""
        SELECT
            ppl.id AS lookup_id,
            {lookup_id_sql} AS platform_property_id,
            {listing_name_sql} AS listing_name,
            ppl.created_at,
            p.id AS property_id,
            p.descrp->>'latitude' AS latitude,
            p.descrp->>'longitude' AS longitude
        FROM platform_property_lookup ppl
        JOIN properties p ON p.id = ppl.properties_ptr
        WHERE ppl.platform_id = :platform_id
        ORDER BY ppl.created_at DESC
        """,
        params={"platform_id": platform_id},
    )
    return {"items": rows}


@api_router.get("/platforms/{platform_id}/properties/remote")
def fetch_remote_properties(
    platform_id: int,
    page: int = Query(default=1, ge=1),
    per_page: int = Query(default=20, ge=1, le=100),
    fetch_all: bool = Query(default=True),
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    platform = _get_platform_row(platform_id)
    auth_headers = _resolve_platform_auth_headers_for_remote_fetch(platform)
    items = _fetch_remote_platform_properties(
        platform,
        auth_headers=auth_headers,
        page=page,
        per_page=per_page,
        fetch_all=fetch_all,
    )
    annotated_items = _annotate_remote_properties(platform_id, items)
    return {
        "platform_id": platform_id,
        "platform_name": platform.get("name"),
        "fetch_all": fetch_all,
        "items": annotated_items,
    }


@api_router.post("/platforms/{platform_id}/properties/import", status_code=status.HTTP_201_CREATED)
def import_platform_properties(
    platform_id: int,
    payload: PlatformPropertyImportRequest,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    if not payload.items:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="No items provided")

    imported: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    annotation_rows = _annotate_remote_properties(
        platform_id,
        [item.model_dump(mode="json") if hasattr(item, "model_dump") else item.dict() for item in payload.items],
    )
    annotations_by_platform_property_id = {
        str(row.get("platform_property_id") or "").strip(): row for row in annotation_rows
    }
    for item in payload.items:
        platform_property_id = str(item.platform_property_id or "").strip()
        if not platform_property_id:
            errors.append({"platform_property_id": "", "error": "platform_property_id is required"})
            continue

        latitude = _normalize_coordinate_text(item.latitude)
        longitude = _normalize_coordinate_text(item.longitude)
        if not latitude or not longitude:
            errors.append(
                {
                    "platform_property_id": platform_property_id,
                    "error": "latitude and longitude are required numeric values",
                }
            )
            continue

        annotation = annotations_by_platform_property_id.get(platform_property_id) or {}
        existing_property_id = annotation.get("existing_property_id")
        existing_lookup_id = annotation.get("lookup_id")
        requested_link_to_lookup_id = item.link_to_lookup_id

        link_to_lookup_id_for_write, link_error = resolve_import_link_choice(annotation, requested_link_to_lookup_id)
        if link_error:
            errors.append(
                {
                    "platform_property_id": platform_property_id,
                    "error": link_error,
                }
            )
            continue

        existing_property = (
            {
                "property_id": existing_property_id,
                "latitude": annotation.get("existing_property_latitude"),
                "longitude": annotation.get("existing_property_longitude"),
            }
            if existing_property_id is not None
            else None
        )
        if existing_property is not None:
            canonical_latitude = str(existing_property.get("latitude") or latitude)
            canonical_longitude = str(existing_property.get("longitude") or longitude)
        else:
            canonical_latitude = latitude
            canonical_longitude = longitude

        item_payload = item.model_dump(mode="json") if hasattr(item, "model_dump") else item.dict()
        property_details = build_property_details(item_payload)
        listing_metadata = build_listing_metadata(item_payload)
        listing_name = str(listing_metadata.get("name") or "").strip() or None
        try:
            function_params = {
                "input_platform_id": platform_id,
                "input_platform_property_id": platform_property_id,
                "prop_latitude": canonical_latitude,
                "prop_longitude": canonical_longitude,
                "prop_details": json.dumps(property_details),
            }
            if link_to_lookup_id_for_write is not None:
                function_params["link_to_lookup_id"] = link_to_lookup_id_for_write
            if (
                annotation.get("is_linked_on_platform")
                and existing_lookup_id is not None
                and existing_property_id is not None
                and link_to_lookup_id_for_write is None
                and _property_link_write_mode() != "link_platform_property"
            ):
                preserved_row = execute_auto_write(
                    """
                    UPDATE platform_property_lookup
                    SET properties_ptr = :property_id,
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = :lookup_id
                    RETURNING id AS lookup_id
                    """,
                    params={"property_id": existing_property_id, "lookup_id": existing_lookup_id},
                    fetch_one=True,
                )
                link_id = preserved_row.get("lookup_id") if isinstance(preserved_row, dict) else preserved_row
            else:
                link_id = _execute_property_link_write(function_params)
            _persist_platform_listing_metadata(
                link_id,
                listing_name=listing_name,
                listing_metadata=listing_metadata,
            )
            imported.append(
                {
                    "platform_property_id": platform_property_id,
                    "lookup_id": link_id,
                    "existing_property_id": existing_property_id,
                    "link_to_lookup_id": link_to_lookup_id_for_write or existing_lookup_id,
                    "listing_name": listing_name,
                }
            )
        except Exception as exc:  # pragma: no cover - depends on DB rules
            errors.append({"platform_property_id": platform_property_id, "error": str(exc)})

    return {"imported": imported, "errors": errors}


@api_router.get("/platforms/{platform_id}/api-tokens")
def list_platform_api_tokens(
    platform_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    items = _parse_platform_api_token_slots(platform.get("metadata") or {})
    return {"platform_id": platform_id, "platform_name": platform.get("name"), "items": items}


@api_router.put("/platforms/{platform_id}/api-tokens/{token_key:path}")
def upsert_platform_api_token(
    platform_id: int,
    token_key: str,
    payload: ApiTokenUpsert,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    secret = payload.secret.strip()
    if not secret:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Secret cannot be blank")
    validation_overrides: dict[str, str] = {}
    for key, value in (payload.validation_overrides or {}).items():
        token_key_name = str(key or "").strip()
        token_secret = str(value or "").strip()
        if token_key_name and token_secret:
            validation_overrides[token_key_name] = token_secret
    return _upsert_platform_api_token(
        platform_id,
        token_key,
        secret=secret,
        validation_overrides=validation_overrides or None,
    )


@api_router.delete("/platforms/{platform_id}/api-tokens/{token_key:path}", status_code=status.HTTP_204_NO_CONTENT)
def delete_platform_api_token(
    platform_id: int,
    token_key: str,
    current_user: User = Depends(get_current_user),
) -> Response:
    _require_admin_user(current_user)
    _delete_platform_api_token(platform_id, token_key)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@api_router.get("/platforms/{platform_id}/secrets/status")
def platform_secret_status(
    platform_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    slot = _first_platform_api_token_slot(platform.get("metadata") or {})
    secret_id = slot.get("secret_id") if slot else None
    return {
        "platform_id": platform_id,
        "secret_id": secret_id,
        "has_secret": secret_id is not None,
        "token_key": slot.get("token_key") if slot else None,
    }


@api_router.post("/platforms/{platform_id}/secrets", status_code=status.HTTP_201_CREATED)
def create_platform_secret(
    platform_id: int,
    payload: SecretUpsert,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    secret = payload.secret.strip()
    if not secret:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Secret cannot be blank")
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    slot = _first_platform_api_token_slot(platform.get("metadata") or {})
    if slot is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Platform has no API token slots")
    result = _upsert_platform_api_token(
        platform_id,
        slot["token_key"],
        secret=secret,
        description=payload.description,
    )
    return {"secret_id": result["secret_id"], "platform_id": platform_id, "validation": result.get("validation")}


@api_router.put("/platforms/{platform_id}/secrets/{secret_id}")
def update_platform_secret(
    platform_id: int,
    secret_id: int,
    payload: SecretUpsert,
    current_user: User = Depends(get_current_user),
) -> dict:
    _require_admin_user(current_user)
    secret = payload.secret.strip()
    if not secret:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Secret cannot be blank")

    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    slot = _first_platform_api_token_slot(platform.get("metadata") or {})
    if slot is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Platform has no API token slots")
    current_secret_id = slot.get("secret_id")
    if current_secret_id is not None and current_secret_id != secret_id:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Provided secret_id does not match platform token pointer",
        )
    result = _upsert_platform_api_token(
        platform_id,
        slot["token_key"],
        secret=secret,
        description=payload.description,
    )
    return {
        "secret_id": result["secret_id"],
        "platform_id": platform_id,
        "updated": True,
        "validation": result.get("validation"),
    }


@api_router.delete("/platforms/{platform_id}/secrets/{secret_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_platform_secret(
    platform_id: int,
    secret_id: int,
    current_user: User = Depends(get_current_user),
) -> Response:
    _require_admin_user(current_user)
    platform = _canonicalize_platform_metadata_for_token_management(_get_platform_row(platform_id))
    slot = _first_platform_api_token_slot(platform.get("metadata") or {})
    if slot is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Platform has no API token slots")
    current_secret_id = slot.get("secret_id")
    if current_secret_id is not None and current_secret_id != secret_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Secret not linked to platform token")
    _delete_platform_api_token(platform_id, slot["token_key"])
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@api_router.get("/bso/applied-rules")
def list_bso_applied_rules(
    current_user: User = Depends(get_current_user),
    booking_entry_id: int | None = Query(default=None),
    status_filter: str | None = Query(default=None, alias="status"),
    updated_from: date | None = Query(default=None),
    updated_to: date | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=500),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user

    normalized_status = status_filter.strip().lower() if status_filter else None
    allowed_statuses = {"processing", "applied", "removed", "failed"}
    if normalized_status and normalized_status not in allowed_statuses:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid status. Use one of: processing, applied, removed, failed",
        )

    if updated_from is not None and updated_to is not None and updated_from > updated_to:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="updated_from must be on or before updated_to",
        )

    rows = execute_auto_query(
        """
        SELECT
            id,
            booking_entry_id,
            property_id,
            platform_id,
            listing_id,
            rule_uuid::text AS rule_uuid,
            trigger_category,
            instruction,
            status::text AS status,
            applied_at,
            removed_at,
            updated_at,
            applied_by_task_id,
            removed_by_task_id
        FROM find_booking_applied_rules_audit(
            p_booking_entry_id => :booking_entry_id,
            p_status => :status_filter,
            p_updated_from => :updated_from,
            p_updated_to => :updated_to,
            p_limit => :limit,
            p_cursor => :cursor
        )
        ORDER BY id DESC
        """,
        params={
            "booking_entry_id": booking_entry_id,
            "status_filter": normalized_status,
            "updated_from": updated_from,
            "updated_to": updated_to,
            "limit": limit,
            "cursor": cursor,
        },
    )
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "count": len(rows), "next_cursor": next_cursor}


@api_router.get("/bookings")
def list_bookings(
    current_user: User = Depends(get_current_user),
    property_id: int | None = Query(default=None),
    platform_id: int | None = Query(default=None),
    arrival_from: date | None = Query(default=None),
    arrival_to: date | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    cursor: int | None = Query(default=None),
) -> dict:
    _ = current_user
    if property_id is None and arrival_from is None and arrival_to is None:
        rows = execute_auto_query(
            """
            SELECT id, arrival, departure, booked_at, guest_id, property_id, platform_id, ppl_id, thread_ids_json, metadata, created_at, updated_at
            FROM find_booking_registers(
                p_platform_id => :platform_id,
                p_limit => :limit,
                p_cursor => :cursor
            )
            ORDER BY id DESC
            """,
            params={
                "platform_id": platform_id,
                "limit": limit,
                "cursor": cursor,
            },
        )
    else:
        where: list[str] = []
        params: dict[str, object] = {"limit": limit}
        if property_id is not None:
            where.append("property_id = :property_id")
            params["property_id"] = property_id
        if platform_id is not None:
            where.append("platform_id = :platform_id")
            params["platform_id"] = platform_id
        if arrival_from is not None:
            where.append("arrival >= :arrival_from")
            params["arrival_from"] = arrival_from
        if arrival_to is not None:
            where.append("arrival <= :arrival_to")
            params["arrival_to"] = arrival_to
        if cursor is not None:
            where.append("id < :cursor")
            params["cursor"] = cursor
        where_sql = f"WHERE {' AND '.join(where)}" if where else ""
        rows = execute_auto_query(
            f"""
            SELECT id, arrival, departure, booked_at, guest_id, property_id, platform_id, ppl_id, thread_ids_json, metadata, created_at, updated_at
            FROM booking_registers
            {where_sql}
            ORDER BY id DESC
            LIMIT :limit
            """,
            params=params,
        )
    next_cursor = rows[-1]["id"] if rows and len(rows) == limit else None
    return {"items": rows, "next_cursor": next_cursor}


@api_router.get("/bookings/{booking_id}")
def get_booking_detail(booking_id: int, current_user: User = Depends(get_current_user)) -> dict:
    _ = current_user
    booking = execute_auto_query(
        "SELECT * FROM booking_registers WHERE id = :bid LIMIT 1",
        params={"bid": booking_id},
        fetch_one=True,
    )
    if booking is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

    thread_ids = booking.get("thread_ids_json") or []
    messages: list[dict[str, Any]] = []
    if isinstance(thread_ids, list) and thread_ids:
        messages = execute_auto_query(
            """
            SELECT
                m.id,
                m.thread_id,
                m.mid,
                m.content,
                m.message_timestamp,
                m.metadata,
                mc.name AS class_name
            FROM messages m
            LEFT JOIN message_class_lookup mcl ON mcl.message_id = m.id AND mcl.is_primary = TRUE
            LEFT JOIN message_classes mc ON mc.id = mcl.class_id
            WHERE m.thread_id = ANY(:thread_ids) AND m.platform_id = :platform_id
            ORDER BY m.message_timestamp DESC
            """,
            params={"thread_ids": thread_ids, "platform_id": booking["platform_id"]},
        )

    applied_rules = execute_auto_query(
        """
        SELECT id, rule_uuid::text AS rule_uuid, trigger_category, status::text AS status, instruction, applied_at, updated_at
        FROM booking_applied_rules
        WHERE booking_entry_id = :bid
        ORDER BY applied_at DESC
        """,
        params={"bid": booking_id},
    )

    booking["messages"] = messages
    booking["applied_rules"] = applied_rules
    return booking


@api_router.get("/bookings/{booking_id}/message-threads/{thread_id}/messages")
def get_booking_thread_messages(
    booking_id: int,
    thread_id: int,
    current_user: User = Depends(get_current_user),
) -> dict:
    _ = current_user
    booking = execute_auto_query(
        "SELECT id, platform_id, thread_ids_json FROM booking_registers WHERE id = :bid LIMIT 1",
        params={"bid": booking_id},
        fetch_one=True,
    )
    if booking is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found")

    raw_thread_ids = booking.get("thread_ids_json") or []
    if isinstance(raw_thread_ids, str):
        try:
            raw_thread_ids = json.loads(raw_thread_ids)
        except json.JSONDecodeError:
            raw_thread_ids = []
    thread_ids: list[int] = []
    if isinstance(raw_thread_ids, list):
        for item in raw_thread_ids:
            try:
                thread_ids.append(int(item))
            except (TypeError, ValueError):
                continue
    if thread_id not in thread_ids:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message thread not found for booking")

    rows = execute_auto_query(
        """
        SELECT
            m.id,
            m.mid AS message_id,
            CASE
                WHEN LENGTH(m.content) > 120 THEN LEFT(m.content, 117) || '...'
                ELSE m.content
            END AS content_preview,
            mc.name AS class_name,
            COALESCE(mps.status::text, 'pending') AS processing_status
        FROM messages m
        LEFT JOIN message_processing_status mps ON mps.message_id = m.id
        LEFT JOIN message_class_lookup mcl ON mcl.message_id = m.id AND mcl.is_primary = TRUE
        LEFT JOIN message_classes mc ON mc.id = mcl.class_id
        WHERE m.thread_id = :thread_id
          AND m.platform_id = :platform_id
          AND m.deleted_at IS NULL
        ORDER BY m.message_timestamp ASC, m.id ASC
        LIMIT 500
        """,
        params={"thread_id": thread_id, "platform_id": booking["platform_id"]},
    )
    return {"booking_id": booking_id, "thread_id": thread_id, "items": rows or []}


app.include_router(pages_router)
app.include_router(api_router)

admin = Admin(
    engine=admin_engine,
    title="Password Safe Admin",
    base_url="/pwsadmin/admin",
    auth_provider=JWTAuthBackend(),
)
admin.add_view(UserAdmin(User))
admin.mount_to(app)
