#!/usr/bin/env bash
# hooks/lib/accelerator.sh — resolve shepard-hook binary
#
# Search order:
#   1. Project-local: hooks/bin/shepard-hook (primary)
#   2. Global PATH: command -v shepard-hook
#   3. Empty → bash fallback
#
# Usage: source this file, then check $SHEPARD_HOOK

# Testing: bypass accelerator lookup to force bash code path
if [[ "${SHEPARD_TEST_MODE:-}" == "1" ]]; then
  SHEPARD_HOOK=""
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi

_ACCEL_DIR="${BASH_SOURCE[0]%/lib/*}/bin"
if [[ -x "${_ACCEL_DIR}/shepard-hook" ]]; then
  SHEPARD_HOOK="${_ACCEL_DIR}/shepard-hook"
elif command -v shepard-hook &>/dev/null; then
  SHEPARD_HOOK="shepard-hook"
else
  SHEPARD_HOOK=""
fi
