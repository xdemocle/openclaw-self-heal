#!/usr/bin/env bash
# self-heal/check.sh — OpenClaw infrastructure health probe + safe auto-remediation.
#
# Design contract (agreed with operator):
#   - AUTO-FIX only SAFE classes (plugin-warning normalization; embedding rebuild
#     ONLY with an explicit flag, and always after a backup).
#   - ALERT-ONLY for RISKY classes (exec-policy mode change, anything needing a
#     gateway restart, stale-binary update). Never auto-applied.
#   - Every command below was verified against the live box; nothing invented.
#
# Exit codes: 0 = all healthy (or all issues safely auto-fixed)
#             10 = issues remain that need operator attention (NOTIFY)
#             2  = the probe itself failed to run
#
# Usage:
#   check.sh                 # read-only probe, prints report
#   check.sh --apply         # also apply SAFE auto-fixes
#   check.sh --apply --allow-rebuild   # additionally allow LanceDB rebuild (after backup)
#
# Machine-readable summary is emitted on the last line as: SUMMARY <json>

set -uo pipefail

APPLY=0
ALLOW_REBUILD=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --allow-rebuild) ALLOW_REBUILD=1 ;;
  esac
done

OC=openclaw
STATE="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
LANCE="$STATE/memory/lancedb"
LOGDIR="$STATE/logs"
BACKUPS="$STATE/backups"
TS="$(date +%Y%m%d-%H%M%S)"

# Strip the plugin banner noise the CLI prints to stdout, plus ANSI.
oc_clean() { sed 's/\x1b\[[0-9;]*m//g' | grep -vE '\[(plugins|foundry|safety-guards|agent-state-writer)\]|memory-lancedb: plugin|Recorded insight|Overseer|Autonomous overseer|Initial overseer'; }

ISSUES=()        # human-readable
FIXED=()         # auto-fixed this run
NOTIFY=()        # require operator attention (novel or risky)
RISK=()          # risky-fix descriptions for the alert

note_issue()  { ISSUES+=("$1"); }
note_fixed()  { FIXED+=("$1"); }
note_notify() { NOTIFY+=("$1"); }
note_risk()   { RISK+=("$1"); }

section() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. GATEWAY HEALTH
# ---------------------------------------------------------------------------
section "gateway health"
HEALTH="$($OC health 2>&1 | oc_clean)"
if printf '%s' "$HEALTH" | grep -qiE 'event loop: ok'; then
  echo "gateway: OK"
else
  echo "gateway: DEGRADED"
  note_issue "Gateway health probe did not report 'event loop: ok'."
  note_notify "Gateway degraded/unreachable — needs operator (restart is risky)."
  note_risk "Gateway may need: openclaw gateway restart"
fi

# ---------------------------------------------------------------------------
# 2. BOT / CHANNEL CONNECTIVITY
# ---------------------------------------------------------------------------
section "bot connectivity"
if printf '%s' "$HEALTH" | grep -qiE 'Telegram: configured'; then
  echo "telegram: configured"
else
  echo "telegram: NOT configured"
  note_issue "Telegram channel not reported as configured in health output."
  note_notify "Telegram channel down — operator check (re-login is risky/manual)."
fi

# ---------------------------------------------------------------------------
# 3. LANCEDB RECALL ERRORS  (embedding dimension mismatch class)
# ---------------------------------------------------------------------------
section "lancedb recall"
DIM_HIT=0
if [ -d "$LOGDIR" ]; then
  # signatures of an embedding-dimension / vector-shape failure
  if grep -rilE 'dimension mismatch|expected dim|vector .*(length|dim).*(mismatch|differ)|wrong dimension|recall failed' "$LOGDIR" 2>/dev/null | grep -q .; then
    DIM_HIT=1
  fi
fi
if [ ! -d "$LANCE/memories.lance" ]; then
  echo "lancedb: table missing ($LANCE/memories.lance)"
  note_issue "LanceDB memories table missing."
  note_notify "LanceDB table missing — operator review before rebuild."
elif [ "$DIM_HIT" = 1 ]; then
  echo "lancedb: dimension-mismatch signature found in logs"
  note_issue "Embedding dimension mismatch detected in logs."
  if [ "$APPLY" = 1 ] && [ "$ALLOW_REBUILD" = 1 ]; then
    mkdir -p "$BACKUPS"
    BK="$BACKUPS/lancedb-$TS.tgz"
    if tar -czf "$BK" -C "$STATE/memory" lancedb 2>/dev/null; then
      echo "lancedb: backed up -> $BK"
      MIG="$STATE/scripts/migrate-memories-to-lancedb.sh"
      if [ -x "$MIG" ] && "$MIG" >/dev/null 2>&1; then
        # smoke test: signature gone after rebuild?
        if grep -rilE 'dimension mismatch|recall failed' "$LOGDIR" 2>/dev/null | grep -q .; then
          note_notify "LanceDB rebuild ran but error signature persists — escalate."
        else
          note_fixed "LanceDB rebuilt from migration script (backup: $BK)."
        fi
      else
        note_notify "LanceDB rebuild script missing/failed — backup at $BK, operator needed."
      fi
    else
      note_notify "LanceDB backup failed — refusing to rebuild. Operator needed."
    fi
  else
    note_notify "Embedding dimension mismatch — rebuild gated (run with --apply --allow-rebuild)."
  fi
else
  echo "lancedb: OK"
fi

# ---------------------------------------------------------------------------
# 4. CRON DELIVERY STATUS
# ---------------------------------------------------------------------------
section "cron delivery"
CRON="$($OC cron list 2>&1 | oc_clean)"
# Status column == 'error' for any job?
ERR_JOBS="$(printf '%s\n' "$CRON" | awk '$0 ~ /[[:space:]]error[[:space:]]/ {print}')"
if [ -n "$ERR_JOBS" ]; then
  N=$(printf '%s\n' "$ERR_JOBS" | grep -c .)
  echo "cron: $N job(s) in error state"
  note_issue "$N cron job(s) reporting error status."
  note_notify "Cron job(s) in error — operator review (per-job failures vary)."
else
  echo "cron: no jobs in error state"
fi

# ---------------------------------------------------------------------------
# 5. PLUGIN WARNINGS  (SAFE auto-fix via doctor)
# ---------------------------------------------------------------------------
section "plugin warnings"
DOC="$($OC doctor --non-interactive 2>&1 | oc_clean)"
if printf '%s' "$DOC" | grep -qiE 'warn|warning|deprecat|legacy'; then
  echo "doctor: warnings present"
  note_issue "Plugin/config warnings reported by doctor."
  if [ "$APPLY" = 1 ]; then
    if $OC doctor --non-interactive --fix >/dev/null 2>&1; then
      # smoke test: warnings cleared?
      if $OC doctor --non-interactive 2>&1 | oc_clean | grep -qiE 'warn|warning|deprecat|legacy'; then
        note_notify "doctor --fix ran but warnings remain — operator review."
      else
        note_fixed "Plugin/config warnings cleared via 'doctor --fix'."
      fi
    else
      note_notify "'doctor --fix' failed — operator review."
    fi
  fi
else
  echo "doctor: clean"
fi

# ---------------------------------------------------------------------------
# 6. EXEC POLICY mode:ask blocking writes  (RISKY -> ALERT ONLY, never auto)
# ---------------------------------------------------------------------------
section "exec policy"
EXMODE="$($OC config get tools.exec.mode 2>&1 | oc_clean | tail -1 | tr -d ' "')"
echo "tools.exec.mode = ${EXMODE:-unknown}"
if [ "$EXMODE" = "ask" ]; then
  # only a *problem* if writes are actually being denied — look for the signature
  if printf '%s' "$DOC$HEALTH" | grep -qiE 'exec denied|requires approval|blocked.*write' \
     || grep -rilE 'exec denied|requires approval' "$LOGDIR" 2>/dev/null | grep -q .; then
    note_issue "exec mode 'ask' appears to be blocking writes."
    note_notify "exec policy mode:ask is blocking writes."
    note_risk "RISKY (security gate + restart) — apply manually if intended: openclaw config set tools.exec.mode on-miss && openclaw gateway restart"
  fi
fi

# ---------------------------------------------------------------------------
# 7. STALE BINARY  (RISKY -> ALERT ONLY, needs restart)
# ---------------------------------------------------------------------------
section "binary version"
UPD="$($OC update status 2>&1 | oc_clean)"
if printf '%s' "$UPD" | grep -qiE 'up to date'; then
  echo "binary: up to date"
else
  echo "binary: update available"
  note_issue "OpenClaw binary not up to date."
  note_notify "Stale binary — update available."
  note_risk "RISKY (restart) — apply manually if intended: openclaw update && openclaw gateway restart"
fi

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
section "summary"
printf 'issues=%d  auto-fixed=%d  needs-operator=%d\n' "${#ISSUES[@]}" "${#FIXED[@]}" "${#NOTIFY[@]}"
[ ${#FIXED[@]}  -gt 0 ] && { echo "AUTO-FIXED:"; printf '  - %s\n' "${FIXED[@]}"; }
[ ${#NOTIFY[@]} -gt 0 ] && { echo "NEEDS OPERATOR:"; printf '  - %s\n' "${NOTIFY[@]}"; }
[ ${#RISK[@]}   -gt 0 ] && { echo "RISKY FIXES (manual):"; printf '  - %s\n' "${RISK[@]}"; }

# JSON summary for the agent wrapper. Escapes are minimal (descriptions are ASCII).
json_arr() { local out="" first=1; for x in "$@"; do x=${x//\"/\'}; if [ $first = 1 ]; then out="\"$x\""; first=0; else out="$out,\"$x\""; fi; done; printf '[%s]' "$out"; }
NOTIFY_FLAG=0; [ ${#NOTIFY[@]} -gt 0 ] && NOTIFY_FLAG=1
printf 'SUMMARY {"notify":%d,"fixed":%s,"needs_operator":%s,"risky":%s}\n' \
  "$NOTIFY_FLAG" "$(json_arr "${FIXED[@]}")" "$(json_arr "${NOTIFY[@]}")" "$(json_arr "${RISK[@]}")"

[ "$NOTIFY_FLAG" = 1 ] && exit 10
exit 0
