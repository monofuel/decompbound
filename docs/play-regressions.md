# Play regressions — 2026-07-08 audio/visual incident

Single source of truth for the three tangled `make play` issues from
2026-07-08 and the commit to fall back to when play drifts. Companion to
[`docs/issues.md`](issues.md) (broad status board) and
[`docs/human-verify.md`](human-verify.md) (live play checklist).

**Updated:** 2026-07-09.

## Known-good baseline

```
0bdad7275291ecd881bb585a4c1ba49859f3f86b   (short: 0bdad72)
"Restore visual fixes without breaking audio: Mode 7 + battle UI PPU"
```

Bookmarked by commit `8c58996`. This is the human-verified good tip for
`make play`: correct audio tempo + Mode 7 / battle UI, **without** the
regressions that followed. Treat it as the restore / compare point.

`eb3f714` is the clean emulator core the audio revert (`1b37b4f`) rolled back
to — the morning-of-2026-07-08 state, post DSP bit-exact fix. `0bdad72` =
`eb3f714` core + the safe visual fixes re-applied on top.

## The three issues (do not conflate)

| # | Issue | Kind | Status on `0bdad72` |
|---|-------|------|---------------------|
| A | Room-entry / door **force-blank hang** | Real bug | ⚠️ Regressed for loaded states |
| B | **Saturn Valley** screen corruption + hang | Real bug | ✅ Fixed & live |
| C | **Half-speed music** | Self-inflicted regression | ✅ Gone |

Reports on 2026-07-08 lumped these together as "play is broken." They have
three different root causes and must be tracked separately — the fix for A is
what *caused* C when done the wrong way.

---

### A — Room-entry / door force-blank hang

**Symptom.** Entering a new room (or loading an F12 screenshot-state at a
transition) sticks the screen in force-blank forever. CPU parked at
`$C0:ABD0` (handshake wait on `$2140`), SPC700 spinning at `$0579`
(`MOV A,$FD` / `BEQ`), `INIDISP=$80`.

**Root cause.** APU **timer 0** is disabled, so the music driver never acks
`$2140` and the main CPU never leaves the handshake. Cold-boot `make play` is
fine (driver init enables T0); the hang appears when loading a save-state
(llm-ai bedroom fixtures, F12 hang captures) because save-state v1 does **not**
serialize the APU timer regs (`$F1` / `$FA`–`$FC`).

**Two fixes existed — only one is safe:**

- ✅ **Clean (tempo-safe):** serialize the timers *into the save-state* (v2
  format) and re-arm **only on deserialize**, never during play. Lives on
  orphan commit **`157e8e6`** ("save-state v2: serialize APU timers (door/battle
  hang without half-speed)"): `StateVersion = 2`, `getTimerSnapshot` /
  `setTimerSnapshot`, `recoverTimersAfterLoad`, `tests/test_save_state.nim`.
- ❌ **Dirty (caused C):** re-arm T0 live on `$FD` reads during play. Lives in
  the stashes — see issue C.

**Current gap.** The audio revert (`1b37b4f` → `eb3f714`) rolled back
`save_state.nim` along with the emulator core, so the *clean* fix got dropped
with the dirty one. On the current tree `StateVersion = 1`, no timer
serialization, no `recoverTimersAfterLoad`. Cold-boot play is fine; **loading a
save-state brings the hang back.**

**Fix path.** Cherry-pick `157e8e6` (load-time only, provably tempo-safe).

**Repro fixtures / probes.** F12 hang screenshots →
`probe_battle_lock`, `probe_event_hangs`, `probe_crash_now`, `probe_tea_lock`.

---

### B — Saturn Valley screen corruption + hang while walking

**Symptom.** Around Saturn Valley (walking / talking to Mr. Saturns), tiles turn
to multicolored garbage and the CPU can wedge.

**Root cause.** Event / dialogue DMA (Mr. Saturn talk, inn sleep/wake, sanctuary
visions) programs a **non-zero VMAIN address translation** (`$2115` bits 3-2).
The emulator ignored it and deposited tiles at the raw `VMADD`. `trans = 0`
(boot / overworld) was unaffected, which is why it only showed up at events.

**Fix.** `translatedVramAddr` in `snesbus.nim` rotates the low 8/9/10 address
bits left by 3 per fullsnes; wired into the `$2118` / `$2119` write path
(`snesbus.nim:262,267`). Commits `d28c605` / `c3fde6c`. **In the tree, live on
`0bdad72`.** No APU changes.

---

### C — Half-speed music (self-inflicted regression)

**Symptom.** Music drags at ~half tempo while video stays ~60 fps.

**Root cause.** The **dirty** attempt at fixing issue A: re-arming APU timer 0
live on `$FD` reads and zeroing `internal` / `counter` / `accum` on every poll.
The driver clears + polls T0 constantly, so recovery kept resetting the
accumulators → the `$FD` tick rate collapsed → sequence tempo halved. Not a real
EarthBound bug.

**Correct audio coupling (already right on `0bdad72` — do not "fix" blindly):**

| Piece | Value |
|-------|-------|
| OpenAL stream | `32000` Hz, stereo 16-bit |
| Samples / emu frame | `32000 div 60` = **533** |
| APU step | 2× `tickApu` per scanline + top-up to 533 |
| Wall pacing | `frameAcc` @ 60 Hz |

**Red herrings** (made it worse): `AL_PITCH = 2`, changing `SamplesPerFrame`,
`frequency = 64000` — all stream-math dead ends. The fault was SPC timer0, not
the PCM path.

**Fix.** Reverted the core to `eb3f714` (`1b37b4f`), then re-applied only the
safe visuals → `0bdad72`. The dangerous live-recovery code now lives **only** in
the stashes and must stay dead:

- `stash@{0}` — `servicePorts` bulk-upload handshake.
- `stash@{1}` — `kickTimersIfDriverStarved` / `serviceApuHandshake` / live `$FD`
  re-arm. **This is the half-speed culprit.**

**Guard.** Orphan commit **`2bf4e0d`** carries `docs/half-speed-music.md` (full
postmortem) + `tests/test_audio_tempo.nim` — a ROM-free regression test that
locks `SamplesPerFrame = 533` and the free-running T0 rate so live `$FD` re-arm
can't come back. Cherry-pick to install the guard.

---

## Recommended cleanup

1. `git cherry-pick 157e8e6` — restore the tempo-safe save-state timer fix
   (closes issue A for loaded states). Verify `tests/test_save_state.nim` passes.
2. `git cherry-pick 2bf4e0d` — install `docs/half-speed-music.md` + the tempo
   regression test. Verify `tests/test_audio_tempo.nim` passes.
3. Drop the stashes (`git stash drop`) once A is re-landed cleanly — the live
   `$FD` re-arm they contain is the thing we never want back.

Both orphan commits (`157e8e6`, `2bf4e0d`) are reachable via reflog, not GC'd,
as of 2026-07-09.
