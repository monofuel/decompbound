# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Live-play captures come from F12 (preserved `f12_NNN` bundles) per the debug workflow.

**Human eyeballs:** short "run this / pass if" checks live in
[`docs/human-verify.md`](human-verify.md) — not buried in chat. This file is the
durable status board (FIXED / IN PROGRESS / OPEN); human-verify is the active
checklist monofuel ticks while playing.

**Known-good play baseline + the 2026-07-08 audio/visual incident** (room-entry
hang, Saturn Valley corruption, half-speed music) are tracked together in
[`docs/play-regressions.md`](play-regressions.md), including the fallback commit
`0bdad72` and the salvage path for the orphaned fixes.

**Updated:** 2026-07-05 — restructured as a scannable status board (fixed vs. in-progress vs. open). Grouped from live-play verification this session, cross-checked against recent git log.

## FIXED (verified in live play)

- Iris/window-mask flicker (window masking + compositor).
- Sprite render order (hotel sign / street signs / Ness-behind-counter / battle sprite order / top-edge clip).
- Top-line + battle-border flicker + audio hitching (NMI-at-vblank + real-time 60 Hz pacing).
- Scene/transition delays incl. intro cards + hotel-exit + music-ahead-of-scene (InstrPerLine 40->150 CPU budget).
- Controller-disconnect crash (guarded poll+read, catches Defect).
- Alt-tab super-speed (pacing backlog clamp).
- Swirl color-math MODE (CGADSUB add/subtract bits were swapped).
- Giygas intro red-snow (Mode 7 multiply for HDMA distortion; 2026-07-08 — please confirm in `make play`).
- INIDISP brightness 0 = true black (was `(n+1)/16`, never reached black — Halken/battle
  fade linger on last dim frame).
- Logo glow 1px bottom gap (2026-07-08): OAM sprites were drawn at Y instead of Y+1.
  Hardware places sprites one scanline below OAM Y; hard letter faces sat 1px above the
  BG soft-glow fringe. Fix: `screenY = y + py + 1` in `renderSprites` (linear, no wrap).
- Top scanline garbage after logo fix (2026-07-08): `(y+py+1) and 0xFF` wrapped the
  last row of **Y=$E0 size-32 “offscreen”** sprites onto line 0 (battle UI / overworld).
  Real range is linear 225..256 (outside 0..223). Dropped 8-bit wrap; line 0 clean.
- Battle BG over UI / borderless battles (2026-07-08 live confirm: Mini Barf fight
  shows full psychedelic BG + HP/PP windows + dialogue). Mode-0 per-tile priority
  ladder (`bg3prio` is mode-1-only; commits `01e8084` / `cc898f6` / `eb3f714` /
  `194d450`). Was drawing animated BG in front of command/status UI.
- Battle BG “over” UI via color math (2026-07-08): CGADSUB half-math on BG3 was
  applied to *every* main pixel, so BG1 UI was half-blended too and the animated
  BG looked painted on top. Fix: track topmost layer per pixel; only math when
  that layer’s CGADSUB bit is set (hardware).
## IN PROGRESS (fork/agent actively on it)

- Battle-swirl COLOR still red-instead-of-green (color-math OPERAND — fixed color / CGWSEL window). Color-math fork.
- Battle HP/PP status band cut off / black (TM=00 TS=70 subscreen band). Color-math fork.
- Boss-intro world-dim skips a bush sprite. Color-math / priority fork.
- gradient-test SNES test ROM fails (no gradient). Color-math fork.
- DSP SFX accuracy — "deeper" SFX wrong (Goods-menu click, swirl sound, enemy-defeated) while simple beeps are right. DSP fork.

## OPEN (not yet assigned)

- ~~Giygas red-snow static ANIMATION fidelity~~ **FIXED 2026-07-08** (see [red-snow.md](red-snow.md)).
  Missing Mode 7 multiply (`$211B`/`$211C` → `$2134`–`$2136`) left the HDMA
  BG2HOFS distortion table all zeros, so the intro showed a coherent Giygas
  face tile grid instead of warped TV snow.

- ~~**Door exit → black exterior (force blank stuck)**~~ **FIXED 2026-07-08**:
  save-state v1 restored SPC RAM/PC/ports but **not APU timers** (`$F1`/`$FA`–`$FC`).
  After `--load-state` (llm-ai bedroom fixture) timer 0 stayed disabled; music
  driver spun at APU `$0579` (`MOV A,$FD` / `BEQ`) and never acked `$2140`, so
  the main CPU stayed in `$C0ABD0` wait and left `INIDISP=$80`. `make play` from
  cold boot was fine (driver init enables T0). Fix: state v2 serializes timers;
  v1 loads call `recoverTimersAfterLoad` (enable T0, target from APU `$53` or
  `$10`). Probes: `probe_door_apu.nim`, `probe_outside_black.nim`.

- Sprite-behind-object 1px flicker/lag during movement (OAM/frame-timing polish).
- test_speed ROM fails (CPU cycle-accuracy — we use a fixed instruction budget, not cycles).

Prior detailed sections for now-resolved items (old milestones, input latch, APU snapshot replay, menu hangs, logo fade, etc.) removed; still-relevant mechanics (HDMA per-line TM/TS splits for battle bands, top-scanline vblank timing, CPU budget vs. cycle accuracy) are summarized in the items above.

## Perf / investigations

- **Rare `make play` frame stutter (INVESTIGATING 2026-07-19).** A very rare,
  transient hitch during play (observed mid-dialogue, "What brings you to the
  Monotoli Building?") that **does not** correlate with autosnaps or any game
  event. **Hypothesis (monofuel):** Nim GC pause — we're on the default
  `--mm:orc` (Nim 2.2.4), whose **cycle collector** fires periodically → a rare,
  game-uncorrelated pause. Fits the symptom.
  - **Test in progress:** temporary `config.nims` sets `--mm:arc` (deterministic
    RC, no cycle collector = no GC pauses). Play a session; hitch gone ⇒ confirmed.
    ARC leaks true cycles → diagnostic build only; revert by deleting `config.nims`.
  - **Real fix (if confirmed):** kill hot-path garbage — `ppu.modeLayers` allocates
    a `seq` **per scanline (~262×/frame)**; `overlayForegroundBg` builds a `passes`
    seq/frame; per-frame `&"…"` title/log strings. Preallocate/reuse; optionally
    `GC_fullCollect()` at an idle point (vblank/pause) so it never lands mid-frame.
  - Instrumentation ideas if not the GC: slow-frame detector (log frame + `seg`
    replay anchor when wall-time > budget), surface per-frame `apuPortCatchup`,
    per-phase timing breakdown.

- **ROOT CAUSE FOUND + FIXED (2026-07-20): `bus.dirty` unbounded growth.**
  `cpu.write8` appended every touched address to `bus.dirty` on *every* memory
  write. That list is consumed ONLY by the vector-test harness (`run_vectors`), so
  in normal emulation it grew one `int` per write **forever** — the per-frame
  Nim-heap leak AND the rare frame stutter (its capacity-doubling `seq` periodically
  realloc-copied millions of ints mid-frame). **Fix:** gate the append behind
  `Bus.recordDirty` (default OFF); the vector harness + single-step test opt in.
  Headless proof: core leak **3563 B/frame heap + 6901 B/frame RSS → 0 on both**
  (`probe_frame_leak`, every subsystem mode). Regression test: `tests/test_frame_leak.nim`.
  - How it was found (all headless, no windows): (1) realized live=RssAnon vs
    probe=getOccupiedMem measure different pools; (2) `probe_audio_leak` (OpenAL
    direct) → audio CLEAN; (3) `probe_gl_leak` (surfaceless EGL, real driver, no
    window) → `glTexImage2D`-per-frame FLAT (GL theory wrong); (4) subsystem
    bisection in `probe_frame_leak` → identical 3563 B/frame in EVERY mode incl.
    `emuonly`, pointing at cpu.step/bus; (5) grep → `bus.dirty.add` in write8.
  - The scene-dependence explains why live (busy Fourside, more CPU writes/frame)
    leaked ~80 MB/min while the quiet `game_start` probe state showed less: the
    leak scales with writes-per-frame.

- **~~Live `make play` memory leak~~ (superseded by the dirty-seq root cause above).**
  Historical notes: live RssAnon climbed
  ~80 MB/min (was ~135 before the trace-seq fix). Key realization: the live number
  is **RssAnon** (`/proc`), but the headless probe measured **getOccupiedMem()**
  (Nim GC heap only) — different pools. RssAnon also holds OpenAL PCM buffers and
  the GL driver's texture storage, which a Nim-heap probe is structurally blind to.
  Isolation probes now report **both** metrics. Results:

  | Path (isolated) | Nim-heap | RssAnon | verdict |
  |---|---|---|---|
  | `probe_audio_leak` paced+pump (OpenAL only) | 0 B/frame | **0.3 MB/min** | audio CLEAN — `pump()` keeps up |
  | `probe_audio_leak` nopump control | 5 B/frame | 8.1 MB/min | proves the probe *can* see OpenAL leaks |
  | `probe_frame_leak` core (emulate+render+audio-tick, no GL/OpenAL) | 3563 B/frame | 6901 B/frame (~24 MB/min flat-out) | residual core leak — still unpinned |
  | live `make play` (all paths) | — | ~80 MB/min | GL upload ≈ the remaining ~56 MB/min |

  - **OpenAL exonerated.** With real-time pacing + `pump()`, the audio queue is flat.
  - **Prime suspect: the per-frame `glTexImage2D`** (play.nim ~L971) *reallocates*
    a 256×224×4 = 229 KB texture every frame. On a Mesa/software GL driver that
    realloc churn accumulates in RssAnon. **Likely fix:** one-time `glTexImage2D` to
    allocate, then `glTexSubImage2D` each frame to reuse the same storage.
  - **Confirm live:** `./bin/play --no-tex <rom>` (skips the upload) vs `--no-audio`
    vs normal — watch the mem heartbeat. Whichever flattens RssAnon is the culprit.
  - **Residual core leak** (~3.5 KB/frame Nim-heap) persists after the trace-seq fix
    — the hot-path `seq` churn (`ppu.modeLayers` per scanline, `overlayForegroundBg`
    passes/frame) is the likely source; same target as the stutter fix above.
