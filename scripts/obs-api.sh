#!/usr/bin/env bash
# scripts/obs-api.sh — centralized API client for the obs stack
#
# Usage:
#   obs-api.sh <service> <path> [extra-curl-args...]
#   obs-api.sh prometheus /api/v1/query --data-urlencode 'query=up'
#   obs-api.sh loki /ready
#   obs-api.sh alertmanager /api/v2/alerts
#
# Services: prometheus, loki, tempo, grafana, alertmanager, collector
#
# Auth-ready: set SHEPARD_API_TOKEN for Bearer auth, SHEPARD_CA_CERT for TLS.
# All env vars have sensible localhost defaults for single-machine use.

set -u

# ── Service URLs (override via env) ─────────────────────────────────
SHEPARD_PROMETHEUS_URL="${SHEPARD_PROMETHEUS_URL:-http://localhost:9090}"
SHEPARD_LOKI_URL="${SHEPARD_LOKI_URL:-http://localhost:3100}"
SHEPARD_TEMPO_URL="${SHEPARD_TEMPO_URL:-http://localhost:3200}"
SHEPARD_GRAFANA_URL="${SHEPARD_GRAFANA_URL:-http://localhost:3000}"
SHEPARD_ALERTMANAGER_URL="${SHEPARD_ALERTMANAGER_URL:-http://localhost:9093}"
SHEPARD_COLLECTOR_URL="${SHEPARD_COLLECTOR_URL:-http://localhost:8888}"

# ── Auth (empty = no auth, set when hardening) ──────────────────────
SHEPARD_API_TOKEN="${SHEPARD_API_TOKEN:-}"
SHEPARD_CA_CERT="${SHEPARD_CA_CERT:-}"
SHEPARD_GRAFANA_TOKEN="${SHEPARD_GRAFANA_TOKEN:-}"

# ── Resolve service → base URL ──────────────────────────────────────
resolve_url() {
  case "$1" in
    prometheus|prom)   echo "$SHEPARD_PROMETHEUS_URL" ;;
    loki)              echo "$SHEPARD_LOKI_URL" ;;
    tempo)             echo "$SHEPARD_TEMPO_URL" ;;
    grafana)           echo "$SHEPARD_GRAFANA_URL" ;;
    alertmanager|am)   echo "$SHEPARD_ALERTMANAGER_URL" ;;
    collector|otel)    echo "$SHEPARD_COLLECTOR_URL" ;;
    *) echo "Unknown service: $1" >&2; return 1 ;;
  esac
}

# ── Build auth headers ──────────────────────────────────────────────
auth_args() {
  local service="$1"
  local args=()

  # Grafana has its own token (API key / service account)
  if [[ "$service" == "grafana" && -n "$SHEPARD_GRAFANA_TOKEN" ]]; then
    args+=(-H "Authorization: Bearer $SHEPARD_GRAFANA_TOKEN")
  elif [[ -n "$SHEPARD_API_TOKEN" ]]; then
    args+=(-H "Authorization: Bearer $SHEPARD_API_TOKEN")
  fi

  # TLS CA certificate
  if [[ -n "$SHEPARD_CA_CERT" ]]; then
    args+=(--cacert "$SHEPARD_CA_CERT")
  fi

  printf '%s\n' "${args[@]}"
}

# ── Main ────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: obs-api.sh <service> <path> [extra-curl-args...]" >&2
  echo "Services: prometheus, loki, tempo, grafana, alertmanager, collector" >&2
  exit 1
fi

SERVICE="$1"
shift
API_PATH="$1"
shift

BASE_URL=$(resolve_url "$SERVICE") || exit 1

# Build curl command
CURL_ARGS=(-sf --max-time 10)

# Add auth args
while IFS= read -r arg; do
  [[ -n "$arg" ]] && CURL_ARGS+=("$arg")
done < <(auth_args "$SERVICE")

# Add extra args from caller
CURL_ARGS+=("$@")

# Execute
curl "${CURL_ARGS[@]}" "${BASE_URL}${API_PATH}"
