# Human captures needed (unblock the sunrise ladder)

Two live F12 captures from `make play` are the ground truth that unblocks the
story milestones past knock=80. Both are things the **bot can't produce itself**
(one needs a real battle the emulator can't yet run headless; the other is a
scripted beat that isn't bot-triggerable). Once captured, we flag-diff them the
same way we nailed the meteor flag `$9885`.

F12 = screenshot + embedded, drag-drop-restorable save-state. It lands in
`bin/sessions/<session>/f12/` and `~/Pictures/Screenshots`, and auto-archives to
`../decompbound_secret/sessions/` if that dir exists. (F9 = debug bundle; Steam
hijacks F12 for its own screenshot, so ours matches that key.)

---

## Capture 1 — healthy mid-battle state (unblocks the whole battle system)

**Why:** headless battle entry currently aborts ~6 frames in (`$4DBA` sets then
clears, PPU never reaches mode 0, command menu never renders — see
`bin/battle_re_notes.txt` + task #19). Every `4DBA=1` fixture we have is stale
VRAM ("DEAD — glitched house tiles"). We need ONE real mid-battle state to RE the
command-menu cursor + turn engine and build a `winBattle` that actually wins.

**Recipe:**
1. `make play`
2. Walk in any grassy/encounter area until a random battle starts and the
   **command menu is fully up** — the box showing `Bash / Goods / Auto Fight /
   PSI / Defend / Run Away`.
3. Press **F12** right there (menu visible, before choosing anything).
4. Optional but great: also F12 (a) mid-attack animation (SMAAAASH / damage
   numbers) and (b) the victory "EXP" box. More phase samples = faster turn-engine RE.

**What we need in the capture:** `$4DBA != 0` **and** BG mode 0 (`$2105 & 7 == 0`)
— that combination is what distinguishes a live battle from the dead fixtures.
Verify with `nim r src/tools/probe_battle_quick.nim <path>` after.

---

## Capture 2 — prologue-night sleep → Pokey knock (unblocks knock 80→100, then Buzz Buzz + Sunrise)

**Why:** knock caps at 80 (bedroom reached) because the scripted "Pokey knocks
you awake" event flag isn't RE'd, and the bot can't trigger the beat (verified
inconclusive). Buzz Buzz % and Sunrise % are story-gated behind it and honestly
return 0 until this flag lands (`src/tools/story_percents.nim`).

**Recipe (do the real prologue so the event is legit):**
1. From a post-meteor return home (Ness back inside after the crater), go upstairs
   and **sleep in the bed**.
2. **F12 the instant you're in bed, just BEFORE the knock fires** (this is the
   "pre" snapshot).
3. Let the **knock event play** (Pokey knocks, dialogue). **F12 again right when
   the knock/dialogue triggers** (the "post" snapshot).
4. If easy, F12 once more after the dialogue resolves.

**What we do with it:** flag-diff pre vs post (like `bin/knock_re_notes.txt`) to
pin the knock event bit — candidates already scoped are `$9A05/$9A06/$9A0F/$9A10`
but those are post-METEOR, not post-KNOCK, so we need the clean before/after to
confirm the real bit. Then `pokeyKnockPercent` grades 100, and the Buzz Buzz /
Sunrise ladders (bat → King → Picky → Buzz Buzz → Minch escort → death scene →
day-one) become RE-able from there.

---

## Priority

Capture **1 (mid-battle)** first — it unblocks the biggest strand ("consistently
reach sunrise" runs through random encounters, which don't work headless yet).
Capture 2 unblocks the story-flag tail. Both are ~1-minute grabs during normal
play; drop the resulting `.state` files anywhere under `bin/states/` (or just
leave them in the session `f12/` dir and tell me the path).
