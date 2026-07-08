# Music — the jukebox track

**Status:** foundation built; pack-1 prepend fixed most standalone halts
(2026-07-08). Residual quiet songs (ids 4/11/76) and polish remain.

The goal: **every EarthBound song plays audibly**, and a browsable **jukebox** where
you pick any track and hear it. Distinct from `docs/sfx.md` (DSP synthesis accuracy)
and `docs/audio.md` (the shared SPC700/S-DSP foundation + the ROM-side data format).

## Where it stands

- **In-game music works** — `make play` streams real APU audio (SPC700 + S-DSP + IPL)
  via slappy. Songs play *while playing the game*.
- **`sound_explore.nim`** (the jukebox foundation) resolves a song's packs (song table
  `0x04F70A`, pack table `0x04F947`), uploads them into a standalone APU exactly like
  `$C0AB06`, runs the SPC700 + DSP, and writes a WAV per song — **but the output is
  near-silent.** The driver is resident and running, but the song is never *triggered*.
- **`music_explore.nim`** is a sequence/data explorer, not a player.

## The frontier — two layers, first one partly cracked

**Layer 1 — the song-start trigger (PARTLY DONE, 2026-07-06).** Disasm of the loader tail
(`$C4FBBD` after `$C0AB06`) gave a play command: poke `0x57` → `$2143`, then songN →
`$2140`. Wired into `sound_explore`. **Song 1 now produces audio** (~1330 peak, quiet) — the
jukebox's first non-silent sound. So the trigger fires.

**Layer 2 — pack 1 (engine @ `$0500`) must be present (CRACKED 2026-07-08).** Songs
whose table omits pack 1 used to halt (`stopped=true`, `flg=$E0`) because only song
data packs loaded and `$0500` was empty/stub. **`sound_explore` / `jukebox_app` now
prepend pack 1 when missing** → full scan ≈188/191 songs audible; **0 halts**.
Without prepend, song 3 dies at `pc=$00F4` (see `src/tools/songstart_dig.nim`).
Residual **quiet** ids **4 / 11 / 76** (alive but peak≈0) are sequence/id selection
inside shared packs — next dig, not soft-reset.

## Delegatable tasks (pick one)

1. **Crack the song-start port protocol.** Disasm the song-loader `$C4FBBD` *tail*:
   after the `JSL $C0AB06` upload, what does it poke to `$2140-$2143` (and the `$B549 /
   $B53B` state) to start playback? Cross-ref the SFX helpers (`$C0AC01` etc.). Then make
   `sound_explore` issue that sequence → confirm a non-silent WAV (peak amplitude jumps
   from ~15 to a real waveform).
2. **The `.spc`-snapshot route (sidesteps the frontier).** In-game music already works,
   so add a key to `play.nim` that dumps the live APU state (64 KB RAM + regs) as a
   `.spc` file while music plays; a standalone SPC player then plays that. Builds the
   soundtrack by capturing songs as you hit them.
3. **Sequence bytecode semantics.** The per-track byte streams (`docs/audio.md`
   hypothesizes `0xE0 xx` = instrument, `0xF4 xx` = tempo, loop markers `0xF0/F7/FA`) —
   pin the note/duration split + operand widths by tracing the resident driver's
   dispatch loop, or a PCM-diff after upload.
4. **The jukebox UI.** Once songs play: a silky browser with the real track list (song
   IDs → names), play/stop, now-playing, channel muting. Realtime needs slappy's queued-
   buffers loop (~50 lines upstream). See `docs/apps.md`.

## Definition of done

- [ ] A song renders to a **non-silent** WAV via `sound_explore` (the trigger works).
- [ ] Round-trip: a song's sequence/instrument data decodes → re-encodes byte-exact.
- [ ] A jukebox browses the soundtrack by name and plays any track on demand.

## Related

`docs/audio.md` (SPC700 + S-DSP + the ROM-side upload/data format), `docs/sfx.md` (making
the samples *sound right*), `docs/apps.md` (the jukebox app).
