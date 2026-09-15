#!/usr/bin/env bash
# exec-duty-lib.sh — shared alert-latch helpers for the scheduler's duty steps.
# SOURCED, not run (see targets_lib.sh in the mirror kit for the pattern).
#
# The executor-side alert contract (P1-B design §3.2 / §5.3, amended R3 + T46-A2):
#   * One OPEN issue per alert class on the ALERT REPO, label exec-duty-alert,
#     title prefix "duty alert: <class>". The open issue IS the latch — the
#     executor is stateless by design; closing the issue re-arms the lane.
#   * ALERT REPO (T46-A2 retarget): default `claudecode-headless/fsm-lab` —
#     Issues ENABLED (live-verified), and its workflows trigger on
#     repository_dispatch + schedule ONLY, so PAT-authored issue posts wake
#     NOTHING (zero absorbed-skip cost). The upstream executor repo itself has
#     Issues DISABLED (the live 410 defect of run 34917023897) — it is never
#     the alert target. `EXEC_ALERT_REPO=self` restores the in-repo lane
#     (honest-red fork mode: issues-disabled repos will 410 and gate RED).
#   * ALERT TOKEN: `EXEC_ALERT_TOKEN` env, default the step's `GH_TOKEN`.
#   * Bodies ALWAYS start with the '[exec-duty]' marker (24h dedup key).
#   * LOG HYGIENE (public alert repo): bodies/comments carry aliases, counts
#     and public run URLs only — never private repo slugs, never secret values.
#   * Canon: output-returning functions print ONLY their return value on
#     stdout; every diagnostic goes to stderr. Callers re-emit ::warning /
#     ::error annotations on stdout themselves (annotations are unreliable
#     from stderr).
#   * R2 law 5 (T46-A2): callers gate RED on alert POST failures (create /
#     comment / close) in mode=on paths — a due alert that could not be posted
#     must not ride green cycles. Detection GETs (find / marker reads) never
#     gate. Retry-After ladder: 403/429 → sleep min(RA,20) → retry ONCE.
#
# Requires: gh + curl in PATH, GH_TOKEN env (or EXEC_ALERT_TOKEN override).
# GITHUB_REPOSITORY env is read ONLY in EXEC_ALERT_REPO=self fork mode.

# ---- the alert lane: single-source target + token --------------------------
# Every alert-lane path in this lib AND in scheduler.yml routes through these
# two helpers — no hardcoded executor-repo target remains anywhere (B2).
_alert_repo() { # → alert repo slug
  local r="${EXEC_ALERT_REPO:-}"
  case "$r" in
    self) printf '%s' "${GITHUB_REPOSITORY:-}" ;;
    '')   printf '%s' 'claudecode-headless/fsm-lab' ;;
    *)    printf '%s' "$r" ;;
  esac
}

_alert_token() { # → the alert-lane token (no secret ever reaches stdout logs:
  # callers embed it in curl/gh env only)
  printf '%s' "${EXEC_ALERT_TOKEN:-${GH_TOKEN:-}}"
}

# _alert_curl METHOD api-path [json-body] → prints the response body on stdout
# ONLY on HTTP 2xx; rc 1 + stderr diagnostic otherwise. The POST/PATCH lane
# (create/comment/close) — plain `gh` cannot read Retry-After headers (M1),
# so mutations go through curl with -D header capture + rc + body triage.
# HTTP 403/429 → parse `Retry-After:` header (fallback 10s) → sleep
# min(RA, 20) → retry ONCE (C4; bounded — physics law 6, no patient retries).
# Second failure or any other non-2xx → stderr diagnostic + rc 1; the raw
# error body is NEVER printed to stdout (C2 — it must not leak as a value).
_alert_curl() {
  local method="$1" path="$2" body="${3:-}"
  local hdr out code ra msg attempt
  hdr=$(mktemp "${TMPDIR:-/tmp}/exec-alert-curl.XXXXXX.hdr") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/exec-alert-curl.XXXXXX.body") || { rm -f "$hdr"; return 1; }
  for attempt in 1 2; do
    local args=( -sS -o "$out" -D "$hdr" -w '%{http_code}' --max-time 30
                 -X "$method"
                 -H "Authorization: token $(_alert_token)"
                 -H "Accept: application/vnd.github+json" )
    if [ -n "$body" ]; then
      args+=( -H "Content-Type: application/json" --data-binary "$body" )
    fi
    code=$(curl "${args[@]}" "https://api.github.com/${path}" 2>/dev/null) || code=000
    case "$code" in
      2??)
        cat "$out"
        rm -f "$hdr" "$out"
        return 0
        ;;
      403|429)
        if [ "$attempt" -eq 2 ]; then break; fi
        ra=$(awk 'tolower($1) == "retry-after:" { gsub(/[\r ]/, "", $2); print $2; exit }' "$hdr" 2>/dev/null || true)
        case "$ra" in ''|*[!0-9]*) ra=10 ;; esac
        if [ "$ra" -gt 20 ]; then ra=20; fi
        echo "exec-duty: alert ${method} /${path} → HTTP ${code}; Retry-After ${ra}s — retrying ONCE (bounded)" >&2
        sleep "$ra"
        ;;
      *)
        break
        ;;
    esac
  done
  msg=$(jq -r '.message // empty' "$out" 2>/dev/null | head -c 300 || true)
  echo "exec-duty: alert ${method} /${path} FAILED (HTTP ${code:-none}${msg:+ — api: ${msg}}); raw body withheld from stdout" >&2
  rm -f "$hdr" "$out"
  return 1
}

# exec_alert_find <title-prefix> → open alert issue number (or empty).
# GET lane (detection — never gates). Title-prefix match on OPEN issues,
# label deliberately NOT part of the query filter (label loss must not split
# the latch); numeric-validate candidates; per_page=50.
exec_alert_find() {
  local prefix="$1" json n
  json=$(GH_TOKEN="$(_alert_token)" gh api "repos/$(_alert_repo)/issues?state=open&per_page=50" 2>/dev/null || true)
  n=$(printf '%s' "${json:-}" | jq -r --arg p "$prefix" \
    '[.[] | select((.title // "") | startswith($p)) | .number | numbers] | first // empty' 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*) echo "" ;;
    *)           echo "$n" ;;
  esac
}

# exec_alert_create <title> <body> → new issue number on stdout; rc 1 on
# failure (stderr diagnostics; the raw error body NEVER reaches stdout — C2).
# The body becomes the FIRST '[exec-duty]' marker (its created_at is the dedup ts).
exec_alert_create() {
  local title="$1" body="$2" payload resp n
  payload=$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b, labels: ["exec-duty-alert"]}' 2>/dev/null) || payload=""
  if [ -z "$payload" ]; then
    echo "exec-duty: alert create '${title}' — payload build failed" >&2
    return 1
  fi
  if ! resp=$(_alert_curl POST "repos/$(_alert_repo)/issues" "$payload"); then
    echo "exec-duty: FAILED to open alert issue '${title}' (HTTP/token/issues-enabled? — target $(_alert_repo))" >&2
    return 1
  fi
  n=$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null || true)
  case "$n" in
    ''|*[!0-9]*)
      echo "exec-duty: FAILED to open alert issue '${title}' — response carried no numeric issue number (raw body withheld)" >&2
      return 1
      ;;
  esac
  echo "exec-duty: opened alert issue #${n} ('${title}')" >&2
  echo "$n"
}

# exec_alert_comment <issue-number> <body> → 0 posted / 1 failed (real rc —
# callers gate on it per R2 law 5; diagnostics stderr)
exec_alert_comment() {
  local num="$1" body="$2" payload
  payload=$(jq -n --arg b "$body" '{body: $b}' 2>/dev/null) || payload=""
  if [ -z "$payload" ] \
     || ! _alert_curl POST "repos/$(_alert_repo)/issues/${num}/comments" "$payload" >/dev/null; then
    echo "exec-duty: comment on alert issue #${num} FAILED (rate limit? token? — target $(_alert_repo))" >&2
    return 1
  fi
  echo "exec-duty: commented alert issue #${num}" >&2
  return 0
}

# exec_alert_close <issue-number> [final-body] → transition comment (when a
# body is given) + close. Real rc (the old best-effort close is dead — M4):
# a failed comment or PATCH returns 1 so callers gate RED (a stuck-open latch
# must be visible, not silently conservative).
exec_alert_close() {
  local num="$1" body="${2:-}"
  if [ -n "$body" ] && ! exec_alert_comment "$num" "$body"; then
    echo "exec-duty: closing alert issue #${num} aborted — final comment failed (latch stays open)" >&2
    return 1
  fi
  if ! _alert_curl PATCH "repos/$(_alert_repo)/issues/${num}" '{"state":"closed"}' >/dev/null; then
    echo "exec-duty: closing alert issue #${num} FAILED — it stays open" >&2
    return 1
  fi
  echo "exec-duty: closed alert issue #${num} (lane re-armed)" >&2
  return 0
}

# exec_alert_marker_age_h <issue-number> → hours (integer) since the newest
# '[exec-duty]' marker on the issue (body counts as the first marker); empty
# when the issue carries no marker at all.
#   per_page=20 + max(created_at): order-independent on purpose — the comments
#   API ignores sort/direction server-side (verified live, W2-b law 20), so the
#   W2-e P2-d per_page=1 regression is NOT re-shipped from birth.
#   Reads the ALERT repo (B2 — this helper was missed by the six-helper
#   enumeration; a wrong-repo read here = dedup bypass + heartbeat spam).
exec_alert_marker_age_h() {
  local num="$1" ts
  ts=$(GH_TOKEN="$(_alert_token)" gh api "repos/$(_alert_repo)/issues/${num}/comments?per_page=20&direction=desc" 2>/dev/null \
    | jq -r '[.[] | select((.body // "") | startswith("[exec-duty]")) | .created_at] | max // empty' 2>/dev/null \
    || true)
  if [ -z "${ts:-}" ]; then
    # the issue body itself is the first marker — fall back to its created_at
    ts=$(GH_TOKEN="$(_alert_token)" gh api "repos/$(_alert_repo)/issues/${num}" \
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

# lane_breaker_verdict <timeouts> <done> [alert_ratio] [clear_ratio] →
# echoes exactly one of: alert | clear | hold (R2 law 3 — the work-lane
# breaker; pure: no API, no state, deterministic).
#   ratio r = timeouts / (timeouts + done) — timeouts counts EVENTS, done
#   counts TASKS (lib/fsm.mjs); an epoch reset zeroes both → (0,0) → hold
#   (no false alert at genesis).
#   alert: timeouts ≥ 3 AND r ≥ alert_ratio (default 0.5)
#   clear: timeouts ≥ 3 AND r <  clear_ratio (default 0.25) — the floor gates
#          BOTH directions: a latch that never armed has nothing to clear
#          ((2,99) → hold), and post-reset small samples stay hold until the
#          new epoch re-proves the lane.
#   hold:  everything else (hysteresis band, small-sample, unparseable input).
lane_breaker_verdict() {
  local timeouts="${1:-}" done="${2:-}" ar="${3:-0.5}" cr="${4:-0.25}"
  case "$timeouts" in ''|*[!0-9]*) echo hold; return 0 ;; esac
  case "$done"     in ''|*[!0-9]*) echo hold; return 0 ;; esac
  awk -v t="$timeouts" -v d="$done" -v a="$ar" -v c="$cr" 'BEGIN {
    n = t + d
    if (n <= 0)            { print "hold";  exit }
    if (t < 3)             { print "hold";  exit }
    if (t / n >= a)        { print "alert"; exit }
    if (t / n <  c)        { print "clear"; exit }
    print "hold"
  }'
}
