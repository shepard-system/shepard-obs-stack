#!/usr/bin/env bash
# tests/test-hooks.sh — behavioral tests for hook scripts
#
# Tests exit codes, stdout output, and metric emission (via mock curl).
# Requires: jq, bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

# --- Setup mocks ---
MOCK_DIR=$(mktemp -d)
CAPTURE_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR"' EXIT

# Mock curl: capture -d payload
cat > "$MOCK_DIR/curl" << 'MOCK'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-d" ]]; then
    echo "$arg" >> "$SHEPARD_TEST_CAPTURE/curl_payloads.log"
  fi
  prev="$arg"
done
MOCK
chmod +x "$MOCK_DIR/curl"

# Mock git: return known values
cat > "$MOCK_DIR/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *rev-parse*--abbrev-ref*) echo "test-branch";;
  *remote*get-url*) echo "https://github.com/test/test-repo.git";;
  *) ;;
esac
MOCK
chmod +x "$MOCK_DIR/git"

export PATH="$MOCK_DIR:$PATH"
export SHEPARD_TEST_MODE=1
export SHEPARD_TEST_CAPTURE="$CAPTURE_DIR"

reset_capture() { rm -f "$CAPTURE_DIR/curl_payloads.log"; }

run_hook() {
  local hook="$1"
  shift
  local rc=0
  bash "$REPO_ROOT/$hook" "$@" || rc=$?
  sleep 0.3  # let background mock curl finish
  return $rc
}

payload_count() {
  [[ -f "$CAPTURE_DIR/curl_payloads.log" ]] && wc -l < "$CAPTURE_DIR/curl_payloads.log" | tr -d ' ' || echo "0"
}

payload_has() {
  [[ -f "$CAPTURE_DIR/curl_payloads.log" ]] && grep -q "$1" "$CAPTURE_DIR/curl_payloads.log" 2>/dev/null
}

# ========================================================
echo "PreToolUse (Claude) — sensitive file guard"
# ========================================================

# Should block .env
reset_capture
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/.env"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .env (exit 2)"; else fail "blocks .env" "got exit $rc"; fi

# Should block .pem
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/ssl/server.pem"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .pem (exit 2)"; else fail "blocks .pem" "got exit $rc"; fi

# Should block id_rsa
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/home/user/.ssh/id_rsa"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks id_rsa (exit 2)"; else fail "blocks id_rsa" "got exit $rc"; fi

# Should block .aws/
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/home/user/.aws/credentials"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 2 ]]; then pass "blocks .aws/ (exit 2)"; else fail "blocks .aws/" "got exit $rc"; fi

# Should allow normal files
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/src/main.py"}}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "allows normal file (exit 0)"; else fail "allows normal file" "got exit $rc"; fi

# Should allow empty input
rc=0
echo '{}' | run_hook hooks/claude/pre-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "allows empty input (exit 0)"; else fail "allows empty input" "got exit $rc"; fi

# ========================================================
echo ""
echo "PostToolUse (Claude) — metric emission"
# ========================================================

# Normal tool call → exit 0, emits tool_calls + events (2 payloads)
reset_capture
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/main.py"},"tool_response":"file contents","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "normal tool → exit 0"; else fail "normal tool → exit 0" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -ge 2 ]]; then pass "emits ≥2 metrics (tool_calls + events)"; else fail "emits ≥2 metrics" "got $count"; fi

# Error response → tool_status="error"
reset_capture
echo '{"tool_name":"Bash","tool_input":{},"tool_response":"FAILED: exit code 1","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || true
if payload_has '"error"'; then pass "error response → tool_status=error"; else fail "error response → tool_status=error"; fi

# Sensitive file → emits sensitive_file_access (3 payloads)
reset_capture
echo '{"tool_name":"Read","tool_input":{"file_path":"/app/.env.local"},"tool_response":"ok","cwd":"/tmp/project"}' \
  | run_hook hooks/claude/post-tool-use.sh || true
count=$(payload_count)
if [[ "$count" -ge 3 ]]; then
  pass "sensitive file → emits sensitive_file_access (3 metrics)"
else
  fail "sensitive file → emits sensitive_file_access" "got $count payloads"
fi

# ========================================================
echo ""
echo "Stop hook (Claude) — session end + compaction"
# ========================================================

# Setup temp HOME for session file lookup
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR" "$CAPTURE_DIR" "$TEST_HOME"' EXIT

# stop_hook_active=true → early exit, no emission
reset_capture
rc=0
echo '{"session_id":"test","cwd":"/tmp/project","stop_hook_active":true}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "stop_hook_active=true → exit 0 (early)"; else fail "stop_hook_active" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -eq 0 ]]; then pass "stop_hook_active → no metrics emitted"; else fail "stop_hook_active → no metrics" "got $count"; fi

# Normal session end → emits events(session_end)
reset_capture
rc=0
echo '{"session_id":"test-sess","cwd":"/tmp/project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then pass "normal stop → exit 0"; else fail "normal stop" "got exit $rc"; fi
if payload_has '"session_end"'; then pass "emits session_end event"; else fail "emits session_end event"; fi

# BUG FIX: zero compactions → no arithmetic error
reset_capture
slug=$(echo "/tmp/test-project" | sed 's|/|-|g')
mkdir -p "$TEST_HOME/.claude/projects/${slug}/"
echo '{"type":"user","sessionId":"zero-comp"}' > "$TEST_HOME/.claude/projects/${slug}/zero-comp.jsonl"
rc=0
echo '{"session_id":"zero-comp","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "zero compactions → no arithmetic error (bug fix)"
else
  fail "zero compactions → arithmetic error!" "got exit $rc"
fi

# Positive: session with compactions → emits compaction_events
reset_capture
echo '{"type":"user","sessionId":"with-comp"}
{"type":"system","subtype":"compact_boundary"}
{"type":"system","subtype":"compact_boundary"}' > "$TEST_HOME/.claude/projects/${slug}/with-comp.jsonl"
echo '{"session_id":"with-comp","cwd":"/tmp/test-project","stop_hook_active":false}' \
  | HOME="$TEST_HOME" run_hook hooks/claude/stop.sh || true
if payload_has '"compaction_events"'; then
  pass "session with compactions → emits compaction_events"
else
  fail "session with compactions → emits compaction_events"
fi

# ========================================================
echo ""
echo "SessionStart (Claude) — post-compaction context"
# ========================================================

output=$(echo '{}' | run_hook hooks/claude/session-start.sh)
if echo "$output" | grep -q 'shepherd_'; then
  pass "outputs conventions text (contains shepherd_)"
else
  fail "outputs conventions text" "missing shepherd_ in output"
fi

# ========================================================
echo ""
echo "AfterTool (Gemini) — JSON stdout"
# ========================================================

reset_capture
output=$(echo '{"tool_name":"read_file","tool_input":{},"tool_response":"ok","cwd":"/tmp/project"}' \
  | GEMINI_CWD="/tmp/project" run_hook hooks/gemini/after-tool.sh)
if [[ "$output" == *"{}"* ]]; then
  pass "outputs {} on stdout"
else
  fail "outputs {} on stdout" "got: $output"
fi

# ========================================================
echo ""
echo "Notify (Codex) — event filtering"
# ========================================================

# Valid event → exit 0
reset_capture
rc=0
run_hook hooks/codex/notify.sh '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/project"}' || rc=$?
if [[ $rc -eq 0 ]]; then pass "agent-turn-complete → exit 0"; else fail "agent-turn-complete" "got exit $rc"; fi

# Non-matching type → exit 0, no emission
reset_capture
rc=0
run_hook hooks/codex/notify.sh '{"type":"other","cwd":"/tmp/project"}' || rc=$?
if [[ $rc -eq 0 ]]; then pass "non-matching type → exit 0"; else fail "non-matching type" "got exit $rc"; fi
count=$(payload_count)
if [[ "$count" -eq 0 ]]; then pass "non-matching type → no metrics"; else fail "non-matching type → no metrics" "got $count"; fi

# ========================================================
echo ""
echo "Hook tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
