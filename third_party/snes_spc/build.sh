#!/bin/bash
# Build spc2wav reference renderer from blargg's snes_spc.
# Run from repo root or anywhere; cds to its dir.
set -e
cd "$(dirname "$0")"
g++ -O2 -I. -o spc2wav snes_spc/*.cpp demo/wave_writer.c demo/demo_util.c spc2wav.c
echo "built: $(pwd)/spc2wav"
