# Scripts: text + the event system (decomp track)

**Status:** CHARSET + POINTER TABLES + DUMP TOOL STARTED. Event opcode
semantics and full control-code widths still open. See the hub,
`docs/decompilation.md`. This is the one that lets us **read the game**.

EarthBound's "scripts" are two intertwined layers, both stored as data the game
interprets at runtime:

1. **Dialogue text** — the words, in EB's own (non-ASCII) character encoding,
   sprinkled with **control codes** (line break, wait-for-button, "insert
   player name," "insert item/PSI name," window control, portrait, etc.).
2. **The event system** — the control-code "bytecode" that drives *game logic*:
   NPC conversations branching on flags, cutscenes, item-give, battle triggers,
   teleports, party changes. (The CoilSnake community exposes this as CCScript.)

"I'd love to see the scripts" = extracting both layers into a readable dump —
the dialogue as text, the events as a legible instruction listing.

## Why this is the heart of it

Text + events *are* EarthBound — its writing is the reason the game is beloved,
and the event system is the game's actual logic. Decoding them is the most
"decompilation" of the data tracks: it turns opaque bytes into the story and
the machine that tells it.

## Relationship to `text-log.md`

`docs/text-log.md` is the **live-streaming feature** (echo dialogue to stdout as
you play, by hooking the print routine). **This track is the format RE +
static extraction** behind it: the character table, the full control-code set,
*and* the event-interpreter opcode set — enough to dump scripts straight from
the ROM without playing to them. They share the text-decoding RE; text-log is
one consumer of it.

## The instrument: hook the interpreters

Two dynamic hooks (`docs/decompilation.md`) crack this fast:

- **Text-print routine** — read the character byte per print call, decode via
  the char table → the dialogue stream (exactly text-log's approach).
- **Event interpreter** — find the routine that fetches and dispatches event
  control codes; log each opcode + operands as it executes → you learn the
  event "instruction set" by watching it run, then disassemble the rest
  statically.

## Round-trip verification

Per the hub: **`encode(decode(bytes)) == bytes`**. Decode a script block to a
readable text/event listing, re-assemble it, and get the original bytes back.
This proves we've mapped every control code and operand width, not just the
common ones — the same honesty the 65816 assembler gave the code.

## Components

1. **Character table** — byte → glyph (EB offsets from ASCII; a lookup table).
2. **Text control codes** — line break, wait, name/item/PSI substitution,
   window/portrait control; decode to readable tags (`[wait]`, `[name:1]`).
3. **Event opcode set** — the event interpreter's control codes: operands,
   widths, and semantics (flag test/set, give item, start battle, teleport…).
4. **Script extractor** — dump the ROM's dialogue as text and events as a
   listing; the browsable payoff.
5. **Round-trip assembler** — re-encode the listing to byte-exact ROM data.

## Findings so far (verified byte-exact against the ROM)

Two grok digs, both spot-verified:

**Text encoding — DONE.** Printable characters are `byte - 0x30` (ASCII + 0x30).
Confirmed by decoding two independent blocks to clean English (file `0x63040` →
"INPUT YOUR COMMAND.", `0x45B67` → "PSI info.Unconscious"). Line break = `0x00`.

**Text control-code VMs — primary + secondary (dig 2026-07-24).** There is a
**primary** dispatch and a set of **secondary** sub-op VMs; `$C179AA` is not the
top-level switch.

- **Primary** at SNES **`$C1890E`** (file `0x1890E`): CMP chain for CCs
  `0x00–0x14` and `0x18–0x1F`. Glyph path continues at `$C18B04`. CCs `0x15–0x17`
  are pre-dispatch dialogue-pointer table lookups (`$C18815` / `$C1886F` /
  `$C188C8`) before the main switch.
- **Secondary installers:** primary `0x18–0x1F` write a collector address into
  `$1E` (e.g. `0x19` → `$C18ACC` does `LDY #$79AA; STY $1E`), so the next stream
  byte is handled by a sub-op VM.
- **Secondary `$C179AA`** (file `0x179AA`, family for primary `0x19`): `REP #$31`
  + `TXA` + sparse CMP chain for sub-ops `02,04,05,10,11,14,16,18–28`; unknown →
  `LDA #0`. Exit `PLD; RTS` at `$C17B54`/`$C17B55`. Handlers `0x1B–0x28` mostly
  load a next-collector immediate (0 stream operands at this layer); `0x1E`/`0x1F`
  call helpers (`JSR $AD26` / `$AD02`) that consume operands (widths still TODO).
- Other secondary bases (files): `0x1790B` (`0x18`), `0x17B56` (`0x1A`),
  `0x17C36` (`0x1B`), `0x17D94` (`0x1C`), `0x17F11` (`0x1D`), `0x1811F` (`0x1E`),
  `0x181BB` (`0x1F`).

**Operand model.** The interpreter walks a byte stream via a far pointer held in a
struct (indexed by Y / dp), reading operands then advancing by the opcode's width
and writing the pointer back (e.g. op `0x02` advances +4: `ADC #$0004` near
`0x17C9D`).

**The frontier (needs the dynamic hook).** Story semantics (give-item, battle,
teleport, party, flags) live in the text-CC secondary handlers, not the
action-script table. Pinning meanings wants the live interpreter hook
(`docs/text-log.md`). Dispatch layout + encoding are the solid foundation.

**Two more layers located (verified byte-exact):**

- **Event/object-script opcode dispatch: file `0x9558`** (SNES `$C09558`) — the
  main event/entity bytecode interpreter, the `[$80],Y` stream system that drives
  NPCs, cutscenes, *and* doors — distinct from the `$C179AA` *text* control-code
  dispatch. (Resolved as a Goal-1 frontier jump door.) The precise two-table
  dispatch structure is verified below (grok dig 2026-07-21, conductor-verified
  byte-exact against the ROM). Per-opcode *semantics* remain tentative.
- **Dialogue text-block pointer table: file `0x8CDED`** (SNES `$C8CDED`) — 4-byte
  entries (`id * 4`), each a 24-bit far pointer to an encoded script block (first
  entries point to `$C8BC2D`+). Parallel tables at `~0x8D1ED` / `~0x8D5ED`; lookup
  code at file `0x18815` / `0x44676`. Bulk script bytes are scattered (verified
  blocks at `0x45B67`, `0x63040`, and the `~0x8BCxx` cluster). A top-level master
  dialogue-ID table wasn't isolated — that needs the dynamic hook.

### Entity action-script VM — opcode mapping (dig 2026-07-21)

There are **two** interpreters, and they are NOT the same VM:

- **Entity action-script VM** — dispatch `$C0952B` → jump table `$C09558`
  (`JSR ($9558,X)`), opcodes `0x00–0x4C`. Drives NPC/entity behaviour, movement,
  animation, doors, and cutscene sequencing via the `[$80],Y` stream.
- **Text control-code VM** — primary `$C1890E`, secondaries including `$C179AA`
  (documented above). This is where the *story* "event language" lives:
  give-item, start-battle, teleport, party change, dialogue-flag ops. **Still
  the frontier** — do not attribute those to the action-script table.

**Verified byte-exact (✅ — grok dig 2026-07-21, every table byte re-read from the
ROM by the conductor):** the dispatch is **two tables**, split by opcode value at
`$C09524 CMP #$0070 / BCS`:

- **Low path — table `$C09558` (file `0x9558`), 77 entries.** Opcode `< $70`:
  `ASL A / TAX / JSR ($9558,X)` → `X = opcode*2`. Dense bound `($95F2−$9558)/2 =
  77`; all 77 words are in-bank code pointers spanning `$95F2..$9BF8`, first
  handler `$95F2` immediately follows the table. 69 unique targets (the tail
  duplicates the 8 high-path handlers). Entries 0..7 =
  `$95F2 $9603 $9627 $964D $9685 $96AA $96C3 $99DD`.
- **High path — table `$C095E2` (file `0x95E2`), 8 entries.** Opcode `>= $70`:
  `AND #$0070 / LSR×3 / TAX / JSR ($95E2,X)` → 8 slots `X∈{0,2,…,E}`. These 8
  words physically **overlay** words 69..76 of the `$9558` table; targets
  `$96CF $9A38 $9A3E $9A44 $9713 $9731 $974F $993D`.
- Sampled handlers all disassemble as real routines ending `RTS`. A few whose
  bodies are unambiguous: high-path `$9A38 = INC $10F2,X`, `$9A3E = DEC $10F2,X`
  (per-entity timer op at `$10F2`), `$96CF` sets `$10F2,X = −1` on a `$FF`
  stream sentinel. Most bodies still need the live trace for full semantics.
- **NOT a single `0x00–0x6F` table** (an earlier note); opcodes past the 77 low
  slots route through the high-path table, and frontier sites like `($FCFC,X)` /
  `($C08E,X)` near here are misaligned decodes into data/operands, not tables.
- **Round-trip block file `0x3A076`** (`$C3A076`, 9 bytes), an idle-entity loop
  seen live on many slots: `42 e3 a6 c0 | 06 01 | 19 76 a0` decodes as
  `CALL $C0A6E3` (op `0x42`, +3 far ptr) · `WAIT 1` (op `0x06`, +1) ·
  `GOTO $A076` (op `0x19`, +2, target = the block's own start → loops).
  `encode(decode(bytes)) == bytes`; do NOT linear-decode past a `0x19` (the
  following bytes are other scripts — you must follow the jump).
- **Bitop sub-ops** (op `0x0D` → jump words at `$C09ABD`, static-disasm verified):
  targets `$9AC5` / `$9ACC` / `$9AD3` / `$9ADB` = **AND / ORA / ADC / EOR** on
  the addressed value (re-check assign-style ops against gold before relying on
  older “XOR + assign” notes).

#### Declared in the decomp registry (data, not script content)

The action-script jump tables are now **project-owned declared data** in
[`src/decompbound/snes_src/action_script_tables.nim`](../src/decompbound/snes_src/action_script_tables.nim)
and registered via `adopted.nim` / `rom_chunks.nim` as `ckImplementedMeta`
(pointer tables into our decompiled code — **not** dialogue or event bytes).
Gold-gated like header/vectors.

| Name | File offset | Len | SNES | Role |
|------|-------------|-----|------|------|
| `actionScriptDispatchTable` | `0x9558` | 154 (77×u16) | `$C09558` | Low-path opcode → handler words (high-path `$C095E2` = last 8 words) |
| `jmpTable8C65` | `0x8C65` | 8 (4×u16) | `$C08C65` | Companion jump table (convert_all seed) |
| `jmpTableA1AE` | `0xA1AE` | 32 | `$C0A1AE` | Stride-4 word+pad table |
| `jmpTableA350` | `0xA350` | 16 (8×u16) | `$C0A350` | Eight code pointers |

Fetch loop (file `0x951E`): `LDA [$80],Y / INY / AND #$00FF / … / JSR ($9558,X)` —
the opcode byte is consumed **before** the handler runs; handlers see only operands
at `[$80],Y`.

#### Operand widths (handler disasm, ✅ static)

Verified from gold-gated `code_bank00` disasm of the dispatch targets (M/X=16).
Instruction bytes reconstructed from the project opcode table (same encodings the
assembler emits against gold).

| Op | Handler | Ops | Meaning (width) | Evidence (file / instr bytes) |
|----|---------|-----|-----------------|-------------------------------|
| **`0x06`** | `$C096C3` (table word 6) | **1** | **WAIT** u8 frames → `$1372,X` | file `0x96C3`: `A6 8A` `LDX $8A`; `B7 80` `LDA [$80],Y`; `29 FF 00` `AND #$00FF`; `9D 72 13` `STA $1372,X`; `C8` `INY`; `60` `RTS`. One stream byte, one `INY`. |
| **`0x19`** | `$C09649` (table word 25) | **2** | **GOTO** abs16 → replace script PC (Y) | file `0x9649`: `B7 80` `LDA [$80],Y`; `A8` `TAY`; `60` `RTS`. 16-bit load (M=0) becomes the new Y; no `INY` (control transfer, not linear advance). |
| **`0x42`** | `$C0993D` (table word 66) | **3** | **FAR CALL** — word+bank to `$0A5A`/`$0A5C`, then `JSL $C09D9E` | file `0x993D`: `B7 80` `LDA [$80],Y`; `8D 5A 0A` `STA $0A5A`; `C8 C8` `INY×2`; `B7 80` `LDA [$80],Y`; `C8` `INY`; `8D 5C 0A` `STA $0A5C`; … `22 9E 9D C0` `JSL $C09D9E`. Three stream bytes total. |

These widths match the idle-loop round-trip block at file `0x3A076` above. Do not
linear-scan past `0x19`.

**Tentative (🟡 — from a PARTIAL live trace; only ~12 of 77 ops fired in idle
Onett):** rough semantics clusters seen so far — `0x06` wait, `0x19` goto,
`0x42` far-call (`$C09D9E` anim/interaction kernel), conditionals sourced from
`$1516,X` (per-entity work register), timers from `$10F2,X`. Movement (`0x28–
0x30`), far-call (`0x03–0x05`), bitop-to-flags (`0x0D`), and halt (`0x00`) did
**not** fire idle — they need door/talk/cutscene states to observe. Treat the
per-opcode meaning table as unproven until each opcode is traced live. The story
event ops (item/battle/teleport/party) are the OTHER VM and remain unmapped.

**Script-engine WRAM (🟡, from the same trace — verify before relying):** entity
work/condition `$1516,X`; frame/anim timer `$10F2,X`; story/event flags `$988B…`
(hit via absolute WRAM bitops, not a dedicated opcode). Candidates needing a
clean trace: `$1372` wait, `$13FE`/`$148A` script PC, `$12E6` stack depth.

**Next dig:** force door-enter / talk / cutscene states to fire `0x00`, `0x03–
0x05`, `0x0D`, `0x28–0x30`; separately hook the text-CC VM (`$C179AA`) for the
give-item / start-battle / flag story ops.

**Text-stream decode mechanics (verified byte-exact):**

- **Glyph → tile index:** `glyph_id = (byte − 0x50) & 0x7F` — verified at file
  `0x44750` (`38 e9 50 00 29 7f 00` = `SEC; SBC #$0050; AND #$007F`), the
  width/layout walker. (Distinct from the *storage* encoding `byte = ASCII + 0x30`
  above; both are self-consistent.)
- **Text-block dispatch: file `0x1890E`** (SNES `$C1890E`) — the dialogue-stream
  interpreter. `CMP #$0020; BCC` (verified at `0x18914`: `c9 20 00 90 03 4c 04 8b`)
  splits control codes (`< 0x20`) from glyph runs; `0x00` is the terminator
  (special-cased in the fetch loop at `$C1878F` as well as in the CMP chain).
- **Fetch loop: file `0x18754`** — `LDA [$0A]; AND #$00FF; BEQ …; STA $14; INC $0A`
  (stream already advanced past the opcode before dispatch). Working pointer is
  `$1A/$1C`; secondary multi-byte mode uses `$1E` as a bank-local handler ptr
  (RTS-trick at `$C187D0`).
- **Runtime dump tool:** `src/tools/script_dump.nim` + `src/decompbound/text_decode.nim`.
  Stdout only — never write dialogue dumps into the repo.

### Text control codes with evidence (operand width + purpose)

| Code | Ops | Purpose (current reading) | Evidence |
|------|-----|---------------------------|----------|
| **`0x00`** | 0 | **End of block.** | Fetch BEQ at `$C18794`; dispatch `CMP #$0000` → JMP `$8A04` → `JSL $C438B1` then `JMP $8754`. |
| **`0x01`** | 0 | **Line / layout helper** (not a pure no-op). | JMP `$8A0B`: `JSR $04B5` (window/width lookup via `$8958` tables); if zero, return to loop, else same end path as `0x00`. Tag: `[nl]`. |
| **`0x02`** | 0 | **Prompt / suspend interpreter.** | JMP `$8B0A`: copies text-state pointer, `JSR $869D` / `JSR $4049`, saves resume ptr to `$2A/$2C`, **`PLD; RTL`** out of the JSL'd interpreter. No stream operand reads. Leading `@` in blocks like `0x63040` / table id 30 is a **real glyph** (`0x70` = ASCII `@` + `0x30`), not an operand. Tag: `[prompt]`. |
| **`0x15` / `0x16` / `0x17`** | **1** (u8 index) | **Call / include** another text block via far-ptr table 0/1/2. | Pre-dispatch at `$C187ED`. Handler `$C18804` (and siblings): `LDA #$CDED / #$D1ED / #$D5ED` + `LDA #$00C8` → tables `$C8CDED` / `$C8D1ED` / `$C8D5ED`; `LDA [$0A]; AND #$00FF; ASL; ASL` → **1-byte** index × 4; `INC $0A` once; loads far ptr and redirects `$1A/$1C`, then `JMP $890E`. Each table is `0x400` bytes = **256** entries. Tags: `[call0:XX]` / `[call1:XX]` / `[call2:XX]`. |
| **`0x18`** | 1+ (sub-op) | **Multi-byte CC prefix** (family `$790B`). | Main handler `$8AC4`: `LDY #$790B; STY $1E; JMP $8754`. Next stream byte is dispatched via `$1E` (secondary switch at file `0x1790B` for sub-ops `0x00–0x0A`, `0x0D`, …). First-order dump model consumes **1** sub-op byte; some sub-ops re-arm `$1E` for more operands. Tag: `[cc18:XX]`. |
| **`0x1C`** | 1+ (sub-op) | **Multi-byte CC prefix** (family `$7D94`). | Main handler `$8AE4`: `LDY #$7D94; STY $1E`. Secondary at file `0x17D94` is a CMP-chain on the sub-op. Tag: `[cc1C:XX]`. |

**Still open (need live hook or deeper sub-op RE):** exact semantics of `0x03–0x14` / `0x19–0x1B` / `0x1D–0x1F` (many just `LDY #imm; STY $1E` — secondary handler installers); full sub-op operand widths under `0x18`/`0x1C`; name/item/PSI substitution codes.

**Spot-check blocks (storage = ASCII+0x30):**

- File `0x63040`: `[cc18:0A][prompt]@INPUT YOUR COMMAND.[end]`
- File `0x45B67`: `PSI info.Unconscious[end]`
- Table0 id 0 @ `0x8BC2D`: spaces then `[end]`; id 1: ` in the [end]`; id 30: `@Do you want to [end]`

## What goes in git (and what never does)

The **extractor, the character/opcode tables, and the format docs are code —
commit them.** The **extracted scripts themselves are a copyrighted asset —
never commit them** (dialogue is a literary work; events are creative
expression). The dump is generated locally from the user's own ROM into a
git-ignored path, exactly like graphics/audio. So **"see the scripts" means *run
the extractor on your ROM*, not *open a file in the repo*.** See AGENTS.md
"Copyright hygiene" and `docs/copyright-notes.md` §2b.

## Definition of done

- [x] Character table (ASCII+0x30) + pointer tables + first control codes decode
      dialogue readably via `script_dump` (stdout only).
- [ ] Full text control-code set + sub-op widths (live hook + secondary RE).
- [ ] The event opcode set is documented (learned via the interpreter hook +
      disassembly).
- [ ] An **extractor** that produces a readable dump of the game's scripts —
      dialogue as text, events as a listing — from the user's ROM. (The dump is
      generated locally into a git-ignored path, never committed.)
- [ ] Round-trip: a decoded script block re-encodes byte-exact against gold.

## Non-goals

- Translation / rewriting the script (this is reading, not romhacking).
- Full name/item substitution polish in v1 (annotate the codes first; pretty
  substitution later — same staging as `text-log.md`).

**Scope:** text + event-system RE + an extractor + a round-trip encoder. The
live-log feature (`docs/text-log.md`) rides on the text half. Parallel-safe.
</content>
