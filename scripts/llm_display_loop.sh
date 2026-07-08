#!/usr/bin/env bash
# Always-on house-display restart loop for make llm-ai-display.
# Restarts forever on crash/exit; logs to bin/llm_display.log (gitignored via bin/*).
# Never touches human play slots — only bin/states/llm/ via make llm-ai-display.
#
# Usage:
#   ./scripts/llm_display_loop.sh              # real qwen display loop
#   make llm-ai-display-loop                   # same via Makefile
#   SLEEP_SECS=5 ./scripts/llm_display_loop.sh
#
# Dry-run (no emulator; prints plan + exits 0):
#   DRY_RUN=1 ./scripts/llm_display_loop.sh
#   make llm-ai-display-loop DRY_RUN=1
#
# Optional env:
#   SLEEP_SECS   seconds between restarts (default 3)
#   LOG          log path (default bin/llm_display.log)
#   ARGS         extra args forwarded to make llm-ai-display (e.g. ARGS="--sync-llm")
#   DRY_RUN=1    print what would run and exit without starting the game
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SLEEP_SECS="${SLEEP_SECS:-3}"
LOG="${LOG:-bin/llm_display.log}"
mkdir -p bin

echo_tg_max() {
  # Pull latest max_touch_grass / touch_grass_pct lines from display + llm_ai logs.
  local srcs=()
  [[ -f "$LOG" ]] && srcs+=("$LOG")
  [[ -f bin/llm_ai_log.txt ]] && srcs+=("bin/llm_ai_log.txt")
  if ((${#srcs[@]} == 0)); then
    echo "tg: (no log yet)"
    return
  fi
  local line
  line="$(grep -E 'max_touch_grass=|touch_grass_pct=' "${srcs[@]}" 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$line" ]]; then
    echo "tg last: $line"
  else
    echo "tg: (no touch_grass lines in log yet)"
  fi
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN=1 — would loop: make llm-ai-display ARGS='${ARGS:-}'"
  echo "  sleep ${SLEEP_SECS}s between restarts"
  echo "  log -> ${LOG}"
  echo "  state: bin/states/llm/bedroom.state only (never slot1-4)"
  echo_tg_max
  exit 0
fi

n=0
while true; do
  n=$((n + 1))
  ts="$(date -Iseconds 2>/dev/null || date)"
  {
    echo "===== llm-ai-display start #${n} at ${ts} ====="
    echo_tg_max
  } | tee -a "$LOG"
  set +e
  # shellcheck disable=SC2086
  make llm-ai-display ARGS="${ARGS:-}" 2>&1 | tee -a "$LOG"
  code=$?
  set -e
  {
    echo "===== llm-ai-display exit #${n} code=${code} at $(date -Iseconds 2>/dev/null || date) ====="
    echo_tg_max
  } | tee -a "$LOG"
  sleep "$SLEEP_SECS"
done
