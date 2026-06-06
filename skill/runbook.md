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

## 2. Embedding dimension mismatch (LanceDB recall) — `AUTO+BACKUP`
- **Detect:** log signatures `dimension mismatch | expected dim | recall failed`,
  or missing `~/.openclaw/memory/lancedb/memories.lance`.
- **Fix (gated):** back up `memory/lancedb` → `~/.openclaw/backups/lancedb-<ts>.tgz`,
  then re-run `~/.openclaw/scripts/migrate-memories-to-lancedb.sh`.
- **Smoke test:** error signature absent from logs after rebuild.
- **Why gated:** a rebuild rewrites the vector store. The script refuses to proceed
  unless the backup succeeded, and only runs at all with `--allow-rebuild`.
  > ⚠️ The exact rebuild procedure here is **candidate, not yet field-verified** on a
  > real mismatch. Confirm against a real incident before trusting it unattended.

## 3. Cron delivery failures — `ALERT-ONLY`
- **Detect:** any job shows `error` in `openclaw cron list`.
- **Why alert:** root causes differ per job (model error, channel auth, payload).
  No single safe blanket fix. The alert names the failing job IDs.
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

---

## Gateway down / degraded — `ALERT-ONLY`
- **Detect:** `openclaw health` does not report `event loop: ok`.
- **Operator path:** `openclaw gateway status` then `openclaw gateway restart`
  (systemd unit: `openclaw-gateway.service`).

## Adding a new failure class
1. Add detection + (if safe) fix to `check.sh`, mirroring an existing block.
2. Add a section here with detect / fix / smoke / risk-class.
3. If risky, route it through `note_notify`/`note_risk` — never auto-apply.
