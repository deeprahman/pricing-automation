let unauthorizedHandler = null;

export function configureHttp(options = {}) {
  unauthorizedHandler = typeof options.onUnauthorized === "function" ? options.onUnauthorized : null;
}

export function getToken() {
  const url = new URL(window.location.href);
  const token = url.searchParams.get("token");
  if (token) {
    sessionStorage.setItem("pwsadmin_token", token);
    localStorage.removeItem("pwsadmin_token");
    url.searchParams.delete("token");
    window.history.replaceState({}, "", url.toString());
    return token;
  }
  return sessionStorage.getItem("pwsadmin_token") || localStorage.getItem("pwsadmin_token");
}

export async function requestJSON(path, options = {}) {
  const token = getToken();
  const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  const response = await fetch(path, {
    ...options,
    headers,
    credentials: "same-origin",
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    let detail = body.detail;
    if (detail && typeof detail === "object") {
      detail = detail.message || detail.validation?.message || JSON.stringify(detail);
    }
    const error = new Error(detail || `Request failed: ${response.status}`);
    error.responseBody = body;
    error.statusCode = response.status;
    if (response.status === 401 && unauthorizedHandler) {
      unauthorizedHandler();
    }
    throw error;
  }
  return response.status === 204 ? null : response.json();
}

