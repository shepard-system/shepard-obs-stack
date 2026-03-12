#!/usr/bin/env bash
# tests/test-parsers.sh — session parser tests with fixtures
#
# Verifies span count, required fields, attribute values, and error status.
# Requires: jq, bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
PASS=0 FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

if ! command -v jq &>/dev/null; then
  echo "  ✗ jq not found — cannot run parser tests"
  exit 1
fi

# ========================================================
echo "Claude session parser"
# ========================================================

CLAUDE_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session.jsonl" 2>/dev/null)

# Span count: root + meta + 2 tools + 1 compaction = 5
span_count=$(echo "$CLAUDE_OUTPUT" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 5 ]]; then
  pass "span count = 5 (root + meta + 2 tools + compaction)"
else
  fail "span count" "expected 5, got $span_count"
fi

# All spans have required fields
missing=0
while IFS= read -r span; do
  for field in trace_id span_id name start_ns end_ns status attributes; do
    if ! echo "$span" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
      missing=$((missing+1))
    fi
  done
done <<< "$CLAUDE_OUTPUT"
if [[ $missing -eq 0 ]]; then
  pass "all spans have required fields"
else
  fail "missing fields" "$missing fields missing across spans"
fi

# Root span attributes
root=$(echo "$CLAUDE_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "claude.session" ]]; then pass "root span name = claude.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "claude-code" ]]; then pass "root provider = claude-code"; else fail "root provider" "got $provider"; fi

model=$(echo "$root" | jq -r '.attributes.model')
if [[ "$model" == "claude-sonnet-4-20250514" ]]; then pass "root model correct"; else fail "root model" "got $model"; fi

tool_count=$(echo "$root" | jq -r '.attributes["tool.count"]')
if [[ "$tool_count" == "2" ]]; then pass "root tool.count = 2"; else fail "root tool.count" "got $tool_count"; fi

error_count=$(echo "$root" | jq -r '.attributes["tool.error_count"]')
if [[ "$error_count" == "1" ]]; then pass "root tool.error_count = 1"; else fail "root tool.error_count" "got $error_count"; fi

compaction_count=$(echo "$root" | jq -r '.attributes["compaction.count"]')
if [[ "$compaction_count" == "1" ]]; then pass "root compaction.count = 1"; else fail "root compaction.count" "got $compaction_count"; fi

# Error tool span has status=2
error_tool=$(echo "$CLAUDE_OUTPUT" | jq -s '[.[] | select(.name == "claude.tool.Bash")][0]')
error_status=$(echo "$error_tool" | jq '.status')
if [[ "$error_status" == "2" ]]; then pass "Bash tool span status = 2 (error)"; else fail "Bash tool span status" "got $error_status"; fi

# Compaction span exists
comp_span=$(echo "$CLAUDE_OUTPUT" | jq -s '[.[] | select(.name == "claude.compaction")][0]')
comp_trigger=$(echo "$comp_span" | jq -r '.attributes["compaction.trigger"]')
if [[ "$comp_trigger" == "auto" ]]; then pass "compaction span trigger = auto"; else fail "compaction span" "got trigger=$comp_trigger"; fi

# Trace ID consistency
trace_ids=$(echo "$CLAUDE_OUTPUT" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# Context breakdown attributes
tool_output_chars=$(echo "$root" | jq -r '.attributes["context.tool_output_chars"]')
if [[ "$tool_output_chars" == "64" ]]; then pass "context.tool_output_chars = 64"; else fail "context.tool_output_chars" "got $tool_output_chars"; fi

tool_output_est=$(echo "$root" | jq -r '.attributes["context.tool_output_tokens_est"]')
if [[ "$tool_output_est" == "16" ]]; then pass "context.tool_output_tokens_est = 16"; else fail "context.tool_output_tokens_est" "got $tool_output_est"; fi

user_prompt_chars=$(echo "$root" | jq -r '.attributes["context.user_prompt_chars"]')
if [[ "$user_prompt_chars" == "38" ]]; then pass "context.user_prompt_chars = 38"; else fail "context.user_prompt_chars" "got $user_prompt_chars"; fi

user_prompt_est=$(echo "$root" | jq -r '.attributes["context.user_prompt_tokens_est"]')
if [[ "$user_prompt_est" == "9" ]]; then pass "context.user_prompt_tokens_est = 9"; else fail "context.user_prompt_tokens_est" "got $user_prompt_est"; fi

compact_summary_chars=$(echo "$root" | jq -r '.attributes["context.compact_summary_chars"]')
if [[ "$compact_summary_chars" == "58" ]]; then pass "context.compact_summary_chars = 58"; else fail "context.compact_summary_chars" "got $compact_summary_chars"; fi

compact_summary_est=$(echo "$root" | jq -r '.attributes["context.compact_summary_tokens_est"]')
if [[ "$compact_summary_est" == "14" ]]; then pass "context.compact_summary_tokens_est = 14"; else fail "context.compact_summary_tokens_est" "got $compact_summary_est"; fi

compaction_pre_tokens=$(echo "$root" | jq -r '.attributes["context.compaction_pre_tokens"]')
if [[ "$compaction_pre_tokens" == "50000" ]]; then pass "context.compaction_pre_tokens = 50000"; else fail "context.compaction_pre_tokens" "got $compaction_pre_tokens"; fi

# Per-turn spans (gated by SHEPARD_DETAILED_TRACES=1)
CLAUDE_DETAILED=$(SHEPARD_DETAILED_TRACES=1 bash "$REPO_ROOT/hooks/lib/session-parser.sh" "$FIXTURES/claude-session.jsonl" 2>/dev/null)

detail_count=$(echo "$CLAUDE_DETAILED" | wc -l | tr -d ' ')
if [[ "$detail_count" -eq 7 ]]; then pass "detailed spans = 7 (5 base + 2 turns)"; else fail "detailed span count" "expected 7, got $detail_count"; fi

turn0=$(echo "$CLAUDE_DETAILED" | jq -s '[.[] | select(.name == "claude.turn" and .attributes["turn.index"] == "0")][0]')
turn0_input=$(echo "$turn0" | jq -r '.attributes["turn.input_tokens"]')
if [[ "$turn0_input" == "450" ]]; then pass "turn 0 input_tokens = 450"; else fail "turn 0 input_tokens" "got $turn0_input"; fi

turn0_tools=$(echo "$turn0" | jq -r '.attributes["turn.tool_count"]')
if [[ "$turn0_tools" == "2" ]]; then pass "turn 0 tool_count = 2"; else fail "turn 0 tool_count" "got $turn0_tools"; fi

turn1=$(echo "$CLAUDE_DETAILED" | jq -s '[.[] | select(.name == "claude.turn" and .attributes["turn.index"] == "1")][0]')
turn1_input=$(echo "$turn1" | jq -r '.attributes["turn.input_tokens"]')
if [[ "$turn1_input" == "50" ]]; then pass "turn 1 input_tokens = 50"; else fail "turn 1 input_tokens" "got $turn1_input"; fi

turn1_tools=$(echo "$turn1" | jq -r '.attributes["turn.tool_count"]')
if [[ "$turn1_tools" == "0" ]]; then pass "turn 1 tool_count = 0"; else fail "turn 1 tool_count" "got $turn1_tools"; fi

turn_parent=$(echo "$turn0" | jq -r '.parent_span_id')
root_sid=$(echo "$CLAUDE_OUTPUT" | jq -s -r '.[0].span_id')
if [[ "$turn_parent" == "$root_sid" ]]; then pass "turn spans parent = root span"; else fail "turn parent" "got $turn_parent, expected $root_sid"; fi

# ========================================================
echo ""
echo "Codex session parser"
# ========================================================

CODEX_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/codex-session-parser.sh" "$FIXTURES/codex-session.jsonl" 2>/dev/null)

# Span count: root + meta + 1 tool = 3
span_count=$(echo "$CODEX_OUTPUT" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 3 ]]; then
  pass "span count = 3 (root + meta + 1 tool)"
else
  fail "span count" "expected 3, got $span_count"
fi

# Root span attributes
root=$(echo "$CODEX_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "codex.session" ]]; then pass "root span name = codex.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "codex" ]]; then pass "root provider = codex"; else fail "root provider" "got $provider"; fi

tokens_in=$(echo "$root" | jq -r '.attributes["tokens.input"]')
if [[ "$tokens_in" == "500" ]]; then pass "root tokens.input = 500"; else fail "root tokens.input" "got $tokens_in"; fi

# Tool span name
tool=$(echo "$CODEX_OUTPUT" | jq -s '[.[] | select(.name | startswith("codex.tool"))][0]')
tool_name=$(echo "$tool" | jq -r '.name')
if [[ "$tool_name" == "codex.tool.shell" ]]; then pass "tool span = codex.tool.shell"; else fail "tool span name" "got $tool_name"; fi

# Trace ID consistency
trace_ids=$(echo "$CODEX_OUTPUT" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# ========================================================
echo ""
echo "Gemini session parser"
# ========================================================

GEMINI_OUTPUT=$(bash "$REPO_ROOT/hooks/lib/gemini-session-parser.sh" "$FIXTURES/gemini-session.json" 2>/dev/null)

# Span count: root + meta + 2 tools = 4
span_count=$(echo "$GEMINI_OUTPUT" | wc -l | tr -d ' ')
if [[ "$span_count" -eq 4 ]]; then
  pass "span count = 4 (root + meta + 2 tools)"
else
  fail "span count" "expected 4, got $span_count"
fi

# Root span attributes
root=$(echo "$GEMINI_OUTPUT" | jq -s '.[0]')
root_name=$(echo "$root" | jq -r '.name')
if [[ "$root_name" == "gemini.session" ]]; then pass "root span name = gemini.session"; else fail "root span name" "got $root_name"; fi

provider=$(echo "$root" | jq -r '.attributes.provider')
if [[ "$provider" == "gemini-cli" ]]; then pass "root provider = gemini-cli"; else fail "root provider" "got $provider"; fi

tool_count=$(echo "$root" | jq -r '.attributes["tool.count"]')
if [[ "$tool_count" == "2" ]]; then pass "root tool.count = 2"; else fail "root tool.count" "got $tool_count"; fi

error_count=$(echo "$root" | jq -r '.attributes["tool.error_count"]')
if [[ "$error_count" == "1" ]]; then pass "root tool.error_count = 1 (shell error)"; else fail "root tool.error_count" "got $error_count"; fi

# Error tool span has status=2
error_tool=$(echo "$GEMINI_OUTPUT" | jq -s '[.[] | select(.name == "gemini.tool.shell")][0]')
error_status=$(echo "$error_tool" | jq '.status')
if [[ "$error_status" == "2" ]]; then pass "shell tool span status = 2 (error)"; else fail "shell tool span status" "got $error_status"; fi

# Trace ID consistency
trace_ids=$(echo "$GEMINI_OUTPUT" | jq -r '.trace_id' | sort -u | wc -l | tr -d ' ')
if [[ "$trace_ids" -eq 1 ]]; then pass "all spans share same trace_id"; else fail "trace_id consistency" "$trace_ids unique trace_ids"; fi

# ========================================================
echo ""
echo "Parser tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
