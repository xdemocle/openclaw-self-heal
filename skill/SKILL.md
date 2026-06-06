---
name: self-heal
description: Autonomous OpenClaw self-healing. Probes gateway health, bot connectivity, LanceDB recall, cron delivery, config integrity, host resources (disk/OOM), and orphaned browser processes; auto-applies SAFE fixes from the runbook (plugin-warning normalization, orphaned-process reaping, gated LanceDB rebuild); messages the operator ONLY for novel issues or risky fixes (exec-policy change, config restore, restarts). Use on a cron schedule or when the operator asks to "check infra" / "self-heal".
---

# Self-Heal — OpenClaw infrastructure

**For agent use, typically via cron.** Diagnoses known failure classes, applies the
verified safe fixes, confirms with a smoke test, and stays quiet unless something
genuinely needs the operator.

## Files
- `check.sh` — deterministic probe + safe auto-remediation engine.
- `runbook.md` — the known failure classes, fixes, smoke tests, and risk classes.

## Workflow

1. **Run the probe with safe auto-fix enabled:**
   ```bash
   bash ~/.openclaw/skills/self-heal/check.sh --apply
   ```
   (Add `--allow-rebuild` only if the operator has explicitly authorized unattended
   LanceDB rebuilds — otherwise leave it off; the probe will alert instead.)

2. **Read the last line** — `SUMMARY {...}` JSON:
   - `notify` — 1 if operator attention is needed, 0 if not.
   - `fixed` — safe fixes already applied this run.
   - `needs_operator` — issues that were NOT auto-fixed (novel or risky).
   - `risky` — exact one-shot commands for risky fixes (exec-policy, updates, restart).

3. **Decide whether to message the operator — this is the whole point of the skill:**
   - **`notify` == 0** → Stay SILENT. Do not send anything. (Optionally log a one-line
     "all green / N safe fixes applied" to the run output, but do not message.)
   - **`notify` == 1** → Send ONE concise Telegram message to the operator's
     configured chat id (supplied by the cron job's message, e.g. `$SELF_HEAL_CHAT_ID`):
     - What is wrong (the `needs_operator` items).
     - What was already auto-fixed (the `fixed` items), if any.
     - For each `risky` item, the **exact command** to run — but DO NOT run it
       yourself. Risky fixes (exec-policy `mode` change, `openclaw update`, any
       `openclaw gateway restart`) are operator-approved only.

4. **Never** auto-change `tools.exec.mode`, never `openclaw gateway restart`, never
   `openclaw update` on your own. Detect → report → wait for the operator.

## Message format (only when notify==1)

```
⚠️ OpenClaw self-heal — action needed
Issues: <needs_operator joined>
Auto-fixed: <fixed joined, or "none">
Run to fix (review first):
  <each risky command on its own line>
```

Keep it short. No IPs or sensitive host details.

## Notes
- The probe strips the noisy plugin banner the CLI prints; trust its `SUMMARY` line.
- Exit code 10 also signals "notify"; 0 means healthy/auto-resolved.
- To extend coverage, edit `check.sh` + `runbook.md` together (see runbook's last section).
