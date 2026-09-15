#!/usr/bin/env bash
# tests/test-exec-duty-lib.sh — offline mock-first suite for the alert lane
# (T46-A2). Stubs `gh` + `curl` (+ `sleep`) in a temp PATH dir with canned
# responses; NO live API calls anywhere. Exit non-zero on any FAIL.
#
# Canned responses: 200-success (numeric issue), 410-with-JSON-error-body,
# 403-with-Retry-After:7 (once, then 200), 429-with-Retry-After:30 (always),
# 500. The gh stub serves issue lists (mixed / empty / garbage / error-body),
# comment lists (with and without [exec-duty] markers) and single issues.
#
# Run: bash tests/test-exec-duty-lib.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/exec-duty-lib.sh"
WF="$ROOT/.github/workflows/scheduler.yml"

PASS=0; FAIL=0; SKIPPED=0; FAILED=()
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL: $1"; }
assert() { # assert <desc> <command...> — asserts the command exits 0
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
assert_eq() { # assert_eq <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}

# ---- stub environment -------------------------------------------------------
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
export STUB_DIR="$STUB"
export PATH="$STUB/bin:$PATH"
export GH_TOKEN="test-token-stub"
unset EXEC_ALERT_REPO EXEC_ALERT_TOKEN GITHUB_REPOSITORY 2>/dev/null || true

CURL_LOG="$STUB/curl.args"; CURL_COUNT="$STUB/curl.count"
GH_LOG="$STUB/gh.args";      SLEEP_LOG="$STUB/sleep.log"

# stub: sleep — records the requested seconds, never actually sleeps
cat > "$STUB/bin/sleep" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${STUB_DIR}/sleep.log"
exit 0
STUB_EOF

# stub: curl — canned GitHub API responses, behavior via $CURL_MODE:
#   200 | 410 | 429 (Retry-After: 30, always) | 500 | 403-once-then-200 (RA: 7)
cat > "$STUB/bin/curl" <<'STUB_EOF'
#!/usr/bin/env bash
n=$(($(cat "${STUB_DIR}/curl.count" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$n" > "${STUB_DIR}/curl.count"
printf '%s\n' "$*" >> "${STUB_DIR}/curl.args"
hdr=""; out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -D) hdr="${args[$((i + 1))]}" ;;
    -o) out="${args[$((i + 1))]}" ;;
  esac
done
mode="${CURL_MODE:-200}"
case "$mode" in
  200)
    [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nx-oauth-scopes: repo, workflow\r\n\r\n' > "$hdr"
    [ -n "$out" ] && printf '{"number": 101, "state": "open", "html_url": "https://example.com/i/101"}' > "$out"
    echo 200 ;;
  410)
    [ -n "$hdr" ] && printf 'HTTP/1.1 410 Gone\r\n\r\n' > "$hdr"
    [ -n "$out" ] && printf '{"message": "Issues has been disabled in this repository", "documentation_url": "https://docs.github.com/rest"}' > "$out"
    echo 410 ;;
  403-once-then-200)
    if [ "$n" -eq 1 ]; then
      [ -n "$hdr" ] && printf 'HTTP/1.1 403\r\nRetry-After: 7\r\n\r\n' > "$hdr"
      [ -n "$out" ] && printf '{"message": "rate limited"}' > "$out"
      echo 403
    else
      [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
      [ -n "$out" ] && printf '{"number": 202}' > "$out"
      echo 200
    fi ;;
  429)
    [ -n "$hdr" ] && printf 'HTTP/1.1 429\r\nRetry-After: 30\r\n\r\n' > "$hdr"
    [ -n "$out" ] && printf '{"message": "secondary rate limit"}' > "$out"
    echo 429 ;;
  500)
    [ -n "$hdr" ] && printf 'HTTP/1.1 500\r\n\r\n' > "$hdr"
    [ -n "$out" ] && printf '{"message": "boom"}' > "$out"
    echo 500 ;;
  *)
    echo "stub-curl: unknown CURL_MODE '${mode}'" >&2; exit 9 ;;
esac
exit 0
STUB_EOF

# stub: gh — canned REST payloads by path; list variant via $GH_LIST
# (mixed | empty | garbage | error-body), comment markers via $GH_MARKERS.
cat > "$STUB/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_DIR}/gh.args"
case "$*" in
  *"issues?state=open"*)
    case "${GH_LIST:-mixed}" in
      mixed)
        printf '%s\n' '[{"number": "oops-not-numeric", "title": "duty alert: mirror-health"}, {"number": 42, "title": "duty alert: mirror-health RED note"}, {"number": 43, "title": "duty alert: unrelated class"}, {"number": 44, "title": "duty alert: mirror-health-old"}]' ;;
      empty)   printf '[]\n' ;;
      garbage) printf 'not json at all\n' ;;
      error)
        printf '%s\n' '{"message": "Issues has been disabled in this repository"}'
        exit 1 ;;
      *) echo "stub-gh: unknown GH_LIST '${GH_LIST}'" >&2; exit 9 ;;
    esac ;;
  *"/comments"*)
    ts=$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)
    if [ "${GH_MARKERS:-yes}" = "yes" ]; then
      printf '[{"number": 1001, "body": "[exec-duty] marker one", "created_at": "%s"}, {"number": 1002, "body": "human noise — not a marker", "created_at": "2026-01-01T00:00:00Z"}]\n' "$ts"
    else
      printf '[{"number": 1002, "body": "human noise — not a marker", "created_at": "2026-01-01T00:00:00Z"}]\n'
    fi ;;
  *)
    ts=$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)
    if [ "${GH_BODY_MARKER:-yes}" = "yes" ]; then
      body="[exec-duty] initial body marker"
    else
      body="no marker in the body"
    fi
    if [[ "$*" == *"--jq"* ]]; then
      # emulate gh --jq 'select((.body // "") | startswith("[exec-duty]"))
      # | .created_at // empty' — matched case only (unmatched prints nothing)
      if [ "${GH_BODY_MARKER:-yes}" = "yes" ]; then printf '%s\n' "$ts"; fi
    else
      printf '{"number": 42, "body": "%s", "created_at": "%s"}\n' "$body" "$ts"
    fi ;;
esac
exit 0
STUB_EOF
chmod +x "$STUB/bin/sleep" "$STUB/bin/curl" "$STUB/bin/gh"

reset_lane() { # truncate stub logs + restore default canned modes
  : > "$CURL_LOG"; : > "$CURL_COUNT"; : > "$GH_LOG"; : > "$SLEEP_LOG"
  export CURL_MODE=200 GH_LIST=mixed GH_MARKERS=yes GH_BODY_MARKER=yes
}

# The lib under test (after the stub PATH is in place — functions resolve
# curl/gh/sleep at CALL time).
# shellcheck source=../scripts/exec-duty-lib.sh
. "$LIB"

# ---- 1. create with 410 error body → rc 1, stdout EMPTY (no JSON leak) -----
echo "== 1. exec_alert_create, 410 error body =="
reset_lane; export CURL_MODE=410
out=$(exec_alert_create "duty alert: test" "[exec-duty] test body" 2>"$STUB/t1.err"); rc=$?
assert "1: rc 1 on HTTP 410" test "$rc" -eq 1
assert "1: stdout EMPTY (no JSON leak)" test -z "$out"
assert "1: stderr diagnostic present" test -s "$STUB/t1.err"
assert "1: stderr carries the triaged api message" grep -q "Issues has been disabled" "$STUB/t1.err"
export CURL_MODE=200

# ---- 2. create success → rc 0, stdout = numeric only ------------------------
echo "== 2. exec_alert_create, 200 success =="
reset_lane
out=$(exec_alert_create "duty alert: test" "[exec-duty] test body" 2>"$STUB/t2.err"); rc=$?
assert "2: rc 0 on success" test "$rc" -eq 0
assert_eq "2: stdout = the numeric issue number" "$out" "101"
assert "2: stdout is digits-only" sh -c 'case "$1" in ""|*[!0-9]*) exit 1 ;; esac' _ "$out"

# ---- 3. all alert calls route to the default alert repo ---------------------
echo "== 3. default target routing (claudecode-headless/fsm-lab) =="
reset_lane
exec_alert_find "duty alert: mirror-health"          >/dev/null 2>&1
exec_alert_create "duty alert: routing" "[exec-duty] r" >/dev/null 2>&1
exec_alert_comment 42 "[exec-duty] c"                >/dev/null 2>&1
exec_alert_close 42 "[exec-duty] close"              >/dev/null 2>&1
exec_alert_marker_age_h 42                           >/dev/null 2>&1
assert "3: curl lane saw the default alert repo" grep -q "repos/claudecode-headless/fsm-lab" "$CURL_LOG"
assert "3: gh lane saw the default alert repo"   grep -q "repos/claudecode-headless/fsm-lab" "$GH_LOG"
stray=$( { cat "$CURL_LOG" "$GH_LOG"; } \
  | grep -o 'repos/[^ /]*/[^ /]*' | grep -v '^repos/claudecode-headless/fsm-lab$' | sort -u || true)
assert "3: zero stray repo targets (find/create/comment/close/marker_age_h)" test -z "$stray"

# ---- 4. EXEC_ALERT_REPO=self routes to GITHUB_REPOSITORY --------------------
echo "== 4. EXEC_ALERT_REPO=self fork mode =="
reset_lane
export EXEC_ALERT_REPO=self GITHUB_REPOSITORY=fork-owner/fork-repo
exec_alert_create "duty alert: self" "[exec-duty] s" >/dev/null 2>&1
exec_alert_find "duty alert: self"                   >/dev/null 2>&1
unset EXEC_ALERT_REPO GITHUB_REPOSITORY
assert "4: self mode routes POSTs to GITHUB_REPOSITORY" grep -q "repos/fork-owner/fork-repo" "$CURL_LOG"
assert "4: self mode routes GETs to GITHUB_REPOSITORY"  grep -q "repos/fork-owner/fork-repo" "$GH_LOG"
assert "4: self mode never touched the default target"  sh -c '! grep -q "repos/claudecode-headless/fsm-lab" "$1"' _ "$CURL_LOG"

# ---- 5. 403 + Retry-After: 7 → one retry, 2 calls, sleep ≤ 20 ----------------
echo "== 5. Retry-After ladder (403 → retry once) =="
reset_lane; export CURL_MODE=403-once-then-200
out=$(exec_alert_create "duty alert: ra" "[exec-duty] ra" 2>/dev/null); rc=$?
assert "5: rc 0 after the successful retry" test "$rc" -eq 0
assert_eq "5: retry returned the numeric number" "$out" "202"
assert_eq "5: exactly 2 curl calls (ONE retry)" "$(cat "$CURL_COUNT")" "2"
assert_eq "5: exactly one sleep" "$(wc -l < "$SLEEP_LOG" | tr -d '[:space:]')" "1"
assert_eq "5: slept the Retry-After value (7 ≤ 20)" "$(head -n1 "$SLEEP_LOG")" "7"
export CURL_MODE=200

# ---- 6. 429 twice → rc 1 after ONE retry -------------------------------------
echo "== 6. Retry-After ladder (429 twice → give up) =="
reset_lane; export CURL_MODE=429
out=$(exec_alert_comment 42 "[exec-duty] rl" 2>/dev/null); rc=$?
assert "6: rc 1 after one retry" test "$rc" -eq 1
assert "6: stdout empty on comment failure" test -z "$out"
assert_eq "6: exactly 2 curl calls (ONE retry, then fail)" "$(cat "$CURL_COUNT")" "2"
assert_eq "6: Retry-After 30 capped to 20s" "$(head -n1 "$SLEEP_LOG")" "20"
export CURL_MODE=200

# ---- 7. find: title-prefix match, numeric validation, label-independent ------
echo "== 7. exec_alert_find semantics =="
reset_lane
n=$(exec_alert_find "duty alert: mirror-health" 2>/dev/null)
assert_eq "7: title-prefix match + numeric validation (string 'number' skipped)" "$n" "42"
assert "7: label NOT part of the filter (latch-split fix)" sh -c '! grep -q "labels=" "$1"' _ "$GH_LOG"
assert "7: per_page=50" grep -q "per_page=50" "$GH_LOG"
assert "7: open-state filter" grep -q "state=open" "$GH_LOG"
export GH_LIST=empty
n=$(exec_alert_find "duty alert: mirror-health" 2>/dev/null)
assert_eq "7: no match → empty" "$n" ""
export GH_LIST=garbage
n=$(exec_alert_find "duty alert: mirror-health" 2>/dev/null)
assert_eq "7: unparseable payload → empty" "$n" ""
export GH_LIST=error
n=$(exec_alert_find "duty alert: mirror-health" 2>/dev/null)
assert_eq "7: gh error body (rc 1) → empty, never a number" "$n" ""
export GH_LIST=mixed

# ---- 8. lane_breaker_verdict (pure) ------------------------------------------
echo "== 8. lane_breaker_verdict =="
assert_eq "8: (3,1)  → alert"  "$(lane_breaker_verdict 3 1)"   "alert"
assert_eq "8: (3,9)  → hold (ratio 0.25 not < 0.25)" "$(lane_breaker_verdict 3 9)"  "hold"
assert_eq "8: (2,99) → hold (timeouts < 3 floor)"    "$(lane_breaker_verdict 2 99)" "hold"
assert_eq "8: (3,10) → clear (ratio ≈0.231 < 0.25)"  "$(lane_breaker_verdict 3 10)" "clear"
assert_eq "8: (0,0)  → hold (epoch genesis)"         "$(lane_breaker_verdict 0 0)"  "hold"
assert_eq "8: (3,3)  → alert (ratio 1.0)"            "$(lane_breaker_verdict 3 3)"  "alert"
assert_eq "8: custom alert ratio (10,10,0.9) → hold"     "$(lane_breaker_verdict 10 10 0.9)"    "hold"
assert_eq "8: custom clear ratio (3,5,0.5,0.4) → clear"  "$(lane_breaker_verdict 3 5 0.5 0.4)"  "clear"
assert_eq "8: unparseable input → hold"                  "$(lane_breaker_verdict x y)"          "hold"

# ---- 9. marker_age_h reads from _alert_repo ----------------------------------
echo "== 9. exec_alert_marker_age_h routing =="
reset_lane
age=$(exec_alert_marker_age_h 42 2>/dev/null)
assert "9: comments GET routed to the alert repo" \
  grep -q "repos/claudecode-headless/fsm-lab/issues/42/comments" "$GH_LOG"
assert "9: age is a plain integer" sh -c 'case "$1" in ""|*[!0-9]*) exit 1 ;; esac' _ "$age"
assert "9: age ≈ 25h (marker 25h old)" sh -c '[ "$1" -ge 24 ] && [ "$1" -le 25 ]' _ "$age"
export GH_MARKERS=no
age=$(exec_alert_marker_age_h 42 2>/dev/null)
export GH_MARKERS=yes
assert "9: body-marker fallback GET also on the alert repo" \
  grep -q "repos/claudecode-headless/fsm-lab/issues/42 --jq" "$GH_LOG"
assert "9: fallback age from the issue body (≈30h)" sh -c '[ "$1" -ge 29 ] && [ "$1" -le 30 ]' _ "$age"
export GH_MARKERS=no GH_BODY_MARKER=no
age=$(exec_alert_marker_age_h 42 2>/dev/null)
export GH_MARKERS=yes GH_BODY_MARKER=yes
assert "9: no marker anywhere → empty age (dedup posts the comment)" test -z "$age"

# ---- 10. B2 sweep: zero hardcoded alert targets ------------------------------
echo "== 10. B2 sweep — no hardcoded repos/\${GITHUB_REPOSITORY} anywhere =="
hits_lib=$(grep -Fn 'repos/${GITHUB_REPOSITORY}' "$LIB" || true)
assert "10: lib carries zero hardcoded alert targets" test -z "$hits_lib"
hits_wf=$(grep -Fn 'repos/${GITHUB_REPOSITORY}' "$WF" || true)
assert "10: workflow carries zero hardcoded alert targets" test -z "$hits_wf"
assert "10: workflow wires EXEC_ALERT_REPO from vars" grep -Fq "EXEC_ALERT_REPO:" "$WF"

# ---- 11. static checks --------------------------------------------------------
echo "== 11. static checks =="
assert "11: bash -n on the lib" bash -n "$LIB"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  assert "11: scheduler.yml parses as YAML" \
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WF"
else
  SKIPPED=$((SKIPPED+1))
  echo "SKIP: 11: yaml check (python3/pyyaml unavailable in this environment)"
fi

# ---- summary ------------------------------------------------------------------
echo
echo "test-exec-duty-lib: ${PASS} passed, ${FAIL} failed, ${SKIPPED} skipped"
if [ "$FAIL" -gt 0 ]; then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
