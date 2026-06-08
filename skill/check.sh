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
# 4. CRON DELIVERY STATUS   [per-job error detail adapted from cathrynlavery/openclaw-ops, MIT]
# ---------------------------------------------------------------------------
section "cron delivery"
CRON_F="$(mktemp)"
$OC cron list --all --json >"$CRON_F" 2>/dev/null
CRON_ERR=""
if [ -s "$CRON_F" ]; then
  # Pass the JSON as a file arg (NOT stdin — stdin is the heredoc script).
  CRON_ERR="$(python3 - "$CRON_F" <<'PY' 2>/dev/null
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
jobs = d if isinstance(d, list) else d.get("jobs", d)
for j in jobs:
    st = j.get("state", {}) or {}
    if st.get("lastStatus") == "error" or st.get("consecutiveErrors", 0) > 0:
        name = (j.get("name") or j.get("id", "?"))[:40]
        err = (st.get("lastError") or st.get("lastErrorReason") or "unknown").splitlines()[0][:90]
        print(f"{name} (x{st.get('consecutiveErrors', 0)}): {err}")
PY
)"
else
  # Fallback to text table if --json is unavailable on older builds.
  CRON_ERR="$($OC cron list 2>&1 | oc_clean | awk '$0 ~ /[[:space:]]error[[:space:]]/ {print "(job in error — run: openclaw cron list)"}')"
fi
rm -f "$CRON_F"
if [ -n "$CRON_ERR" ]; then
  N=$(printf '%s\n' "$CRON_ERR" | grep -c .)
  echo "cron: $N job(s) in error state"
  while IFS= read -r l; do echo "  • $l"; done <<< "$CRON_ERR"
  note_issue "$N cron job(s) in error."
  DETAIL="$(printf '%s\n' "$CRON_ERR" | head -3 | paste -sd'; ' -)"
  note_notify "Cron error(s): $DETAIL"
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
# 8. CONFIG INTEGRITY (preflight)   [concept ported from Ramsbaby/openclaw-self-healing, MIT]
# ---------------------------------------------------------------------------
section "config integrity"
CFG="$STATE/openclaw.json"
if ! python3 -c "import json; json.load(open('$CFG'))" 2>/dev/null; then
  echo "config: openclaw.json is NOT valid JSON"
  note_issue "openclaw.json failed JSON parse."
  note_notify "Config corrupt (openclaw.json invalid) — restore needed (risky, restart)."
  note_risk "RISKY (restart) — inspect, then: cp ~/.openclaw/openclaw.json.last-good ~/.openclaw/openclaw.json && openclaw gateway restart"
else
  echo "config: openclaw.json valid"
fi
CLOB=$(find "$STATE" -maxdepth 1 -name 'openclaw.json.clobbered.*' -newermt '-7 days' 2>/dev/null | wc -l | tr -d ' ')
if [ "${CLOB:-0}" -gt 0 ]; then
  echo "config: $CLOB clobbered snapshot(s) in last 7d"
  note_issue "$CLOB recent openclaw.json.clobbered.* snapshot(s)."
  note_notify "Config was clobbered recently ($CLOB in 7d) — review for instability."
fi

# ---------------------------------------------------------------------------
# 9. HOST RESOURCES (disk / OOM pressure)   [concept ported from Ramsbaby, MIT]
# ---------------------------------------------------------------------------
section "host resources"
DISK_PCT=$(df -P "$HOME" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
echo "disk(home): ${DISK_PCT:-?}% used"
if [ "${DISK_PCT:-0}" -ge 90 ]; then
  note_issue "Home filesystem at ${DISK_PCT}%."
  note_notify "Disk pressure: home fs at ${DISK_PCT}% (>=90%)."
fi
if command -v free >/dev/null 2>&1; then
  MEM_AVAIL_PCT=$(free | awk '/^Mem:/{printf "%d", $7/$2*100}')
  echo "mem available: ${MEM_AVAIL_PCT:-?}%"
  if [ "${MEM_AVAIL_PCT:-100}" -le 10 ]; then
    note_issue "Available memory at ${MEM_AVAIL_PCT}%."
    note_notify "Memory pressure: only ${MEM_AVAIL_PCT}% available (OOM risk)."
  fi
fi

# ---------------------------------------------------------------------------
# 10. ORPHANED BROWSER PROCESSES (zombie Chrome/Playwright)   [ported from Ramsbaby, MIT]
#     SAFE auto-fix: reap ONLY browser procs reparented to init (ppid 1).
# ---------------------------------------------------------------------------
section "orphaned browser procs"
mapfile -t ORPHANS < <(ps -eo pid=,ppid=,args= | awk '$2==1 && (tolower($0) ~ /chrom(e|ium)|playwright/) && (tolower($0) ~ /headless|--type=/) {print $1}')
echo "orphaned browser procs: ${#ORPHANS[@]}"
if [ "${#ORPHANS[@]}" -gt 0 ]; then
  note_issue "${#ORPHANS[@]} orphaned browser process(es) detected."
  if [ "$APPLY" = 1 ]; then
    kill "${ORPHANS[@]}" 2>/dev/null
    sleep 2
    LEFT=0; for p in "${ORPHANS[@]}"; do kill -0 "$p" 2>/dev/null && LEFT=$((LEFT+1)); done
    [ "$LEFT" -gt 0 ] && kill -9 "${ORPHANS[@]}" 2>/dev/null
    note_fixed "Reaped ${#ORPHANS[@]} orphaned browser process(es)$([ "$LEFT" -gt 0 ] && echo " (force-killed $LEFT)")."
  else
    note_notify "Orphaned browser processes present — run with --apply to reap."
  fi
fi

# ---------------------------------------------------------------------------
# 11. BACKUP (*.bak*) ROTATION   [adapted from cathrynlavery/openclaw-ops, MIT]
#     SAFE auto-fix: keep newest N per group; delete older surplus.
# ---------------------------------------------------------------------------
section "backup rotation"
BAK_KEEP=3
BAK_PLAN="$(python3 - "$STATE" "$BAK_KEEP" <<'PY' 2>/dev/null
import os, sys
root, keep = sys.argv[1], int(sys.argv[2])
groups = {}
for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in ('node_modules', 'npm', 'cache', '.git')]
    for f in files:
        if '.bak' in f:
            p = os.path.join(dirpath, f)
            key = p[:p.index('.bak')]            # group by path prefix before first .bak
            try: mt = os.path.getmtime(p)
            except OSError: continue
            groups.setdefault(key, []).append((mt, p))
for key, items in groups.items():
    items.sort(reverse=True)                      # newest first
    for _, p in items[keep:]:                     # surplus = everything past newest N
        try: print(f"{os.path.getsize(p)}\t{p}")
        except OSError: pass
PY
)"
if [ -n "$BAK_PLAN" ]; then
  CNT=$(printf '%s\n' "$BAK_PLAN" | grep -c .)
  BYTES=$(printf '%s\n' "$BAK_PLAN" | awk -F'\t' '{s+=$1} END{print s+0}')
  HUMAN=$(awk -v b="$BYTES" 'BEGIN{u="B";if(b>1048576){b/=1048576;u="MB"}else if(b>1024){b/=1024;u="KB"}printf "%.1f%s",b,u}')
  echo "backups: $CNT surplus *.bak* file(s) beyond newest $BAK_KEEP/group (~$HUMAN)"
  note_issue "$CNT surplus backup file(s) (~$HUMAN reclaimable)."
  if [ "$APPLY" = 1 ]; then
    printf '%s\n' "$BAK_PLAN" | cut -f2- | while IFS= read -r f; do rm -f "$f"; done
    note_fixed "Rotated backups: removed $CNT surplus *.bak* file(s), freed ~$HUMAN."
  else
    note_notify "Backup sprawl: $CNT surplus *.bak* file(s) (~$HUMAN) — run with --apply to rotate."
  fi
else
  echo "backups: within retention (newest $BAK_KEEP/group)"
fi

# ---------------------------------------------------------------------------
# DEDUP: avoid re-pinging the same needs_operator item every cycle.
# New fingerprints always notify. Repeated fingerprints notify at most once
# per 24h. Risky items (RISK array non-empty) force-notify everything, so
# security-gate / restart-class fixes are never silently suppressed.
# ---------------------------------------------------------------------------
NOTIFY_STATE="$STATE/state/self-heal-notify-state.json"
REPEAT_SUPPRESS_SEC=$((24 * 3600))

# Snapshot full list BEFORE filtering (used in report + summary + state)
NEEDS_ALL=("${NOTIFY[@]}")

# Load lastNotifiedAt epoch per fingerprint from state file
declare -A NS_LAST=()
if [ -f "$NOTIFY_STATE" ]; then
  while IFS=$'\t' read -r fp ep; do
    [ -n "$fp" ] && NS_LAST["$fp"]="${ep:-0}"
  done < <(python3 - "$NOTIFY_STATE" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for fp, v in (d.get('items') or {}).items():
        ln = v.get('lastNotifiedAt') or ''
        ep = 0
        if ln:
            try:
                from datetime import datetime
                ep = int(datetime.fromisoformat(ln.replace('Z','+00:00')).timestamp())
            except Exception: ep = 0
        print(f"{fp}\t{ep}")
except Exception: pass
PY
)
fi
NOW_EPOCH=$(date +%s)

# If any risky item present, force-notify all (operator must see security/restart)
FORCE_NOTIFY=0
[ ${#RISK[@]} -gt 0 ] && FORCE_NOTIFY=1

NEW_NOTIFY=()
DEDUPED_LIST=()
for item in "${NEEDS_ALL[@]}"; do
  if [ "$FORCE_NOTIFY" = 1 ]; then
    NEW_NOTIFY+=("$item")
    continue
  fi
  FP="$(printf '%s' "$item" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])')"
  LAST="${NS_LAST[$FP]:-0}"
  if [ "$LAST" = 0 ] || [ $((NOW_EPOCH - LAST)) -ge "$REPEAT_SUPPRESS_SEC" ]; then
    NEW_NOTIFY+=("$item")
  else
    DEDUPED_LIST+=("$item")
  fi
done
NOTIFY=("${NEW_NOTIFY[@]}")
DEDUPED=("${DEDUPED_LIST[@]}")

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
section "summary"
printf 'issues=%d  auto-fixed=%d  needs-operator=%d  (deduped=%d)\n' \
  "${#ISSUES[@]}" "${#FIXED[@]}" "${#NEEDS_ALL[@]}" "${#DEDUPED[@]}"
[ ${#FIXED[@]}     -gt 0 ] && { echo "AUTO-FIXED:";                       printf '  - %s\n' "${FIXED[@]}"; }
[ ${#NEEDS_ALL[@]} -gt 0 ] && { echo "NEEDS OPERATOR:";                  printf '  - %s\n' "${NEEDS_ALL[@]}"; }
[ ${#RISK[@]}      -gt 0 ] && { echo "RISKY FIXES (manual):";            printf '  - %s\n' "${RISK[@]}"; }
[ ${#DEDUPED[@]}   -gt 0 ] && { echo "DEDUPED (silently re-observed, last ping < 24h):"; printf '  - %s\n' "${DEDUPED[@]}"; }

# JSON summary for the agent wrapper. Escapes are minimal (descriptions are ASCII).
json_arr() { local out="" first=1; for x in "$@"; do x=${x//\"/\'}; if [ $first = 1 ]; then out="\"$x\""; first=0; else out="$out,\"$x\""; fi; done; printf '[%s]' "$out"; }
NOTIFY_FLAG=0
[ ${#NOTIFY[@]} -gt 0 ] && NOTIFY_FLAG=1
[ ${#RISK[@]}   -gt 0 ] && NOTIFY_FLAG=1
printf 'SUMMARY {"notify":%d,"fixed":%s,"needs_operator":%s,"risky":%s,"deduped_count":%d}\n' \
  "$NOTIFY_FLAG" "$(json_arr "${FIXED[@]}")" "$(json_arr "${NEEDS_ALL[@]}")" "$(json_arr "${RISK[@]}")" "${#DEDUPED[@]}"

# ---------------------------------------------------------------------------
# PERSIST DEDUP STATE
# ---------------------------------------------------------------------------
python3 - "$NOTIFY_STATE" "$NOW_EPOCH" "---NEW---" "${NEW_NOTIFY[@]}" "---ALL---" "${NEEDS_ALL[@]}" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone
import hashlib
state_path = sys.argv[1]
now_epoch = int(sys.argv[2])
mode = 'none'
new_items, all_items = [], []
for arg in sys.argv[3:]:
    if arg == '---NEW---': mode = 'new'
    elif arg == '---ALL---': mode = 'all'
    elif mode == 'new': new_items.append(arg)
    elif mode == 'all': all_items.append(arg)
now_iso = datetime.fromtimestamp(now_epoch, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
new_fps = {hashlib.sha256(x.encode()).hexdigest()[:12] for x in new_items}
try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {'schemaVersion': 1, 'items': {}}
except Exception:
    state = {'schemaVersion': 1, 'items': {}}
state.setdefault('items', {})
for item in all_items:
    fp = hashlib.sha256(item.encode()).hexdigest()[:12]
    entry = state['items'].get(fp, {})
    if 'firstSeenAt' not in entry:
        entry['firstSeenAt'] = now_iso
    entry['lastSeenAt'] = now_iso
    entry['example'] = item[:200]
    if fp in new_fps:
        entry['lastNotifiedAt'] = now_iso
        entry['notifyCount'] = entry.get('notifyCount', 0) + 1
    state['items'][fp] = entry
os.makedirs(os.path.dirname(state_path), exist_ok=True)
with open(state_path, 'w') as f:
    json.dump(state, f, indent=2, sort_keys=True)
PY

[ "$NOTIFY_FLAG" = 1 ] && exit 10
exit 0
