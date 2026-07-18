#!/usr/bin/env bash
#
# Starts a worker debug session inside the Docker `workers` container.
#
# Bash counterpart to scripts/start-worker-debug.ps1.
#
# Reads `.env.local` by default, resolves the worker selected by
# `WORKER_DEBUG_WORKER`, starts or refreshes the `workers` service, and then
# launches the reserved worker under `debugpy` inside the container.

set -Eeuo pipefail

WORKER_NAME=""
HEARTBEAT_INTERVAL=""
LEASE_DURATION=""
ENV_FILE=".env.local"
NO_BUILD=false
DRY_RUN=false

declare -A ENV_VALUES=()
WORKER_ARGS=()

print_help() {
  cat <<'EOF'
Usage: start-worker-debug.sh [options]

Starts a worker debug session inside the Docker `workers` container.

Options:
  --worker-name NAME, -WorkerName NAME
      Worker name override. When omitted, uses WORKER_DEBUG_WORKER from
      the env file.

  --heartbeat-interval VALUE, -HeartbeatInterval VALUE
      Optional worker heartbeat interval override, for example "5 seconds".

  --lease-duration VALUE, -LeaseDuration VALUE
      Optional worker lease duration override, for example "30 seconds".

  --env-file PATH, -EnvFile PATH
      Env file for docker compose. Defaults to .env.local.

  --no-build, -NoBuild
      Skip --build when starting the workers service.

  --dry-run, -DryRun
      Print the commands without running them.

  -h, --help
      Show this help.

Examples:
  scripts/start-worker-debug.sh
  scripts/start-worker-debug.sh --worker-name messages-worker
  scripts/start-worker-debug.sh --worker-name messages-worker --heartbeat-interval "5 seconds" --lease-duration "30 seconds"
  scripts/start-worker-debug.sh --worker-name external-services-worker --heartbeat-interval "10 seconds" --lease-duration "1 minute"
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

write_section() {
  local title="$1"
  printf '\n== %s ==\n' "$title"
}

trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_edge_char() {
  local value="$1"
  local char="$2"
  while [[ "$value" == "$char"* ]]; do
    value="${value#"$char"}"
  done
  while [[ "$value" == *"$char" ]]; do
    value="${value%"$char"}"
  done
  printf '%s' "$value"
}

strip_env_value_quotes() {
  local value="$1"
  value="$(strip_edge_char "$value" '"')"
  value="$(strip_edge_char "$value" "'")"
  printf '%s' "$value"
}

resolve_full_path() {
  local base_path="$1"
  local raw_path="$2"
  local candidate

  if [[ "$raw_path" = /* ]]; then
    candidate="$raw_path"
  else
    candidate="${base_path}/${raw_path}"
  fi

  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$candidate"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$candidate" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
    return
  fi

  if command -v python >/dev/null 2>&1; then
    python - "$candidate" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
    return
  fi

  printf '%s\n' "$candidate"
}

resolve_executable_path() {
  local command_name="$1"
  command -v "$command_name" 2>/dev/null || die "Executable not found in PATH: $command_name"
}

resolve_python_path() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return
  fi

  if command -v python >/dev/null 2>&1; then
    command -v python
    return
  fi

  die "python3 or python is required to parse workers/pws_workers/worker_manifest.json."
}

read_dotenv() {
  local path="$1"
  local raw_line line key value

  [[ -f "$path" ]] || die "Env file not found: $path"

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(trim "$raw_line")"
    if [[ -z "$line" || "$line" == \#* || "$line" != *=* ]]; then
      continue
    fi

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    value="$(strip_env_value_quotes "$value")"
    ENV_VALUES["$key"]="$value"
  done < "$path"
}

env_value() {
  local key="$1"
  printf '%s' "${ENV_VALUES[$key]-}"
}

resolve_selected_worker_name() {
  local requested_worker_name="$1"
  local from_env

  requested_worker_name="$(trim "$requested_worker_name")"
  if [[ -n "$requested_worker_name" ]]; then
    printf '%s' "$requested_worker_name"
    return
  fi

  from_env="$(trim "$(env_value WORKER_DEBUG_WORKER)")"
  if [[ -z "$from_env" ]]; then
    die "WORKER_DEBUG_WORKER is not set in the env file. Set it in '$ENV_FILE' or pass --worker-name."
  fi

  printf '%s' "$from_env"
}

resolve_host_debug_port() {
  local port_text
  port_text="$(trim "$(env_value WORKERS_DEBUG_PORT)")"
  if [[ -z "$port_text" ]]; then
    printf '5678'
    return
  fi

  if [[ ! "$port_text" =~ ^-?[0-9]+$ ]]; then
    die "WORKERS_DEBUG_PORT must be an integer in the env file."
  fi

  printf '%s' "$port_text"
}

resolve_target_db_name() {
  local name value
  for name in WORKER_DB_NAME SCHEMA_DB POSTGRES_DB; do
    value="$(trim "$(env_value "$name")")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
  done

  printf 'auto_pws'
}

load_worker_manifest_entry() {
  local python_path="$1"
  local manifest_path="$2"
  local target_worker_name="$3"
  local db_name="$4"
  local log_dir="$5"
  local heartbeat_interval_override="$6"
  local lease_duration_override="$7"
  local -a manifest_parts=()

  mapfile -d '' -t manifest_parts < <(
    "$python_path" - \
      "$manifest_path" \
      "$target_worker_name" \
      "$db_name" \
      "$log_dir" \
      "$heartbeat_interval_override" \
      "$lease_duration_override" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
target_worker_name = sys.argv[2]
db_name = sys.argv[3]
log_dir = sys.argv[4]
heartbeat_interval_override = sys.argv[5].strip()
lease_duration_override = sys.argv[6].strip()

with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)

workers = manifest.get("workers") if isinstance(manifest, dict) else manifest
workers = workers or []

entry = next((item for item in workers if item.get("name") == target_worker_name), None)
if entry is None:
    available = ", ".join(str(item.get("name")) for item in workers if item.get("name"))
    print(f"Unknown worker '{target_worker_name}'. Available workers: {available}", file=sys.stderr)
    raise SystemExit(1)

script_path = "workers/pws_workers/" + str(entry.get("script_path", "")).replace("\\", "/")

resolved_args = []
for arg in entry.get("args") or []:
    arg = str(arg)
    if arg == "{db}":
        resolved_args.append(db_name)
    elif arg == "{logdir}":
        resolved_args.append(log_dir)
    else:
        resolved_args.append(arg)

if heartbeat_interval_override:
    resolved_args.extend(["--heartbeat-interval", heartbeat_interval_override])

if lease_duration_override:
    resolved_args.extend(["--lease-duration", lease_duration_override])

out = sys.stdout.buffer
out.write(script_path.encode("utf-8") + b"\0")
for arg in resolved_args:
    out.write(str(arg).encode("utf-8") + b"\0")
PY
  )

  if (( ${#manifest_parts[@]} == 0 )); then
    exit 1
  fi

  CONTAINER_SCRIPT_PATH="${manifest_parts[0]}"
  WORKER_ARGS=("${manifest_parts[@]:1}")
}

print_command() {
  local file_path="$1"
  shift

  printf '%q' "$file_path"
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

run_streaming_external_command() {
  local file_path="$1"
  shift
  local -a args=("$@")
  local exit_code

  print_command "$file_path" "${args[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  set +e
  "$file_path" "${args[@]}"
  exit_code=$?
  set -e

  if (( exit_code != 0 )); then
    die "Command failed with exit code $exit_code"
  fi
}

test_debugpy_port_availability() {
  local docker_path="$1"
  shift
  local -a compose_args=("$@")
  local container_port=5678
  local probe_script probe_output details

  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  probe_script="$(cat <<PY
import os
import socket
import sys

port = $container_port
current_pid = str(os.getpid())
s = socket.socket()
try:
    s.bind(("0.0.0.0", port))
except OSError:
    print(f"DEBUGPY_PORT_IN_USE:{port}")
    for pid in sorted(p for p in os.listdir("/proc") if p.isdigit()):
        if pid == current_pid:
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\\x00", b" ").decode("utf-8", "ignore").strip()
        except Exception:
            continue
        if "debugpy" in cmd:
            print(f"PID={pid} CMD={cmd}")
    sys.exit(1)
else:
    print(f"DEBUGPY_PORT_AVAILABLE:{port}")
finally:
    s.close()
PY
)"

  if probe_output="$("$docker_path" "${compose_args[@]}" exec -T workers python -c "$probe_script" 2>&1)"; then
    return
  fi

  details="$(printf '%s\n' "$probe_output" | grep '^PID=' || true)"
  {
    printf "Debug port %s is already in use inside the 'workers' container.\n" "$container_port"
    printf 'A previous debugpy session is still listening, so the new attach session cannot start.\n'
    printf 'Stop the old debug session, restart the workers container, or terminate the stale debugpy process and try again.\n'
    if [[ -n "$details" ]]; then
      printf 'Existing debugpy processes:\n'
      printf '%s\n' "$details"
    fi
  } >&2
  exit 1
}

require_option_value() {
  local option_name="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    die "Missing value for $option_name"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-name|-WorkerName)
      require_option_value "$1" "${2-}"
      WORKER_NAME="$2"
      shift 2
      ;;
    --worker-name=*)
      WORKER_NAME="${1#*=}"
      shift
      ;;
    --heartbeat-interval|-HeartbeatInterval)
      require_option_value "$1" "${2-}"
      HEARTBEAT_INTERVAL="$2"
      shift 2
      ;;
    --heartbeat-interval=*)
      HEARTBEAT_INTERVAL="${1#*=}"
      shift
      ;;
    --lease-duration|-LeaseDuration)
      require_option_value "$1" "${2-}"
      LEASE_DURATION="$2"
      shift 2
      ;;
    --lease-duration=*)
      LEASE_DURATION="${1#*=}"
      shift
      ;;
    --env-file|-EnvFile)
      require_option_value "$1" "${2-}"
      ENV_FILE="$2"
      shift 2
      ;;
    --env-file=*)
      ENV_FILE="${1#*=}"
      shift
      ;;
    --no-build|-NoBuild)
      NO_BUILD=true
      shift
      ;;
    --dry-run|-DryRun)
      DRY_RUN=true
      shift
      ;;
    -h|--help|-Help)
      print_help
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(resolve_full_path "$SCRIPT_DIR" "..")"
RESOLVED_ENV_FILE="$(resolve_full_path "$REPO_ROOT" "$ENV_FILE")"
MANIFEST_PATH="$(resolve_full_path "$REPO_ROOT" "workers/pws_workers/worker_manifest.json")"
DOCKER_PATH="$(resolve_executable_path docker)"
PYTHON_PATH="$(resolve_python_path)"

read_dotenv "$RESOLVED_ENV_FILE"

SELECTED_WORKER="$(resolve_selected_worker_name "$WORKER_NAME")"
HOST_DEBUG_PORT="$(resolve_host_debug_port)"
TARGET_DB="$(resolve_target_db_name)"
CONTAINER_SCRIPT_PATH=""

load_worker_manifest_entry \
  "$PYTHON_PATH" \
  "$MANIFEST_PATH" \
  "$SELECTED_WORKER" \
  "$TARGET_DB" \
  "output/worker-logs" \
  "$HEARTBEAT_INTERVAL" \
  "$LEASE_DURATION"

COMPOSE_BASE_ARGS=(
  compose
  -f docker-compose.yml
  -f docker-compose.local.yml
  --env-file "$RESOLVED_ENV_FILE"
)

# Ensure docker compose interpolation reserves the selected worker even when
# the caller passes --worker-name instead of editing the env file.
export WORKER_DEBUG_WORKER="$SELECTED_WORKER"

pushd "$REPO_ROOT" >/dev/null
trap 'popd >/dev/null 2>&1 || true; unset WORKER_DEBUG_WORKER' EXIT

write_section "Worker Debug Target"
printf 'Worker: %s\n' "$SELECTED_WORKER"
printf 'Script: %s\n' "$CONTAINER_SCRIPT_PATH"
printf 'Database: %s\n' "$TARGET_DB"
printf 'VS Code attach port: %s\n' "$HOST_DEBUG_PORT"
if [[ -n "$(trim "$HEARTBEAT_INTERVAL")" ]]; then
  printf 'Heartbeat interval override: %s\n' "$HEARTBEAT_INTERVAL"
fi
if [[ -n "$(trim "$LEASE_DURATION")" ]]; then
  printf 'Lease duration override: %s\n' "$LEASE_DURATION"
fi

write_section "Starting Workers Service"
COMPOSE_UP_ARGS=("${COMPOSE_BASE_ARGS[@]}" up -d)
if [[ "$NO_BUILD" != "true" ]]; then
  COMPOSE_UP_ARGS+=(--build)
fi
COMPOSE_UP_ARGS+=(workers)
run_streaming_external_command "$DOCKER_PATH" "${COMPOSE_UP_ARGS[@]}"

write_section "Checking Debug Port"
test_debugpy_port_availability "$DOCKER_PATH" "${COMPOSE_BASE_ARGS[@]}"

write_section "Starting Debugpy Session"
printf "Attach in VS Code using 'Python: Attach to Workers Container'.\n"
printf 'When prompted for the port, enter %s.\n' "$HOST_DEBUG_PORT"
COMPOSE_EXEC_ARGS=(
  "${COMPOSE_BASE_ARGS[@]}"
  exec
  workers
  python
  -Xfrozen_modules=off
  -m
  debugpy
  --listen
  0.0.0.0:5678
  --wait-for-client
  "$CONTAINER_SCRIPT_PATH"
  "${WORKER_ARGS[@]}"
)
run_streaming_external_command "$DOCKER_PATH" "${COMPOSE_EXEC_ARGS[@]}"
