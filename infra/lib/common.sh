#!/usr/bin/env bash
# lib/common.sh — sourced by every script in this bundle. Loads .env, adds a
# little logging, and a couple of small helpers used in more than one place.

set -euo pipefail

# Resolve this bundle's own root directory regardless of where it's invoked
# from, so scripts can be run as ./02-source-setup.sh or bash infra/02-...sh.
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(basename "$0")" "$*" >&2; }
warn() { printf '\033[1;33m[%s] WARNING:\033[0m %s\n' "$(basename "$0")" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

load_env() {
  local env_file="${1:-$INFRA_ROOT/.env}"
  if [ ! -f "$env_file" ]; then
    die "$env_file not found — copy .env.example to .env and fill it in first."
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  log "loaded config from $env_file"
}

# Persist a KEY=value into .env, replacing an existing line for that key if
# present, appending otherwise. Used by 00-aws-provision.sh to write back
# discovered IPs/IDs so later scripts (and reruns) pick them up automatically.
write_env_value() {
  local key="$1" value="$2" env_file="${3:-$INFRA_ROOT/.env}"
  touch "$env_file"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    # Portable in-place edit (works on both GNU and BSD sed without a backup file).
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$env_file" && rm -f "$env_file.bak"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "\$$name is not set — check .env (see .env.example for the full list)."
  fi
}

wait_for_tcp() {
  local host="$1" port="$2" tries="${3:-30}"
  log "waiting for $host:$port ..."
  for _ in $(seq 1 "$tries"); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      log "$host:$port is up"
      return 0
    fi
    sleep 2
  done
  warn "$host:$port never came up after $((tries * 2))s — continuing anyway, check it by hand"
  return 1
}

# curl wrapper for SEMP v2 config calls: prints method, path, and response
# status/body so a schema mismatch is immediately visible rather than a
# silent failure. Exits non-zero on connection failure, but NOT on a 4xx/5xx
# from the broker itself (the caller decides whether that's fatal), since a
# 400 "already exists" on a rerun is normal and expected.
semp() {
  local method="$1" host="$2" port="$3" path="$4" body="${5:-}"
  local url="http://${host}:${port}/SEMP/v2/config${path}"
  local resp status
  if [ -n "$body" ]; then
    resp=$(curl -sS -u "${BROKER_ADMIN_USER}:${BROKER_ADMIN_PASS}" \
      -X "$method" "$url" -H "Content-Type: application/json" -d "$body" \
      -w '\n%{http_code}')
  else
    resp=$(curl -sS -u "${BROKER_ADMIN_USER}:${BROKER_ADMIN_PASS}" \
      -X "$method" "$url" -w '\n%{http_code}')
  fi
  status="${resp##*$'\n'}"
  local payload="${resp%$'\n'*}"
  printf '  %-6s %s -> %s\n' "$method" "$path" "$status" >&2
  if [ "$status" -ge 400 ]; then
    printf '    %s\n' "$payload" | head -c 400 >&2
    printf '\n' >&2
  fi
  echo "$payload"
}

semp_monitor() {
  local host="$1" port="$2" path="$3"
  curl -sS -u "${BROKER_ADMIN_USER}:${BROKER_ADMIN_PASS}" \
    "http://${host}:${port}/SEMP/v2/monitor${path}"
}
