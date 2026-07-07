# Hard problems — the honest wall

Not every question has a clean answer yet. This doc catalogs the genuinely **hard**
problems — the ones where the *path* isn't obvious, static analysis stalls, and we may
need a dynamic trace, a lucky break, or a new idea. Listing them openly beats pretending
they're solved (or quietly dropping them).

**The general weapon:** the emulator is a *dynamic-RE instrument*. When static disasm
stalls, reach the moment in-game, grab a `Ctrl+3` **save-state right there**, and let the
trace tool watch memory + the CPU at the instant the thing happens. Half the bugs this
project solved were cracked by a save-state at the exact frame — these problems want the
same treatment.

---

## 1. Every "Photo Man" location  ·  *status: cracking — dynamic trace landed the first confirmed spot*

**Breakthrough (2026-07-06):** a user F12 screenshot caught the Photographer *active*, with
the save-state embedded — the exact dynamic anchor this needed. From it:
- **Confirmed spot #1 — Peaceful Rest Valley (entrance):** player pos `$0B8E`=`0x0590`,
  `$0BCA`=`0x1B88`, sector `$89CA`=`0xFFFF`. Photographer spawned as **entity slot 10**, at
  X `0x05B0` (player + `0x20`) same Y — the framing offset.
- Spots are **position-triggered** (walk the exact tile → fire); miss the tile, miss the photo.
- A guessed "photo counter" (value 22 at `$7E00A9`) is **unconfirmed / distrusted** — it
  contradicts the player having taken only 1 photo. Do not rely on it.
- **Definitive finding (2026-07-07): there is NO central photo-spot table.** A deeper RE
  pass confirmed the spots are **scattered as individual scripted triggers inside each map's
  event bytecode** — walk the tile → the map script fires → spawn ops `$C096E3`/`$C096F3`
  place the photographer (slot 10) + run the fuzzy dialogue (`$C7AC00`). Found the end-game
  **album reader** at `~$C01819E`, but it only holds photo **order + captions** (`$C75562`
  strings) + per-index taken-flags — **no map/X/Y locations**. So there's nothing to "dump."
- **Only two ways to enumerate all spots:** (a) **capture them one-by-one as you play**
  (each Photographer F12 = one confirmed coord — the playthrough IS the enumeration), or
  (b) a full **event-script scan** across every map, interpreting the bytecode for the
  photographer-spawn opcode. (a) is cheap + already underway; (b) is a big RE project.

<details><summary>original "open — static exhausted" framing</summary>

**Want:** the full list of ~32 Photographer ("Say fuzzy pickles!") photo spots —
location + trigger order — extracted from the ROM.

**What we pinned (verified):**
- Dialogue: "fuzzy pickles" / **"photograph!"** at `$0x7AC00` / `$0x7AC68`.
- Photo-album text (end-game) at `$0x75562`.
- The event-script engine: dispatch table `$C09558` (56 handlers), `JSR ($9558,X)`.

**Why it's hard:**
- No clean central "photo-counter → coordinate table → spawn photographer" structure
  turns up in static disasm. The photo spots are likely **scattered as individual
  scripted triggers** inside the map/event bytecode — which is *interpreted at runtime*,
  so following it statically means hand-simulating the interpreter.
- The event opcodes' semantics (`$C095xx–$C09Bxx`) need a live interpreter hook to read
  reliably (per `docs/scripts.md`).

**Leads / approaches:**
1. ~~**Candidate table `~0x0D0000`**~~ — **REFUTED** (decode dig, commit `e3ca981`-era).
   Decoded to non-coordinate packed data (compressed-stream-like: small-int runs, `ff/1f`
   masks), **no code indexes `$0D:0000`**, and the ~31 count was coincidence. Siblings
   `~0x0A0000 / 0x0C0000 / 0x0E0000` refuted too. Blind static table-scanning is exhausted —
   the spots almost certainly live in **interpreted event/script data** or a small trigger
   table reached only through a pos-check the interpreter runs at runtime.
2. **Dynamic trace — THE path now.** Reach a photo spot in-game, `Ctrl+3` a save-state
   *right there*, and trace `$0B8E/$0BCA` (player pos) + `$89CA` (sector) + event state +
   the **PC at the instant the photographer spawns**. That reveals the exact check + the
   data it reads — turning a static needle-in-haystack into a one-frame observation.
   **The playthrough is the instrument** — a save-state at a spot is the whole key.
3. **Album-display code.** The end-game photo album walks the photos in order; it must
   reference the same list. Find that reader (from the album text `$0x75562`) → the list +
   order for free. Also aided by a save-state at the album screen.
</details>

---

## 2. The song-start protocol (standalone music)  ·  *status: open*

**Want:** songs actually *play* in the standalone jukebox (`sound_explore.nim` uploads +
runs the driver but renders near-silent). See `docs/music.md`.

**What we pinned:** the song-load chain (song table `0x04F70A`, pack table `0x04F947`,
upload `$C0AB06`). The packs upload correctly.

**Why it's hard:** after upload, the resident SPC driver needs a specific **"play song N"
command** poked to `$2140-$2143` (+ driver state at `$B549/$B53B`). That command interface
isn't pinned, and the loader tail that issues it is awkward to follow statically.

**Leads / approaches:**
1. Trace the loader tail (`$C4FBBD`) *after* the `JSL $C0AB06` — capture exactly what it
   pokes to the APU ports.
2. **The `.spc`-snapshot workaround** — in-game music already works, so dump the live APU
   state (64 KB + regs) to a `.spc` while a song plays, and play *that* standalone.
   Sidesteps the trigger entirely.

---

## 3. Battle-BG layer-entry exact fields  ·  *status: partially solved*

**Want:** the exact per-field layout of a battle-background layer entry (graphics ptr +
palette + anim-list ref) + the background-ID → layer mapping. See `docs/battle-backgrounds.md`.

**What we pinned:** the animation lists (`$C59400`, keyed by layer ID), the BG1+BG2
color-math combine, the battle code paths. The *gross* format is known.

**Why it's hard (mildly):** the exact ~12-byte entry fields need one more load-path trace
or a known background ID to disambiguate. Tractable — a `Ctrl+3` **in-battle save-state**
lets the trace tool watch the exact loads.

---

## 4. Event VRAM-upload garbage — Paula, inn, Lilliput (ONE bug)  ·  *status: root cause found, fix is delicate*

**Symptom:** a scripted event triggers, and part of the screen renders as **garbage tiles**.
Three instances, now proven to share **one root cause**:
- **Paula telepathy scene** — BG2 tilemap/CHR junk (mode 1).
- **Inn (Happy Happy) wake-up** — BG1+BG2+BG3 all junk (whole screen).
- **Lilliput Steps sanctuary vision** ("baby in a red cap") — a vertical column of broken
  **sprites** at center-screen: sprites 0-3 (tiles 00/02/04/06, `tileBase $4000`) whose CHR
  only **partially loaded**.

**Root cause (confirmed):** the game DMAs graphics into VRAM during the scripted event —
BG tiles/CHR in the first two, **sprite (OBJ) CHR** in Lilliput — and **some of that DMA
doesn't fully land** in our emulator. The OAM/tilemaps are correct (the game set them up
right); the *graphics they point at* are absent or partial. Suspect the DMA path
(`snesbus.runDma` → `writeBbus` → `vram` + `vramIncrement`/VMAIN): word order, incr mode
(1 vs 32), auto-inc, or size==0 wrap on the specific transfer shape these events use.

**Why it's hard:** it's a **DMA-accuracy** bug in delicate `snesbus`/`ppu` territory
(regressions happened there today), and pinning *which* transfer drops needs a live trace.

**Leads / approaches:**
1. **Live DMA trace (surest).** A `Ctrl+3` save-state from **just before touching the
   sanctuary / entering the scene** (while the map still looks *fine*) → step through the
   event, trace every DMA to `$2118/$2119` (+ `$420B` general DMA, `bbad=0x18/19`) + VMADD,
   and find which upload lands short vs. a working one (e.g. tiles 02/06 loaded, 00/04 didn't).
2. **Static DMA-path review** — audit `runDma`'s 1/2/4-byte + fixed/decrement + size-0-wrap
   handling for a gap specific to the transfer shape these events use.
3. Fix the **upload**, never hack OAM/CHR in the renderer — the state shows what the buggy
   machine had; the bug is the missing DMA. Verify byte-exact on the captured states
   (slot85 etc.) + no regression on sprite-heavy scenes (overworld NPCs, battles).

**Cosmetic** — every instance still plays the event correctly (sanctuary collected, scene
advances); only the visuals corrupt, and they clear on the next scene's re-upload.

## How to promote a problem out of this doc

When a save-state, trace, or breakthrough cracks one: move its findings into the relevant
track doc (`music.md`, `battle-backgrounds.md`, a new `photographer.md`), mark it solved
here with the commit, and — if it earned it — build the toy (the jukebox, the photo map,
the BG gallery). This list should *shrink*.

## Related

`docs/decompilation.md` (the dynamic-RE-instrument philosophy), `docs/scripts.md` (the
event engine), `docs/music.md`, `docs/battle-backgrounds.md`. Save-states at the exact
moment are the shared key.
