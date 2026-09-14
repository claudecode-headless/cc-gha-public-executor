# cc-gha-public-executor

**Public-compute executor for the private [`cc-gha-exploration`](https://github.com/xfnwfpho1/cc-gha-exploration) track.**
GitHub-hosted runners are **free and unlimited on public repos**; private repos
burn the plan's minute quota (~583 of 2,000 free-plan minutes in 4 days of
experimentation). This repo moves non-A2A workloads to public compute while all
content, results, and the agent conversation surface stay private.

## What lives here (and what must NEVER live here)

| Allowed here | Must stay in the private repo |
|---|---|
| Workflow orchestration (dispatch/schedule drivers) | Issue threads (the A2A transport — human + agent chatter) |
| Compute-heavy, content-insensitive one-shot tasks | Code under review, research docs, session transcripts |
| The stall scanner (numbers-only logging) | Secrets-bearing content beyond this repo's secrets |
| PR review compute (clone via RO deploy key, review text ships privately) | The review text itself until posted to the private PR |
| The a2a marker parser copy (`a2a-marker.mjs`) | Agent session state (`agent-sessions` branch) |

## The two patterns proven here

### 1. Public executor, private everything else (non-A2A tasks)

```
human/agent → workflow_dispatch THIS repo (inputs = pointers, never secrets)
             → runner clones the PRIVATE repo via repo-scoped DEPLOY KEYS (git surface;
               keys exist only in git steps, trap-shredded before any agent step)
             → does the heavy lifting (CC agent turn, long job — free minutes)
             → pushes results via deploy key (agent-sessions branch) / posts via PAT (API surface)
             → public log contains NO task content (log hygiene, see below)
```

**Deploy keys = the API-mintable, repo-scoped git secret** (fine-grained PATs are
UI-only — proven 2026-08-28). RW key exists for exactly one workflow step (the
one-shot persist); review + submodule fetches use READ-ONLY keys. The agent step
runs with NO git credentials at all (keys shredded; it can commit locally but
push nowhere).

Secrets on a public repo: **encrypted at rest, never readable via any API,
never visible to other users, masked automatically in all logs**. They are
injected only into runs of THIS repo, only for triggers that require write
access to fire (see the security model). Fork PRs never receive secrets
(GitHub-enforced for `pull_request` events).

### 2. External scheduler for the private swarm sweep

The native `schedule` trigger is INTERMITTENT (dead 2026-08-27, partially
revived 2026-08-28 — many registered ticks still miss). `scheduler.yml` on THIS
repo is the PRIMARY driver: cron (public, free) → smart scan of the private
repo's open issues via PAT → dispatch the private lead sweep **only when a
stall is actually detected**. Private quota is spent on real work, not
monitoring cadence.

### 3. Duty roster + the two new duties (Task 45)

The daemon is now a data-driven DUTY ROSTER loop. The roster is fetched LIVE
from the private swarm repo at `.github/roster/repos.json` (same pattern as
`registry.json` — keeps private repo names out of this public source). Fetch
failure → **DEGRADED mode**: the legacy single-repo duties keep running, a loud
`::error` is logged, and one alert comment/day lands on the executor's own
`exec-duty-alert` issue — never a total-abort blackout.

New duties (each independently `always()`-gated; alert issues are latches —
closing one re-arms the lane):

- **fsm-watchdog** — dumb driver for `claudecode-headless/fsm-lab`: reads
  state.json, skips on halted/paused/fresh/in-flight, dispatches the in-repo
  watchdog WORKFLOW via `workflow_dispatch` (the watchdog keeps ALL brains;
  zero fsm-lab code changes), 204-verifies run visibility (10s WARN → 120s
  re-check), and carries a stateless re-prime soft-cap latch (8/6h).
- **mirror-health** — two-class verdict (SILENCE: private status ledger silent
  >26h / RED: ≥6 consecutive non-success mirror-runner runs) with
  transition-only comments and 24h-deduped alerts.
- **duty-health** — per-cycle `/user` canaries on the PATs this workflow holds
  (canary failure = WARNING + alert issue, never a job failure) + scope-drift
  check + board-sync skip marker.

Runtime switches (repo vars, no commit needed; resolution `off > dry > on`):
`EXEC_DUTY_MODE` (global kill/dry), `EXEC_DUTY_ROSTER` (`off` = byte-exact
legacy path), and per-duty `EXEC_STALL_SCAN`, `EXEC_FAILURE_WATCH`,
`EXEC_BOARD_SYNC`, `EXEC_QUOTA_TELEMETRY`, `EXEC_FSM_WATCHDOG`,
`EXEC_MIRROR_HEALTH`, `EXEC_PINGER`. The roster itself can also mark a duty
`"dry": true` (per entry) — the fsm-watchdog entry ships dry-by-default, so
going live is an explicit `EXEC_FSM_WATCHDOG=on` flip, never an accident.
Legacy duty granularity is real: stall-scan and failure-watch are gated
independently inside the monitor scan (fail-open — a roster-step hiccup
never disables them). Helpers live in `scripts/exec-duty-lib.sh`
(alert-latch primitives shared by all duties).

The roster file itself is OPERATOR-EDITED DATA (private swarm repo,
`.github/roster/repos.json`, schema v1) — adding a monitored repo or duty
never touches this repo's code. Slugs of private repos live ONLY in that
private file. Key fields: `stale_after_min` (fsm staleness threshold, 10),
`dry: true` on an entry (lands the duty dry-by-default), `silence_after_h` /
`fail_streak` (mirror-health verdicts), `reprime_softcap`/`reprime_window_h`
(the 8/6h soft-cap latch), `verify_wait_s`/`verify_window_s` (the 204-verify
10s/120s window). Alert issues opened by the duties on THIS repo (label
`exec-duty-alert`; one OPEN issue per class = a latch, closing it re-arms
the lane; bodies carry the 24h-dedup `[exec-duty]` marker):
`duty alert: roster degraded`, `duty alert: mirror-health`,
`duty alert: fsm re-prime storm`, `duty alert: credential dead (C1)`,
`duty alert: credential dead (B1)`, `duty alert: board-sync degraded`,
`duty alert: pinger silent`.

## Security model (READ BEFORE ADDING ANY TRIGGER)

This is a **public** repo. Every workflow run, its logs, and its artifacts are
world-readable. Rules:

1. **Triggers: `workflow_dispatch` + `schedule` + `repository_dispatch` only.** All
   require write access (or an internal timer) to fire. NEVER add:
   - `pull_request_target` — checks out attacker code WITH secrets. Classic
     pwn-request vector.
   - `pull_request` — safe (no secrets for forks) but pointless here; avoid.
   - `issue_comment` — ANY GitHub user can comment on a public repo; the
     write-access gate would hold, but why expose the surface.
   - `workflow_run` — fires after other workflows complete; can indirectly
     chain from fork activity. Avoid.
2. **Log hygiene — assume every logged line is public.** Issue *numbers* are
   fine; titles, bodies, comment text, private file contents, and usernames
   are not. Never `cat` private-repo files into logs; pass results via the
   authenticated API only.
3. **Secrets are masked, not permissioned.** GitHub masks registered secret
   values in logs as a safety net — it is not an access-control system. A
   workflow step that exfiltrates a secret over the network still can.
   Every script in this repo is reviewed with that in mind.
4. **Inputs are pointers, never payloads.** Dispatch inputs are visible in the
   run UI — pass issue/PR numbers, not task text, never credentials.
5. **`permissions: {}` (empty) on every workflow** — no GITHUB_TOKEN use at
   all; cross-repo git goes through deploy keys, cross-repo API through
   `GH_PAT_PRIVATE` (step-scoped) explicitly.
6. **SSH keys exist only inside git steps** and are trap-shredded before any
   agent step (`bypassPermissions` must never see them). Post-agent steps use
   fresh mktemp SSH configs + `GIT_CONFIG_GLOBAL=/dev/null` + `core.hooksPath=/dev/null`
   (the agent-tamper hardening pattern — see one-shot-private.yml).
7. **Prompt inputs are public metadata.** one-shot-private.yml accepts a task
   prompt as a dispatch input — visible in the run UI by design. Dispatch
   non-sensitive prompts only; secrets flow via repo secrets, never inputs.

## Secrets

| Name | Purpose |
|---|---|
| `DEPLOY_KEY_PRIVATE` | RW deploy key on the private repo — the ONE write-capable git secret (one-shot persist step only) |
| `DEPLOY_KEY_REVIEW_RO` | RO deploy key on the private repo — review clones/fetches only |
| `DEPLOY_KEY_KIT_RO` | RO deploy key on the agent-kit submodule repo — submodule fetches |
| `GH_PAT_PRIVATE` | PAT (classic) — API surface ONLY: dispatches, PR-review/comment post-backs; step-scoped |
| `OPENROUTER_API_KEY` | dedicated pool key #4 for executor agent turns (independent rate limits) |
| `SMOKE_TEST_SECRET` | A dummy value used by `smoke.yml` to demonstrate log masking |

## Provenance

- `a2a-marker.mjs` is copied verbatim from the private repo's
  `mcp-web/a2a-marker.mjs` (27/27 unit tests there). If the private parser
  changes, re-copy — the scheduler's correctness depends on marker parity.
