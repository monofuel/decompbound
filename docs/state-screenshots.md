# State-screenshots: every screenshot IS a save-state (goal track)

**Status:** NOT STARTED (design only — do not implement yet). A tooling/UX track;
parallel-safe, rides on the existing save-state code (`save_state.nim`) and windy's
drag-and-drop.

## The idea

Embed a (compressed) save-state **inside the screenshot PNG itself**, in an
ancillary chunk that image viewers ignore. The PNG still opens as a normal 256×224
picture everywhere — but our emulator can pull the machine state back out of it.
Then: **drag a screenshot onto the game window → restore that exact state.**

So a screenshot stops being a picture *of* a moment and becomes the moment itself.

## Why this is worth building

- **Bug reports become one-file repros.** "The HP/PP band is black" + a screenshot =
  the exact frozen machine that reproduces it. No "what were you doing", no slot
  files to ship — the picture *is* `slot1.state`. (We just lived this: the whole
  HP/PP fix hinged on the user's save-state. Imagine if the F9 bug-shot already *was*
  that state.)
- **Debugging autopsies for free.** `make inspect` already loads a state + dumps
  PPU/HDMA + re-renders. Point it at any screenshot and you can autopsy any captured
  frame after the fact — the autoshot history becomes a scrubbable state timeline.
- **Sharing = teleporting.** Send someone a PNG of a spot in Onett; they drop it in
  and they're standing there. Speedrun routing, "check this glitch", handing off a
  hard fight — all become "here's a picture."
- **It composes with everything we have.** The autoshot system (every 5s), the F9
  debug bundle, and F12 all already write frames; making them state-carrying is a
  write-path change plus a drop handler, not new infrastructure.

## How it works

**Write (embed):** PNG is a signature followed by typed chunks
(`IHDR … IDAT … IEND`). Chunks whose type has a **lowercase first letter** are
*ancillary* — decoders that don't recognise them skip them. We append a private
ancillary chunk carrying the compressed state.

- Proposed chunk type: **`ebSt`** (EarthBound State). The casing is meaningful and
  correct for our use: `e` lowercase = ancillary (safe to ignore), `b` lowercase =
  private (not a registered PNG chunk), `S` uppercase = reserved bit clear, `t`
  lowercase = safe-to-copy (a dumb image editor may re-save and keep it).
- Chunk data layout:
  ```
  magic     : "EBSS"            (4 bytes, sanity)
  version   : u16               (state format version, mirrors save_state StateVersion)
  romHash   : u32 (or 8 bytes)  (hash of the ROM the state came from)
  rawLen    : u32               (uncompressed state size, for the inflate buffer)
  payload   : deflate(stateBytes)
  ```
- The state bytes are exactly what `save_state.nim` already serialises (CPU + WRAM +
  VRAM + CGRAM + OAM + PPU/HDMA regs + APU image + SRAM). Refactor `saveState` to
  serialise to a `seq[byte]` (a stream over a memory buffer) so both the slot files
  **and** the PNG chunk reuse one code path.

**Restore (drag-and-drop):** windy already exposes file-drop (the user added it).
On drop of a `.png`:
1. Read the file, walk its chunks, find `ebSt`.
2. Validate `magic` + `version` + `romHash` (reject a state from a different ROM or an
   incompatible format — show a message, don't crash).
3. Inflate the payload, then `loadState` it **in place** (the same in-place restore
   the slot loader uses, so the live audio stream stays wired — see the
   save-state-kills-audio fix, `3c48c96`).

## Compression + size

A raw state is ~330 KB (WRAM 128 KB + APU 64 KB + VRAM 64 KB + SRAM 8 KB + regs). It
is *very* compressible — WRAM/VRAM/APU RAM are mostly sparse/repetitive — so deflate
should land it around ~50–150 KB depending on the scene. A screenshot PNG grows from
a few KB to that; still tiny, still a normal PNG. Use **zippy** (already in the tree
via pixie) for `deflate`/`inflate` — no new dependency.

Design knob: the autoshot loop fires every 5 s. State-embedding *every* autoshot is
fine size-wise (~a few MB/hour) but optional — reasonable default is **F12 + F9
bundles carry state; rapid autoshots stay lightweight**, with a flag to make autoshots
state-carrying too. Decide at implementation; note whatever we pick so it isn't a
silent cap.

## Components

1. **State (de)serialise to a buffer** — refactor `save_state.nim` so the state
   round-trips through a `seq[byte]`, not only a file. Slots + PNG chunk share it.
2. **PNG chunk writer** — inject an `ebSt` chunk into a PNG (length + type + data +
   CRC-32, placed before `IEND`). Either post-process pixie's PNG bytes or write a
   thin chunk-append helper. (Pixie/zippy already have CRC-32 + deflate.)
3. **PNG chunk reader** — walk chunks, extract `ebSt`, validate header, inflate.
4. **saveScreenshot integration** — `play.nim`'s `saveScreenshot` (and the F9 bundle
   path) captures the current state, compresses, embeds. Guard behind the ROM hash so
   the shot is self-describing.
5. **windy drop handler** — wire the file-drop callback in `play.nim`'s main loop to
   the reader + `loadState`. Confirm the exact windy drop API at implementation time
   (the user added it; find the callback name in `../windy`).
6. **`make inspect` + tools accept a `.png`** — let `state_inspect` (and friends) load
   a state straight from a screenshot, not just a slot file. Turns the autoshot folder
   into a browsable state archive.

## Round-trip verification (the honest bar)

- **State fidelity:** `loadState(extract(embed(state))) == state` — a screenshot's
  embedded state restores byte-identically to the original capture. Concretely: save a
  slot, screenshot it, drop the screenshot, and the two states compare equal.
- **PNG validity:** the state-carrying PNG still opens as a correct 256×224 image in
  standard viewers (the chunk is invisible to them). Verify against `pixie`'s own
  decode + at least one external viewer.
- **ROM/version guard:** dropping a screenshot from a different ROM or an old format is
  rejected cleanly (message, no crash).

## Copyright hygiene (important)

A state-carrying screenshot **embeds VRAM/WRAM/APU RAM — i.e. copyrighted game data**
(decoded graphics, script bytes, samples). Treat these exactly like `.srm` / `.spc` /
`.state` files: **user-generated, git-ignored, never committed.** Sharing one shares
game data (the user's own play data, like handing someone a save file) — that's the
user's call, not something the repo ships. The *code* (chunk format, reader/writer,
drop handler) is ours and committable; the *state-PNGs* are not. See AGENTS.md
"Copyright hygiene" and `docs/copyright-notes.md`.

## Definition of done

- [ ] `save_state` round-trips through a `seq[byte]` (shared by slots + PNG).
- [ ] F12 (and F9 bundle) screenshots embed a compressed `ebSt` state chunk.
- [ ] The PNG still displays correctly as a normal image everywhere.
- [ ] Dragging a state-screenshot onto the window restores that exact state
      (in-place, audio intact), with ROM/version guards.
- [ ] `state_inspect` / `make inspect` can load a state from a `.png`.
- [ ] Round-trip test: screenshot → drop → byte-identical state.

## Non-goals

- Not a general PNG-metadata framework — one private chunk, one purpose.
- Not cross-ROM or cross-emulator state portability (guarded out, not solved).
- Not a replacement for the slot save-states — this is additive (screenshots gain a
  superpower; slots stay).

**Relationship to other tracks:** rides on `save_state.nim`; complements
`docs/input-replay.md` (replays reach a state by *doing*, screenshots reach it by
*restoring*) and `docs/apps.md` (an autoshot browser could scrub the state timeline).
Parallel-safe; touches `save_state.nim` + `play.nim` + a small PNG-chunk helper.
