# Bestiary — the EarthBound-styled enemy browser

**Status:** plan v2 (track breakdown; promoted from the "Animated Bestiary" stretch goal).
**Updated:** 2026-08-01.

A browsable catalog of every EarthBound enemy — name, stats, abilities, battle +
overworld sprites, **animated battle backgrounds** (some enemies have several),
and **battle music** — extracted from the **user's own ROM at run time**
(asset-free; nothing game-derived is committed). Styled like the game itself:
the ROM's own font, EB window flavor, the psychedelic bg warping behind the
sprite. Its *secret purpose* is unchanged: every track below cracks or exercises
real game-data formats, so building it advances the decomp.

## Two consumers → two modes, one backbone

```
                ┌─────────────────────────┐
   ROM ───────▶ │  bestiary data backbone │  decode records → structured model
                │  (bestiary module)      │  (stats + abilities + sprites + bg + music)
                └───────────┬─────────────┘
                    ┌───────┴────────┐
        pretty GUI  │                │  AI / CLI
   (default, human) ▼                ▼  (machine-readable)
   animated Pokédex: bg warping,   `enemy_info "Mani-Mani Statue"` → stats + can-cast
   sprite, stats, battle music     `enemy_info --json <name>` for agents/qwen
```

## RE state (what each track stands on)

- ✅ **Enemy configuration table** — pinned (sword-of-kings RE, 2026-07-27): base
  `$D59589` / file `0x159589`, **`0x5E`-byte records**, indexed id×`$5E`
  (`LDY #$005E` + `JSL $C08FF7` at `$C24D88`; init copy `$C2B6FA`). Name EB-text
  `+0x01`, HP u16 `+0x21`, PP `+0x23`, EXP u32 `+0x25`, money `+0x29`, drop freq
  `+0x57`, drop item id `+0x58`. Remaining fields (off/def/speed, resistances,
  music, sprite pointers, death style) not yet field-mapped — that's Track A.
- ✅ **Battle enemy sprites** — output path mapped (`docs/graphics.md`): the enemy
  record holds **two 3-byte far gfx pointers + a dimension byte**; decode via
  `gfx_lz` (byte-exact round-trip codec already shipped).
- ✅ **Battle backgrounds** — format RE complete (`docs/battle-backgrounds.md`,
  2026-07-07): layer table `$CADEA1` (17 B/entry, ~327 layers), bg-ID → layer
  pair `$CBDA9A`, gfx/palette pointer tables, anim params (scroll, HDMA sine
  distortion, palette rotation). One layer round-tripped byte-exact.
  `battle_bg_explore.nim` exists; the reusable animated renderer is Track C.
- ✅ **Song table** — `0x04F70A` (song ID → 3 pack indices), loader `$C4FBBD`
  (`docs/audio.md`); `sound_explore.nim` already resolves a song's packs, and
  the live-APU streaming path is designed in `docs/apps.md` App 1.
- ✅ **PSI table** — `0x158C50`, ~15-byte records (holds *PSI Shield*).
- ✅ **Battle-group table** — `$D0C60D` / file `0x10C60D`, **484 × 8-byte**
  records: `+0..+2` far ptr to member list (`[u8 count, u16 enemyId]…$FF`),
  `+4` u16 event-flag + `+6` wanted value (enable predicate, reader `$C0C524`),
  `+7&3` letterbox selector (`$C2D121`). Bg layer pair per group reported at
  `$CBD89A + groupId*4` — reconciliation with the `$CBDA9A` claim below is
  Track D's job. (Older `0x10D74C` note was mid-blob, not a table base.)
- ✅ **Text decode** — `text_decode.nim` (names, via the EB text encoding).
- ❌ **Ability/action list** — where an enemy's castable-PSI/actions live is the
  open frontier (Track E).
- ❌ **Overworld sprite definitions** — ID → CHR table still open; needs the
  emulator-as-referee DMA watch (Track H, stretch).

## Track breakdown

Each track is a self-contained delegatable ticket with a **mechanical referee**
(`docs/delegation.md`: grok conductor + sub-agents; never merge on self-report).
A, B, C, F are independent — parallel workers from day one. D and E are RE digs
(one hypothesis per worker). G assembles.

### Track A — Data backbone + CLI (plumbing, zero new RE)
`src/decompbound/bestiary.nim` module + `src/tools/enemy_info.nim`. Decode the
full `0x5E` record: name via `text_decode`, the pinned stats/drops, and
**field-map the rest of the record** — offense/defense/speed, status/element
resistances, music id, the two battle-sprite pointers, death style. Ship the
CLI modes in the same ticket: plain, `--json`, `--all`, `--query "<question>"`
(yes/no + evidence) so llm-play's qwen can use it immediately. Magic offsets
get `const` + comment.
**Referee:** Pogo Punk + Mani-Mani stats byte-match the documented offsets;
`--all` decodes every id with no garbage names.

### Track B — Battle sprite decode (buildable now)
Enemy record gfx pointers → `gfx_lz` decompress → tile + palette assembly →
renderable frames (render-to-PNG headless probe).
**Referee:** the round-trip rule — `encode(decode(bytes)) == bytes` against the
gold ROM; pixel-compare one known enemy against an emulator battle frame.

### Track C — Battle background renderer (RE done, renderer pending)
Grow `battle_bg_explore` into a reusable animated renderer: bg-ID → layer pair
→ decompress gfx + palette → run anim params (scroll, HDMA distortion wave,
palette rotation) → frame sequence. **Headless first** (no-GUI-testing rule).
**Referee:** pixel-compare a rendered bg against a captured emulator battle
frame; decoded layers re-encode byte-exact.

### Track D — Enemy → context linkage (why some enemies have multiple bgs)
RE dig: field-map the formation/battle-group records (`0x10D74C`) — member
enemy ids, **background id(s)**, and (hypothesis) the battle-music selector.
Deliverable: enemy id → the formations it appears in → each formation's bg +
music. This is exactly why one enemy shows several backgrounds, and it gives
the app "appears alongside: X, Y" for free.
**Referee:** in-battle save state (Ctrl+3) + trace: the predicted bg id and
song id match what the emulator actually loads for a known encounter.

### Track E — Ability/action list (the hard RE frontier)
Which PSI/battle actions each enemy can cast, cross-referenced to the PSI table
(`0x158C50`) so the tool can say "casts *PSI Shield Σ* (reflect)". One
hypothesis per worker: inline id bytes in the `0x5E` record vs. a pointer into
a separate action table. If behavior turns out AI-driven and the AI isn't RE'd,
the tool **says so explicitly** — never guesses.
**Referee:** live battle where a known enemy casts a known move; the decoded
list must contain it. Acceptance test: *"does the Mani-Mani Statue have a
shield?"* answered from ROM (or the gap honestly reported).

### Track F — Battle music (✅ field PINNED 2026-08-01; playback remains)
**Pinned:** battle song id = **enemy record `+0x37`** (u8), selected from the
battle group's **first member**; the group record has **no music field**.
Evidence: byte-exact chain `$C24A4B`/`$C24CD5` (`id×$5E` → `ADC #$0037` →
`LDA $D59589,X` → `JSL $C4FBBD`); machine referee
`src/probes/probe_battle_music.nim` (asserts opcode bytes, range-checks all
231 records vs the 191-song table, cross-checks the live slot200 fight);
module `src/decompbound/battle_music.nim`. Remaining: playback — reuse the
`docs/apps.md` App 1 path (live APU, write song id to the driver's "play song
N" port command, stream via slappy) so the bestiary plays battle themes on
demand (lands with Track G).

### Track G — The EB-styled silky app (assembles A+B+C, then D/E/F slot in)
`sprites_explore.nim` (currently a one-line silky stub) becomes the bestiary
browser, following the `docs/apps.md` explorer pattern. EarthBound feel comes
**asset-clean** because everything renders from the user's ROM at runtime: the
game's own font, EB window-border flavor, the animated battle bg warping behind
the enemy sprite, stats in an EB-style window, battle theme playing. Scrollable
+ searchable enemy list; a cycle button for multi-background enemies; overworld
sprite pane ships as a labeled "coming soon" slot until Track H.
**Referee:** headless render-to-PNG layout probes; window/audio changes get a
flagged live `make play` smoke test (headless-untestable, per field notes).

### Track H — Overworld sprites (stretch; don't block the app)
The sprite-definition table (ID → CHR) via the emulator-as-referee approach:
watch OBJ CHR DMA during a known sprite. Lands as the second sprite pane.
**Referee:** decoded overworld frame pixel-matches an emulator OAM capture.

## Sequencing

```
day 1 (parallel):  A backbone   B battle sprites   C bg renderer   F music-field pin
RE digs (parallel): D formations ←coordinates→ F    E abilities
assembly:          G app  = A+B (+C when ready; D/E/F slot in as they land)
stretch:           H overworld sprites → second pane in G
```

## Definition of done

- [ ] `enemy_info` CLI: any enemy by name/id → stats, drops, abilities (or the
      honest RE-gap report), sprite + bg + music refs; `--json --all` works.
- [ ] The Mani-Mani shield question answered from ROM.
- [ ] Full `0x5E` record field-mapped and documented in `docs/decompilation.md`.
- [ ] Formation records field-mapped: enemy → formations → bg id(s) + music.
- [ ] Bestiary app: browse every enemy — animated battle bg behind the battle
      sprite, EB-styled stat window, battle theme playback, multi-bg cycling.
- [ ] All decode paths byte-exact/pixel/trace-refereed; zero extracted assets
      committed.

## References

- Origin: [`docs/stretch-goals.md`](stretch-goals.md) §Animated Bestiary
- Game-data RE: [`docs/decompilation.md`](decompilation.md) §Game data ·
  [`docs/sword-of-kings.md`](sword-of-kings.md) (enemy record correction)
- Battle backgrounds: [`docs/battle-backgrounds.md`](battle-backgrounds.md) ·
  `src/tools/battle_bg_explore.nim`
- Sprites: [`docs/graphics.md`](graphics.md) · `src/tools/sprites_explore.nim`
- Music: [`docs/audio.md`](audio.md) (song table + loader) ·
  [`docs/apps.md`](apps.md) App 1 (live-APU streaming path)
- App pattern + delegation: [`docs/apps.md`](apps.md) ·
  [`docs/delegation.md`](delegation.md)
- Text: `src/decompbound/text_decode.nim`
- Memory: `earthbound-cloud-ai-blindspots` (ROM ground-truth, never model memory)
