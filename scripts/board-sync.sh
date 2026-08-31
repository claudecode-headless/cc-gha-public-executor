#!/usr/bin/env bash
# board-sync — mirror the swarm's per-issue state onto the Projects v2 board.
#
# Part of Task 36 (channel strategy + GH-seam glue + robustness layers).
# Runs on the PUBLIC executor inside the scheduler job (free minutes).
#
# INPUT: a jsonl state file, one line per ACTIVE (marker-carrying) issue:
#   {"issue": 6, "status": "In Progress|Stalled|Idle|Failed", "agent": "coder"}
#
# BOARD MODEL (A2A-CHANNEL-STRATEGY.md): the board is the STATE layer and the
# operator's single dashboard — never a wake surface (projects_v2_item cannot
# trigger workflows; proven run 33142384110). One item per agent-active issue;
# Status mirrors the conversation state; Agent = who is on the hook. Issues
# that close (or lose their markers) are REMOVED — the board shows live work.
#
# CAPABILITY / GRACEFUL DEGRADATION: Projects v2 GraphQL requires a PAT with
# `project` scope. GH_PAT_PRIVATE was audited 2026-08-28 to carry repo+workflow
# only → this step logs a skip and exits 0 (the scheduler NEVER breaks because
# of the board). It lights up the moment the operator adds a project-scoped
# BOARD_PAT secret (or expands GH_PAT_PRIVATE). Runbook: DIAGNOSTICS.md.
#
# SELF-INSTALLING: if the board (or a field) is missing, or a field's option
# set doesn't match the required set, it is created/recreated (recreating a
# single-select drops its values — acceptable for a mirror, never a source).
#
# LOG HYGIENE (public repo — every line is world-readable):
#   - issue NUMBERS, statuses, agent ids, and counts ONLY
#   - never titles/bodies/comment text (they never enter this script)
#   - GraphQL error TYPES may be logged (e.g. INSUFFICIENT_SCOPES), never data
set -euo pipefail

STATE_FILE=${1:?usage: board-sync.sh <state-file.jsonl> [scanned-issues-file]}
SCANNED_FILE=${2:-}   # issues confirmed scanned this pass (removal guard — see below)
PRIVATE_REPO=${PRIVATE_REPO:?}
ROSTER=${ROSTER:?}                  # comma-separated agent ids (registry-driven)
BOARD_NUMBER=${BOARD_NUMBER:-1}     # the "A2A Swarm Board" user project
BOARD_TITLE=${BOARD_TITLE:-A2A Swarm Board}
# BOARD_PAT (project-scoped) overrides GH_PAT_PRIVATE when present.
TOKEN=${BOARD_PAT:-${GH_PAT_PRIVATE:?need GH_PAT_PRIVATE or BOARD_PAT}}

# Missing/empty state file = a legitimately quiet repo (the scheduler now
# ALWAYS creates it) — but treat a MISSING file as skip-not-wipe anyway
# (defense in depth, review 36-r1/r3 P1: an accidental absence must not
# mass-remove every board item).
if [ ! -f "$STATE_FILE" ]; then
  echo "board sync: SKIPPED — state file missing (scan did not run or passed no path). Scheduler continues normally."
  exit 0
fi

GQL() { # GQL <payload-json> → GraphQL response on stdout; empty string on transport failure
  # curl, NOT `gh api graphql`: the live scheduler run (33186444016) showed gh
  # returning empty for the capability probe where the identical curl call
  # returns the INSUFFICIENT_SCOPES body (audited live — the scope-skip
  # message must be precise or the operator cannot tell transport from
  # capability). curl's body handling is deterministic either way.
  curl -sS -X POST https://api.github.com/graphql \
    -H "Authorization: bearer ${TOKEN}" -H "Content-Type: application/json" \
    --data-binary "$1" --max-time 30 2>/dev/null || true
}

# ---------- 0. capability gate (the graceful-skip contract) ----------
# TASK-40 PORT: the swarm home is an ORG (claudecode-headless). An org login
# under user() returns null data (not an error) — the original user()-only
# probe would self-install a DUPLICATE board under the viewer EVERY cycle.
# Probe the org first; fall back to user for personal-account repos; self-
# install under the org when the repo is org-owned (else the viewer).
REPO_OWNER=${PRIVATE_REPO%%/*}
ORG_PROBE=$(GQL "{\"query\": \"query { organization(login: \\\"${REPO_OWNER}\\\") { id projectV2(number: ${BOARD_NUMBER}) { id title } } }\"}")
USER_PROBE=$(GQL "{\"query\": \"query { user(login: \\\"${REPO_OWNER}\\\") { id projectV2(number: ${BOARD_NUMBER}) { id title } } }\"}")
if [ -z "$ORG_PROBE" ] && [ -z "$USER_PROBE" ]; then
  echo "board sync: SKIPPED — board probe returned nothing (transport). Scheduler continues normally."
  exit 0
fi
for P in "$ORG_PROBE" "$USER_PROBE"; do
  if printf '%s' "$P" | jq -e '.errors[]? | select(.type=="INSUFFICIENT_SCOPES")' >/dev/null 2>&1; then
    echo "board sync: SKIPPED — token lacks the project scope (audited state; add BOARD_PAT to activate). Scheduler continues normally."
    exit 0
  fi
done
ORG_ID=$(printf '%s' "$ORG_PROBE" | jq -r '.data.organization.id // empty' 2>/dev/null || true)
if [ -n "$ORG_ID" ]; then
  PROBE="$ORG_PROBE"
  PROJECT_ID=$(printf '%s' "$PROBE" | jq -r '.data.organization.projectV2.id // empty' 2>/dev/null || true)
else
  PROBE="$USER_PROBE"
  PROJECT_ID=$(printf '%s' "$PROBE" | jq -r '.data.user.projectV2.id // empty' 2>/dev/null || true)
fi
if [ -z "$PROJECT_ID" ]; then
  echo "board sync: board #${BOARD_NUMBER} not found — creating it (self-install)."
  if [ -n "$ORG_ID" ]; then
    OWNER_ID="$ORG_ID"   # org-owned repo: the board lives with the org
  else
    VIEWER=$(GQL '{"query": "query { viewer { id } }"}')
    OWNER_ID=$(printf '%s' "$VIEWER" | jq -r '.data.viewer.id // empty' 2>/dev/null || true)
  fi
  if [ -z "$OWNER_ID" ]; then echo "board sync: owner/viewer id unavailable — skipping this cycle." >&2; exit 0; fi
  CREATE=$(GQL "{\"query\": \"mutation(\$o: ID!, \$t: String!) { createProjectV2(input: {ownerId: \$o, title: \$t}) { projectV2 { id } } }\", \"variables\": {\"o\": \"${OWNER_ID}\", \"t\": \"${BOARD_TITLE}\"}}")
  PROJECT_ID=$(printf '%s' "$CREATE" | jq -r '.data.createProjectV2.projectV2.id // empty' 2>/dev/null || true)
  [ -n "$PROJECT_ID" ] || { echo "board sync: createProjectV2 failed — skipping this cycle." >&2; exit 0; }
fi

# ---------- 1. ensure the Status + Agent fields with the right options ----
REQUIRED_STATUS="In Progress,Stalled,Idle,Failed"
AGENT_OPTIONS="${ROSTER},unassigned"

# SCHEMA NOTE (live-proven 2026-08-29, first ACTIVE-path run): a field's
# `options` is a PLAIN LIST (`options { name }`), NOT a connection —
# `options(first: N) { nodes { ... } }` is a schema error that silently
# zeroes every field lookup (the fixture mocks had encoded the connection
# shape and papered over it; only the live run exposed it). The create
# mutation's option input type is ProjectV2SingleSelectFieldOptionInput.
FIELDS_RES=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options { name } } } } } } }\"}")

build_opts() { # build_opts <comma-separated options> → JSON array of option inputs
  # ProjectV2SingleSelectFieldOptionInput REQUIRES name + color + description
  # (all non-null — live-proven 2026-08-29: {name} alone is rejected), and
  # color is a NAMED enum — GRAY|BLUE|GREEN|YELLOW|ORANGE|RED|PINK|PURPLE —
  # hex strings are rejected. Description = the operator legend.
  printf '%s' "$1" | jq -R -r 'split(",") | map(select(length > 0)) | map({name: ., color: (if . == "In Progress" then "GREEN" elif . == "Stalled" then "ORANGE" elif . == "Idle" then "GRAY" elif . == "Failed" then "RED" elif . == "unassigned" then "GRAY" else "BLUE" end), description: "board-sync mirror — the issue thread is the source of truth"}) | tojson'
}

ensure_field() { # ensure_field <name> <comma-separated options> → field id on STDOUT
  local NAME=$1 OPTIONS=$2
  local FID HAVE WANT
  # NOTE: this function's stdout is a RETURN VALUE (captured by the caller) —
  # all diagnostics MUST go to stderr or they corrupt the returned id.
  # (Verified live in fixture tests: a stray message on stdout BECOMES the
  # field id; the failing mutations then silently no-op — the worst failure
  # mode: looks healthy, does nothing.)
  FID=$(printf '%s' "$FIELDS_RES" | jq -r --arg n "$NAME" '[.data.node.fields.nodes[] | select(.name == $n)][0].id // empty' 2>/dev/null || true)
  WANT=$(printf '%s' "$OPTIONS" | tr ',' '\n' | sed '/^$/d' | sort | paste -sd,)
  if [ -n "$FID" ]; then
    HAVE=$(printf '%s' "$FIELDS_RES" | jq -r --arg n "$NAME" '[.data.node.fields.nodes[] | select(.name == $n)][0].options[].name' 2>/dev/null | sort | paste -sd, || true)
    if [ "$HAVE" != "$WANT" ]; then
      # Option-set drift → UPDATE the options in place FIRST
      # (updateProjectV2Field accepts singleSelectOptions — live-proven
      # 2026-08-29, works even on the project's DEFAULT fields; values whose
      # option names survive the change are preserved). Only if the update
      # fails do we fall back to delete+recreate — and DEFAULT fields reject
      # deletion ("Only custom fields can be deleted"), which is why the
      # update path must come first.
      echo "board sync: field '${NAME}' option drift — updating options in place (values with surviving names are kept)." >&2
      local OPTS UPD
      OPTS=$(build_opts "$OPTIONS")
      UPD=$(GQL "{\"query\": \"mutation(\$f: ID!, \$o: [ProjectV2SingleSelectFieldOptionInput!]!) { updateProjectV2Field(input: {fieldId: \$f, singleSelectOptions: \$o}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }\", \"variables\": {\"f\": \"${FID}\", \"o\": ${OPTS}}}")
      if ! printf '%s' "$UPD" | jq -e '.data.updateProjectV2Field' >/dev/null 2>&1; then
        echo "board sync: option update for '${NAME}' failed — falling back to delete+recreate (values reset)." >&2
        # DeleteProjectV2FieldInput takes ONLY fieldId (live-introspected
        # 2026-08-29 — the projectId form is a schema error now).
        GQL "{\"query\": \"mutation(\$f: ID!) { deleteProjectV2Field(input: {fieldId: \$f}) { projectV2Field { ... on ProjectV2FieldCommon { id } } } }\", \"variables\": {\"f\": \"${FID}\"}}" >/dev/null
        FID=""
      fi
    fi
  fi
  if [ -z "$FID" ]; then
    local OPTS CREATED
    OPTS=$(build_opts "$OPTIONS")
    CREATED=$(GQL "{\"query\": \"mutation(\$p: ID!, \$n: String!, \$o: [ProjectV2SingleSelectFieldOptionInput!]!) { createProjectV2Field(input: {projectId: \$p, name: \$n, dataType: SINGLE_SELECT, singleSelectOptions: \$o}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"n\": \"${NAME}\", \"o\": ${OPTS}}}")
    FID=$(printf '%s' "$CREATED" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null || true)
    [ -n "$FID" ] || { echo "board sync: could not ensure field '${NAME}' — skipping this cycle." >&2; exit 0; }
  fi
  printf '%s' "$FID"
}

STATUS_FIELD=$(ensure_field "Status" "$REQUIRED_STATUS")
AGENT_FIELD=$(ensure_field "Agent" "$AGENT_OPTIONS")

# ---------- 2. current board items + option ids ---------------------------
# fieldValues' `field` is a UNION (ProjectV2FieldConfiguration) — select the
# name via ... on ProjectV2FieldCommon (ProjectV2Field is not a member;
# live-proven 2026-08-29).
ITEMS=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { items(first: 100) { nodes { id content { ... on Issue { number } } fieldValues(first: 10) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } } } } } } } } }\"}")
OPTIONS_RES=$(GQL "{\"query\": \"query { node(id: \\\"${PROJECT_ID}\\\") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }\"}")
if [ -z "$ITEMS" ] || [ -z "$OPTIONS_RES" ]; then
  echo "board sync: item/option query failed (transport) — skipping this cycle." >&2
  exit 0
fi
# Non-empty but INVALID items payload (GraphQL errors / truncation) must not
# masquerade as an empty board — that would re-ADD every issue as a duplicate
# (Projects v2 accepts duplicates; the twin is invisible to later runs —
# review 36-r1 P2).
if ! printf '%s' "$ITEMS" | jq -e '.data.node.items.nodes' >/dev/null 2>&1; then
  echo "board sync: items payload failed validation — skipping this cycle (no board change)." >&2
  exit 0
fi

opt_id() { # opt_id <field name> <option name> → option id ("" on any parse failure)
  # Hardened: a malformed/empty OPTIONS_RES must degrade to "no update",
  # never crash the scheduler step (verified live: the unhardened form exits 5
  # and takes the whole job down — the exact anti-contract failure).
  printf '%s' "$OPTIONS_RES" | jq -r --arg f "$1" --arg o "$2" \
    '[.data.node.fields.nodes[] | select(.name == $f)][0].options[] | select(.name == $o) | .id' 2>/dev/null | head -1 || true
}

# ---------- 3. diff state vs board ----------------------------------------
ADDED=0; UPDATED=0; REMOVED=0; KEPT=0
declare -A BOARD_ITEM_ID BOARD_STATUS BOARD_AGENT
while IFS=$'\t' read -r ITEM_ID INUM CST CAG; do
  BOARD_ITEM_ID[$INUM]=$ITEM_ID
  BOARD_STATUS[$INUM]=$CST
  BOARD_AGENT[$INUM]=$CAG
done < <(printf '%s' "$ITEMS" | jq -r '.data.node.items.nodes[]
  | select((.content.number // 0) > 0)   # draft items (number 0) are operator-owned — never manage them
  | [.id, (.content.number // 0),
     ([.fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // ""),
     ([.fieldValues.nodes[] | select(.field.name == "Agent") | .name][0] // "")] | @tsv' 2>/dev/null || true)

while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  NUM=$(printf '%s' "$LINE" | jq -r '.issue // empty' 2>/dev/null || true)
  [ -n "$NUM" ] || continue   # malformed state line — skip, never crash the step
  WANT_STATUS=$(printf '%s' "$LINE" | jq -r '.status // empty' 2>/dev/null || true)
  WANT_AGENT=$(printf '%s' "$LINE" | jq -r '.agent // "unassigned"' 2>/dev/null || true)
  ITEM_ID=${BOARD_ITEM_ID[$NUM]:-}
  if [ -z "$ITEM_ID" ]; then
    # new active issue → add the real issue as a board item
    NODE_ID=$(gh api "repos/${PRIVATE_REPO}/issues/${NUM}" --jq .node_id 2>/dev/null || echo "")
    if [ -z "$NODE_ID" ]; then echo "board sync: issue #${NUM} not fetchable — skipping."; continue; fi
    ADDED=$((ADDED+1))
    ITEM_ID=$(GQL "{\"query\": \"mutation(\$p: ID!, \$c: ID!) { addProjectV2ItemById(input: {projectId: \$p, contentId: \$c}) { item { id } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"c\": \"${NODE_ID}\"}}" | jq -r '.data.addProjectV2ItemById.item.id // empty' 2>/dev/null || true)
    if [ -z "$ITEM_ID" ]; then echo "board sync: addProjectV2ItemById failed for issue #${NUM} — skipping it." >&2; continue; fi
    BOARD_ITEM_ID[$NUM]=$ITEM_ID; BOARD_STATUS[$NUM]=""; BOARD_AGENT[$NUM]=""
    echo "board sync: + issue #${NUM} (${WANT_STATUS}, ${WANT_AGENT})"
  fi
  # Status + Agent field updates only on change
  for FLD in Status Agent; do
    if [ "$FLD" = "Status" ]; then WANT=$WANT_STATUS; CUR=${BOARD_STATUS[$NUM]}; FID=$STATUS_FIELD
    else WANT=$WANT_AGENT; CUR=${BOARD_AGENT[$NUM]}; FID=$AGENT_FIELD; fi
    if [ -n "$WANT" ] && [ "$WANT" != "$CUR" ]; then
      OID=$(opt_id "$FLD" "$WANT")
      if [ -n "$OID" ]; then
        UPD_RES=$(GQL "{\"query\": \"mutation(\$p: ID!, \$i: ID!, \$f: ID!, \$v: String!) { updateProjectV2ItemFieldValue(input: {projectId: \$p, itemId: \$i, fieldId: \$f, value: {singleSelectOptionId: \$v}}) { projectV2Item { id } } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"i\": \"${ITEM_ID}\", \"f\": \"${FID}\", \"v\": \"${OID}\"}}")
        # verify the mutation actually landed (review 36-r3 P3: counting
        # regardless made GraphQL errors look like healthy syncs)
        if printf '%s' "$UPD_RES" | jq -e '.data.updateProjectV2ItemFieldValue' >/dev/null 2>&1; then
          UPDATED=$((UPDATED+1))
        else
          echo "board sync: field update for issue #${NUM} (${FLD}=${WANT}) failed — retried next cycle" >&2
        fi
      fi
    fi
  done
  KEPT=$((KEPT+1))
done < "$STATE_FILE"

# remove items whose issue left the active set. GUARD (review 36-r3 P2): an
# item is removed ONLY if its issue was CONFIRMED scanned this pass (present
# in the scanned-set file) and is not agent-active — a partial/failed scan
# (transport errors, issue-list truncation) leaves unscanned items untouched.
# Without the guard, one bad scan silently wipes the board.
STATE_NUMS=$(jq -r '.issue // empty' "$STATE_FILE" 2>/dev/null | sort -n | paste -sd' ' || true)
SCANNED_NUMS=""
if [ -n "$SCANNED_FILE" ] && [ -f "$SCANNED_FILE" ]; then
  SCANNED_NUMS=$(sort -n "$SCANNED_FILE" | uniq | paste -sd' ' || true)
fi
for INUM in "${!BOARD_ITEM_ID[@]}"; do
  if [ -n "$SCANNED_NUMS" ] \
     && printf ' %s ' "$SCANNED_NUMS" | grep -q " ${INUM} " \
     && ! printf ' %s ' "$STATE_NUMS" | grep -q " ${INUM} "; then
    DEL_RES=$(GQL "{\"query\": \"mutation(\$p: ID!, \$i: ID!) { deleteProjectV2Item(input: {projectId: \$p, itemId: \$i}) { deletedItemId } }\", \"variables\": {\"p\": \"${PROJECT_ID}\", \"i\": \"${BOARD_ITEM_ID[$INUM]}\"}}")
    if printf '%s' "$DEL_RES" | jq -e '.data.deleteProjectV2Item' >/dev/null 2>&1; then
      REMOVED=$((REMOVED+1))
      echo "board sync: - issue #${INUM} (no longer active)"
    else
      echo "board sync: removal of issue #${INUM} failed — retried next cycle" >&2
    fi
  fi
done

echo "board sync: ${KEPT} active issues (+${ADDED} added, ${UPDATED} field updates, -${REMOVED} removed)"
