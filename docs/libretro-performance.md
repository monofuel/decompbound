# Libretro core performance

This is the working reference for improving decompbound's libretro core on the
RG DS Plus. Profiling tools and an optional opaque XBGR transport are implemented;
CPU/PPU emulation optimizations have not been implemented. Other ideas below
remain hypotheses until measurements and correctness checks support them.
Initial profiling ran on the desktop while the handheld was unavailable, at
monofuel's request. Subsequent handheld profiling confirms that CPU polling and
PPU rendering dominate. The measured battle core alone exceeds the 60 Hz budget;
see [the ARM/x86 comparison](#measured-rg-ds-plus-profile).

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

## Measured PC baseline

Measured on `high-steel`, Ryzen 9 7950X, Linux 6.18.54, Nim 2.2.4 and GCC
15.3.0. The host and core use the shipping configuration, ORC and the core's
existing libc allocator selection. Runs are serial and pinned to logical CPU
2. The desktop's `powersave` governor and boost were left unchanged. Longer
golden checks ran on CPUs 17 and 23, outside that CPU and its SMT sibling;
ordinary desktop background activity was not stopped. These are desktop
measurements, not predictions for the Cortex-A55 handheld.

Each row combines **three runs of 2,000 measured frames**, each following 240
warmup frames imported from the same private capture. Video packing and PCM
generation are enabled, callbacks discard output, and hashing is disabled in
timing runs. Walking alternates right/left every 30 frames. Percentiles are
computed from all 6,000 individual samples, not averaged run percentiles.

| Workload | CPU mean | CPU p95 | CPU p99 | Wall mean | Wall max |
|---|---:|---:|---:|---:|---:|
| Cave, idle, DS | 1.585 ms | 1.623 ms | 1.711 ms | 1.590 ms | 1.848 ms |
| Cave, walking, DS | 1.611 ms | 1.659 ms | 1.723 ms | 1.616 ms | 1.975 ms |
| Cave, walking, single screen | 1.568 ms | 1.615 ms | 1.689 ms | 1.573 ms | 2.036 ms |
| Dialogue, DS | 1.308 ms | 1.333 ms | 1.416 ms | 1.312 ms | 1.579 ms |
| Titanic Ant battle menu, DS | 1.855 ms | 1.944 ms | 1.991 ms | 1.861 ms | 2.166 ms |

The captures are `earthbound_20260818-022023.png` for cave cases,
`earthbound_20260708-011828.png` for dialogue, and
`earthbound_20260706-213532.png` for the visually checked battle. All remain
under `~/Pictures/Screenshots/`; no capture, memory or audio data is committed.
The main capture matches the handheld's configured test state.

### Where frame time goes

One additional 2,000-frame instrumented run per workload separates exclusive
stages. Numbers below are mean **wall milliseconds in the instrumented core**,
including clock overhead; they are not exact uninstrumented CPU percentages.
The instrumented host costs about 6–9% more than the normal host across these
cases. Frontend callbacks add less than 0.0004 ms/frame here.

| Workload | Pure wait batches | Other CPU/bus | PPU total | APU total | DS update | Pixel packing |
|---|---:|---:|---:|---:|---:|---:|
| Cave, idle, DS | 0.583 | 0.139 | 0.719 | 0.133 | 0.003 | 0.064 |
| Cave, walking, DS | 0.563 | 0.199 | 0.734 | 0.138 | 0.003 | 0.065 |
| Cave, walking, single screen | 0.551 | 0.199 | 0.722 | 0.132 | 0 | 0.032 |
| Dialogue, DS | 0.672 | 0.035 | 0.464 | 0.146 | 0.004 | 0.065 |
| Battle, DS | 0.576 | 0.163 | 0.969 | 0.136 | 0.024 | 0.064 |

The remaining roughly 0.037–0.042 ms is adapter/system work. Pure polling
accounts for **29–47%** of instrumented frame time, PPU work **33–49%**, and
audio **7–10%**. Repacking the second panel matters more than its cached UI
update in the cave. Disabling the companion saves about 0.043 ms of measured
CPU time there; it is not the dominant core bottleneck on this PC.

### Independent instruction counts and sampling

`src/probes/probe_core_hotpcs.nim` preserves the frame step order, counts
opcode fetches, then reruns the existing stepper and requires identical final
serialized state and pixels. In 180-frame runs, two instructions dominate:

```text
file 0x00875F: LDA $002B
file 0x008762: BEQ back to $875F
```

| Workload | Share of opcode fetches in those two instructions |
|---|---:|
| Cave, neutral | 85.606% |
| Cave, held right | 82.422% |
| Dialogue | 96.636% |
| Battle | 81.594% |

These are instruction counts, **not time percentages**. The timed pure-batch
classification gives separate evidence that the loop is expensive. It must
handle DBR `$7E` and an 8-bit accumulator: the neighboring byte is not part of
that load. Tests cover mirrored WRAM banks, accumulator width, branch flags
and pending NMI. Mixed CPU batches are not counted as pure waits.

Original entry `$C08756` checks `$001E & $B0`, and has another path polling
HVBJOY. NMI code at `$C08170` establishes its register context, then
`$C0818E` increments the event at `$2B`. The poll-loop exit clears the event
and samples input. By contrast, the battle's next hot block around `$C0AF40`
writes M7B `$211C`, reads multiplication results starting at `$2135`, and
fills `$3C46,Y`: its 9.692% instruction share is meaningful work, not an idle
loop to discard.

An independent `perf` run sampled the normal, uninstrumented core for 6,000
walking frames (plus warmup/startup): 10,107 user-cycle samples, none lost.
The largest flat symbol shares were:

| Native function | Sample share |
|---|---:|
| CPU operand/address resolver | 26.31% |
| PPU `bgScanlineInto` | 22.49% |
| Main CPU `step` | 11.28% |
| PPU `compositeScreen` | 10.90% |
| PPU `renderScanline` | 6.59% |
| Runtime `__tls_get_addr` | 4.88% |
| Adapter `retro_run` body | 3.77% |

This confirms the CPU/PPU ranking without the stage timer overhead. TLS access
is pre-existing: generated code uses it for Nim exception state and the PPU's
thread-local palette cache. Flat samples do not split those callers. Hoisting
repeated palette-cache TLS access is another candidate; disabling error
propagation or thread isolation is not an accepted shortcut.

### Conclusions and the 30% target

1. **First experiment: verified wait-loop batching.** Preserve the remaining
   instruction-slot phase, accumulator/flags/PC, NMI handling and the existing
   scanline/APU/HDMA cadence. Start within the existing CPU batch boundary,
   rather than changing the instruction budget. The measured pure waits make
   a 30% improvement plausible, not proven; an optimization still needs to
   demonstrate its real savings and correctness, especially in battle.
2. **Next: the measured PPU hot paths.** Repeated scanline decode/composition
   and palette access have substantial headroom, with exact invalidation and
   scanline effects preserved.
3. **Small complementary work: transport packing.** It is about 0.065 ms per
   DS frame on this PC. Mono-retro's optional opaque XBGR transport is now
   implemented (measurements below); this alone cannot deliver 30% core savings.
4. **Defer audio threading as the first optimization.** Even perfect removal
   of the measured audio cost is far short of 30%, before synchronization
   overhead. Reassess its share on ARM rather than treating PC ratios as universal.

No 30% improvement is claimed by this profiling work. The original handheld
target remains 17 → 11.9 ms for an equivalent workload. A measured ARM baseline
is now available below; the next optimization needs a before/after device run.

### Evidence and controls

Normal results use source `3316f4f`, with the instrumented stage classification
corrected in `f6b76f0`. Both were built from clean source using the shipping
configuration; instrumented JSON also records its flags. Profiling does not
skip emulated instructions. Normal/profile video,
PCM and final WRAM/SRAM hashes match for all five cases in separate 120-frame
hash runs, after 30 warmup frames. Hashing overhead is excluded from the tables.

A pre-instrumentation `fe60f0d` reference was also built with matching settings
and compared in three paired walking runs. CPU means were 1.594 ms before and
1.603 ms with profiling disabled (+0.5% in these controls). No stage clocks or
recording remain in normal builds; one per-frame Nim error check survives.
This is not a claim of byte-identical machine code or zero instruction overhead.

The shared-library ABI/lifecycle tests, 1,200-frame parity in both screen modes,
profiling accounting/integration tests, and all **five full replay goldens
(924,845 frames)** pass. Existing goldens were not regenerated.

Ignored local evidence is under `bin/profiles/pc-3316f4f/` for normal timings
and native samples, and `bin/profiles/pc-f6b76f0/` for corrected stage timings,
hash parity and pre-instrumentation controls. Binary SHA256 identities:

- Normal `22d24fa247669898cbb8cd86abe503ae6b14772db6e50ffc3f02b84444b7cdba`.
- Instrumented `9007cfc7d805cd5e31e20e6098ec36d6e392a0c46b0bbb3a4bdfec51d081be84`.

Retain the PC-count probe while the wait-loop contract is being investigated;
it is a reproduction tool for that open question, not a timing benchmark.

## Measured RG DS Plus profile

Measured 2026-10-29 local time (2026-10-30 UTC) on the actual RK3568/Cortex-A55
handheld, ROCKNIX kernel `7.0.2-mono-rgdsplus-rocknix-r3`. Runs were serial,
pinned to CPU 2, with the menu stopped and restored afterward. The existing
`performance` governor was retained; sampled CPU frequency was 1.992 GHz.
All 36 frequency samples stayed at that value; CPU temperature samples ranged
from 41.25 to 65.63°C. Kernel/background activity was not disabled.
No frontend scaling, presentation or audio-device output is included: the host
still requests video and PCM, then discards the prepared buffers. Thus these
numbers measure the `.so`, with the same boundary as the desktop controls.

Each normal row combines **three runs of 2,000 measured frames**, following
240 warmup frames per run. DS and opaque XBGR are enabled. Hashing is disabled
in timing runs. Captures and input are the same cave walking, dialogue and
Titanic Ant battle cases described above. Fresh PC controls use the current
code and the same XBGR negotiation, rather than the earlier XRGB baseline.

| Workload | ARM CPU mean | ARM CPU p95 | ARM CPU p99 | ARM wall mean | ARM wall max | Fresh PC CPU mean |
|---|---:|---:|---:|---:|---:|---:|
| Cave, walking, DS | 14.813 ms | 15.156 ms | 15.295 ms | 14.909 ms | 15.923 ms | 1.567 ms |
| Dialogue, DS | 13.040 ms | 13.357 ms | 13.453 ms | 13.140 ms | 15.145 ms | 1.283 ms |
| Titanic Ant battle menu, DS | 18.050 ms | 19.257 ms | 19.781 ms | 18.326 ms | 39.967 ms | 1.798 ms |

The ARM core costs roughly **9.5–10.2×** as much CPU time for these workloads.
Cave walking leaves about 1.85 ms of the 16.67 ms budget before frontend work.
All 6,000 battle samples exceeded the CPU budget; none of the cave/dialogue
samples did. The largest battle wall sample was 39.967 ms but used 19.491 ms of
calling-thread CPU: 20.476 ms was not charged to that thread. Off-CPU delays
and emulation work must remain separate measurements. These results establish a core-side bottleneck;
they do not measure the player's total frame time.

One additional instrumented run of 2,000 frames per workload separates
exclusive **wall milliseconds/frame**, including timer overhead and run variance:

| Workload | Pure wait batches | Other CPU/bus | PPU total | APU total | DS update | XBGR copy |
|---|---:|---:|---:|---:|---:|---:|
| Cave, walking, DS | 6.057 | 2.134 | 5.436 | 1.172 | 0.084 | 0.237 |
| Dialogue, DS | 7.547 | 0.440 | 4.021 | 1.388 | 0.094 | 0.297 |
| Battle, DS | 6.416 | 1.996 | 7.674 | 1.350 | 0.336 | 0.286 |

Pure wait batches are **35–54%** of the instrumented ARM frame, versus about
30–50% in the fresh PC controls. PPU work is **29–42%** on ARM, audio **7–10%**.
The ranking agrees with x86, and polling is an even stronger target on ARM.
The stage shares are not exact uninstrumented CPU percentages. Mixed CPU
batches still contain uncounted polling, so the pure-wait classification is a
lower bound on time spent in the identified loop.

Observed instrumented CPU cost was about 3.0%, 6.3% and 1.0% above the normal
cave/dialogue/battle means, respectively, including run variance. Fresh PC
controls were about 6–9% higher with instrumentation.

Additional single-run, 2,000-frame controls measured cave idle DS at 15.307 ms
CPU, walking single-screen at 15.148 ms and walking XRGB DS at 15.833 ms.
They were run later and are exploratory, not paired estimates of option costs:
even single-screen was slower than the earlier DS mean. Stage output preparation
was 0.139 ms for single-screen XBGR versus 0.237–0.297 ms for two panels, and
0.726 ms for the XRGB control. No precise handheld percentage gain is credited
to switching options from these single runs.

### Recommended next experiment

Implement a narrowly guarded polling-loop batch within the existing CPU
instruction budget. In the instrumented ARM battle, pure waiting alone costs
about 6.4 ms/frame. This makes a 30% improvement plausible, but is not a measured
gain. Thirty percent less than the new 18.05 ms battle baseline is 12.64 ms of
core CPU time; frontend work must still fit afterward. Audio threading cannot
deliver that reduction from a measured 7–10% audio share.

The candidate contract is deliberately small: validate the live original
`$C0875F LDA $002B / $C08762 BEQ -5` loop, its bank/width/event state and lack
of pending NMI. Execute two ordinary instructions to establish accumulator,
flags, width invariants and the APU-handshake marker, then skip only complete
two-instruction pairs and execute any odd remainder normally. Preserve the
final PC phase and every scanline, NMI, HDMA and APU boundary. The current
profiling classifier is evidence, not a sufficient optimization guard:
custom read hooks can observe or change every fetch. Use a verified canonical
bus or a sealed core-only path; leave diagnostic/custom hooks on normal stepping.
No polling fast path has been implemented.

### Build identity and correctness controls

ARM normal timings use the **installed** shipping core `380b41b0da`. ARM
instrumentation and both fresh PC libraries use clean source `d87c2e2088`;
the intervening diff contains only documentation, so emulator/configuration
source is identical. All use Nim 2.2.4, GCC 15.3.0, shipping `danger`, ORC and
the existing core libc allocator. ARM uses the existing generic AArch64 target;
no new CPU tuning flags or runtime dependencies were introduced. Profiling
artifacts have separate output/cache paths and do not replace installed binaries.

For each of the three cases, separate 64-frame/5-warmup hash runs match between
normal and instrumented builds **and across ARM/x86**: raw XBGR video, PCM and
final exposed WRAM/SRAM. Stage totals equal frame wall time exactly, recording
counts and build flags are checked, and timing samples contain no hash work.
No ROM, screenstate, SRAM or other game data is added to Git.
All 18 timing runs and six hash runs completed. The menu service was restored;
installed player/core and ordinary SRAM checksums stayed unchanged. Native
sampling with `perf` was not run on ARM; its function percentages above are
PC evidence, separate from these ARM stage measurements.

To repeat the cave workload with the staged ARM tools, pause the menu, run this
from the device's `/tmp/decompbound-profile-d87c2e2/`, then restore the menu:

```sh
sudo taskset -c 2 ./libretro-profile-arm64 \
  --core:/usr/local/lib/libretro/decompbound_libretro.so \
  --rom:/var/lib/mono-retro/roms/EarthBound.smc \
  --state:/var/lib/mono-retro/states/decompbound/earthbound_20260818-022023.png \
  --ds --xbgr --walk --frames:2000 --warmup:240 --out:bin/repeat-cave.json
```

Ignored raw samples and metadata are in `bin/profiles/rgds-d87c2e2/` and
`bin/profiles/pc-d87c2e2/`. Binary SHA256 identities:

- ARM installed normal: `e1307dadc6cc1cb7c03f767381a077af065ff7f8ed9370c871b121db1533eaba`.
- ARM instrumented: `187e8a9c7c45968b7583215454838d4d4c8f8d73ad29a5a4a55faada13621503`.
- PC normal: `38da180709717f61a7a19b73f8ca26e2ff5e016f284409a78e36dcdbf9aac7a4`.
- PC instrumented: `ab216506e9eab999f033554f1b5ee72e635e3979f94dd17c343170ef90b98da6`.

## Implemented: opaque XBGR transport

The core now negotiates mono-retro's optional private XB24 transport, copying
opaque Pixie bytes into its existing output buffer. Older frontends retain the
standard XRGB packing path. This changes video preparation only; CPU/PPU/APU
execution and the combined game-above-party layout are unchanged. See
[the transport contract](libretro.md#frontend-contract).

The following comparison uses the **same new shipping core** with either
negotiation result, alternating standard/XBGR in three serial pairs. Each run
has 240 warmup and 2,000 measured cave-walking DS frames, pinned to CPU 2 on the
same PC as the baseline, without hashing. Thus each row contains 6,000 samples.
The host's callbacks discard output: this measures core savings, excluding any
additional frontend conversion savings.

| Transport | CPU mean | CPU p95 | CPU p99 | Wall mean | Wall max |
|---|---:|---:|---:|---:|---:|
| Standard XRGB8888 | 1.613 ms | 1.658 ms | 1.712 ms | 1.619 ms | 1.847 ms |
| Private opaque XBGR | 1.560 ms | 1.615 ms | 1.875 ms | 1.567 ms | 2.478 ms |

Mean core CPU work fell **3.25% (0.052 ms/frame)**. The XBGR runs had a worse
combined p99/max, including a transient in the second run; these measurements
do not demonstrate a tail-latency improvement. Separate instrumented runs put
output preparation at **0.0635 ms → 0.0072 ms** per DS frame, consistent with
replacing channel conversion by two contiguous copies. Those stage clocks
perturb execution and are not substituted for the uninstrumented totals.
The 30% target remains open, and no handheld gain is claimed.

The independent C host checks exact negotiation payloads, successful startup
logging, rejection/fallback, both-rejected failure, colors, every private filler
byte, blanking, panel offsets, reset and load/unload lifecycle. ROM integration
checks all normalized pixels, PCM, WRAM and SRAM for 1,200 frames in each of
four mode/transport combinations, including an imported private screenstate.
Normal/profile hash parity passes separately within each transport; raw video
CRCs intentionally differ between transports because their byte layouts differ.

The updated desktop mono-retro-player also passed its isolated X11 integration
suite, including its older-player fallback fixture. It then ran this actual core
for 180 paced frames in each screen mode from the private test state, selecting
XBGR and reporting no audio underruns/overruns with the null audio driver.
An older desktop player ran the same core/state in DS mode for 180 frames,
selected standard XRGB8888 and also reported no audio underruns/overruns.
The shipping ARM core cross-build passes (AArch64 ELF, standard runtime
dependencies, no Nix store runpath). The matching
`mono-retro-performance/build/player-xbgr-arm64` is now deployed with this core;
native validation is recorded below.

Ignored numeric evidence is under `bin/profiles/pc-xbgr-6a532f6-worktree/`.
These builds report source `6a532f6+dirty` plus the XBGR diff; SHA256 identities:

- Normal `d598a738afb9f169bcc29e77bd368a7451dd07088b1668f204ade0aeee74a515`.
- Instrumented `8005dbfbaf3d9c1fe761ca3afd07530f6968495be1d0b0d15b06f0932333024f`.

To offer XBGR in the profiling host, add `--xbgr` to the commands below.
Reports record both whether it was offered and whether the core selected it.
The default host rejects the private request to retain an older frontend control.

### RG DS Plus deployment check

2026-10-29, actual RG DS Plus running `7.0.2-mono-rgdsplus-rocknix-r3`:

- Installed shipping core `380b41b` at
  `/usr/local/lib/libretro/decompbound_libretro.so`, SHA256
  `e1307dadc6cc1cb7c03f767381a077af065ff7f8ed9370c871b121db1533eaba`.
- Installed mono-retro's supplied `player-xbgr-arm64` at both
  `/usr/local/bin/mono-retro-player` and the active ROCKNIX path
  `/usr/local/libexec/mono-retro-rocknix/mono-retro-player`, SHA256
  `f6593096c10503b13d677e7dd535a7a4be75c8a235f96ef7985f1d66c6cf9a58`.
- Ran the installed DS launcher with `--frames:300 --no-input`, real OpenAL/
  ALSA audio and its existing private `earthbound_20260818-022023.png` default.
  Exactly one startup message selected private opaque XBGR; 300 video frames
  and 159,900 stereo frames completed, with zero reported audio underruns or
  overruns. Both active DRM planes were 1024×768 XB24 buffers owned by the player.
- Ran the independent C core ABI/color/opacity/lifecycle host and mono-retro's
  ARM XBGR color/padded-row/ownership/worker tests on the device. Both passed.
- The previous ROCKNIX player also ran the updated core for 180 DS frames,
  selected standard XRGB8888 and delivered 95,940 stereo frames, with zero
  reported audio underruns/overruns.

Successful private negotiation selects the core's `opaquePixieVideo` branch in
`src/libretro/core.nim`, which copies main/companion images and skips its XRGB
packing loops. The frontend stores `PixelXbgr8888`; its `copyFrame` in
`src/retro/playervideo.nim` copies rows and returns before `convertXrgbRow`.
Thus **both transport channel conversions are bypassed**. Buffer ownership
copies, screen splitting/scaling and display presentation still occur.

The menu service was restored. Ordinary
`/var/lib/mono-retro/saves/decompbound/EarthBound.srm` stayed byte-identical;
test saves remain separate. Previous binaries and the unchanged DS wrapper are
backed up on the device under
`/var/backups/mono-retro/xbgr-380b41b-fqtsGx/`. Local ignored evidence is in
`bin/rgds-xbgr-380b41b/`, with device logs in
`/tmp/decompbound-xbgr-380b41b/`. No states, images or game data were committed.

Monofuel subsequently confirmed the installed build works in manual play, while
reporting that sustained 60 fps still needs work. The native transport/audio
test is not a handheld performance comparison. The PC gain above remains the
only measured before/after CPU improvement claimed here; the remaining
performance check is tracked in [human-verify.md](human-verify.md).

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
4. Copy opaque Pixie pixels or pack standard XRGB into the persistent output buffer,
   according to the negotiated transport.
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
| Pixel packing | Optional opaque XBGR now avoids conversion with updated mono-retro; improve the standard fallback only if worthwhile. | PC core mean improved 3.25% in the measured DS workload. Measure on ARM; frontend conversion is separately owned. |
| Buffer writes | Investigate redundant frame clears and overwritten scratch/output buffers. | Prove coverage and forced-blank/transition behavior before removing initialization. `retro_run` clears before a stepper that may also fill the backdrop. |
| Allocation and lifetime | Reuse transient storage and reduce unnecessary reference-management work in hot paths. | Measure allocations and correlate them with slow frames. Keep ORC/libc allocation and unload correctness unless evidence justifies a change. |
| Compiler | Evaluate target CPU tuning and profile-guided optimization using representative scenes. | Verify the actual device ISA/toolchain, compare shipping builds and validate portability. Older Pi PGO gains are historical; ARC/LTO changes previously measured as noise there. |
| Parallel work | Consider an APU worker, or later PPU work from consistent snapshots. | Measure the available parallel fraction and synchronization/ownership cost; see below. |
| Runtime TLS | Reduce repeated thread-local palette/error-state access where safe. | Native sampling finds 4.88% in `__tls_get_addr`; establish the call sites and preserve exception behavior and isolation. |
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
synchronization overhead. The current PC measurements put audio at 7–10%; its
share on the handheld is still unknown. Additional
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

Wait-loop batching is the leading candidate from the PC evidence. It has not
been implemented or credited with savings. Optional XBGR transport is the first
completed optimization, documented separately above.

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
