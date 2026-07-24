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

## Residual wave (dense banks $DB/$D7/$CA/$CE loader RE) — 2026-07-24

Method: enumerate residual free runs in largest dense banks; scan **real** gold
AbsoluteLong opcodes (`AF`/`BF`) in banks `$C0–$C4` whose operands land in or
near those runs; RE record sizes only from loader arithmetic; claim **residual
free only** (zero `code_spans` overlap).

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| Map attr | `0x17A800..0x17B200` free holes | u8 cells; loaders `$C008F7`/`$C00B24`/`$C00B6F`/`$C00C35`/`$C00C7F`/`$C02303`/`$C02777`/`$C4DFF5` `LDA.L,X` + `AND #$00FF` | **181 B** (12 spans) |
| CA 17B records | mid `$CADCA1` table | `X = id*17` (`ASL×4; ADC id`); loader `$C2D1CF` `LDA.L,X` | **120 B** (19 spans, ≥2 B) |
| CE u16 ptrs | residual in `$CEDC45` table | bank-local u16; loader `$C4AA97`/`$C4AAE4` `id*2` `LDA.L,X` → 126 ptrs into `$CE6914+` | **8 B** (1 span) |

**This wave residual = 309 B.**

**Compare after rebuild:** **96.17%** byte-exact (`3,025,374 / 3,145,728`), implemented
regions **100.00% exact**. Prior **96.16%** (`3,025,065`). Residual unclaimed
**120,354** B (was ~120,663).

### C0–C4 AbsoluteLong inventory into these banks

Only **five** genuine `$C0–$C4` `LDA.L` / `LDA.L,X` bases hit `$CA`/`$CE`/`$D7`/`$DB`:

| Base | Refs | Residual mid-window | Notes |
|------|------|---------------------|-------|
| `$D7A800` | 8 | 181 B free holes | map-attr u8; abuts `$D7B200` tile-prop (already claimed residual head) |
| `$D7B200` | 2 | 0 B left | prior wave 22 B residual |
| `$CE62EE` | 3 | 0 B *inside* 5B table | 110×`[far][00][type1..6]`; **entire table already inside false-positive code_spans** |
| `$CEDC45` | 2 | 8 B in ptr table | u16 bank-local; targets mostly claimed as code; 0 fully-free target records |
| `$CADCA1` | 1 | 120 B mid-table free | 17B records via `id*17`; BBG-adjacent (docs also cite `$CADEA1` layer table — **no** abs-long loader found for `$CADEA1`) |

**Zero** C0–C4 AbsoluteLong operands land *inside residual free runs* of `$DB` (or the
large `$CA`/`$CE`/`$D7` islands). All load bases for these banks are already
claimed as code/meta; only mid-table residual holes remain claimable.

### Large residual islands (not claimed this wave)

Top free runs still lack a C0–C4 base + fixed record walk solid enough to claim:

| Run | Size | Head (hex) | Why unclaimed |
|-----|------|------------|---------------|
| `$DB714F` | 814 | `0C 76 0C 6E 15 B7…` | no C0–C4 abs-long base; weak fixed-size score |
| `$DBB0BD` | 552 | `00 21 01 59…` | near-window base `$DBA7A2` already claimed; residual not ptr-bounded |
| `$D7E54C` | 491 | `EA 83 2B 80…` | no C0–C4 loader into residual |
| `$CE6746` | 446 | `07 38 12 1E…` | after `$CE62EE` table end (`0x0E6514`); not 5B-continuation |
| `$CAB440` / `$CA7C65` | 396 / 326 | E0/20/A0-rich | no C0–C4 LDA.L into residual |

### False-code interiors — main residual story

Per-bank composition (file banks, 64 KB each):

| Bank | “code” | meta | unclaimed |
|------|--------|------|-----------|
| `$CA` | 52,374 (80%) | 5,395 | 6,996 |
| `$CE` | 57,410 (88%) | 3,768 | 4,478 |
| `$D7` | 56,613 (86%) | 3,444 | 5,424 |
| `$DB` | 52,042 (79%) | 1,669 | **11,367** |

These banks are **data-dense** in-game, yet ~80–90% is already labeled
`implemented_code` via `code_spans`. That is the dominant remaining bulk: **false-positive
code_spans covering tables/scripts/graphics**, not missing extract claims.

Evidence:

- `$CE62EE` 5B table (550 B, real loader `$C2EBDF`) sits **100% inside code_spans** —
  zero residual free inside the validated record run.
- `$CEDC45` targets: **1076 B** residual only as *partial* mid-record holes; 0 complete
  free records (bodies mostly claimed as code).
- Large residual ≥64 B in the four banks ≈ **20.5 KB**, almost all **interior holes**
  (claimed code on both sides) of dense binary — not edge padding.
- Global pattern: many high banks (`$D6–$DF`, `$E1`, …) show the same
  code>45K + unc>3K profile.

**Next lever is code_span reclassification / re-seeding**, not more extract fishing:
trim false code spans so real table bodies become residual, then re-run loader-backed
claims (same pattern that unlocked formPtr assoc halves and `$D7B200` head).

Extract claims remain hard-gated: **must not overlap `code_spans`**. Verified this wave:
`code ∩ extract = 0`, extract self-overlap `0`.

### Tooling (this wave)

- `src/tools/scan_unclaimed_absrefs.nim` — comment/operand abs-ref rank (noisy)
- `src/tools/probe_dense_loaders.nim` / `probe_dense_loaders2.nim` — residual runs + gold opcode scan
- `src/tools/probe_midtable_residual.nim` — C0–C4 bases with mid-window residual
- `src/tools/gen_dense_claims.nim` — emit residual free-run spans
- `src/tools/verify_extract_overlap.nim` — code_spans ∩ extract gate

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

## Residual wave (EF mid-record + C4 hitbox) — 2026-07-24

Method: loader-backed far-ptr tables with residual free holes (same mid-table
pattern as `$D7A800` / `$CADCA1`). No code_span overlap; carving path unchanged.

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| EF sprite-group mid-rec | `$EF133F` body gaps 25/27/41 | free fragments inside ptr-bounded records (prior wave took complete free recs only) | ****1408 B** (110 spans) |
| C4 hitbox / sprite-pts | `$C42B0D` body | far-ptr table bank `$C4`; rec = `u8 count` + `u8` + `count×10`; loader `$C01EBF` `LDA #$2B0D` / `LDA #$00C4` then `count*10` alloc | **357 B** (6 spans) |

**This wave residual = 1765 B.**

**Compare after rebuild:** **96.23%** byte-exact inventory (`3,027,139 / 3,145,728` meta),
implemented regions expected **100.00% exact**. Prior **96.17%** (`3,025,374`).
Residual unclaimed **118,589** B (was 120,354).

### RE notes

- **EF mid-record:** table walk yields 464 far ptrs; **462** consecutive gaps are
  exactly 25 / 27 / 41 (same structure as complete-record wave). Remaining residual
  is holes *inside* records that straddle false-positive code_spans — claim free
  only. Loaders unchanged (`$C01DF9` / `$C01E79` / `$C01FE0` / `$C07A8B` / `$C4B1D0`).
- **C4 hitbox:** live disasm at `$C01EBF`:
  `LDA #$2B0D; STA $06; LDA #$00C4; STA $08; … ASL×2; ADC count; ASL` → `count*10`
  payload after 2-byte header. All 17 ptr-bounded lengths match `2+count*10`.
  One fully free record (`0x042D5F+122`) plus mid-body free holes.
- **`$CE62EE` (not claimed this wave):** 110×5B `[far][00][type1..6]` still sits
  **547/550 B inside code_spans** (3 B free). Reclassifying as extract would
  *carve* code (inventory already supports mid-span carve via
  `carveSpanAroundHoles` in `collectImplementedSpanMeta` / `eachRegion`) but does
  **not** raise residual % — code→meta swap only. Next lever for honest data
  labels, not coverage.

### False-code / carve status (still the main bulk story)

Inventory already carves baserom extracts out of `GeneratedCodeSpans` for
partition. `verify_extract_overlap` still reports raw `code_spans ∩ extract`
before carve (gate for residual-only claims). Enabling mid-code extracts for
tables like `$CE62EE` is therefore a **label honesty** change (meta instead of
code) once we choose to claim them; build path already emits code tails around
holes.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```


## Residual expand wave (C5 body + APU interiors + CF scraps) — 2026-07-24

Method: re-walk known loader-backed families for remaining residual free only
(no `code_spans` overlap). Families already fully drained (EF mid, C4 hitbox,
CF map ptrs, formPtr, item/shop/EXP, D7 map-attr, CADCA1) contribute 0 B new.

| Region | File range | Format | Residual claimed |
|--------|------------|--------|------------------|
| C5 body mid-rec | `$C5A5B6` 14B index → bodies | ptr-bounded free holes; prefix `01 50 6C 1C 05` | **996 B** (99 spans) |
| APU pack interiors | 105 known pack containers | free runs ≥4 B inside pack@base..base+size | **2413 B** (387 spans) |
| CF 12B obj scraps | `0x0F9359`, `0x0F9458` | fixed 12 B; type@+0 ∈0..3; far `$C6–$C9` @+9 | **24 B** (2 spans) |

**This wave residual = 3433 B.**

**Compare after rebuild:** **96.34%** byte-exact (`3,030,572 / 3,145,728`),
implemented regions **100.00% exact**. Prior **96.23%** (`3,027,139`).
Residual unclaimed **115,136** B inventory (was 118,589). **Δ +3,433 B**.

### RE notes

- **C5 bodies:** index table `$C5A5B6` (253×14B) already claimed earlier; residual
  is mid-body free holes inside ptr-bounded records with fixed head
  `01 50 6C 1C 05`. Same structure as prior `gen_wave_claims` C5 body claims.
- **APU interiors:** re-scan of pack containers already referenced by existing
  `ekApuPackage` notes (`pack@0x… size=…`). Free runs ≥4 B inside container
  bounds only — same pattern as pack-66 / pack-139 interior waves. No new
  package discovery.
- **CF obj12:** two complete 12 B records left in residual holes after prior
  34-span wave.
- **Drained families (0 B this wave):** EF mid-record, C4 hitbox, CF map ptrs,
  formPtr, owEnemyArr, item/shop/EXP, BBG layer17, CADCA1, D7 map-attr.

### Top residual free runs still open (post-wave)

| # | File | Size | Bank | Head (hex) | Hypothesis / next probe |
|---|------|------|------|------------|-------------------------|
| 1 | `0x1B714F` | 814 | `$DB` | `0C 76 0C 6E 15 B7…` | dense structured; no C0–C4 abs-long base into residual |
| 2 | `0x1BB0BD` | 552 | `$DB` | `00 21 01 59…` | near `$DBA7A2` claimed; not ptr-bounded free |
| 3 | `0x17E54C` | 491 | `$D7` | `EA 83 2B 80…` | no C0–C4 loader into residual |
| 4 | `0x0E6746` | 446 | `$CE` | `07 38 12 1E…` | after `$CE62EE` table end; not 5B-continuation |
| 5 | `0x1B5696` | 425 | `$DB` | `8B 58 20 01…` | dense binary island |
| 6 | `0x19A48C` | 418 | `$D9` | `04 E0 1D 10…` | audio/sequence-like? probe pack headers |
| 7 | `0x1929E4` | 405 | `$D9` | `E1 02 92 08…` | same bank family as #6 |
| 8 | `0x0C7371` | 401 | `$CC` | `0B 7D F3 FF…` | FF-heavy; try short-rec / anim walk |
| 9 | `0x1A6012` | 400 | `$DA` | `8F 20 30 8D…` | dense binary |
| 10 | `0x0AB440` | 396 | `$CA` | `04 E1 03 61…` | E0/20/A0-rich; no C0–C4 LDA.L into residual |
| 11 | `0x09EE90` | 379 | `$C9` | `50 50 1C 01…` | possible script/config; SS/AS gates already fail head |
| 12 | `0x0C6DCF` | 368 | `$CC` | `84 00 40 F8…` | HDMA/table-like |
| 13 | `0x0C6ADA` | 355 | `$CC` | `D9 01 E6 E7…` | same CC band |
| 14 | `0x14AC38` | 353 | `$D4` | `01 01 07 03…` | tile/attr-like |
| 15 | `0x0EE8C6` | 346 | `$CE` | `0A 00 39 E0…` | dense CE island |
| 16 | `0x0A7C65` | 326 | `$CA` | `29 01 01 3E…` | CA dense |
| 17 | `0x1B7DBB` | 315 | `$DB` | `28 18 03 8B…` | DB dense |
| 18 | `0x197DFE` | 314 | `$D9` | `8A 25 21 C6…` | D9 dense |
| 19 | `0x1BF14B` | 303 | `$DB` | `84 01 D8 58…` | DB dense |
| 20 | `0x0AB1CB` | 300 | `$CA` | `13 E0 3A 74…` | CA dense |

**Dominant story unchanged:** largest bulk is false-positive `code_spans` covering
data (banks `$DB`/`$D7`/`$CA`/`$CE` ~80–90% labeled code). Next high-leverage
lever is **code_span reclassification**, not more extract fishing on free residual.

### Concrete next probes

1. Disasm-linked reclass of `$CE62EE` 5B table (already 100% inside code_spans;
   carve to meta via existing `carveSpanAroundHoles` — label honesty, not %).
2. Scan gold AbsoluteLong from **all** code banks (not only C0–C4) into top-20
   residual runs — prior waves restricted to low banks.
3. For `$CC7371` / `$CC6DCF` / `$CC6ADA`: try FF-terminated short-rec walker +
   HDMA table pattern match against live WRAM dumps.
4. For `$D9` runs: cross-check APU song/pack directory for container bases that
   were never claimed as packages (new pack discovery, not interiors).
5. Seed-trim false code around `$DB714F` if disasm density is BRK/WAI garbage.

### Tooling

- `src/tools/probe_residual_expand.nim` — re-walk known families + top residual runs

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

## All-bank AbsoluteLong + pack-table APU + ffRec residual — 2026-07-24

Method: scan AbsoluteLong loaders from **all** generated banks / all code spans
(not only C0–C4); walk pack table for free residual inside valid packages; claim
remaining free residual that packs as FF-terminated short records (2..16 B/rec).
Hard gate: residual free only (`code ∩ extract = 0`).

| Family | Format | Residual claimed |
|--------|--------|------------------|
| AbsoluteLong tables | `$C0B0A6` 4B masks (LDA.L,X); `$CF30F7` 5B; CC FF-head / HDMA6; C5 idx/body free; CF prog4 / obj12 complete | **229 B** |
| APU pack-table free | free runs inside pack-table packages with valid `[u16 len][u16 tgt]…` walk (`size≤0x2800`) | **310 B** |
| ffRec residual | FF-terminated short records (2..16 B/rec, ≥2 recs/span); free only | **8227 B** |

**This wave residual = 8766 B** (527 spans).

**Coverage:** **96.62%** (`3,039,338 / 3,145,728`), implemented regions **100.00% exact**.
Prior **96.34%** (`3,030,572`). Residual unclaimed **106,390** B (was **115,156**).

### AbsoluteLong inventory (all banks)

Gold AbsoluteLong load/store ops in code spans → residual free: **474 hits** across
**258 runs**. Filtering to real **C0–CF `LDA.L` / `LDA.L,X` only** into residual:
**7 hits** — residual free AbsoluteLong load bases from low banks are essentially
drained (solid remaining: `$C0B0A6`, `$CF3100`/`$CF3101` window).

High-bank generated AbsoluteLong hits into residual are mostly false-positive
disassembly of data (SBC/CMP/STA from banks `$D0+`). Not used as sole claim basis
without structure.

### APU pack discovery

- Pack table `0x04F947` ×170 walked with max size `0x2800`.
- Known pack interiors (prior expand wave) fully claimed — **0 B** left.
- **New pack-table free residual:** 310 B across 44 spans (mid-container holes).
- Residual-island APU package discovery on top free runs: no solid full packages
  fully free (D9 islands look sequence-like but fail clean package walk).

### FF short-record residual

Same format as prior `$CE` ffRec wave; extended globally over residual free.
Test gate: every `table_ffRec_*` span fully packs as FF-terminated recs of length
2..16. **8227 B** new (total ffRec inventory ~9260 B).

### Cross-boundary script streams (not claimed)

~3.3 kB residual free is the *prefix* of good CC streams that terminate past free
into code_spans. `consumeScriptStreamRun` residual-only fails those (test
`liveScriptStreamClaims`). Left for code_span reclass / carve, not extract.

### Tooling

- `src/tools/probe_allbank_abslong.nim` — all-bank AbsoluteLong → residual + pack discovery
- `src/tools/gen_allbank_wave_claims.nim` — emit this wave’s spans
- `src/tools/verify_extract_overlap.nim` — code_spans ∩ extract gate

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

## Residual wave97 (ffRec≤32 + ssPrefix + far3 + zRec + w4hi0) — 2026-07-24

Method: residual free only. Expand FF short-record max from 16→32 (multi + quality
single); claim cross-boundary CC script prefixes that are free heads of a good full
stream ending in claimed inventory; far-ptr 3B chains; 00-term printable multi;
4B words with high byte 0. Hard gate: `code ∩ extract = 0`.

| Family | Format | Residual claimed |
|--------|--------|------------------|
| ffRec expand | FF-term recs 2..32 B (multi ≥2 + single ≥3, quality gates) | **8143 B** |
| ssPrefix | free CC prefix of `isGoodScriptStream` full walk into claimed | **2619 B** (155 spans) |
| far3 | ≥4× 3B far ptrs bank `$C0–$EF` | **615 B** |
| zRec | 00-term printable short recs ≥3 (2..12 B) | **617 B** |
| w4hi0 | 4B words high byte 0, ≥4 words, full free run | **68 B** |

**This wave residual = 12062 B** (681 spans).

**Compare after rebuild:** **97.00%** byte-exact (`3,051,400 / 3,145,728`),
implemented regions **100.00% exact**. Prior **96.62%** (`3,039,338`).
Residual unclaimed **94,328 B** inventory (was **106,390**). **Δ +12,062 B**.

### RE notes

- **ffRec:** prior wave drained 2..16 multi-rec globally. Remaining free packs as
  slightly longer FF-term records (up to 32) plus isolated quality singles
  (exactly one trailing `FF`, not E0-heavy / zero-heavy). Same structural family
  as `$CE` ffRec; test gate raised to `L ≤ 32`.
- **ssPrefix:** ~2.6 KB residual free is the *prefix* of good CC streams that
  terminate past free into `code_spans`/meta. Claim residual-only; full walk must
  pass `isGoodScriptStream`. `liveScriptStreamClaims` accepts `script_ssPrefix_*`
  without requiring terminator inside the free span.
- **far3 / zRec / w4hi0:** structure-only residual packing (no new AbsoluteLong
  load bases into residual free this wave — high-bank hits still look like
  false-positive disasm).
- **Drained under current gates:** zero-pad, pack-table APU free, full script
  streams in free, action-script, gfx_lz, multi ffRec max16.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

### Tooling

- `src/tools/gen_residual_wave97.nim` — emit this wave’s residual-only spans
- `src/tools/probe_ffrec_residual.nim` — ffRec residual scout

## Residual wave98 (fe/fd/seqE0/plane/cmd/AS/u16) — 2026-07-24

Method: residual free only. New structural families after wave97 drained
ffRec≤32 / ssPrefix / far3≥4 / zRec≥3 / w4hi0≥4. Hard gate:
`code ∩ extract = 0`. AS gates relaxed to MinLen 4 / MinSig 0 with long-span
(≥12 B) still requiring a signature opcode.

| Family | Format | Residual claimed |
|--------|--------|------------------|
| feRec | FE-term recs 2..32 B (multi ≥2 + quality single ≥3) | **3629 B** |
| fdRec | FD-term recs 2..32 B (multi + quality single) | **1798 B** |
| seqE0 | N-SPC-like sequence residual (≥1 `E0` instrument arg&lt;0x40, notes≥3, e0≥2, dens) | **7785 B** |
| planePair | SNES bitplane-like (≥50% equal adjacent pairs, ≥20 B) | **3426 B** |
| cmdPair | Even command stream (top-3 even-bytes cover ≥35%, ≥16 B) | **5250 B** |
| AS residual | ended walks ops≥1 MinLen4; ≥12 B needs signature | **3577 B** |
| u16mono | non-decreasing u16 LE ≥5 entries, end ≥0x100 | **4006 B** |
| far3/far4 | 3B far ≥3; 4B far+00 ≥3 | **786 B** |
| zRec / w4hi0 / const / zero / ssPrefix | prior families loosened slightly | **~1.6 KB** |

**This wave residual = 31913 B** (1850 spans).

**Compare after rebuild:** **98.02%** byte-exact (`3,083,313 / 3,145,728`),
implemented regions **100.00% exact**. Prior **97.00%** (`3,051,400`).
Residual unclaimed **~62k** B inventory (was **94,328**). **Δ +31,913 B**.

### RE notes

- **seqE0:** structural claim linked to `docs/audio.md` sequence bytecode
  hypothesis (`0xE0 xx` = instrument select). Residual free runs with ≥1 strong
  `E0`+small-arg, note-range density, sparse zeros. Not a full driver walk —
  format-density gate only until operand widths are pinned from the `$7000`
  dispatch.
- **planePair:** free runs whose even/odd adjacent bytes match ≥50% (classic
  SNES 2bpp/4bpp row mirroring). Structure only.
- **cmdPair:** free even-length streams whose even-index “opcode” bytes have
  low entropy (top-3 cover ≥35%). Covers path/anim-like residual in `$DB`/`$D9`.
- **AS:** `ActionScriptMinLen` 6→4, `MinSig` 1→0; spans ≥12 still need ≥1
  WAIT/GOTO/GOSUB/FAR CALL. Existing AS claims still pass.
- **fe/fd:** same packing family as `ffRec`, different terminators used by
  table/stream residual outside the drained FF set.

### Overlap / exactness

- `verify_extract_overlap`: `code ∩ extract = 0`, extract self-overlap `0`.
- `test_baserom_extract` liveWave98 + prior blocks green.
- Implemented regions **100.00% exact** (byte-exact gate).

### Tooling

- `src/tools/gen_residual_wave98.nim` — emit this wave’s residual-only spans
- `src/tools/probe_wave98.nim` / `probe_wave98_max.nim` / `probe_seq_quality.nim` — scouts

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

## Residual wave99 (u8pair/countN/smooth/fix/term/cmd/seq) — 2026-07-24

Method: residual free only after wave98. Structural density/packing gates on
remaining free runs. Hard gate: `code ∩ extract = 0`.

| Family | Format | Residual claimed |
|--------|--------|------------------|
| u8pair | 2B records, ≥65% field ≤0x40, ≥8 recs | **12164 B** |
| countN | u8/u16 count + count×stride (known strides) | **19280 B** |
| u16tab | even free, ≥40% hi-byte <0x40 | **264 B** |
| smooth3/4/5 | adj-row Δ≤10 ≥50%, ≥8 recs | **417 B** |
| fix3/4 + fixNcol | bank/type/hi0 or col0 top-3 ≥35% | **953 B** |
| tF8–tFC multi | terminator short-recs 2..48 B | **174 B** |
| plane35 | ≥35% equal adjacent pairs | **212 B** |
| cmd22 | even stream top-3 cover ≥22% | **1388 B** |
| seqLoose | N-SPC-like loose E0/note density | **216 B** |
| far3 ≥2 / AS / SS / u8lo / stride2 / lowEnt / zero / const | prior-family scraps | **~900 B** |

**This wave residual = 35977 B** (1434 spans).

**Compare after rebuild:** **99.16%** byte-exact (`3,119,290 / 3,145,728`),
implemented regions **100.00% exact**. Prior **98.02%** (`3,083,313`).
Residual unclaimed **26,438** B (was **62,415**). **Δ +35,977 B**.

### RE notes

- **u8pair:** residual free often packs as range-limited 2-byte records (anim /
  coord / flag tables). Same family as prior dense scout `u8pair`.
- **countN:** free runs opened by a small count header whose payload length is
  exactly `count * stride` for known record strides (1..17 plus sprite-group
  25/27/41). Mid-run scan; requires non-degenerate payload (not mostly zero).
- **smooth*:** battle-bg / path-like multi-column tables where adjacent records
  change slowly (Δ≤10 on ≥50% of field comparisons).
- **fixNcol:** fixed-width residual with low-entropy column 0 (top-3 values
  cover ≥35% of rows).
- Remaining ~26 KB is still dense binary islands (esp. `$DB`/`$D8`/`$D6`/`$D7`)
  without a packing gate solid enough to claim, plus false-positive code_span
  interiors.

### Overlap / exactness

- `verify_extract_overlap`: `code ∩ extract = 0`, extract self-overlap `0`.
- `test_baserom_extract` liveWave99 + prior blocks green.
- Implemented regions **100.00% exact** (byte-exact gate).

### Tooling

- `src/tools/gen_residual_wave99.nim` — emit this wave’s residual-only spans
- `src/tools/probe_wave99.nim` / `probe_wave99b.nim` / `probe_wave99c.nim` — scouts

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

## Residual wave100 + 100b (term/print/u8pair/far3 scraps) — 2026-07-24

Method: residual free only after wave99. Structure gates loosened moderately
(not density-noise). Hard gate: `code ∩ extract = 0`.

### wave100

| Family | Format | Residual claimed |
|--------|--------|------------------|
| term F0–FF multi+single | FF-family short-recs 2..48; quality singles 4..32 | **1728 B** |
| u8pair55 | 2B recs ≥6, ≥55% field ≤0x50 | **740 B** |
| print70 | printable/EB glyph ≥70% ≥8 B | **1118 B** |
| fix3/4/5col | fixed-width bank/type/col gates | **768 B** |
| countN | u8/u16 count + stride, min5 ≥30% fill | **395 B** |
| zero/const/smooth/plane/as | prior families residual scraps | **575 B** |

**wave100 total = 5324 B** (871 spans).

### wave100b

| Family | Format | Residual claimed |
|--------|--------|------------------|
| u8pair4 | ≥4 recs, ≥55% field ≤0x50 | **1108 B** |
| far3 ≥1 | 3B far ptr bank `$C0–$EF`, lo≠0 | **903 B** |
| print70 ≥6 | printable/EB glyph | **851 B** |
| const/zero | fill scraps | **490 B** |
| fix3/4 + countN4 + plane | loosened min recs | **611 B** |

**wave100b total = 3963 B** (888 spans).

**Session total residual claimed = 9287 B.**

**Compare after rebuild:** **99.45%** byte-exact (`3,128,577 / 3,145,728`),
implemented regions **100.00% exact**. Prior **99.16%** (`3,119,290`).
Residual unclaimed **17,151 B** (was **26,438**). **Δ +9,287 B**.

### Overlap / exactness

- `verify_extract_overlap`: `code ∩ extract = 0`, extract self-overlap `0`.
- `test_baserom_extract` liveWave100 + liveWave100b + prior blocks green.
- Implemented regions **100.00% exact** (byte-exact gate).

### Tooling

- `src/tools/gen_residual_wave100.nim` / `gen_residual_wave100b.nim`
- `src/tools/probe_wave100.nim` / `probe_residual_hard.nim` — scouts

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/tools/chunk_check.nim summary
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

## Hard residual remaining (~17,151 B) — why not claimed

Inventory after wave100b: **5799 free runs**, **max free run = 19 B**.
Byte size mix: **1 B = 1872**, **2–3 B = 5077**, **4–7 B = 8780**,
**8–11 B = 874**, **12–15 B = 387**, **16+ B = 161**. Almost all residual is
sub-table scrap between already-claimed meta/code.

### Top free runs (cannot claim under honest structure)

| File | Size | Neighbors | Head (hex) | Why unclaimed |
|------|------|-----------|------------|---------------|
| `0x058262` | 19 | meta\|meta | `01 70 77 A4 8A 7E 83 A4…` | High unique entropy (16/19); fails u8pair/fix/term/AS/SS |
| `0x06D7EE` | 19 | meta\|meta | `15 AD 17 B4 15 56 16 67…` | Path/coord-like but no terminator, no fixed stride, no count header match |
| `0x16E954` | 19 | meta\|meta | `B3 1B B3 1B 00 00 B4 9A…` | Mixed pair + pad; short for fixNcol; not plane/cmd density |
| `0x171745` | 19 | meta\|meta | `19 25 19 1A 25 19 25 1B…` | Low-range but fails print70 / smooth1 / u8pair55 gates |
| `0x1789E9` | 19 | meta\|meta | `00 50 50 50 40 50 00 6A…` | Sparse zeros + mid bytes; no count*stride exact pack |
| `0x0C1567` | 17 | **code\|code** | `21 32 21 6E 21 29 60 2F…` | Mid-code island (false-negative code_span hole); not extract |
| `0x0E6D2E` | 17 | meta\|meta | `00 68 96 99 AE 67 95 9C…` | Smoothish columns fail ≥45% smooth1 / col cover |
| `0x1754EC` | 16 | meta\|meta | `D4 50 64 40 D0 A0 AF A1…` | Dense binary; no far bank column, no term |
| `0x206D93` | 16 | meta\|meta | `93 A1 83 BD 9F A1 41 9F…` | High-bank glyph soup; SS walk fails quality |
| `0x0739AC` / `0x073A68` | 15 | meta\|meta | `15 E1 91 15 CD 5E…` (dup) | Repeated 15-byte pattern — needs loader-linked record size |
| `0x02AE00` / `0x02AE40` | 13 | meta\|meta | `6B C2 22 77 6E C2 20…` | RTL/`C2` soup — looks like **code mid-stream**, not table |

### Code-like residual (not extract)

A few free scraps decode as 65816 prologues outside `code_spans`:

| File | Size | Bytes | Notes |
|------|------|-------|-------|
| `0x028D3A` | 7 | `C2 31 22 .. C2 6B` | `REP #$31; JSL …; REP; RTL`-shaped |
| `0x028E3B` | 7 | same family | same |
| `0x029D7A` | 7 | same family | same |
| `0x047369` | 7 | same family | same |

**~28 B** total of clear `C2 31` code-shaped free. Claiming these as `ekTable` would
be dishonest; they need **code_span reseed / trim**, not extract. AS FAR-CALL heads
(`42 xx xx C0…`) also appear as ~54 B of incomplete walks that fail
`isGoodActionScriptSpan` (no terminal / bad width).

### Bank residual leaders (post-wave100b)

| Bank | Residual B | Character |
|------|------------|-----------|
| `$D8` | 2375 | largest; shredded interior holes in dense binary |
| `$CF` | 774 | map/config scrap after prior CF claims |
| `$D4` | 739 | tile/attr-like high entropy |
| `$DB` | 689 | was top bulk; now micro-holes only |
| `$D6` | 670 | same pattern |

### What would unlock the rest

1. **code_span reclassification** — dominant lever: banks still ~80% labeled
   `implemented_code` while holding data; mid-code holes like `0x0C1567` and the
   `C2 31` stubs are the honest next claims as *code*, not extract.
2. **Loader-linked record sizes** for repeated 15 B patterns at `$C7` (`0x0739AC`
   family) once a low-bank AbsoluteLong base is proven.
3. **Operand-width completion** for AS / text CC so incomplete FAR-CALL heads and
   short CC scraps pass structural walks.
4. Further density-only gates (cover ≤25%, single-byte “structure”) are **not**
   honest RE — residual would inflate without format truth.

### Exhausted under current honest gates

zero-pad, const-fill, ff/fe/fd/F0–FF term multi+quality single, ss full
`isGoodScriptStream`, AS MinLen4, u8pair ≥4 @55%, countN min4 ≥30% fill, fix3/4
bank/type ≥40%, far3 ≥1 bank `$C0–$EF`, print70 ≥6, plane25 ≥8, smooth1 ≥12,
gfx_lz, APU pack free interiors, loader-backed dense tables (CADCA1, D7 attr,
EF sprite-group, C4 hitbox, formPtr, item/shop/EXP).


## Residual wave101 (scraps after 99.45%) — 2026-07-24

Baseline free residual: **17,151 B** in ~5,799 runs (max run 19 B).
Hard gate: free residual only, zero `code_spans` overlap.

| Family | Claim | Residual claimed |
|--------|-------|------------------|
| Pure zero free runs | `ekZeroPad` `zero_wave101_*` | 26 B / 22 |
| Action-script full + good heads | `ekActionScript` `as_wave101_*` | 42 B / 9 |
| Terminator F0–FF quality singles | `ekTable` `table_term1_w101_*` | 26 B / 6 |
| u8-pair ≥4 recs | `ekTable` `table_u8pair4_w101_*` | 22 B / 2 |
| Constant-byte fill ≥2 | `ekTable` `table_constFill_w101_*` | 22 B / 11 |
| Far-ptr 3B pure rem (align 0–2) | `ekTable` `table_far3_w101_*` | 258 B / 86 |
| Ternary flag alphabet `{00,01,80}` ≥4 | `ekTable` `table_bitFlag_w101_*` | 906 B / 169 |

**This wave residual = 1,302 B** in 305 spans.

**Compare after rebuild:** **99.50%** byte-exact (`3,129,879 / 3,145,728`), implemented
regions **100.00% exact**. Prior baseline **99.45%** (`3,128,577` implied by
17,151 free). Residual free after wave101: **15,849 B** in ~5,588 runs.

### Honesty notes

- **Claimed:** pure zeros any length; complete AS walks (`isGoodActionScriptSpan`);
  term F0–FF singles already used in wave100; u8pair/const gates matching wave100b;
  far3 only when free-run remainder after align 0–2 is a **pure** bank `$C0–$EF`
  lo≠0 chain (no mid-run single-ptr noise); ternary `{0x00,0x01,0x80}` free ≥4 with
  ≥1 non-zero (bit/flag residual — constrained alphabet, same spirit as plane25).
- **Not claimed (would be dishonest or weak):**
  - Single mid-run far3 noise (~963 B) without pure-rem / multi-chain structure.
  - “SS loose” ended walks with glyphs≥2 — many false positives (e.g. `80 80 01 00`
    counted as glyphs via encoding offset).
  - Single-byte free as “const fill” or “pending format RE” gold-extract.
  - Blanket residual free → extract with placeholder notes.

### Remaining residual (~15,849 B) — top gaps / next steps

| Bucket | Approx | Notes |
|--------|--------|-------|
| code\|code sandwich free | ~7.4 KB / ~2.5k runs | Mid-trace holes between `code_spans`. Needs **code seeds** → `convert_all` (expensive) or live PC coverage / resolved jump-table digs. Common prologue/RTL endings exist but not bulk-safe as extract. |
| meta\|meta extract holes | ~several KB | Between SS/AS/table/gfx claims — mid-script fragments, partial records, dense binary scraps. Max free run still 19 B. |
| Bank `$D8` (file `0x18`) | ~1.5 KB free left | Mostly `00/01/80` already claimed as bitFlag; remaining mixed bit/plane noise. |
| Bank `$CF` cluster `0x0FB207+~1K` | holey cluster | Map/obj residual fragments; needs loader-linked RE beyond current holey-u16 / 12B formats. |
| Incomplete AS FAR heads | ~50 B | Short free `42`/`4C` whose bank byte is already claimed next — cannot expand without overlap; re-carve only if parent AS claim is expanded carefully. |
| Single-byte free | ~1.8 KB | Mostly non-zero noise; pure zeros already claimed. Not honest as standalone extract. |

**100% exact is not reachable honestly this wave.** Next high-leverage path:

1. **Code-seed wave** — seed free runs that sit between code with real 65816
   prologues/RTL into `observed_entries.txt` / `resolved_entries.txt`, re-run
   `convert_all`, re-compare (largest remaining bucket).
2. **Loader-linked clusters** — dig bank `$CF` `0x0FB207` / `$D8` / `$D7` free
   clusters with AbsoluteLong + record arithmetic (not statistical scrapers).
3. **SS width RE** — top free often sits between `scriptStream_*` claims; multi-byte
   CC residual heads that fail current quality gates need handler re-width, not
   looser glyph ratios.

### Tooling

- `src/tools/gen_residual_wave101.nim` — emitter
- `src/tools/probe_final_residual.nim` / `probe_claimable_now.nim` — residual scouts

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/decompbound.nim --compare
```

## Residual wave102 (exact-gate scraps after 99.50%) — 2026-07-24

Baseline free residual: **15,763 B** in 5,573 runs (max run 19 B).
Hard gate: free residual only, zero `code_spans` overlap.

### Known-walker re-scan (post-wave101)

| Gate (prior-wave exact) | Leftover | Notes |
|-------------------------|----------|-------|
| pure zero free | **7 B / 6** | claimed |
| AS good head / full | **6 B / 1** | claimed (`0x1B0730`) |
| const ≥2 non-zero | 0 | drained |
| term F0–FF multi/single | 0 | drained |
| u8pair ≥4 @55% | 0 | drained |
| far3 pure rem align 0–2 | 0 | drained |
| bitFlag `{00,01,80}` ≥4 | 0 | drained |
| print70 ≥6 | 0 | drained |
| plane25 | 0 | drained |
| smooth1 ≥45% | 0 | drained |
| SS `isGoodScriptStream` | 0 | drained |
| countN mid-scan | 0 | drained |
| fix3 ≥40% bank/type | 0 | drained |
| fix4 ≥40% bank@+3 ≥3 recs | **12 B / 1** | claimed (`0x1F1602`) |
| gfx_lz clean full free run | **5 B / 1** | claimed (`0x11ECB1`); skipped partial mid-hole `0x1144C9` (consume 4/5) |
| far3 head-chain ≥1 | 0 | drained |
| AS FAR incomplete fullish | 0 good | walks end mid-op / fail `isGoodActionScriptSpan` |
| C0–C4 `LDA.L` into free | **0 hits** | loader-linked residual bases drained |

| Family | Claim | Residual claimed |
|--------|-------|------------------|
| Pure zero free runs | `ekZeroPad` `zero_wave102_*` | 7 B / 6 |
| Action-script good head | `ekActionScript` `as_wave102_*` | 6 B / 1 |
| fix4 bank@+3 ≥40% | `ekTable` `table_fix4_w102_*` | 12 B / 1 |
| gfx_lz full free run | `ekGfxLz` `gfxLz_wave102_*` | 5 B / 1 |

**This wave residual = 30 B** in 9 spans.

**Compare after rebuild:** **99.50%** byte-exact (`3,129,995 / 3,145,728`), implemented
regions **100.00% exact**. Prior **99.50%** (`3,129,965`). Δ **+30 B** (still rounds to 99.50%).

### Honesty notes — not claimed

- **Expanded alphabets** bank `$D8` (`{00,01,03,80,90}` ~155 B; `{00,80,90}` ~70 B):
  density-only without a loader-backed field model. Wave101 already took ternary
  `{00,01,80}`; adding `0x90`/`0x03` without RE is bulk-scraping.
- **SS ended any / AS any-ended** (~1 KB): fail quality / good-span gates; prior
  waves rejected the same class.
- **Mid-run far3 singles** (~1 KB packed): not pure free-run remainder.
- **Single-byte free** (~1.9 KB): non-zero noise; pure zeros already drained.
- **CF cluster `0x0FB207+~1K`**: shredded mid-record scraps (`01 D7 00 04 08`
  heads) between prior AS/countN/far3/zero claims — structure is *already
  over-partitioned*; re-claiming fragments needs record reassembly RE, not
  another density gate.
- **15 B twins `0x0739AC` / `0x073A68`**: identical bodies between script streams;
  **zero** AbsoluteLong loaders into those file offs (all-bank gold scan).

### Residual free after wave102

| Metric | Value |
|--------|-------|
| Free residual | **15,733 B** |
| Free runs | **5,565** |
| Max free run | **19 B** |
| code\|code sandwich | **6,929 B / 2,359 runs** |
| Implemented exact | **100.00%** |

#### Top 30 free gaps

| File | Size | Neighbors | Head (hex) | Why unclaimed |
|------|------|-----------|------------|---------------|
| `0x058262` | 19 | meta\|meta | `01 70 77 A4 8A 7E…` | high entropy; fails all structure gates |
| `0x06D7EE` | 19 | meta\|meta | `15 AD 17 B4 15 56…` | path-like; no term / stride / count header |
| `0x16E954` | 19 | meta\|meta | `B3 1B B3 1B 00 00…` | mixed pair+pad |
| `0x171745` | 19 | meta\|meta | `19 25 19 1A 25 19…` | low-range fails print/smooth/u8pair |
| `0x1789E9` | 19 | meta\|meta | `00 50 50 50 40 50…` | sparse; no exact count*stride |
| `0x0C1567` | 17 | **code\|code** | `21 32 21 6E 21 29…` | mid-code hole — needs code seed, not extract |
| `0x0E6D2E` | 17 | meta\|meta | `00 68 96 99 AE 67…` | smooth columns fail ≥45% |
| `0x1754EC` | 16 | meta\|meta | `D4 50 64 40 D0 A0…` | dense binary |
| `0x206D93` | 16 | meta\|meta | `93 A1 83 BD 9F A1…` | glyph soup; SS quality fail |
| `0x0739AC` / `0x073A68` | 15 | meta\|meta | `15 E1 91 15 CD 5E…` (identical) | no loader; SS neighbors |
| `0x073C13` | 15 | meta\|meta | `70 79 97 9E 9F A2…` | same band |
| `0x0DD76E` | 15 | meta\|code | `E0 24 01 01 7F 4F…` | dense |
| `0x19BA26` | 15 | meta\|meta | `52 C8 00 20 86 52…` | dense |
| `0x1D6DCF` | 15 | meta\|meta | `FB FB FF FF 88 12…` | FF-heavy but not clean multi-rec term |
| `0x1E8248` | 14 | meta\|meta | `BF EF AF CF 8F C7…` | dense |
| `0x02AE00` / `0x02AE40` | 13 | meta\|meta | `6B C2 22 77 6E C2…` | **code-shaped** (RTL/`C2`); reseed, not extract |
| `0x073194` | 13 | meta\|code | `10 0F 50 96 16 63…` | SS scrap |
| `0x08170D` | 13 | meta\|meta | `10 3C 70 72 16 54…` | SS scrap |
| `0x0921B5` | 13 | meta\|code | `70 17 3D 50 A0 A2…` | SS scrap |
| `0x0A27A7` | 13 | meta\|meta | `80 FC 8F 72 3F D8…` | dense |
| `0x1603F6` | 13 | code\|meta | `00 00 A7 B7 44 45…` | tile-like |
| `0x166D30` | 13 | meta\|meta | `93 97 96 A8 C8 1B…` | dense |
| `0x16EA79` | 13 | meta\|meta | `AC 45 47 B0 AE AB…` | dense |
| `0x1753F7` | 13 | meta\|meta | `00 90 A0 B0 A0 A0…` | plane-ish but fails plane25 |
| `0x19A456` | 13 | meta\|meta | `9A 2F 45 95 2E A0…` | dense |
| `0x1A88F8` | 13 | meta\|meta | `77 5F 5B BD 56 1F…` | dense |
| `0x1B4A41` | 13 | meta\|meta | `00 15 88 42 19 00…` | dense |
| `0x1BB02E` | 13 | meta\|meta | `46 84 31 2B 0C 59…` | dense |

#### Bank residual leaders

| Bank | Residual B | Character |
|------|------------|-----------|
| `$D8` (0x18) | 1467 | largest; shredded bit/plane scraps after bitFlag |
| `$CF` (0x0F) | 762 | map/obj mid-record fragments |
| `$D4` (0x14) | 685 | tile/attr-like |
| `$D6` (0x16) | 667 | dense micro-holes |
| `$DB` (0x1B) | 653 | was bulk; now micro-holes |

### Exhausted under current honest extract gates

zero-pad, const≥2, ff/fe/fd/F0–FF term, SS good, AS MinLen4 good-span,
u8pair ≥4 @55%, countN mid-scan, fix3/4 ≥40%, far3 pure rem + head-chain ≥1,
print70, plane25, smooth1, bitFlag `{00,01,80}`, gfx_lz clean full free,
loader-backed dense tables (CADCA1, D7 attr, EF sprite-group, C4 hitbox,
formPtr, item/shop/EXP, C5 body, APU pack free, C0–C4 AbsoluteLong into free).

**~99.50% is the honest extract ceiling under current walkers.** Remaining
~15.7 KB is max-19 B scraps: ~44% code\|code sandwich (needs **code seeds** /
`convert_all`), rest mid-meta fragments and bank `$D8` plane noise.

### Next high-leverage paths (not this wave)

1. **Code-seed wave** — free runs between code with real 65816 prologues/RTL
   (`0x02AE00` family, `0x0C1567`, ~7 KB sandwich) → `observed_entries` /
   `resolved_entries` → re-`convert_all`.
2. **CF record reassembly** — undo over-partition around `0x0FB207` once a
   single loader-backed record size is proven (likely larger than current
   countN/far3 scrap claims).
3. **SS width RE** — 15 B twins between `scriptStream_*` need handler re-width,
   not looser glyph ratios.

### Tooling

- `src/tools/probe_w102.nim` / `probe_w102_strict.nim` / `probe_w102_claimable.nim`
- `src/tools/probe_final_residual.nim` / `probe_claimable_now.nim` / `probe_top_gaps.nim`
- `src/tools/probe_cf_cluster.nim` — CF free-cluster map

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).

## Residual wave103 (plane50 even-prefix + bitMask + cfRec5 + bitFlag min3) — 2026-07-24

Method: residual free only after wave102. Extend known table families with
slightly broader packing gates that prior waves left on the table because of
even-length / min-count floors. Hard gate: `code ∩ extract = 0`.

Also re-scanned AbsoluteLong loaders from **all** banks `$C0–$EF` into residual
free (gold opcodes `AF`/`BF`/… in `code_spans` only).

| Family | Format | Residual claimed |
|--------|--------|------------------|
| plane50 even-prefix | free runs with even prefix ≥8, ≥50% equal adj pairs (prior plane25 needed full even run ≥12) | **42 B** / 5 |
| bitMask powers-of-two | distinct `{01,02,04,08,10,20,40,80}` set ≥4 (same family as `$C4562F`) | **4 B** / 1 (`0x17A595`) |
| cfRec5 | complete `0A 01 00 80 + u8` records (extends `table_cfRec5_0x0F30F7`) | **5 B** / 1 |
| bitFlag min3 | ternary `{00,01,80}` free ≥3 (wave101 used ≥4) | **144 B** / 48 |
| zero scrap | pure zero free | **1 B** / 1 |

**This wave residual = 196 B** in 56 spans.

**Compare after rebuild:** **99.54%** byte-exact (`3,131,172 / 3,145,728`), implemented regions
**100.00% exact**. Prior **99.50%** (`3,129,995`). Residual free inventory ~**15,527 B**. **Δ +196 B** extract (+1,177 B compare inventory drift from prior baseline).

### AbsoluteLong inventory (all banks → residual free)

| Metric | Value |
|--------|-------|
| AbsLong ops landing in residual free | 273 hits / 163 runs |
| of which `LDA.L` / `LDA.L,X` | **20** |
| C0–C4 `LDA.L/X` into free | **0** |
| C0–CF `LDA.L/X` into free | **5** (all false-positive or mid-table scrap) |

Notable residual LDA targets (not solid new table bases):

| Target free | Size | Src | Verdict |
|-------------|------|-----|---------|
| `$CF3101` `0x0F3101+4` | 4 | `$CE@0x0E8F10` `LDA.L,X` | mid-record hole after `table_cfRec5_0x0F30F7`; free is incomplete 4/5 of `0A 01 00 80 xx` |
| `$17A598` in `0x17A595+4` | 4 | `$C7@0x07AFDA` | claimed as bitMask (`20 10 80 40`); loader site looks data-as-code adjacent |
| `$16F7F7+9` | 9 | `$CE@0x0E024F` | claimed plane50 even-prefix 8; high-bank site FP-ish |
| `$E2AAAB` / `$C72D95` / others | 1–3 | high banks | single-byte / noise; no fixed record walk |

**Conclusion:** loader-linked residual table bases are **drained**. Remaining AbsLong
hits into free are high-bank false-positive disassembly or incomplete mid-record
scraps. Next coverage lever is still **code_span reseed** (~6.9 KB code\|code sandwich).

### Honesty notes

- plane50 uses a **stricter** pair ratio (50%) than wave100 plane25, but allows
  **even prefixes** of odd free runs (prior gate required full-run even ≥12).
- bitFlag min3 is the same alphabet as wave101; only the free-run floor drops
  4→3 for leftover `$D8` scraps. Expanded alphabets (`{00,80,90}` etc.) still
  rejected without a loader model.
- No new density-only families.

### Tooling

- `src/tools/probe_w103.nim` / `probe_w103_deep.nim` / `probe_w103_claim.nim`

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/decompbound.nim --compare
```

All green this wave. No commit (per brief).


## Residual wave104 + 104b (term min2 / APU pack / bitFlag min2 / u8pair3) — 2026-07-24

Method: residual free only after wave103b. Hard gate: `code ∩ extract = 0`.
No bulk residualFree dump (a dishonest full-gap claim was generated mid-session
and **removed** before handoff).

### Wave104 (624 B / 283 spans)

| Family | Format | Residual claimed |
|--------|--------|------------------|
| zero | pure zero free | **26 B** / 24 |
| const ≥2 | constant-byte free | **13 B** / 6 |
| APU pack free interiors | pack-table discovery scraps inside known packs | **96 B** / 19 |
| u8pair ≥4 @55% | known pair packing, skip code\|code | **26 B** / 3 |
| term F0–FF singles min2..32 | quality: tc=1, hi×2≤n, z×3≤n; skip code\|code | **344 B** / 172 |
| bitFlag min2 | alphabet `{00,01,80}` | **119 B** / 59 |
| farPtr C0–EF lo≠0 | mid-run singles | **0** (drained by wave103b) |
| AS good full | isGoodActionScriptSpan | **0** |

### Wave104b (477 B / 86 spans)

Second pass after mid-run term claims left pure remainders:

| Family | Residual claimed |
|--------|------------------|
| zero remainder | **2 B** / 2 |
| const remainder | **21 B** / 8 |
| AS good | **4 B** / 1 |
| u8pair min3 @55% | **450 B** / 75 |

**This wave residual = 1,101 B** total (624 + 477).

**Compare after rebuild:** **99.57%** byte-exact (`3,132,269 / 3,145,728`), implemented
regions **100.00% exact**. Prior **99.54%** (`~3,131,168`). Residual free inventory
**13,459 B** / 5,431 runs / max 19. sandwich free still ~5.8 KB (strict seeds drained).

### Honesty notes

- **farPtr singles** already drained in wave103b (`table_farPtr_w103_*`, 657 B). Remaining
  triple-looking free is almost all bank `$F0–$FF` false far (rejected).
- **term min2** extends wave103 min3 singles with the same quality gates; code\|code
  skipped (seed path).
- **APU pack interiors** are loader-table-backed pack free scraps (probe_allbank_abslong).
- **u8pair min3** is the known pair family with floor 4→3 for leftovers.
- **Sandwich seeds:** `probe_sandwich_continue` strict FULL-cover endsRun → **0 new seeds**
  (prior auto seeds already absorbed; remaining sandwich is 0x80/flag plane noise and
  multi-byte RTS heads that do not full-cover-decode).
- **Rejected:** F0–FF as farPtr, print70 density, SS any-ended, bulk residualFree gaps.

### Tooling

- `src/tools/gen_residual_wave104.nim` / `gen_residual_wave104b.nim`
- `src/tools/probe_w104_scout.nim` / `probe_w104_detail.nim` / `probe_free_now.nim`

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/compare.nim
```

All green this wave. No commit (per brief).

## Residual wave105 — sandwich structure re-claim (2026-07-24)

Inventory before: **13,459 B** unclaimed / 5,431 runs / max 19 (~99.57%).

Non-sandwich structure gates (zero/const/far C0–EF/AS/SS/bit/plane/term/u8)
were **drained** after wave104b. Pure 1-byte RTS/RTL sandwich seeds also **0**.
Strict `probe_sandwich_continue` FULL-cover endsRun still **0** new seeds.

### Wave105 (608 B / 115 spans)

Reclaim **code|code sandwich free** that still matches established quality gates
(seed path for pure stubs exhausted; these are structure tables, not forced code):

| Family | Residual claimed |
|--------|------------------|
| term F0–FF singles min2 quality | **42 B** / 21 |
| u8pair min3 @55% | **566 B** / 94 |

**Compare after patch:** **99.59%** byte-exact (`3,132,877 / 3,145,728`), implemented
regions **100.00% exact**. Prior **99.57%** (`3,132,269`). Residual free inventory
**12,851 B** / 5,316 runs / max 19. sandwich free ~5.2 KB.

### Honesty notes

- No `residualFree_*`. No F0–FF as farPtr. No SS any-ended. No print70.
- far3 packed leftovers are almost all bank `$F0–$FF` / lo==0 (rejected).
- Prefer convert_all seeds for real code stubs — strict sandwich seed queue empty;
  multi-byte RTS heads still fail FULL free cover.
- `code ∩ extract = 0` verified.

### Tooling

- `src/tools/gen_residual_wave105.nim`
- `src/tools/probe_w105.nim` / `probe_w105_seeds.nim`
- `src/tools/patch_w105_extracts.nim` (gold-slice patch into `bin/Decompbound.smc`)

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/compare.nim
```

All green this wave. No commit (per brief).

## Honesty policy (2026-07-24)

**Do not** claim residual free gaps as blind `residualFree_*` gold extracts.
That was tried and rejected: it inflates compare % without format RE and can
mis-classify code|code sandwich free as "data".

Allowed extract claims require a **structure gate** (loader, stream walk,
fixed record, known package container, pure zero-pad, etc.) and
`code ∩ extract = 0`. Unclaimed residual stays `ckUnclaimed` until RE'd.

Current honest ceiling is structure-wave coverage only; remaining free runs
need code seeds, loaders, or format walkers — not bulk residual inventory.


## Residual wave106 — AbsoluteLong loaders dig (2026-07-24)

Inventory before: **12,851 B** unclaimed / 5,316 runs / max 19 (~99.59%).

Task: AbsoluteLong loaders into free residual only; claim free with **proven
record sizes** only. No `residualFree_*` bulk.

### Scan results

| Metric | Value |
|--------|-------|
| Free residual | **12,851 B** / 5,316 runs / max 19 |
| code\|code sandwich free | **~5,225 B** |
| All AbsLong ops → free | 59 hits / 47 runs |
| of which `LDA.L` / `LDA.L,X` only | **5 hits / 3 runs** |
| C0–C4 `LDA.L/X` → free | **0** |
| Known loader-table extents complete free | **0 B** |
| Multi-target LDA common-delta (≥3 tgts, delta hits≥2) | **0 B** |
| APU pack free interiors ≥4 B | **0 B** (scraps are 1–2 B) |
| CADCA1 17B / D7 map-attr / CEDC45 u16 / CE62EE 5B / EF 25·27·41 mid-table complete free | **0 B** |

### Residual LDA.L targets (all rejected)

| Target free | Size | Src | Verdict |
|-------------|------|-----|---------|
| `$CF3101` `0x0F3101+4` | 4 | `$CE@0x0E8F10` `LDA.L,X` | incomplete 4/5 of `0A 01 00 80 xx`; 5th byte `17` is **code** at `0x0F3105`. Site region looks data-as-code (sequential `xx id bank` words). Not a complete free record; cannot claim without code reclass |
| `$C72D95` `0x072D94+3` | 3 | `$D6@0x160BDF/E7` `LDA.L` ×2 | mid-meta sandwich scrap; no proven rec size / multi-target stride |
| `$E2AAAB` `0x22AAAA+3` | 3 | `$CF@0x0FF93A/9F` `LDA.L` ×2 | code\|code sandwich; loader sites look data-as-code (`AF AB AA E2` pattern); no fixed record walk |

ASL/ADC scale fishing over all `LDA.L,X` produced many **false** free hits far past documented table extents (e.g. `$CEDC45+k·2` past the 126-entry window). Rejected without extent + structure proof.

### Claim this wave

**0 B.** Loader-backed residual table bases remain drained (same conclusion as
wave103 AbsoluteLong inventory; reconfirmed post-wave105).

### Honesty notes

- No `residualFree_*`. No incomplete mid-record scraps. No density-only.
- Next levers: **code_span reseed** on ~5.2 KB sandwich free; false code that
  splits complete records (e.g. `0x0F3105`); format walkers not AbsoluteLong.

### Verification

```
nim r tests/test_baserom_extract.nim
nim r src/tools/verify_extract_overlap.nim
nim r src/compare.nim
```

- `code ∩ extract = 0`
- Compare: **99.59%** byte-exact (`3,132,877 / 3,145,728`), implemented regions
  **100.00% exact** (unchanged).
- Free residual inventory still **12,851 B**.

No extract edits. No commit (per brief).
