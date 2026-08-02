# Decompilation Progress Report

Generated: 2026-08-02 15:07:21

## Git Information

- Commit: `e64542de2308f1e70ce8146dd3acfa83b04fea2e`
- Dirty: true

## How to read these numbers

Almost the whole ROM can **match gold** in an "implemented map" without being **understood**. Understanding means named, readable Nim (Goal 1.5 adoption) that still assembles byte-exact. Scaffold and baserom extracts fill the map; they are not the decomp needle.

## PRIMARY — truly understood (Goal 1.5)

- **TOTAL UNDERSTOOD: 2,026 / 3,145,728 = 0.0644% of ROM** ← drive this up
- Named code (snesAsm): 1,816 bytes (32 routines)
- Named data tables (RE'd): 210 bytes (4 tables)

## SECONDARY — data extract claims

Layout/format claimed in `baserom_extract.nim`; content read from gold at build time.

- gfx_lz: 99,164 bytes (3.15% of ROM)
- apu_package: 49,846 bytes (1.58% of ROM)
- zero_pad: 15,122 bytes (0.48% of ROM)
- script_stream: 21,352 bytes (0.68% of ROM)
- action_script: 13,095 bytes (0.42% of ROM)
- table: 108,704 bytes (3.46% of ROM)
- **TOTAL EXTRACT: 307,283 bytes** (12519 spans, 9.77% of ROM)

## MAP ONLY — anonymous scaffold

Generated `code_spans` — byte-exact, not understood; may include false-positive data.

- Scaffold code: 2,825,303 bytes (5473 spans, 89.81% of ROM)

## Infra / unclaimed

- Header + vectors: 80 bytes
- Unclaimed (outside map): 11,036 bytes (0.35% of ROM)

## Byte-exact gate (referee)

- Implemented map exact: 3,134,692 / 3,134,692 = 100.00% of map
- Map coverage of ROM: 3,134,692 / 3,145,728 = 99.65% — **not** "understood"
- Coincidental matches (never claimed): 679 (679 zero-fill + 0 non-zero)
- Raw byte matches (inflated): 3,135,371 / 3,145,728
- Non-matching bytes: 10,357

## Header Comparison

- Total bytes: 64
- Matching bytes: 64
- Non-matching bytes: 0
- Progress: 100.0%
