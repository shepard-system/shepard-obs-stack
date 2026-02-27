#!/usr/bin/env bash
# hooks/lib/session-parser.sh — parse Claude Code JSONL session logs into trace data
#
# Usage: bash session-parser.sh /path/to/session.jsonl
#
# Single-pass jq: reads pre-filtered JSONL, outputs all spans in ~0.3s.
# No subprocess spawning per span (v1 took 1m34s on 43MB files).
#
# Output format (one JSON per line):
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns", "attributes": {...} }
#
# Dependencies: grep, jq (1.6+)

set -u

SESSION_FILE="${1:?Usage: session-parser.sh <session.jsonl>}"
[[ -f "$SESSION_FILE" ]] || { echo "File not found: $SESSION_FILE" >&2; exit 1; }

# Pre-filter to assistant/user/progress lines only (~30% of file).
# Skips file-history-snapshot and queue-operation entries (large, unneeded).
grep -E '"type":"(assistant|user|progress)"' "$SESSION_FILE" | \
jq -n -c '

# --- Helper functions ---

def to_hex:
  def _h: if . < 10 then . + 48 else . - 10 + 97 end | [.] | implode;
  if . == 0 then "0"
  elif . < 16 then _h
  else ((. / 16 | floor) | to_hex) + ((. % 16) | _h)
  end;

def pad16:
  if . == 0 then "0000000000000000"
  else to_hex | ("0000000000000000" + .) | .[-16:]
  end;

def pad9: tostring | ("000000000" + .) | .[-9:];

# ISO 8601 → {s: epoch_seconds, ns: fractional_nanos}
def ts_parts:
  if . == null or . == "" then {s: 0, ns: 0}
  else
    split(".") |
    (.[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime | floor) as $epoch |
    ((.[1] // "0") | rtrimstr("Z") | (. + "000000000")[:9] | tonumber) as $frac |
    {s: $epoch, ns: $frac}
  end;

# {s, ns} → nanosecond string
def parts_to_ns: "\(.s)\(.ns | pad9)";

# ISO 8601 → nanosecond string
def ts_to_ns: ts_parts | parts_to_ns;

# Subtract milliseconds from {s, ns} timestamp parts
def subtract_ms($ms):
  (($ms / 1000) | floor) as $s_off |
  (($ms % 1000) * 1000000 | floor) as $ns_off |
  (.ns - $ns_off) as $new_ns |
  if $new_ns >= 0 then {s: (.s - $s_off), ns: $new_ns}
  else {s: (.s - $s_off - 1), ns: ($new_ns + 1000000000)}
  end;

# ===== Read all pre-filtered entries =====
[inputs] |

# --- Session metadata ---
(map(.sessionId // empty) | .[0] // null) as $session_id |
if $session_id == null then empty else

# trace_id = UUID without dashes (32 hex chars)
($session_id | gsub("-"; "")) as $trace_id |
"0000000000000001" as $root_sid |

# First/last message timestamps
(map(select((.type == "user" or .type == "assistant") and .timestamp != null) | .timestamp) | sort) as $ts |
($ts[0] // "") as $t_start |
($ts[-1] // "") as $t_end |

# Model from first real assistant message
(map(select(.type == "assistant" and .message.model != null and .message.model != "<synthetic>") | .message.model) | .[0] // "unknown") as $model |

# Git branch
(map(select(.gitBranch != null) | .gitBranch) | .[0] // "unknown") as $git_branch |

# --- Build lookups ---

# tool_use_id → end_timestamp
([.[] | select(.type == "user") |
  . as $m | ($m.message.content // [] | if type == "array" then .[] else empty end) |
  select(.type == "tool_result") |
  {key: .tool_use_id, value: $m.timestamp}
] | from_entries) as $results |

# Ordered tool_use entries
[.[] | select(.type == "assistant") |
  . as $m | ($m.message.content // [] | if type == "array" then .[] else empty end) |
  select(.type == "tool_use") |
  {id: .id, name: .name, ts: $m.timestamp, tok: ($m.message.usage.output_tokens // 0)}
] as $tools |

# MCP completed entries
[.[] | select(
  .type == "progress" and
  .data.type == "mcp_progress" and
  .data.status == "completed"
)] as $mcps |

# Agent progress grouped by agentId
([.[] | select(
  .type == "progress" and
  .data.type == "agent_progress" and
  (.data.message.type // "") == "user"
) | {
  aid: .data.agentId,
  ts: .timestamp,
  prompt: ((.data.prompt // "")[:80])
}] | group_by(.aid) | to_entries) as $agents |

# ===== Emit spans =====

# 1. Root session span
{trace_id: $trace_id, span_id: $root_sid, parent_span_id: "",
 name: "claude.session",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_end | ts_to_ns),
 attributes: {"session.id": $session_id, "model": $model, "git.branch": $git_branch}},

# 2. Tool call spans (span_id offset: 16)
($tools | to_entries[] |
  (.key + 16) as $i | .value as $t |
  ($results[$t.id] // $t.ts) as $end |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.tool.\($t.name)",
   start_ns: ($t.ts | ts_to_ns), end_ns: ($end | ts_to_ns),
   attributes: {"tool.name": $t.name, "tokens.output": ($t.tok | tostring)}}),

# 3. MCP call spans (span_id offset: 10016)
($mcps | to_entries[] |
  (.key + 10016) as $i | .value as $m |
  ($m.data.elapsedTimeMs // 0) as $elapsed |
  ($m.data.serverName // "unknown") as $srv |
  ($m.data.toolName // "unknown") as $tool |
  ($m.timestamp | ts_parts) as $ep |
  ($ep | subtract_ms($elapsed)) as $sp |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.mcp.\($srv).\($tool)",
   start_ns: ($sp | parts_to_ns), end_ns: ($ep | parts_to_ns),
   attributes: {"mcp.server": $srv, "mcp.tool": $tool, "mcp.duration_ms": ($elapsed | tostring)}}),

# 4. Sub-agent spans (span_id offset: 20016)
($agents[] |
  (.key + 20016) as $i | .value as $g |
  ($g | map(.ts) | sort) as $sorted |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.agent.\($g[0].aid)",
   start_ns: ($sorted[0] | ts_to_ns), end_ns: ($sorted[-1] | ts_to_ns),
   attributes: {"agent.id": $g[0].aid, "agent.prompt": $g[0].prompt}})

end
'
