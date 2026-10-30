# Libretro core performance

This is the working reference for improving decompbound's libretro core on the
RG DS Plus. Profiling tools are available; emulation optimizations have not
been implemented. Ideas below remain hypotheses until measurements and
correctness checks support them. Initial profiling runs on the desktop while
the handheld is unavailable, at monofuel's request.

The scope is the `.so`: CPU/bus execution, PPU rendering, APU/DSP audio, the DS
companion, and libretro output preparation. Another agent owns
mono-retro-player. Frontend scaling, display presentation, audio-device output
and frontend threading belong to that work, not this document's implementation
scope. The [libretro contract](libretro.md) remains the boundary.

## Baseline and target

Monofuel reports about **15.9 ms/frame average**, with occasional **17.1 ms**
frames on the handheld. The measurement boundary, scene, build identity and
distribution still need to be recorded before treating these as exclusive
core timings. These numbers are not a measured subsystem profile.

The core currently advertises 60 Hz, giving a **16.67 ms** frame budget. If
15.9 ms is required work on the critical path, only 0.77 ms remains. The working
target is **30% less core CPU time per emulated frame**: a 17 ms workload would
become **11.9 ms**, leaving about 4.8 ms of frame budget. This means multiplying
cost by 0.7 (about 1.43× throughput), not merely 30% higher throughput. An
uncapped benchmark using an entire host core is not itself a regression in CPU
usage; compare CPU time for the same emulated work.
Tail latency matters alongside the mean; buffering can absorb some isolated
spikes but cannot compensate for sustained excess work.

Both desktop and ARM core builds already default to `danger` and release
optimization through root `config.nims`. `-d:debug` selects checked development
builds; tests default to checked builds. Verify the installed `.so` identity
and build flags before comparing results. Build-profile selection is already
implemented, not a proposed new optimization.

## Ideal core and current execution

The ideal core executes necessary game work once, reuses decoded data, avoids
allocation during steady playback, and prepares native-resolution video and
PCM with minimal copying. An unchanged companion image should require little
additional work. Emulated devices advance in a deterministic order, with enough
host parallelism to help only where dependencies permit it.

The current path is `retro_run` in `src/libretro/core.nim`:

1. Poll input and clear the native frame image.
2. Call `stepReplayFrame`: CPU/PPU/APU scanline stepping plus audio top-up.
3. Read party state and update the optional DS companion.
4. Pack game and companion pixels into the persistent XRGB8888 output buffer.
5. Invoke the frontend's video and audio callbacks.

`frame_step.nim` schedules 262 scanlines with up to 150 main-CPU instruction
steps each: **39,300 step slots/frame**. Rendering includes scanlines, sprites
and foreground composition. `replay_run.nim` completes the regular output to
**533 stereo sample pairs/frame**. APU port polling can also advance audio
internally; its catch-up work is distinct from that regular output count.

The main image, output pixels and PCM storage are already persistent.
`ds_companion.nim` already redraws its image only when relevant display state
changes. PPU palette caching, tile-row decoding and shared main/subscreen
decoding also exist. Assess their remaining costs rather than proposing them
as entirely new capabilities.

## Measurement comes first

Measure the actual shipping `.so` on the target with a pinned private
screenstate and reproducible input. Include moving overworld scenes, dialogue,
animated battles, transitions/music changes and DS companion updates. Standing
still alone is not representative. Record ROM/core identities, compiler flags,
device clocks, temperature, duration and whether the DS companion is enabled.
Keep private states and captures outside tracked files.

The desired breakdown is:

| Work | What to distinguish |
|---|---|
| Main CPU and bus | Dispatch, ordinary memory access, MMIO, DMA and waiting loops. |
| PPU | Background decode/composition, sprites, foreground passes and color math. |
| APU | SPC700 instructions/timers versus DSP mixing; regular versus port catch-up work. |
| DS companion | Reading/comparing party state versus actual image redraw. |
| Video packing | Game pixels versus companion pixels. |
| Callbacks | Time executing frontend input, video and audio callbacks, reported separately. |

Keep both total `retro_run` elapsed time and exclusive core work. A timer around
`cpu.step` also includes APU catch-up triggered by MMIO reads: nested work must
not be double-counted or mistaken for CPU interpreter cost. Prefer coarse stage
instrumentation or sampling over a clock read for every emulated instruction.
Instrumentation should compile out of normal builds.

Report median, mean, p95/p99 and maximum frame time, and separate startup from
steady playback. Compare DS enabled/disabled and rendering enabled/disabled to
isolate costs, while keeping emulated devices advancing. A headless harness
must still exercise the normal video/audio preparation paths when measuring
the full core; merely omitting callbacks can omit packing work too.

Existing starting points are `src/tools/bench_replay.nim` (`--frame-times`,
`--no-render`, fixed tapes and private start states), the shared-library hosts
in `tests/test_libretro.nim` / `tests/integration_libretro.nim`, and the
[historical Pi measurements](raspberry-pi.md). Replay benchmarks do not include
the libretro adapter or DS companion, so they complement the `.so` baseline.

## Candidate improvements

| Area | Idea | Evidence or decision needed |
|---|---|---|
| CPU waiting | Recognize proven polling loops and skip equivalent iterations until the next relevant event. | Identify hot PCs and exact loop side effects; preserve CPU results, scheduling and device progress. Historical Pi work found substantial polling, not a current RG DS Plus percentage. |
| CPU and bus | Reduce repeated decoding, dispatch and ordinary-memory lookup overhead; consider cached instruction blocks for hot code. | Profile actual instructions/accesses. Preserve generic hooks, MMIO and self-modifying RAM behavior; account for CPU width/mode changes. |
| PPU | Reuse decoded tile indices across appropriate writes; retain useful intermediate composition instead of decoding again. | Identify the remaining repeated work. Invalidate for VRAM, palette and relevant register changes; retain scanline effects, windows, priority and color math. |
| APU/DSP | Streamline SPC dispatch, timer handling, BRR/sample decoding and DSP loops where profiling finds cost. | Separate these costs first. Preserve feedback-dependent decoding, audio samples and CPU/APU interaction. |
| DS state | Reduce repeated party/inventory construction, string work and allocations when relevant WRAM contents are unchanged. | Measure snapshot/read/compare cost separately from rendering; preserve roster order, HP/PP updates, palettes, input and inventory selection. |
| Companion output | Repack its cached image into XRGB only when that image changes. | Provide a reliable image revision/invalidation path, including reset and state import. The image is cached now, but its pixels are still repacked every frame. |
| Pixel packing | Improve the core's native-frame-to-XRGB conversion, including compiler vectorization or ARM SIMD if warranted. | Measure the loop on the target and inspect generated code; preserve colors, layout and pitch. Frontend conversion is separately owned. |
| Buffer writes | Investigate redundant frame clears and overwritten scratch/output buffers. | Prove coverage and forced-blank/transition behavior before removing initialization. `retro_run` clears before a stepper that may also fill the backdrop. |
| Allocation and lifetime | Reuse transient storage and reduce unnecessary reference-management work in hot paths. | Measure allocations and correlate them with slow frames. Keep ORC/libc allocation and unload correctness unless evidence justifies a change. |
| Compiler | Evaluate target CPU tuning and profile-guided optimization using representative scenes. | Verify the actual device ISA/toolchain, compare shipping builds and validate portability. Older Pi PGO gains are historical; ARC/LTO changes previously measured as noise there. |
| Parallel work | Consider an APU worker, or later PPU work from consistent snapshots. | Measure the available parallel fraction and synchronization/ownership cost; see below. |
| Native execution | At the far end, compile understood game routines into native code rather than interpreting every instruction. | A substantial separate direction requiring contracts and decompilation evidence. Full native game reimplementation is outside the current five goals unless explicitly added. |

These candidates are not a commitment to implement every approach. Start with
the measured dominant cost and the smallest verifiable change; compiler tuning
and small packing savings should not substitute for finding wasted emulation.

## Multithreading and the separate sound CPU

Yes: the SNES has a separate **SPC700 sound CPU**, with its own memory and a
sound DSP. The main CPU communicates through four ports. This hardware boundary
makes the complete APU a plausible host-thread candidate, but does not make it
independent of game execution. See the hardware overview in the
[Nintendo development manual](https://floating.muncher.se/bot/manual/book1_text.pdf)
and the separate-CPU/port description in
[SPC700 Programming Information](https://snesmusic.org/files/spc700_documentation.html).
These are references; the implementation constraints below come from our code.

Currently `apu.nim` owns SPC execution, timers and DSP mixing. Its `runSample`
advances SPC execution for a sample interval and mixes one stereo sample.
`snesbus.nim` handles `$2140..$2143` reads by advancing the APU during handshake
polling before returning port values. This is important existing behavior:
stale replies have caused upload/transition failures. `cpu.nim` identifies
handshake routines so those paths receive a larger bounded catch-up allowance.

A viable threaded design would need:

- One owner for SPC/DSP/timer state and ordered main-CPU port events.
- An explicit emulated-time/event schedule; current scheduling combines
  instruction budgets per scanline with port-triggered catch-up.
- Bounded work batches and synchronization where port observations depend on
  APU progress. Avoid an OS wakeup or lock round trip for each sample.
- Deterministic sample delivery within `retro_run`'s contract, plus safe reset,
  state import, error propagation and unload/join behavior.
- No arbitrary full-frame APU lead or lag: future main-CPU commands and current
  port replies constrain how independently it can advance.

The best-case model is `max(main work, audio work) + synchronization`, rather
than their serial sum. For illustration only, if audio were 20% of 15.9 ms of
exclusive core work, perfect overlap would bottom out around **12.7 ms** before
synchronization overhead. The actual audio fraction is unknown. Additional
threads cannot remove a dominant serial bottleneck, and contention or frequent
rendezvous can worsen tail latency.

| Parallelization | Initial assessment |
|---|---|
| Entire APU on one worker | Plausible if its measured cost justifies explicit scheduling and port synchronization. |
| SPC and DSP on separate workers | More dependencies and very small work units; investigate single-thread efficiency first. |
| Individual DSP voices | Shared mixing/feedback dependencies and tiny tasks make this a poor first candidate. |
| PPU rows/layers on workers | Requires consistent temporal inputs; live CPU/HDMA writes and module-global PPU caches prevent naive parallel calls. A frame-start snapshot does not preserve mid-frame effects. |
| Consecutive emulated frames in parallel | Frames depend on previous machine state; not independent jobs for this core. Frontend presentation overlap is separate. |

Audio threading is therefore an option to evaluate after profiling, not an
automatic first optimization. Preserve the deterministic single-thread path
as the reference while evaluating any worker design.

## Acceptance and investigation loop

For each candidate, record the hypothesis, fixed workload/build, before/after
timing distribution, correctness result and retained/rejected decision here.
Do not claim gains from different scenes or debug-versus-shipping comparisons.

Existing video, PCM, WRAM and SRAM checks remain independent referees. Use
targeted tests, the actual shared-library integration, all recorded replay
goldens and the captured-scene sweep appropriate to an emulator change. Never
regenerate goldens or weaken assertions to accept an optimization. Threading
also needs repeated deterministic runs and lifecycle/handshake stress checks.

Keep existing behavior-preservation and hardware fidelity as separate claims:
matching current goldens does not prove unresolved emulation behavior matches
a console. Record any required handheld play/audio check in
[human-verify.md](human-verify.md). Maintain ROM rebuild identity when touching
assembly, codecs or extraction, following [GOAL.md](../GOAL.md).

No optimization has been selected or benchmarked in this investigation yet.

## Profiling tools

`make libretro libretro-profile` builds the normal `.so`, a separate
`bin/libretro/profile-instrumented.so`, and the standalone
`bin/libretro-profile` host. All use the shipping configuration by default.
Only the instrumented core has `-d:coreProfile`; normal builds compile away the
stage clocks and recording buffers. No frontend or device library is required.

The host always installs video and audio callbacks, so packing and audio
generation remain enabled even though output is discarded. It does not load
or save battery SRAM. Optional state import uses the normal public API.
Reports contain raw per-frame wall time, Linux calling-thread CPU time and
quantiles, plus build information and callback counts. Output must be JSON
beneath the current directory's ignored `bin/` tree. `--hash` checks video,
PCM and final WRAM/SRAM without storing their contents; use it for correctness,
not timing, since hashing is performed in timed callbacks.

```sh
make libretro libretro-profile
taskset -c 2 bin/libretro-profile \
  --core:bin/libretro/decompbound_libretro.so \
  --rom:"bin/Earthbound (U) [!].smc" \
  --state:/home/monofuel/Pictures/Screenshots/earthbound_20260818-022023.png \
  --warmup:240 --frames:2000 --ds --walk --out:bin/profiles/normal.json

DECOMPBOUND_PROFILE_OUT=bin/profiles/stages.json \
DECOMPBOUND_PROFILE_WARMUP=240 DECOMPBOUND_PROFILE_FRAMES=2000 \
taskset -c 2 bin/libretro-profile \
  --core:bin/libretro/profile-instrumented.so \
  --rom:"bin/Earthbound (U) [!].smc" \
  --state:/home/monofuel/Pictures/Screenshots/earthbound_20260818-022023.png \
  --warmup:240 --frames:2000 --ds --walk --out:bin/profiles/instrumented.json
```

Stage accounting is exclusive, including APU work nested inside main-CPU MMIO.
`MainCpuWait` identifies complete CPU scanline batches beginning inside the
verified `$C0875F/$C08762` wait loop with a zero event flag, appropriate branch
state and no pending NMI. It is a lower bound on time in that polling loop;
mixed batches remain in `MainCpu`. Classification does not skip instructions.
The input/video/audio callback stages remain separate from core execution.

Compare normal and instrumented runs to quantify timer overhead. Run benchmarks
serially with the same affinity and input; do not overlap them on one CPU.
`make libretro-profile-test` checks nested scopes, warmup/caps, normal-build
behavior, host quantiles and actual shared-library output/memory hash parity.
