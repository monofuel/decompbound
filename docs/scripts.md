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
