#!/bin/bash
# Build one bench_replay variant on this node and time the fixed workload.
#
#   scripts/ember_bench.sh <variant> "<extra nim flags>" [tape] [frames]
#
# Run from the repo root on an ember node (the checkout is on NFS, the binary
# and nimcache stay local so four nodes can build at once). Appends one row
# per run to /mnt/ember/scratch/bench/results.<host>.tsv. A run that starts or
# ends throttled is not a benchmark, so the CPU clock and SoC temperature are
# recorded before each run and 15 s into it (the clock idles down as soon
# as the run ends).
set -euo pipefail

VARIANT=${1:?variant name}
FLAGS=${2:-}
TAPE=${3:-../decompbound_secret/sessions/20260816-223148}
FRAMES=${4:-3600}
ROM="bin/Earthbound (U) [!].smc"
RESULTS_DIR=/mnt/ember/scratch/bench
BIN_DIR=$HOME/bench
HOST=$(hostname)
OUT=$RESULTS_DIR/results.$HOST.tsv

export PATH=$HOME/.local/bin:$HOME/.nimby/nim/bin:$PATH
mkdir -p "$BIN_DIR" "$RESULTS_DIR"

temp() { awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp; }
freq() { awk '{printf "%d", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0; }

BIN=$BIN_DIR/bench_$VARIANT
echo "== $HOST build $VARIANT: $FLAGS"
nim c --hints:off --warnings:off --parallelBuild:4 -d:release $FLAGS -o:"$BIN" src/tools/bench_replay.nim

for run in 1 2; do
  T0=$(temp); F0=$(freq)
  echo "== $HOST run $run/2 temp=${T0}C freq=${F0}MHz"
  "$BIN" "$ROM" "$TAPE" --frames "$FRAMES" --label "$VARIANT" --out "$OUT" | tail -3 &
  sleep 15; F1=$(freq); T1=$(temp)
  wait
  echo "== $HOST done temp=${T1}C freq=${F1}MHz flags=[$FLAGS]"
  printf '%s\t%s\t%s\ttemp_start=%s\ttemp_end=%s\tfreq_start=%s\tfreq_end=%s\tflags=%s\n' \
    "$(date -u +%FT%TZ)" "$HOST" "$VARIANT" "$T0" "$T1" "$F0" "$F1" "$FLAGS" \
    >> "$RESULTS_DIR/thermal.$HOST.tsv"
done
