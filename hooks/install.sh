#!/usr/bin/env bash
# hooks/install.sh — auto-detect AI CLIs and inject hook configs
#
# Usage:
#   ./hooks/install.sh              # install all detected CLIs
#   ./hooks/install.sh claude       # install only Claude Code
#   ./hooks/install.sh codex gemini # install Codex + Gemini
#
# Supported providers: claude, codex, gemini

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED=0

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }

# ── Claude Code ──────────────────────────────────────────────────────

install_claude() {
  local config_dir="$HOME/.claude"
  local config_file="$config_dir/settings.json"

  if ! command -v claude &>/dev/null; then
    yellow "Claude Code  — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  # Read existing config or start fresh
  local existing='{}'
  [[ -f "$config_file" ]] && existing="$(cat "$config_file")"

  # Merge hooks into existing config
  local hook_config
  hook_config=$(jq -n \
    --arg post_tool "${HOOKS_DIR}/claude/post-tool-use.sh" \
    --arg stop "${HOOKS_DIR}/claude/stop.sh" \
    '{
      hooks: {
        PostToolUse: [{
          hooks: [{
            type: "command",
            command: $post_tool
          }]
        }],
        Stop: [{
          hooks: [{
            type: "command",
            command: $stop
          }]
        }]
      }
    }')

  # Native OTel: env vars scoped to Claude Code via settings.json "env" block
  local otel_env
  otel_env=$(jq -n '{
    env: {
      "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
      "OTEL_METRICS_EXPORTER": "otlp",
      "OTEL_LOGS_EXPORTER": "otlp",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
      "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4317",
      "OTEL_METRIC_EXPORT_INTERVAL": "10000",
      "OTEL_LOGS_EXPORT_INTERVAL": "5000",
      "OTEL_LOG_TOOL_DETAILS": "1"
    }
  }')

  # Deep merge: existing config + hooks + native OTel env
  echo "$existing" | jq --argjson hooks "$hook_config" --argjson otel "$otel_env" '. * $hooks * $otel' > "$config_file"

  green "Claude Code  — hooks + native OTel installed → $config_file"

  INSTALLED=$((INSTALLED + 1))
}

# ── Codex CLI ────────────────────────────────────────────────────────

install_codex() {
  local config_dir="$HOME/.codex"
  local config_file="$config_dir/config.toml"

  if ! command -v codex &>/dev/null; then
    yellow "Codex CLI    — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  # Remove existing shepherd-managed blocks (idempotent re-install)
  if [[ -f "$config_file" ]] && grep -q '# shepherd-managed:' "$config_file" 2>/dev/null; then
    sed -i.tmp '/^# shepherd-managed:start/,/^# shepherd-managed:end/d' "$config_file"
    rm -f "${config_file}.tmp"
  fi

  # Remove legacy (pre-marker) shepherd notify line
  if [[ -f "$config_file" ]] && grep -q 'codex/notify\.sh' "$config_file" 2>/dev/null; then
    sed -i.tmp '/codex\/notify\.sh/d' "$config_file"
    rm -f "${config_file}.tmp"
  fi

  # Remove legacy (pre-marker) shepherd [otel] section (only if endpoint matches)
  if [[ -f "$config_file" ]] && grep -q '^\[otel\]' "$config_file" 2>/dev/null; then
    if sed -n '/^\[otel\]/,/^\[/p' "$config_file" | grep -q 'localhost:4317'; then
      sed -i.tmp '/^\[otel\]/,/^\[/{/^\[otel\]/d;/^\[/!d;}' "$config_file"
      rm -f "${config_file}.tmp"
    fi
  fi

  local notify_line="notify = [\"/bin/bash\", \"${HOOKS_DIR}/codex/notify.sh\"]"
  local skip_notify=false
  local skip_otel=false

  # Warn if non-shepherd notify exists (TOML allows only one top-level key)
  if [[ -f "$config_file" ]] && grep -q '^notify' "$config_file" 2>/dev/null; then
    yellow "Codex CLI    — existing non-shepherd notify found, skipping hook install"
    skip_notify=true
  fi

  # Warn if non-shepherd [otel] exists
  if [[ -f "$config_file" ]] && grep -q '^\[otel\]' "$config_file" 2>/dev/null; then
    yellow "Codex CLI    — existing non-shepherd [otel] found, skipping OTel config"
    skip_otel=true
  fi

  # Prepend managed notify block
  if ! $skip_notify; then
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# shepherd-managed:start notify
${notify_line}
# shepherd-managed:end notify
EOF
    if [[ -f "$config_file" ]] && [[ -s "$config_file" ]]; then
      echo "" >> "$tmp"
      cat "$config_file" >> "$tmp"
    fi
    mv "$tmp" "$config_file"
  fi

  # Append managed otel block
  if ! $skip_otel; then
    cat >> "$config_file" <<'OTEL_EOF'

# shepherd-managed:start otel
[otel]
environment = "dev"
exporter = { otlp-grpc = { endpoint = "http://localhost:4317" } }
trace_exporter = { otlp-grpc = { endpoint = "http://localhost:4317" } }
# shepherd-managed:end otel
OTEL_EOF
  fi

  if $skip_notify && $skip_otel; then
    yellow "Codex CLI    — nothing installed (existing non-shepherd config)"
    return
  fi

  green "Codex CLI    — hooks + native OTel installed → $config_file"
  INSTALLED=$((INSTALLED + 1))
}

# ── Gemini CLI ───────────────────────────────────────────────────────

install_gemini() {
  local config_dir="$HOME/.gemini"
  local config_file="$config_dir/settings.json"

  if ! command -v gemini &>/dev/null; then
    yellow "Gemini CLI   — not found, skipping"
    return
  fi

  mkdir -p "$config_dir"

  # Back up existing config
  if [[ -f "$config_file" ]]; then
    cp "$config_file" "${config_file}.bak.$(date +%s)"
  fi

  local existing='{}'
  [[ -f "$config_file" ]] && existing="$(cat "$config_file")"

  local hook_config
  hook_config=$(jq -n \
    --arg after_tool "bash ${HOOKS_DIR}/gemini/after-tool.sh" \
    --arg after_agent "bash ${HOOKS_DIR}/gemini/after-agent.sh" \
    --arg after_model "bash ${HOOKS_DIR}/gemini/after-model.sh" \
    --arg session_end "bash ${HOOKS_DIR}/gemini/session-end.sh" \
    '{
      hooks: {
        AfterTool: [{
          matcher: "*",
          hooks: [{ type: "command", command: $after_tool }]
        }],
        AfterAgent: [{
          matcher: "*",
          hooks: [{ type: "command", command: $after_agent }]
        }],
        AfterModel: [{
          matcher: "*",
          hooks: [{ type: "command", command: $after_model }]
        }],
        SessionEnd: [{
          matcher: "exit",
          hooks: [{ type: "command", command: $session_end }]
        }]
      }
    }')

  # Merge hooks + native OTel telemetry config
  local telemetry_config
  telemetry_config=$(jq -n '{
    telemetry: {
      enabled: true,
      target: "local",
      otlpEndpoint: "http://localhost:4317",
      otlpProtocol: "grpc"
    }
  }')

  echo "$existing" | jq --argjson hooks "$hook_config" --argjson telem "$telemetry_config" '. * $hooks * $telem' > "$config_file"

  green "Gemini CLI   — hooks + native OTel installed → $config_file"
  INSTALLED=$((INSTALLED + 1))
}

# ── Main ─────────────────────────────────────────────────────────────

PROVIDERS=("$@")
ALL_PROVIDERS=(claude codex gemini)

# Validate arguments
for p in "${PROVIDERS[@]}"; do
  case "$p" in
    claude|codex|gemini) ;;
    -h|--help)
      echo "Usage: $0 [claude] [codex] [gemini]"
      echo ""
      echo "  No args  — install all detected CLIs"
      echo "  With args — install only specified providers"
      exit 0
      ;;
    *)
      red "Unknown provider: $p"
      echo "Supported: claude, codex, gemini"
      exit 1
      ;;
  esac
done

# Default to all if no args
if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
  PROVIDERS=("${ALL_PROVIDERS[@]}")
fi

echo "shepherd-hooks installer"
echo "========================"
echo ""

# Make all hooks executable
chmod +x "${HOOKS_DIR}"/claude/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/codex/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/gemini/*.sh 2>/dev/null || true
chmod +x "${HOOKS_DIR}"/lib/*.sh 2>/dev/null || true

for provider in "${PROVIDERS[@]}"; do
  "install_${provider}"
done

echo ""
if [[ $INSTALLED -eq 0 ]]; then
  red "No supported CLIs found. Install Claude Code, Codex, or Gemini CLI first."
  exit 1
fi

echo "${INSTALLED} CLI(s) configured. Start the obs stack:"
echo "  docker compose up -d"
echo ""
echo "Verify with:"
echo "  ./scripts/test-signal.sh"
