#!/usr/bin/env bash
# hooks/lib/session-parser.sh — parse Claude Code JSONL session logs into trace data
#
# Usage: bash session-parser.sh /path/to/session.jsonl
#
# Single-pass jq: reads pre-filtered JSONL, outputs all spans in ~0.3s.
# No subprocess spawning per span (v1 took 1m34s on 43MB files).
#
# Output format (one JSON per line):
#   { "trace_id", "span_id", "parent_span_id", "name", "start_ns", "end_ns",
#     "status": 0|2, "attributes": {...} }
#
# Dependencies: grep, jq (1.6+)

set -u

SESSION_FILE="${1:?Usage: session-parser.sh <session.jsonl>}"
[[ -f "$SESSION_FILE" ]] || { echo "File not found: $SESSION_FILE" >&2; exit 1; }

# Pre-filter to assistant/user/progress/system lines only (~30% of file).
# Skips file-history-snapshot and queue-operation entries (large, unneeded).
grep -E '"type":"(assistant|user|progress|system)"' "$SESSION_FILE" | \
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

# Truncate string to max length
def trunc($n): if length > $n then .[:$n] + "…" else . end;

# ===== Read all pre-filtered entries =====
[inputs] |

# --- Session metadata ---
(map(.sessionId // empty) | .[0] // null) as $session_id |
if $session_id == null then empty else

# trace_id = UUID without dashes (32 hex chars)
($session_id | gsub("-"; "")) as $trace_id |
"0000000000000001" as $root_sid |
"0000000000000002" as $meta_sid |

# --- Deduplicate assistant entries by message.id ---
# Claude writes multiple streaming entries per API response (same message.id).
# Keep last occurrence (has complete content and final usage).
(
  [.[] | select(.type == "assistant")] |
  group_by(.message.id // .uuid) | [.[] | .[-1]]
) as $assistants |

# Rebuild full entry list with deduplicated assistants
([.[] | select(.type != "assistant")] + $assistants | sort_by(.timestamp)) as $all |

# First/last message timestamps
($all | map(select((.type == "user" or .type == "assistant") and .timestamp != null) | .timestamp) | sort) as $ts |
($ts[0] // "") as $t_start |
($ts[-1] // "") as $t_end |

# Model from first real assistant message
($assistants | map(select(.message.model != null and .message.model != "<synthetic>") | .message.model) | .[0] // "unknown") as $model |

# Git branch + repo
($all | map(select(.gitBranch != null) | .gitBranch) | .[0] // "unknown") as $git_branch |
($all | map(select(.gitRepo != null) | .gitRepo) | .[0] // "") as $git_repo |

# --- Token aggregation from deduplicated assistants ---
($assistants | map(.message.usage // empty) |
  { input: (map(.input_tokens // 0) | add // 0),
    output: (map(.output_tokens // 0) | add // 0),
    cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
    cache_create: (map(.cache_creation_input_tokens // 0) | add // 0) }
) as $tokens |
($tokens.input + $tokens.output + $tokens.cache_read + $tokens.cache_create) as $tokens_total |

# --- stop_reason from last assistant with non-null stop_reason ---
($assistants | map(select(.message.stop_reason != null) | .message.stop_reason) | last // "unknown") as $stop_reason |

# --- Thinking block count ---
($assistants | [.[] | .message.content // [] |
  if type == "array" then .[] else empty end |
  select(.type == "thinking")] | length) as $thinking_count |

# --- User interruptions ---
([$all[] | select(.type == "user") |
  .message.content // "" |
  if type == "string" then . else "" end |
  select(test("Request interrupted by user"))
] | length) as $interruption_count |

# --- Compaction events (system entries with compact_boundary) ---
([$all[] | select(.type == "system" and .subtype == "compact_boundary") |
  {ts: .timestamp, trigger: (.compactMetadata.trigger // "auto"), preTokens: (.compactMetadata.preTokens // 0)}
]) as $compactions |

# --- Build lookups ---

# tool_use_id → {end_ts, is_error}
([$all[] | select(.type == "user") |
  . as $m | ($m.message.content // [] | if type == "array" then .[] else empty end) |
  select(.type == "tool_result") |
  {key: .tool_use_id, value: {ts: $m.timestamp, err: (.is_error == true)}}
] | from_entries) as $results |

# Ordered tool_use entries with input params
[$assistants[] |
  . as $m | ($m.message.content // [] | if type == "array" then .[] else empty end) |
  select(.type == "tool_use") |
  {id: .id, name: .name, ts: $m.timestamp, tok: ($m.message.usage.output_tokens // 0),
   file_path: (.input.file_path // .input.notebook_path // ""),
   command: ((.input.command // "")[:200]),
   pattern: (.input.pattern // .input.query // "")}
] as $tools |

# Count tool errors
([$tools[] | ($results[.id].err // false) | select(. == true)] | length) as $tool_error_count |

# Turn count (user messages that are human input, not tool results)
([$all[] | select(.type == "user") |
  .message.content // "" | if type == "string" then "human" elif type == "array" then
    (if any(.[]; .type == "tool_result") then "tool" else "human" end)
  else "other" end |
  select(. == "human")
] | length) as $turn_count |

# MCP completed entries
[$all[] | select(
  .type == "progress" and
  .data.type == "mcp_progress" and
  .data.status == "completed"
)] as $mcps |

# Agent progress grouped by agentId
([$all[] | select(
  .type == "progress" and
  .data.type == "agent_progress" and
  (.data.message.type // "") == "user"
) | {
  aid: .data.agentId,
  ts: .timestamp,
  prompt: ((.data.prompt // "")[:80])
}] | group_by(.aid) | to_entries) as $agents |

# ===== Emit spans =====

# 1. Root session span (enriched)
{trace_id: $trace_id, span_id: $root_sid, parent_span_id: "",
 name: "claude.session",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_end | ts_to_ns),
 status: 0,
 attributes: (
   {"session.id": $session_id, "model": $model, "provider": "claude-code",
    "git.branch": $git_branch, "git.repo": $git_repo,
    "tokens.input": ($tokens.input | tostring),
    "tokens.output": ($tokens.output | tostring),
    "tokens.cache_read": ($tokens.cache_read | tostring),
    "tokens.cache_create": ($tokens.cache_create | tostring),
    "tokens.total": ($tokens_total | tostring),
    "tool.count": ($tools | length | tostring),
    "tool.error_count": ($tool_error_count | tostring),
    "turn.count": ($turn_count | tostring),
    "compaction.count": ($compactions | length | tostring),
    "thinking.block_count": ($thinking_count | tostring),
    "stop_reason": $stop_reason} +
   (if $interruption_count > 0 then
     {"has_interruption": "true", "interruption.count": ($interruption_count | tostring)}
   else {} end)
 )},

# 1b. Session meta marker (zero-duration child of root, kept for backward compatibility in trace views)
{trace_id: $trace_id, span_id: $meta_sid, parent_span_id: $root_sid,
 name: "claude.session.meta",
 start_ns: ($t_start | ts_to_ns), end_ns: ($t_start | ts_to_ns),
 status: 0,
 attributes: {"session.id": $session_id, "provider": "claude-code"}},

# 2. Tool call spans (span_id offset: 16) — enriched with input params + error status
($tools | to_entries[] |
  (.key + 16) as $i | .value as $t |
  ($results[$t.id] // {ts: $t.ts, err: false}) as $r |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.tool.\($t.name)",
   start_ns: ($t.ts | ts_to_ns), end_ns: ($r.ts | ts_to_ns),
   status: (if $r.err then 2 else 0 end),
   attributes: (
     {"tool.name": $t.name, "tokens.output": ($t.tok | tostring),
      "tool.is_error": (if $r.err then "true" else "false" end)} +
     (if $t.file_path != "" then {"tool.input.file_path": $t.file_path} else {} end) +
     (if $t.command != "" then {"tool.input.command": $t.command} else {} end) +
     (if $t.pattern != "" then {"tool.input.pattern": $t.pattern} else {} end)
   )}),

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
   status: 0,
   attributes: {"mcp.server": $srv, "mcp.tool": $tool, "mcp.duration_ms": ($elapsed | tostring)}}),

# 4. Sub-agent spans (span_id offset: 20016)
($agents[] |
  (.key + 20016) as $i | .value as $g |
  ($g | map(.ts) | sort) as $sorted |
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.agent.\($g[0].aid)",
   start_ns: ($sorted[0] | ts_to_ns), end_ns: ($sorted[-1] | ts_to_ns),
   status: 0,
   attributes: {"agent.id": $g[0].aid, "agent.prompt": $g[0].prompt}}),

# 5. Compaction spans (span_id offset: 30016)
($compactions | to_entries[] |
  (.key + 30016) as $i | .value as $c |
  # Compaction is a point event — start = end
  {trace_id: $trace_id, span_id: ($i | pad16), parent_span_id: $root_sid,
   name: "claude.compaction",
   start_ns: ($c.ts | ts_to_ns), end_ns: ($c.ts | ts_to_ns),
   status: 0,
   attributes: {"compaction.trigger": $c.trigger, "compaction.pre_tokens": ($c.preTokens | tostring)}})

end
'
