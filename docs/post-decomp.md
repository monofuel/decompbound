# Post-decompilation — patches & emulator hacks

**Status:** brainstorm / wishlist. The "once we've mastered how the game works"
class of goals. Off the critical path.

The stretch goals (`docs/stretch-goals.md`) *read* the game — galleries, dumps,
players. This class *changes* it. Once the data tracks (`docs/decompilation.md`)
are mature and we control the emulator, a whole family of "build on top of
EarthBound" goals opens up — the same territory as the popular romhacks, plus
things only *we* can do because we own the emulator.

## The dividing line: ROM-side vs emulator-side

Two families, and the split is the key insight — different prerequisites,
different distribution, different legal shape.

| | **ROM patches (romhacks)** | **Emulator hacks (enhancements)** |
|---|---|---|
| **Changes** | the game's data/code | how the emulator runs it (ROM untouched) |
| **Needs** | deep decomp mastery — you can only patch what you understand | just emulator control — available *now-ish* |
| **Ships as** | a **patch** (IPS/BPS diff) against the user's own ROM | our own emulator code, freely |
| **Legal** | patch-only, never the patched ROM (see below) | fully ours — no copyright issue at all |

**The ordering insight:** emulator hacks are the *early* post-decomp fun (several
are doable today, they don't need the decomp). ROM patches are the *mature*
payoff (they need the formats cracked first). So this class starts the moment we
want it, and deepens as the decomp lands.

---

## Family 1: ROM patches (romhacks)

Modify the game itself, distribute as a diff applied to the user's own ROM. You
can only change what you understand, so these ride on the decomp tracks.

- **🎲 Randomizer** — its home is here; full write-up in `docs/stretch-goals.md`.
  Shuffle enemies/items/music/text. Pulls nearly every data track.
- **🐛 Bugfix ROM** — fix EarthBound's known bugs and glitches. Community-valued,
  and a great *first* romhack: small, surgical, and each fix proves we understand
  the code it touches.
- **⚡ Quality-of-life patch** — faster text, a run/dash button, better menus,
  bigger inventory, auto-sort, skippable cutscenes. QoL hacks are perennially the
  most-loved category.
- **⚖️ Rebalance / difficulty mods** — harder mode, boss rush, tuned EXP/drops.
  Pulls the game-data tables.
- **📝 Restoration / relocalization** — restore cut content, polish the script.
  Caveat: editing the copyrighted script is derivative work — distribute as a
  patch, never ship text (see legal note).
- **🎭 LLM remix** — regenerate the writing in EB's own voice via an LLM and
  patch it in. The most creative content-hack; own doc: `docs/llm-remix.md`.
- **🌍 Full content hack** — new areas, enemies, story. The big one; the endgame
  of ROM mastery.

### Legal: distribute patches, not ROMs

The clean romhack model (and it *is* cleaner than shipping ROMs): distribute an
**IPS/BPS patch** — a diff that is useless without the original — which the user
applies to their **own** legally-dumped ROM. Never distribute a patched, playable
ROM. Small/additive patches (a bugfix) are the safest; patches that replace large
copyrighted chunks (a full rewritten script) carry the derivative-work caveat.
Full reasoning added to `docs/copyright-notes.md` §5. Not legal advice — the same
"tolerated grey for preservation/modding" lane as the decomp itself.

---

## Family 2: Emulator hacks (enhancements)

Change how *our emulator* renders/runs the game — ROM untouched. Because we own
the emulator, we can do things real hardware never could. Fully our own code, no
copyright issue, ship freely. Several need no decomp at all.

- **🖥️ Widescreen mode** — the flagship. Render a wider viewport than 256px by
  extending the PPU's per-scanline render + revealing more of the scrolled BG.
  Tricky (sprite pop-in at the edges, HUD layout), but pure emulator-side.
- **⏪ Save states + rewind** — snapshot emulator state; rewind = a ring buffer of
  snapshots. Also directly feeds the TAS/replay work (`docs/input-replay.md`) and
  the accuracy regression harness (`docs/accuracy.md`).
- **⏩ Fast-forward / slow-mo / turbo** — speed control; trivial once the loop is
  decoupled from wall-clock.
- **✨ Upscaling / CRT / shader filters** — post-process the framebuffer in GL
  (scanlines, smoothing, bloom). We already blit through a shader.
- **🔧 Cheats / RAM poke** — Game-Genie-style live memory writes (infinite HP,
  walk-through-walls). Note the contrast with the LLM-plays harness, which is
  deliberately *read-only*; this is the opt-in write path.
- **📷 Photo mode** — toggle BG/sprite layers, free camera, hide the HUD. A
  natural extension of the debug HUD (`docs/apps.md`).
- **🎨 Colorization / HD sprite packs** — remap palettes or swap in HD tiles at
  render time (the "HD texture pack" idea, SNES-flavored).
- **🌐 Netplay** — two players over the network (big stretch; deterministic
  lockstep, which the replay work also wants).

---

## The fun → prerequisite map

| Idea | Family | Needs | When |
|---|---|---|---|
| Save states / rewind / fast-fwd | emulator | emulator control | ~now |
| Shaders / CRT filter | emulator | GL blit (have it) | ~now |
| Cheats / RAM poke | emulator | memory access (have it) | ~now |
| Photo mode | emulator | layer toggles | soon |
| Widescreen | emulator | PPU render extension | medium |
| Bugfix / QoL patch | ROM | code decomp of the touched routines | after decomp |
| Rebalance | ROM | game-data tables | after decomp |
| Randomizer / content hack | ROM | most data tracks | mature |

**Start-here picks:** the emulator hacks that need no decomp — **save
states + rewind** (also pays back the accuracy/replay work) and a **CRT/shader
filter** (instant gratification). On the ROM side, the **bugfix patch** is the
gentlest first romhack. **Widescreen** is the show-stopper once the PPU work
settles.
</content>
