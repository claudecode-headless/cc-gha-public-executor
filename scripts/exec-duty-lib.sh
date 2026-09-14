#!/usr/bin/env bash
# exec-duty-lib.sh — shared alert-latch helpers for the scheduler's duty steps.
# SOURCED, not run (see targets_lib.sh in the mirror kit for the pattern).
#
# The executor-side alert contract (P1-B design §3.2 / §5.3, amended R3):
#   * One OPEN issue per alert class on THIS repo, label exec-duty-alert,
#     title prefix "duty alert: <class>". The open issue IS the latch — the
#     executor is stateless by design; closing the issue re-arms the lane.
#   * Bodies ALWAYS start with the '[exec-duty]' marker (24h dedup key).
#   * LOG HYGIENE (public repo): bodies/comments carry aliases, counts and
#     public run URLs only — never private repo slugs, never secret values.
#   * Canon: output-returning functions print ONLY their return value on
#     stdout; every diagnostic goes to stderr. Callers re-emit ::warning /
#     ::error annotations on stdout themselves (annotations are unreliable
#     from stderr).
#
# Requires: gh (authenticated via GH_TOKEN env), GITHUB_REPOSITORY env.

# exec_alert_find <title-prefix> → open exec-duty-alert issue number (or empty)
exec_alert_find() {
  local prefix="$1" n
  n=$(gh api "repos/${GITHUB_REPOSITORY}/issues?state=open&labels=exec-duty-alert&per_page=20" 2>/dev/null \
    | jq -r --arg p "$prefix" '[.[] | select((.title // "") | startswith($p)) | .number] | first // empty' 2>/dev/null \
    || true)
  echo "${n:-}"
}

# exec_alert_create <title> <body> → new issue number on stdout (empty on failure).
# The body becomes the FIRST '[exec-duty]' marker (its created_at is the dedup ts).
exec_alert_create() {
  local title="$1" body="$2" n
  n=$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b, labels: ["exec-duty-alert"]}' 2>/dev/null \
    | gh api -X POST "repos/${GITHUB_REPOSITORY}/issues" --input - --jq '.number' 2>/dev/null \
    || true)
  if [ -n "${n:-}" ]; then
    echo "exec-duty: opened alert issue #${n} ('${title}')" >&2
  else
    echo "exec-duty: FAILED to open alert issue '${title}' (issues disabled? token?)" >&2
  fi
  echo "${n:-}"
}

# exec_alert_comment <issue-number> <body> → 0 posted / 1 failed (diagnostics stderr)
exec_alert_comment() {
  local num="$1" body="$2"
  if jq -n --arg b "$body" '{body: $b}' 2>/dev/null \
     | gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${num}/comments" --input - >/dev/null 2>&1; then
    echo "exec-duty: commented alert issue #${num}" >&2
    return 0
  fi
  echo "exec-duty: comment on alert issue #${num} FAILED (rate limit?)" >&2
  return 1
}

# exec_alert_close <issue-number> <final-body> → comment + close (best effort)
exec_alert_close() {
  local num="$1" body="$2"
  exec_alert_comment "$num" "$body" || true
  if gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/${num}" -f state=closed >/dev/null 2>&1; then
    echo "exec-duty: closed alert issue #${num} (lane re-armed)" >&2
  else
    echo "exec-duty: closing alert issue #${num} FAILED — it stays open (conservative)" >&2
  fi
}

# exec_alert_marker_age_h <issue-number> → hours (integer) since the newest
# '[exec-duty]' marker on the issue (body counts as the first marker); empty
# when the issue carries no marker at all.
#   per_page=20 + max(created_at): order-independent on purpose — the comments
#   API ignores sort/direction server-side (verified live, W2-b law 20), so the
#   W2-e P2-d per_page=1 regression is NOT re-shipped from birth.
exec_alert_marker_age_h() {
  local num="$1" ts
  ts=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${num}/comments?per_page=20&direction=desc" 2>/dev/null \
    | jq -r '[.[] | select((.body // "") | startswith("[exec-duty]")) | .created_at] | max // empty' 2>/dev/null \
    || true)
  if [ -z "${ts:-}" ]; then
    # the issue body itself is the first marker — fall back to its created_at
    ts=$(gh api "repos/${GITHUB_REPOSITORY}/issues/${num}" \
      --jq 'select((.body // "") | startswith("[exec-duty]")) | .created_at // empty' 2>/dev/null || true)
  fi
  [ -n "${ts:-}" ] || { echo ""; return 0; }
  echo $(( ($(date +%s) - $(date -u -d "$ts" +%s)) / 3600 ))
}

# exec_alert_dedup_ok <issue-number> [dedup_h] → 0 when a marker comment should
# be posted (no marker yet, or the newest is ≥ dedup_h hours old; default 24),
# 1 when deduped. Pure check — callers do the posting.
exec_alert_dedup_ok() {
  local num="$1" dedup_h="${2:-24}" age
  age=$(exec_alert_marker_age_h "$num")
  if [ -z "${age:-}" ] || [ "${age:-0}" -ge "${dedup_h}" ]; then
    return 0
  fi
  echo "exec-duty: deduped (last marker on #${num} is ${age}h old < ${dedup_h}h)" >&2
  return 1
}
