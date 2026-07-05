# Stretch goals — deliverable-driven RE

**Status:** brainstorm / wishlist. Off the critical path, morale-driven, and
proud of it.

The organizing idea: **"figure out how X works" is grind, but "build a toy that
needs X" makes the grind ride along for free.** Pick a shiny artifact you *want
to exist*; building it forces you to crack a format — now the format is a means
to a fun end, not a chore. Most of these also **realize the silky explorer
stubs** (`sprites_explore`, `map_explore`, `sound_explore`) already staked out in
the repo.

**Legal note (applies to all):** every one of these *runs against the user's own
ROM* and generates its output **locally** — galleries, posters, dumps, and
randomized ROMs are copyrighted-asset output and are **never committed**
(AGENTS.md "Copyright hygiene"). The *tool* ships; the *content* stays on your
machine. Same clean pattern as the data tracks (`docs/decompilation.md`).

---

## Tier 1 — Eye-candy galleries (fast dopamine, each realizes a stub)

### 🌀 Psychedelic Battle-Background Player
**What:** a standalone app that plays EarthBound's iconic warping, scrolling,
color-cycling battle backgrounds as a hypnotic screensaver.
**Secretly cracks:** the battle-BG layer format + the HDMA distortion / palette-
cycle engine — which **is issue #10's battle swirl**. The fun toy fixes an
emulator bug as a side effect.
**Done when:** all battle backgrounds render + animate standalone, and a decoded
BG round-trips byte-exact (`docs/graphics.md` rule).

### 👾 Animated Bestiary
**What:** a browsable "Pokédex" of every enemy, NPC, and party sprite —
animations playing, stats beside them.
**Secretly cracks:** sprite decoding (graphics track) + enemy tables (game-data).
**Realizes:** `sprites_explore.nim`.
**Done when:** every sprite decodes + animates in a silky browser, with stats
pulled from the game-data tables.

### 🗺️ The Whole World, One Image
**What:** render all of Eagleland as a single Google-Maps-style pannable/zoomable
poster; export a giant PNG. Toggle overlays for sectors / music zones / enemy
regions.
**Secretly cracks:** map RE (tilesets, tilemaps, sectors).
**Realizes:** `map_explore.nim`.
**Done when:** the full overworld renders as one browsable image and a map region
round-trips byte-exact.

---

## Tier 2 — Readable & playable artifacts

### 📖 The EarthBound Screenplay
**What:** a searchable browser of the game's writing — every NPC line by area —
plus a "random EarthBound quote" generator. The writing is why people love this
game.
**Secretly cracks:** the scripts track (char table + control codes).
**Legal:** generates text locally from the user's ROM, ships none of it —
"read the game" means *run it on your ROM* (`docs/scripts.md`).
**Done when:** the extractor produces a searchable local dialogue browser.

### 🎹 The EarthBound Soundboard
**What:** a little keyboard that plays EarthBound's actual BRR instruments, plus
a pad for every SFX (the SMAAAASH, menu blips). Make music *with* the game's
voices.
**Secretly cracks:** audio-data RE — the instrument / BRR sample directory (the
deeper half of `docs/audio.md`).
**Done when:** you can trigger every SFX and play notes on the ripped
instruments; a decoded instrument round-trips.

---

## Tier 3 — A playable slice (a Goal-3 teaser)

### ⚔️ The Battle Sandbox
**What:** pick a party + any enemy group and fight a real EarthBound battle — the
actual damage formulas, PSI, and the legendary **rolling-odometer HP** (win
before it ticks to zero).
**Secretly cracks:** game-data + battle-math RE + sprites + battle-BG, at once.
**Why it matters:** the first honest bite of Goal 3 (native reimplementation),
scoped to something playable in a week instead of the whole game.
**Done when:** a full battle plays out natively with correct formulas and the
odometer HP, differential-tested against the emulator for a fixed input.

---

## Tier 4 — Capstones (these pull almost everything)

### 🎲 The Randomizer
**What:** shuffle enemies, items, music, maybe text. Community-beloved, and a
monster motivator — it forces near-total data RE. (It's also the flagship of the
ROM-patch class — see `docs/post-decomp.md`.)
**Secretly cracks:** game-data + maps + scripts + graphics.
**Legal:** the tool ships; the **randomized ROM stays local** on the user's own
copy, never distributed — same as any romhack tool.
**Done when:** it emits a playable randomized ROM from the user's baserom, with
seed-reproducible shuffles.

### 📚 The Eagleland Almanac
**What:** a locally-generated EarthBound wiki from your ROM — every enemy, item,
PSI, location, NPC, with sprites + stats + map crumbs, all cross-linked.
**Secretly cracks:** the grand synthesis — *all five data tracks* at once.
**Legal:** generated locally, never committed (full of copyrighted text/art).
**Done when:** one browsable encyclopedia builds from the user's ROM, pulling
every data track.

---

## The fun → grind map

| Deliverable | Secretly cracks | Realizes |
|---|---|---|
| Battle-BG player | BG distortion engine (+ fixes #10) | — |
| Bestiary | sprites + enemy data | `sprites_explore` |
| World map poster | maps | `map_explore` |
| Screenplay | scripts | text-log |
| Soundboard | audio instruments | `sound_explore` |
| Battle sandbox | game-data + battle math | Goal 3 teaser |
| Randomizer / Almanac | *everything* | capstone |

**Highest fun-to-effort:** the **Battle-BG player** (gorgeous, debugs the
emulator for free) and the **World map poster** (the "whoa, the whole world"
moment). The **Randomizer** is the dream capstone once the data tracks mature.
</content>
