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

## Residual wave (text multi-byte CC + AS gates) — 2026-07-24 evening

| Region | Change | Residual claimed |
|--------|--------|------------------|
| Text CC primary collectors | `0x04/05/06/07` = 2; `0x08/0A` = 3 (`$97CA` collect-N from `code_bank01`) | retuned 7 SS shrinks (−334 B) + drop 28 false-positive ends (−936 B) |
| Text CC sub-op extras | `0x18/19/1A/1C/1D` per-sub-op tables (`controlOperandBytes`) | +~4 KB net `ekScriptStream` |
| Action-script gates | `MinLen` 9→6, `MinSig` 2→1 (widths already full `0x00–0x4C`) | +3754 B `ekActionScript` |
| SS quality gates | min glyphs 6→4, ratio 0.45→0.35, min len 8→6 | +2787 B additional residual SS |

**Totals this wave:** script_stream **18605 B** (605 spans); action_script **9181 B** (628 spans).

**Compare:** **96.04%** byte-exact (`3,021,265 / 3,145,728`), implemented regions **100.00% exact**.
Prior baseline this session: **95.79%** (`3,013,405`). **Δ ≈ +0.25%** (`+7,860` B).

### RE notes

- Primary multi-byte CCs STZ `$97CA` at `$C18916` then install `$1E` collectors; widths from collect-N / store-then-process in `code_bank01`.
- Sub-op families re-arm next collectors; extras are additional stream bytes after the sub-op (not including the sub-op itself).
- AS low-path `0x00–0x4C` widths re-verified against `generateCode0095F2` (stream INY only).
- Scanner: `src/tools/scan_residual_as_ss.nim`.


## Residual wave (CF map ptr / placement / obj12) — 2026-07-24 map RE

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| CF map holey u16 ptrs | `0x0F6921..0x0F6BE7` fragments | bank-local u16 + `0000` holes → targets `@0x0F80xx+` | 226 B (18 spans) |
| CF map placement recs | `0x0F71FB` | `u16 n` + `n × (u16 id, u8 a, u8 b)` | 18 B (3 records) |
| CF 12B object/config | `0x0F9315..0x0F9FF7` residual holes | fixed 12 B; far ptr bank `$C6`–`$C9` @`+9` | 408 B (34 spans) |

**This wave residual ≈ 652 B** (`table_cfMapPtr_*` + `table_cfMapRec_*` + `table_cfObj12_*`).

**Compare after rebuild:** **96.06%** byte-exact (`3,021,917 / 3,145,728`), implemented regions **100.00% exact**.
Task baseline: **95.79%** (`~132k` residual).

### RE notes (map/sector track)

- **Map cores already claimed as code spans** (not residual): tilemap ptrs `0x100000`, tilemap data `0x101800`, sector 8B `@0x03E250`, obj place `@0x03E012`, map attr `$D7A800`.
- **New CF map table:** holey u16 pointer band just after the earlier `u16@0x0F59F1` / `cfProg` pool. Non-zero entries are monotonic bank-local offsets into `$CF80xx+`. Every target validates as **`u16 n` + `n × 4-byte entries** with exact next-ptr spacing (177/177 on full reconstructed band).
- **4-byte entry:** `u16 id` + `u8` + `u8` (likely local x/y or flags — semantic decode still open; claim is structural).
- **12B obj/config:** residual holes later in `$CF` end with a **24-bit far ptr** (banks `$C6`–`$C9`) at `+9..+11`; type byte `@+0` ∈ `{0..3}`.
- **Largest residual banks (`$DB`/`$D7`/`$CA`)** still look like dense structured binary (not gfx_lz / script / action-script / zero-pad). No solid claim this wave — needs dedicated disasm-linked RE.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/decompbound.nim --compare
```

## Residual wave (EF sprite-group / obj-config) — 2026-07-24

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| EF sprite-group body | scattered `$EF1D5C`..`$EF47xx` free holes | records via far-ptr table `$EF133F` (file `0x2F133F`); lengths 25/27/41; type byte `@+0` ∈ 1..7 | **1715 B** (17 spans, 67 complete records) |

**Largest single span:** `0x2F2426+452` = ids **80..97** (was top residual L465 minus 1-byte orphan tail of id79 + partial id98).

**Compare after rebuild:** **96.12%** byte-exact (`3,023,649 / 3,145,728`), implemented regions **100.00% exact**. Prior **96.06%** (`3,021,917`). **Δ +1,732 B** (~+0.06%).

### RE notes (loader-linked)

- **Pointer table:** SNES `$EF133F`, 4-byte far ptrs bank `$EF`, indexed `id*4`. Real loaders in bank `$C0` / `$C4` (`LDA #$133F` + `LDA #$00EF` at `0x001DF9`, `0x001E79`, `0x001FE0`, `0x007A8B`, `0x04B1D0`).
- **Record layout (structural):** variable **25 / 27 / 41** bytes between consecutive ptrs. Common head `03 20 05 1C 08 08 08 08` or `02 20 00 1C …` then tile/offset payload. Matches earlier docs object-config track (`docs/decompilation.md` / `$2CD6` sprite-group id → `$EF133F`).
- **Claim policy:** only **complete** records that are 100% residual-unclaimed (no partials straddling code_spans). Semantic field decode (script bank@+8 note was for a different config width) still open — claim is ptr-bounded structure only.
- **Other top residuals (`$DB`/`$D7`/`$CA`/`$CE`):** still dense binary without a matching far-ptr table + fixed record walk solid enough to claim this wave. `$CE62EE` is a 5-byte `[far][00][type1..6]` table (loader `$C2EBDF` `LDA.l,X`) but sits almost entirely inside false-positive code_spans already claimed as code.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/decompbound.nim --compare
```


## Residual wave (abs-ref unclaimed scan) — 2026-07-24

Method: build unclaimed from `code_spans` + `baserom_extract` + meta; scan
`code_bank*.nim` for absolute-long operands (`$C…` / `0xC…`) that land in
unclaimed gaps; prefer **genuine LDA/AND.L loaders** in banks `$C0–$C4`
(REP/JSL/RTL context) over raw ref counts (many hits are data-as-code false
positives). Also claim remaining CF map-ptr holes that match the existing
holey-u16 → count+4n format.

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| Bit-index masks | `0x04562F` ×8 | `01 02 04 08 10 20 40 80`; loaders `$C21645`/`$C21685` | 8 B |
| Bit-index masks | `0x0458AB` ×4 | residual `01 02 04 08`; loaders `$C1B08D`/`$C3EE38` | 4 B |
| u8 lookup | `0x04A1F2` ×3 | 3×u8; loaders `$C2382B`/`$C23B51` | 3 B |
| Map tile props | `0x17B200` ×22 | u16 residual of `$D7B200` table; loaders `$C00ABC`/`$C026CD` (low3 enum) | 22 B |
| CF map ptrs | `0x0F6943`/`0x0F69D5`/`0x0F6B91` | holey bank-local u16 → count+4n | 80 B |

**This wave residual = 117 B.**

### RE notes

- Naïve abs-ref ranking is dominated by **mis-disassembled data** (WAI/BRK
  streams that decode as `CMP/SBC AbsoluteLong`). Filter to load-like ops with
  real prologues in low banks before trusting a hit.
- `$C4562F` is the classic 8-byte bit mask table (bit number → mask). Flag tests
  use `DEC; LSR×3` for byte index then `JSL $C09231` for bit index into this table.
- `$D7B200` is a large u16 tile-property grid (most already claimed as code
  spans mid-table); residual head only. Second loader masks `AND #$0007` for a
  0..7 enum.
- CF map ptr holes sit between prior `table_cfMapPtr_*` claims; all targets
  re-validate as count+4n placement records.

### Tooling

- `src/tools/scan_unclaimed_absrefs.nim` — rank unclaimed gaps by abs-ref density
  from generated bank comments/operands.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/chunk_check.nim summary
```
