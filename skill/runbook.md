# Self-Heal Runbook — OpenClaw infrastructure

Known failure classes, how `check.sh` detects them, the fix, the smoke test that
confirms resolution, and the **risk class** that decides auto vs. alert-only.

Risk classes:
- **AUTO** — safe, no restart, applied automatically with `--apply`.
- **AUTO+BACKUP** — applied automatically only after a verified backup, and only
  when explicitly enabled (`--allow-rebuild`).
- **ALERT-ONLY** — never auto-applied. Detected, then the operator is messaged with the
  exact one-shot command. These touch a security gate or require a gateway restart.

All commands below were verified against the live host (OpenClaw 2026.6.1).

---

## 1. Plugin / config warnings — `AUTO`
- **Detect:** `openclaw doctor --non-interactive` output contains `warn|deprecat|legacy`.
- **Fix:** `openclaw doctor --non-interactive --fix` (sanctioned normalizer; no restart).
- **Smoke test:** re-run `openclaw doctor --non-interactive`; warnings gone.
- **Why auto:** doctor's own repair path, idempotent, no service bounce.

## 2. Hindsight memory layer health — `ALERT-ONLY`
- **Detect:** curl http://127.0.0.1:8888/health returns non-healthy status or db disconnection.
  Hindsight is the agent's long-term memory (local, Postgres-backed). LanceDB is retired.
- **Fix:** check `systemctl --user status hindsight-api` for crash logs; restart if needed.
  If the database is corrupted, the restore path is operator judgment.
- **Why alert-only:** Hindsight state is critical; a bad rebuild can lose memory. Operator review.

## 3a. Cron `lightContext:true` + `isolated` → runner-entered stall — `AUTO`
- **Detect:** `openclaw cron list --all --json` — jobs where `sessionTarget=="isolated"`
  AND `payload.lightContext==true`. Confirmed pattern: these stall at `runner-entered`
  before execution. All working isolated crons (med reminders) have `lightContext:false`.
- **Fix:** `openclaw cron update <id> --json '{"payload":{"lightContext":false}}'`.
- **Smoke test:** next scheduled run completes without `runner-entered` error.
- **Why auto:** deterministic, no service impact, no restart. Field-confirmed 2026-06-15.

## 3b. Cron Telegram delivery failure ("account main" error) — `AUTO`
- **Detect:** Two signals — (a) `delivery.accountId == "main"` in config, OR (b) `lastError` /
  `lastErrorReason` contains `"account \"main\""` (stale error from the legacy "main" account
  bug, persists even after config is corrected). The Telegram account in this install is
  named `"default"`, not `"main"` — OpenClaw's delivery system would look for the wrong
  account and fail with that exact error string.
- **Fix:** `openclaw cron edit <id> --account default` (re-patching clears the stale error
  state in addition to correcting the config).
- **Smoke test:** next scheduled run delivers without token-missing error.
- **Why auto:** deterministic, no service impact, no restart. Field-confirmed 2026-06-15.

## 3c. Cron delivery failures (generic) — `ALERT-ONLY`
- **Detect:** `openclaw cron list --all --json` — any job with `state.lastStatus == error`
  or `state.consecutiveErrors > 0`. The alert includes the job name, consecutive-error
  count, and the first line of `state.lastError` / `lastErrorReason`
  *(per-job detail adapted from cathrynlavery/openclaw-ops, MIT)*.
- **Why alert:** root causes differ per job (timeout, model error, channel auth, payload).
  No single safe blanket fix.
- **Operator paths:** `openclaw cron get <id>` to inspect, `openclaw cron run <id>`
  to retry once, `openclaw cron runs <id>` for history.

## 4. exec policy `mode: ask` blocking writes — `ALERT-ONLY` (security)
- **Detect:** `openclaw config get tools.exec.mode` == `ask` **and** a write-denied
  signature (`exec denied | requires approval`) in doctor/health/logs.
- **Fix (manual, on the operator's say-so):**
  ```
  openclaw config set tools.exec.mode on-miss   # NOT 'miss' — invalid enum
  openclaw gateway restart                       # full restart; hot-reload is insufficient
  openclaw config get tools.exec.mode            # verify it took
  ```
- **Why alert-only:** flipping this disables a human-confirmation gate **and**
  needs a restart. Both are operator decisions, never automatic.

## 5. Stale binary — `ALERT-ONLY` (restart)
- **Detect:** `openclaw update status` not "up to date".
- **Fix (manual):** `openclaw update && openclaw gateway restart`.
- **Why alert-only:** requires a gateway restart.

## 6. Config integrity / preflight — `ALERT-ONLY` *(ported from Ramsbaby)*
- **Detect:** `openclaw.json` fails JSON parse, or a recent `openclaw.json.clobbered.*`
  snapshot (< 7 days) indicates the config was overwritten/recovered.
- **Fix (manual):** inspect, then
  `cp ~/.openclaw/openclaw.json.last-good ~/.openclaw/openclaw.json && openclaw gateway restart`.
- **Why alert-only:** a config restore + restart is an operator decision.

## 7. Host resource pressure (disk / OOM) — `ALERT-ONLY` *(ported from Ramsbaby)*
- **Detect:** home filesystem ≥ 90% used, or available memory ≤ 10%.
- **Why alert-only:** the right remediation (cleanup vs. scaling) is operator judgment.

## 8. Orphaned browser processes — `AUTO` *(ported from Ramsbaby)*
- **Detect:** headless chrome/chromium/playwright processes reparented to init (ppid 1).
- **Fix:** reap them (TERM, then KILL stragglers). **Smoke test:** none survive.
- **Why auto:** their parent is already dead, so reaping orphans is low-risk and frees
  RAM. Only `ppid == 1` matches — nothing attached to a live gateway is ever touched.

## 9. Backup (`*.bak*`) sprawl — `AUTO` *(adapted from cathrynlavery/openclaw-ops)*
- **Detect:** files containing `.bak` under `~/.openclaw`, grouped by the path prefix
  before the first `.bak`; any group with more than the newest **3** entries.
  (Skips `node_modules`, `npm`, `cache`, `.git` so packaged fixtures are never touched.)
- **Fix:** delete surplus beyond the newest 3 per group. **Smoke test:** count drops to 0.
- **Why auto:** keeps the 3 most recent backups per file; low-risk disk hygiene.

---

## Gateway down / degraded — `ALERT-ONLY`
- **Detect:** `openclaw health` does not report `event loop: ok`.
- **Operator path:** `openclaw gateway status` then `openclaw gateway restart`
  (systemd unit: `openclaw-gateway.service`).

## Adding a new failure class
1. Add detection + (if safe) fix to `check.sh`, mirroring an existing block.
2. Add a section here with detect / fix / smoke / risk-class.
3. If risky, route it through `note_notify`/`note_risk` — never auto-apply.

---

## Foundry boundary

**Self-heal** handles **deterministic OpenClaw infrastructure**: gateway health, cron config, plugin warnings, host resources, binary version, config integrity, backup hygiene. These are factual checks with a known fix — either auto-apply or alert.

**Foundry** handles **tool-level failure patterns**: tool execution failures, retry resolution strategies, outcome tracking, and learned improvements via RISE. These are probabilistic, context-dependent, and managed by the Foundry plugin which injects learned patterns into context.

There is **no overlap**: self-heal reads `lastError` from cron job state (scheduler-level failures), not from tool execution logs. Foundry tracks tool execution outcomes (how a tool failed and what resolved it). The two systems are orthogonal.

**learnings.json** (`~/.openclaw/foundry/learnings.json`) is Foundry's source of truth. Self-heal does not query it — doing so would require hardcoding paths and would duplicate Foundry's RISE injection mechanism, which is the correct way patterns enter the system.

---

## Credits

Classes 6–8 (config preflight, host resource pressure, orphaned-browser reaping) are
adapted from [Ramsbaby/openclaw-self-healing](https://github.com/Ramsbaby/openclaw-self-healing)
(MIT) — a full crash-recovery/supervision layer.

Class 9 (backup rotation) and the per-job cron-error detail in class 3 are adapted from
[cathrynlavery/openclaw-ops](https://github.com/cathrynlavery/openclaw-ops) (MIT) — a
broad OpenClaw operations skill.

In both cases we ported only the pieces that complement our OpenClaw-domain focus, re-tuned
to our alert-only-for-risky posture (config restore and restarts stay manual here).
