# Bestiary — enemy data, two ways

**Status:** plan (promoted from the "Animated Bestiary" stretch goal).
**Updated:** 2026-07-19.

A browsable catalog of every EarthBound enemy (later NPCs + party) — name, stats,
abilities, and animated sprite — extracted from the **user's own ROM** at run
time (asset-free; nothing game-derived is committed). Promotes the idea in
[`docs/stretch-goals.md`](stretch-goals.md) §"👾 Animated Bestiary" into a real
plan. Its *secret purpose* is to crack the **enemy game-data tables** and **sprite
decoding**, so building it advances the decomp itself.

## Two consumers → two modes, one backbone

```
                ┌─────────────────────────┐
   ROM ───────▶ │  bestiary data backbone │  decode records → structured model
                │  (enemy_info / module)  │  (stats + abilities + sprite ref)
                └───────────┬─────────────┘
                    ┌───────┴────────┐
        pretty GUI  │                │  AI / CLI
   (default, human) ▼                ▼  (machine-readable)
   animated Pokédex, stats     `enemy_info "Mani-Mani Statue"` → stats + can-cast list
   beside each sprite          `enemy_info --json <name>` for agents/qwen
```

### 1. Data backbone (build this first)
`src/tools/enemy_info.nim` (+ a reusable `bestiary` module). Given an enemy **name
or id**, decode from ROM and return a structured model:
- **name** (via `src/decompbound/text_decode.nim`),
- **stats** — HP/PP/EXP/money/Offense/Defense/Speed (fields already RE'd, see below),
- **abilities / actions** — which PSI/battle actions the enemy can use, **cross-
  referenced to the PSI table** so we can say "casts *PSI Shield*" (the reflect
  ability). ← *this link is what answers "does it have a shield".*
- **sprite ref** — pointer into the sprite table (for the GUI; `sprites_explore.nim`).

Reads the user's ROM at runtime; commits **no** extracted data (AGENTS.md hygiene).

### 2. AI / CLI mode
Plain + `--json` output so an agent (qwen in llm-play, or a coding agent) can
answer questions without eyeballing a GUI. Target UX:
```
$ enemy_info "Mani-Mani Statue"
Mani-Mani Statue   HP 1300  PP 80  ...
  can use: PSI Shield Σ (reflect), ...
$ enemy_info --query "has shield" "Mani-Mani Statue"   → yes/no + evidence
$ enemy_info --all --json                              → whole bestiary as JSON
```
This is the mode that makes "does the Mani-Mani statue have a shield?" a
ROM-grounded lookup instead of a confabulation (see memory
`earthbound-cloud-ai-blindspots`).

### 3. Human GUI mode (default, later)
The animated Pokédex from the stretch goal — sprites playing, stats beside them,
searchable. Follows the existing decompbound app pattern (`docs/apps.md`). Depends
on the sprite-decode track. Presentation only; reads the same backbone model.

## RE state (what the backbone stands on)

From [`docs/decompilation.md`](decompilation.md) §"Game data":
- ✅ **Enemy configuration table** — CORRECTED 2026-07-27 (sword-of-kings RE):
  base `$D59589` / file `0x159589`, **`0x5E`-byte records**, indexed id×`$5E`
  (`LDY #$005E` + `JSL $C08FF7` at `$C24D88`; init copy `$C2B6FA`). Name
  EB-text at `+0x01`, HP u16 `+0x21`, PP `+0x23`, EXP u32 `+0x25`, money
  `+0x29`, **drop freq enum `+0x57`, drop item id `+0x58`**. The old
  "`0x30`-byte records, Pogo Punk `0x15C6DE`" claim was a misaligned slice —
  `0x15C6DE` is Pogo Punk (id 134) record + `0x21`, i.e. the HP field, so the
  offsets above (`HP +0x00` etc.) were relative to mid-record. Base + count +
  indexing + name are now pinned; see `docs/sword-of-kings.md` +
  `probe_drop_table.nim`.
- ✅ **PSI table** — `0x158C50`, ~15-byte records (holds *PSI Shield* as an ability).
- ✅ **Formations** — `0x10D74C` (which enemies appear in which fight).
- ✅ **Text decode** — `text_decode.nim` (enemy names).
- 🎨 **Sprite decode** — `sprites_explore.nim` (for the GUI).

**The key gap for abilities:** where an enemy's **action / castable-PSI list** lives
— in the `0x30` record (a field = action-table pointer or PSI-id list?) or a
separate enemy-action table — is **not RE'd**. "Has a shield / reflects PSI" is an
*ability link* (and possibly AI-driven *when* to cast it), so this is the real
frontier. Static ability list is the first target; full battle-AI is a later dig.

## Driving acceptance test

The CLI answers **"does the Mani-Mani statue have a shield?"** from the ROM — by
listing its castable abilities cross-referenced to the PSI table (does it include
*PSI Shield*?). If the static data doesn't encode it (behavior is AI-only and the
AI isn't RE'd yet), the tool must **say so explicitly** and point at what's needed
— never guess. Byte-exact verification against a known enemy (Pogo Punk) is the
referee.

## TODO

**Backbone (data):**
- [ ] Pin the enemy-stat table **base + count + id-indexing**; locate the **name**
      field. Decode names via `text_decode`. Verify: Pogo Punk stats match the doc;
      find "Mani-Mani Statue".
- [ ] RE the enemy **ability/action reference** (which PSI/actions each enemy can
      use); cross-reference IDs to the PSI table (`0x158C50`).
- [ ] `enemy_info.nim` + `bestiary` module: name/id → structured model (stats +
      abilities + sprite ref). Asset-free; magic offsets get `const` + TODO+comment.

**AI / CLI mode:**
- [ ] Plain + `--json` output; `--all`; `--query "<question>"` for yes/no + evidence.
- [ ] Answer the Mani-Mani shield question (or honestly report the AI-RE gap).

**Human GUI mode (later):**
- [ ] Animated Pokédex browser (sprites + stats), once sprite decode lands.

## References
- Stretch goal origin: [`docs/stretch-goals.md`](stretch-goals.md) §Animated Bestiary
- Game-data RE: [`docs/decompilation.md`](decompilation.md) §Game data
- Sprites: [`docs/graphics.md`](graphics.md) · `src/tools/sprites_explore.nim`
- Text: `src/decompbound/text_decode.nim`
- App pattern: [`docs/apps.md`](apps.md)
- Memory: `earthbound-cloud-ai-blindspots` (why ROM ground-truth, not memory)
