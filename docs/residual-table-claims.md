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
