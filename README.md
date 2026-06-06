# openclaw-self-heal

Autonomous self-healing skill for [OpenClaw](https://openclaw.ai) infrastructure.

It runs on a cron schedule, probes the things that actually break, **auto-applies
only the safe fixes**, confirms them with a smoke test, and messages the operator
**only** when an issue is novel or a fix is risky (security-gate change or a service
restart). When everything is healthy — or was safely auto-fixed — it stays silent.

## What it checks

| Area | Probe |
|------|-------|
| Gateway health | `openclaw health` reports `event loop: ok` |
| Bot connectivity | Telegram channel configured |
| LanceDB recall | embedding dimension-mismatch signatures / table present |
| Cron delivery | any job in `error` state |
| Config integrity | `openclaw.json` parses + no recent `.clobbered` snapshot |
| Host resources | home disk < 90%, available memory > 10% |
| Orphaned browser procs | headless chrome/playwright reparented to init |

## Failure classes & autonomy model

| Class | Risk | Action |
|-------|------|--------|
| Plugin/config warnings | safe | **auto** `doctor --fix` + smoke test |
| Embedding dimension mismatch (LanceDB) | safe *after backup* | **auto, gated** behind `--allow-rebuild`, always backs up first |
| Cron delivery failure | varies | **alert-only** (per-job causes differ) |
| exec policy `mode: ask` blocking writes | security gate + restart | **alert-only** — never auto-flips the gate |
| Stale binary | restart | **alert-only** |
| Gateway down | restart | **alert-only** |
| Config corrupt / clobbered | restart | **alert-only** |
| Disk / memory pressure | varies | **alert-only** |
| Orphaned browser processes | low (parent already dead) | **auto** reap (ppid 1 only) |

The guiding rule: **never auto-disable a human-confirmation gate and never restart a
live service unattended.** Those are detected and reported with the exact command,
but applied only by a human.

## Files

- `skill/SKILL.md` — the agent workflow (what cron runs).
- `skill/runbook.md` — per-class detect → fix → smoke test → risk class.
- `skill/check.sh` — deterministic probe + safe auto-remediation engine. Emits a
  machine-readable `SUMMARY {…}` line; exits `10` when the operator should be told.

## Install

Copy (or symlink) the skill into your OpenClaw skills directory:

```bash
git clone https://github.com/xdemocle/openclaw-self-heal.git
ln -s "$PWD/openclaw-self-heal/skill" ~/.openclaw/skills/self-heal
```

Run the probe by hand:

```bash
bash ~/.openclaw/skills/self-heal/check.sh            # read-only
bash ~/.openclaw/skills/self-heal/check.sh --apply    # + safe auto-fixes
```

## Schedule it (every 30 min)

Set `<YOUR_TELEGRAM_CHAT_ID>` to the chat the alerts should go to:

```bash
openclaw cron add \
  --name "healthcheck:self-heal" \
  --cron "*/30 * * * *" --tz "Europe/Rome" \
  --agent main --session isolated \
  --timeout-seconds 600 --no-deliver \
  --description "Autonomous OpenClaw self-heal: probe + safe auto-fix, alert only on novel/risky" \
  --message 'Run the self-heal skill at ~/.openclaw/skills/self-heal/SKILL.md. Execute: bash ~/.openclaw/skills/self-heal/check.sh --apply ; then follow the SKILL workflow — parse the SUMMARY line and message Telegram <YOUR_TELEGRAM_CHAT_ID> ONLY if notify==1, including exact risky-fix commands WITHOUT running them. Stay silent if healthy.'
```

`--allow-rebuild` is intentionally **off** by default — enable it only once the
LanceDB rebuild procedure is field-verified against a real incident.

## Roadmap

- Package as an installable OpenClaw / npm plugin.
- Parameterize the chat id and timezone via skill config rather than the cron message.
- Field-verify the LanceDB rebuild path before allowing it unattended.

## Credits

The config-preflight, host-resource, and orphaned-browser-reaping checks are adapted
from [Ramsbaby/openclaw-self-healing](https://github.com/Ramsbaby/openclaw-self-healing)
(MIT) — a full crash-recovery/supervision system for OpenClaw. This project focuses on
the OpenClaw **application** layer (memory recall, cron delivery, exec policy) and ports
only the complementary host-level checks, re-tuned to an alert-only-for-risky posture.
If you need process supervision / auto-restart / metrics, use their project alongside
this one.

## License

MIT — see [LICENSE](LICENSE). Portions of `skill/check.sh` and `skill/runbook.md`
(config-preflight, host-resource, and orphaned-browser checks) are adapted from
[Ramsbaby/openclaw-self-healing](https://github.com/Ramsbaby/openclaw-self-healing),
© 2026 ramsbaby (이정우), MIT. See [LICENSE](LICENSE) → *Third-Party Attributions*.
