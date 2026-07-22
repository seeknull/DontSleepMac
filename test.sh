#!/usr/bin/env bash
# Automated integration tests for DontSleepMac.
#
# These validate the real system behavior the app relies on:
#   1. caffeinate -d prevents DISPLAY sleep (red state)
#   2. caffeinate -i keeps the system awake with display free (amber state)
#   3. releasing an assertion returns to normal (grey state)
#   4. external holders are detectable by process name (the "who's holding it" feature)
#   5. a real workload keeps running past sleep thresholds (no stalls)
#
# Run on battery AND on AC. Usage: ./test.sh  [--quick]
set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1

src()  { pmset -g batt | grep -o "'.*Power'" | tr -d "'"; }
disp() { pmset -g assertions | awk '/PreventUserIdleDisplaySleep/ {print $2; exit}'; }
sys()  { pmset -g assertions | awk '/PreventUserIdleSystemSleep/ {print $2; exit}'; }
# system held by a REAL source (not the incidental powerd/coreaudiod)?
held_by_real() {
  pmset -g assertions | grep -E "pid [0-9]+" \
    | grep -E "PreventUserIdleSystemSleep|PreventSystemSleep|PreventUserIdleDisplaySleep" \
    | grep -vE "powerd|coreaudiod" | grep -oE "\(([a-zA-Z0-9._-]+)\)" | tr -d '()' | sort -u
}

ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
check(){ [ "$2" = "$3" ] && ok "$1 (=$2)" || bad "$1 (got '$2', want '$3')"; }

cleanup(){ pkill -x caffeinate 2>/dev/null; }
trap cleanup EXIT
cleanup; sleep 1

echo "======================================================"
echo " DontSleepMac test suite   [power: $(src)]"
echo "======================================================"

echo ""
echo "[1] Baseline: nothing should prevent DISPLAY sleep"
check "display not prevented at rest" "$(disp)" "0"

echo ""
echo "[2] caffeinate -d  → DISPLAY-ON (red) state"
caffeinate -d & D=$!; sleep 2
check "display prevented"        "$(disp)" "1"
if held_by_real | grep -q caffeinate; then ok "caffeinate detected as holder"; else bad "caffeinate not detected as holder"; fi
kill $D 2>/dev/null; wait $D 2>/dev/null; sleep 2
check "display released after kill" "$(disp)" "0"

echo ""
echo "[3] caffeinate -i  → SCREEN-OFF-AWAKE (amber) state"
caffeinate -i & I=$!; sleep 2
check "display NOT prevented (screen free)" "$(disp)" "0"
check "system prevented"                    "$(sys)"  "1"
if held_by_real | grep -q caffeinate; then ok "amber holder detected"; else bad "amber holder not detected"; fi
kill $I 2>/dev/null; sleep 2

echo ""
echo "[4] 'Who is holding it' — external holder is nameable"
caffeinate -d & D=$!; sleep 2
HOLDERS="$(held_by_real | paste -sd, -)"
if echo "$HOLDERS" | grep -q caffeinate; then ok "holder name reported: $HOLDERS"; else bad "no holder name (got: '$HOLDERS')"; fi
kill $D 2>/dev/null; wait $D 2>/dev/null; sleep 1

echo ""
echo "[5] Back to normal (grey) after all released"
check "display normal" "$(disp)" "0"
if held_by_real | grep -q .; then bad "something still holding: $(held_by_real|paste -sd, -)"; else ok "no real holders — grey"; fi

if [ "$QUICK" = "0" ]; then
  echo ""
  echo "[6] Workload survives past sleep thresholds under -i  (~90s)"
  LOG="$(mktemp)"
  ( for k in $(seq 1 45); do echo "$(date +%s)" >> "$LOG"; sleep 2; done ) & W=$!
  caffeinate -i & I=$!
  # wait for workload to finish
  wait $W 2>/dev/null
  kill $I 2>/dev/null; wait $I 2>/dev/null
  GAPS=$(awk 'NR>1{g=$1-prev; if(g>3) c++} {prev=$1} END{print c+0}' "$LOG")
  N=$(wc -l < "$LOG" | tr -d ' ')
  check "workload ran all ticks"  "$N"    "45"
  check "zero stalls (gaps>3s)"   "$GAPS" "0"
  rm -f "$LOG"
fi

echo ""
echo "======================================================"
printf " Result: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m   [power: %s]\n" "$PASS" "$FAIL" "$(src)"
echo "======================================================"
[ "$FAIL" -eq 0 ]
