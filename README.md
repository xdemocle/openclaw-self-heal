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
| Cron error detail | per-job name, consecutive count, and last error reason |
| Backup sprawl | `*.bak*` files beyond newest 3 per group |

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
| Backup (`*.bak*`) sprawl | low (keeps newest 3) | **auto** rotate |

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

## Prior art & alternatives considered

We didn't build this in a vacuum. Before and during development we evaluated the existing
OpenClaw self-healing / ops projects. Here's what we found and why we still maintain a
separate, focused skill rather than adopting one wholesale.

| Project | What it is | Why we didn't just reuse it |
|---------|-----------|------------------------------|
| [**openclaw/openclaw#36455**](https://github.com/openclaw/openclaw/issues/36455) | Upstream feature request for a bundled `openclaw-doctor` skill | **Closed as stale, never merged.** No official self-healer exists — so a community/own solution is the only path. |
| [**Ramsbaby/openclaw-self-healing**](https://github.com/Ramsbaby/openclaw-self-healing) (MIT) | Crash-recovery / process **supervision**: watchdog, KeepAlive restart, OOM/zombie cleanup, metrics | Different layer (process supervision vs. our application-domain checks). Its default **auto-restart + auto-config-fix** conflicts with our alert-only-for-risky posture, and it installs a macOS-LaunchAgent watchdog that would collide with our existing `openclaw-gateway.service`. **We ported its complementary host-level checks instead** (config preflight, resources, orphaned-process reaping). |
| [**cathrynlavery/openclaw-ops**](https://github.com/cathrynlavery/openclaw-ops) (MIT) | Broad ops skill: health checks, `heal.sh`, cron inspection, watchdogs, update triage, security scans, session tooling | The most complete alternative and a near-superset — but **more autonomous than we want** (auto-restart, auto-`config set`) and **personalized/macOS-centric** (hardcoded operator paths, LaunchAgent). Adopting it would mean stripping that out and taming its autonomy. **We cherry-picked its best MIT pieces** (per-job cron-error detail, `*.bak*` rotation) into our Linux-native, alert-only base. |
| [**ThisIsJeron/openclaw-better-gateway**](https://github.com/ThisIsJeron/openclaw-better-gateway) | Gateway **web-UI** plugin (auto-refresh, WebSocket) | Out of scope (UI, not ops) and **no LICENSE** (all-rights-reserved), so nothing reusable here. |

**Why a separate skill at all?** Two things none of the above provide together:

1. **An explicit alert-only-for-risky safety model** — we *never* auto-flip the exec-policy
   gate (`tools.exec.mode`), auto-restart the gateway, or auto-restore config. Those are
   detected and reported with the exact command, but applied only by a human.
2. **OpenClaw application-domain checks** — notably **LanceDB embedding-dimension-mismatch**
   detection + gated rebuild, which none of the alternatives cover.

If you want full process supervision / auto-restart / metrics, run **openclaw-ops** or
**openclaw-self-healing** *alongside* this skill — they operate at a layer this one
deliberately leaves alone.

## Credits

Host-level checks (config preflight, host resources, orphaned-browser reaping) are adapted
from [Ramsbaby/openclaw-self-healing](https://github.com/Ramsbaby/openclaw-self-healing) (MIT).
The `*.bak*` rotation and per-job cron-error detail are adapted from
[cathrynlavery/openclaw-ops](https://github.com/cathrynlavery/openclaw-ops) (MIT). Both were
re-tuned to this project's alert-only-for-risky posture. Thanks to both authors.

## License

MIT — see [LICENSE](LICENSE). Portions of `skill/check.sh` and `skill/runbook.md` are adapted
from [Ramsbaby/openclaw-self-healing](https://github.com/Ramsbaby/openclaw-self-healing)
(© 2026 ramsbaby 이정우, MIT) and [cathrynlavery/openclaw-ops](https://github.com/cathrynlavery/openclaw-ops)
(© 2026 Cathryn Lavery, MIT). See [LICENSE](LICENSE) → *Third-Party Attributions*.
