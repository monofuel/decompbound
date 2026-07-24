## Residual fixed/group table claims (2026-07-24)

Claimed **residual unclaimed only** via `ekTable` in `baserom_extract.nim`
(same pattern as enemy-arrangement / battle-formation residuals).

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| Battle-formation ptrs | `0x10C60D..0x10D52D` | 484×8 (far ptr bank `$D0` + 4B assoc) → FF data `@0x10D52D` | 672 B new (assoc halves; full formPtr ekTable now ~1013 B) |
| Item table | `0x155000` + 254×`0x27` | fixed `0x27` records; price u16 `@+0x1A` | 14 B |
| Shops | `0x1578B2` + 66×7 | 7 item-id slots / shop | 21 B |
| EXP-per-level | `0x158F51` + 4×`0x190` | u32 LE, 4 character tables (levels 0..97 mono; tail pad) | 71 B |
| u16 ptr `$CF` | `0x0F59F1` ×36 | bank-local u16 → recs `@0x0F6075` prefix `49 80 5d 00` | 72 B |
| FF short-recs | bank `$CE` (~`0x0E6BEF`..`0x0EA0xx`) | FF-terminated L2..16 records (coord/path-like) | 565 B (7 spans) |

**This wave residual ≈ 1415 B** (formPtr new 672 + item/shop/exp/u16/ffRec).

**Compare after rebuild:** **95.70%** byte-exact (`3,010,498 / 3,145,728`), implemented regions **100.00% exact**.
Baseline was **95.51%**.

### RE notes

- **formPtr:** every 8-byte entry is `lo16 + bank $D0 + 00 + 4B assoc`. Residual
  gaps are almost entirely the 4-byte assoc field (ptr half often looks like code
  and was already claimed as such). All 484 banks check `$D0`; all 483 formation
  data spans are FF-terminated. Formation **data** body already fully claimed.
- **Item / shop / EXP:** documented in `docs/decompilation.md`; residual gaps are
  mid-table body only (majority already implemented as code/meta). Cookie id=88
  price=7; Hamburger id=90 price=14; Bread roll id=103 price=12.
- **u16 `@0x0F59F1`:** 36 monotonic bank-local pointers; each target record opens
  with fixed prefix `49 80 5d 00`. Table ends at a `00 00` sentinel before other
  data in the same unclaimed gap.
- **FF short-recs:** streams of short (2–16 B) `… FF` records, often starting
  `00`. Layout is path/coord-like; full semantic decode still open — claim is
  format walk only (offset/length). Spans trimmed so each claim is a pure
  complete-record run.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/decompbound.nim --compare   # rebuilds bin/Decompbound.smc + compare
```

See also `docs/decompilation.md` §Game data.

## Residual wave (AS/SS widths + CE ffRec + CF programs) — 2026-07-24 later

| Region | Change | Residual claimed |
|--------|--------|------------------|
| Action-script widths | RE handlers: `0x0C/0D/11/14/17/27` + tail `0x45–0x4C` aliases | +769 B `ekActionScript` |
| Text CC `$1E` installers | Primary ops `0x04–0E/10/19–1B/1D–1F` = 1 sub-op (first-order) | +~1.6 KB net `ekScriptStream` (retuned 17 broken under old widths) |
| Bank `$CE` FF short-recs | Same L2..16 / majority-`00` gate as prior wave | +328 B (8 spans) |
| CF program pool | 4-byte-word residual after u16 ptrs `@0x0F59F1` (often `49 80 5d 00`) | +496 B |

**Compare:** **95.79%** byte-exact (`3,013,405 / 3,145,728`), implemented regions **100.00% exact**.
Baseline this session: **95.70%** (`3,010,498`).

### RE notes (this wave)

- **AS `0x0D`:** bitop `u16 addr + u8 sub + u16 value` (5) at `$C09A9F`.
- **AS `0x14` / `0x27`:** field-index / `$1516,X` bitops sharing `$9AA2`/`$9AA3` tail (4 / 3).
- **AS `0x45–0x4C`:** low-path aliases of high-path handlers `0x3B–0x42` (same table words).
- **Text `$1E` installers:** primary handlers only `LDY #imm; STY $1E` then re-fetch; secondary may multi-collect — first-order width 1; full sub-op widths still TODO.
- **CF programs:** pointer targets are variable-length runs of **4-byte LE words** (lengths 4/8/12/16…); residual body immediately after the 36×u16 table uses the same packing (stream-relative, not absolute file align). High byte of each word is 0 in residual spans.
