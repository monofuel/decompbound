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

## Capture 1 — healthy mid-battle state — ✅ FOUND, NO CAPTURE NEEDED

**Resolved 2026-07-20.** A healthy mid-battle F12 was already in the archive:
`../decompbound_secret/screenstates/earthbound_20260719-223714.png` (command menu
up vs a car enemy; party Ness 378/135, Paula 154/145, Jeff 225/0). Extracted to
`bin/states/battle_menu_healthy.state` (scanner: `probe_scan_screenstates.nim`).
**Battle execution + victory work headless from it** (`probe_battle_advance.nim`:
A→Bash→"Ness attacks! 161 HP"→win→overworld). So the battle SYSTEM is unblocked;
what remains is (a) finishing `winBattle` against this fixture and (b) the
separate battle-ENTRY abort (task #19) — neither needs a new capture. Key
correction: a live battle reads `$4DBA=0`/mode 0 (NOT `$4DBA=1`); detect via mode
0 + party structs.

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
