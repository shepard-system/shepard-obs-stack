#!/usr/bin/env bash
# hooks/lib/git-context.sh — extract git repo and branch from cwd
#
# Usage: source this file, then call get_git_context
#
# Sets: GIT_REPO, GIT_BRANCH (empty string if not in a git repo)

get_git_context() {
  local cwd="${1:-.}"

  GIT_BRANCH="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  GIT_REPO="$(basename "$(git -C "$cwd" remote get-url origin 2>/dev/null)" .git 2>/dev/null || echo "")"
}
