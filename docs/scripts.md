# Scripts: text + the event system (decomp track)

**Status:** NOT STARTED. A data-decompilation track — see the hub,
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

**Control-code / event dispatch — located.** The interpreter's opcode dispatch is
at SNES **`$C179AA`** (file `0x179AA`: a `REP #$31` + `TXA` + CMP-chain switch).
The high control codes **0x1B–0x28** form a chain of `CMP #$00xx / BNE / JMP
handler` at file **`0x17A05`+** (e.g. `0x17A0D` = `C9 1C 00 D0 03 4C D9 7A`,
verified). A second sub-dispatch handles low values 0x00–0x0B at file `0x17B56`.
Common exit: `PLD; RTS` at `0x17B55`.

**Operand model.** The interpreter walks a byte stream via a far pointer held in a
struct (indexed by Y / dp), reading operands then advancing by the opcode's width
and writing the pointer back (e.g. op `0x02` advances +4: `ADC #$0004` near
`0x17C9D`).

**The frontier (needs the dynamic hook).** The per-opcode *semantics* — which byte
is give-item vs set-flag vs start-battle vs teleport — are delegated to the
returned handlers, invisible in the dispatch alone. Pinning them down wants the
live interpreter hook (`docs/text-log.md`): watch real script bytes decode as the
game runs. The dispatch + encoding + operand mechanics are the solid foundation;
the opcode meanings are the next dig.

**Two more layers located (verified byte-exact):**

- **Event/object-script opcode dispatch: file `0x9558`** (SNES `$C09558`) — a
  56-entry jump table (opcodes `0x00–0x6F`, bounded by `CMP #$0070`), reached via
  `JSR ($9558,X)` from `$C0952B`. This is the main event/entity bytecode
  interpreter — the `[$80],Y` stream system that drives NPCs, cutscenes, *and*
  doors — distinct from the `$C179AA` *text* control-code dispatch. (Resolved as
  a Goal-1 frontier jump door.) **Per-opcode handlers mapped (semantics tentative,
  need the live hook):** each of the 56 opcodes' handler offset (`$95xx`–`$9Bxx`)
  and rough operand width (0–5 bytes) are disassembled — e.g. op `0x14` → `$9A87`,
  ~5 bytes (coords?); op `0x02` advances +4. Semantics cluster into flag test/set,
  give-item, start-battle (JSL), teleport (map + 2–4-byte coords), party
  add/remove, and conditional/loop — exact meanings + the flag layout still want
  the live interpreter trace.
- **Dialogue text-block pointer table: file `0x8CDED`** (SNES `$C8CDED`) — 4-byte
  entries (`id * 4`), each a 24-bit far pointer to an encoded script block (first
  entries point to `$C8BC2D`+). Parallel tables at `~0x8D1ED` / `~0x8D5ED`; lookup
  code at file `0x18815` / `0x44676`. Bulk script bytes are scattered (verified
  blocks at `0x45B67`, `0x63040`, and the `~0x8BCxx` cluster). A top-level master
  dialogue-ID table wasn't isolated — that needs the dynamic hook.

**Text-stream decode mechanics (verified byte-exact):**

- **Glyph → tile index:** `glyph_id = (byte − 0x50) & 0x7F` — verified at file
  `0x44750` (`38 e9 50 00 29 7f 00` = `SEC; SBC #$0050; AND #$007F`), the
  width/layout walker. (Distinct from the *storage* encoding `byte = ASCII + 0x30`
  above; both are self-consistent.)
- **Text-block dispatch: file `0x1890E`** (SNES `$C1890E`) — the dialogue-stream
  interpreter. `CMP #$0020; BCC` (verified at `0x18914`: `c9 20 00 90 03 4c 04 8b`)
  splits control codes (`< 0x20`) from glyph runs; `0x00` is the terminator
  (special-cased right after). Codes **`0x15/0x16/0x17`** switch the active stream
  via the `0x8CDED` / `~0x8D1ED` / `~0x8D5ED` far-pointer tables — the
  "call/include other text" mechanism. Observed control bytes in real blocks:
  `0x00–0x02, 04, 06, 07, 09–0B, 11, 12, 15–19, 1C`; per-opcode operand widths
  (the round-trip detail) still want the live hook.

## What goes in git (and what never does)

The **extractor, the character/opcode tables, and the format docs are code —
commit them.** The **extracted scripts themselves are a copyrighted asset —
never commit them** (dialogue is a literary work; events are creative
expression). The dump is generated locally from the user's own ROM into a
git-ignored path, exactly like graphics/audio. So **"see the scripts" means *run
the extractor on your ROM*, not *open a file in the repo*.** See AGENTS.md
"Copyright hygiene" and `docs/copyright-notes.md` §2b.

## Definition of done

- [ ] Character table + common text control codes decode dialogue readably.
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
