# Expanded EarthBound viewport

Status: experimental Winters outdoor prototype, with headless verification and
basic desktop play confirmed by monofuel. Desktop tearing remains open, and the
complete manual preset/input matrix is not yet confirmed. All listed sizes and validated custom
dimensions are selectable. The first implementation targets local desktop testing
through mono-retro-player; RG DS Plus deployment is deferred. The existing
[EarthBound DS companion](earthbound-ds.md) remains the default baseline.

Manual play reached Threed via the Skyrunner: neither the cutscene nor Threed
extends the viewport yet. This matches the current Winters-only scene gate;
both need separate renderer coverage before expansion can be enabled there.

The aim is to reveal more of the world while retaining sharp integer-scaled
pixels. On the handheld's 4:3 panels, expanding both dimensions is a useful
alternative to a conventional 16:9 widescreen view. This is an optional emulator
enhancement, outside the canonical five [decompilation goals](../GOAL.md);
investigations can still contribute evidence about the original scene renderer.

## Current display and visual preference

Each physical display is 1024×768. A native Nintendo DS panel is 256×192 and
fits at exactly 4×. EarthBound instead renders 256×224, fitting at 3× as
768×672, with 128 physical pixels of padding on each side and 48 above/below.
At 4× its height would be 896 pixels, exceeding the display.

The default dual-screen core combines two 256×224 panels into a 256×448 frame.
The experimental contract below supports a larger game panel with an unchanged
companion. Logical viewport dimensions and physical window sizes are independent.

Black borders are acceptable. EarthBound interiors often surround rooms with
black, which blends naturally into the player's padding. The existing mode
preserves the complete original frame: the surrounding border is padding,
not a crop of the game image. Filling every physical pixel is not a requirement.
Native DS 1× accommodation remains outside scope; presentation targets 2× and up.

## Candidate resolutions

All sizes below are for one game panel, using square pixels and integer scaling.
Border values are physical pixels on **each** edge, listed horizontal/vertical.
Every row is selectable; expanded scenery coverage is limited to the prototype.

| Logical viewport | Scale | Physical image | Border per edge | Tradeoff |
|---|---:|---|---|---|
| 256×224 | 3× | 768×672 | 128 / 48 | Current view and character size. |
| 320×240 | 3× | 960×720 | 32 / 24 | Modest expansion in both directions; exact 4:3. |
| 336×256 | 3× | 1008×768 | 8 / 0 | Nearly fills the panel; dimensions align to 8-pixel tiles. |
| 448×252 | 2× | 896×504 | 64 / 132 | Exact 16:9; wide view with substantial vertical padding. |
| 512×384 | 2× | 1024×768 | 0 / 0 | Exact 4:3; much more world, smaller physical characters. |

**All listed resolutions are selectable for testing.** The suggested
starting point for visual investigation is **336×256 at 3×**, rather than a
fixed target or settled default. It preserves current physical character
size and could reveal 40 additional logical pixels on each side and 16 above
and below, assuming a centered camera. **320×240 at 3×** is a more conservative
alternative, adding 32 per side and eight above/below.

At 2×, sprites are two-thirds their current physical width and height. The
512×384 option would show substantially more world, but is a separate tradeoff
from preserving the current presentation. At 3× the mathematical maximum is
341×256; 336×256 avoids an odd leftover physical column and aligns to tiles.

336×256 contains 50% more source pixels than 256×224. That is a pixel-count
comparison, not a CPU-time prediction. Expanded scene preparation and drawing
need profiling independently of the frontend's GPU upscaling.

## Configuration requirements

Viewport size must be configurable rather than tied to one device or a single
polished mode. Provide presets for every resolution in the table, including the
original 256×224 view, plus custom logical width and height for future devices
and experiments. Presets are convenient dimension pairs, not separate renderers.
Unfinished scene handling should not prevent selecting an otherwise valid size;
document known visual limitations for each affected mode.

Keep the following settings separate:

- **Core viewport:** logical world width and height. Changing these changes how
  much scenery is drawn, independent of the physical display resolution.
- **Frontend presentation:** physical output, integer scale and centering. Choose
  the largest fitting integer scale automatically, with a testing override for a
  smaller fitting scale. Preserve square pixels and black padding. A requested
  scale that does not fit should produce a clear error instead of silently
  cropping or stretching the image.
- **Companion layout:** describe the companion's logical dimensions separately
  from the game view so a larger world viewport does not force larger UI pixels
  or a redesign of the party panel. Each physical display can choose its own
  fitting integer scale.

The core options and player launch arguments are specified below. Selection is
startup-only; reload content to change geometry. Switching geometry during play
remains outside the prototype. The core logs changes between extended and padded
presentation; the selected dimensions and scale are explicit launch arguments.

Custom dimensions should preserve at least the original 256×224 view and stay
within explicit, validated allocation limits. Set those limits from renderer
constraints and measurements rather than hard-coding the RG DS Plus's physical
resolution as a universal maximum. Tile alignment may simplify internal work,
but must not exclude the suggested 448×252 preset. Invalid input should explain
the constraint; accepted dimensions should not silently become another preset.

The RG DS Plus is the first test device, not a geometry requirement. Keep
device/output selection in the frontend and scene dimensions in the core.
The existing 256×224 mode remains the default until expanded modes are evaluated;
experimental presets can remain available even when some scenes are unpolished.

## First phase — Desktop outdoor prototype

The first phase combines Stage 1 with a bounded part of Stage 2, so the
result demonstrates actual extra scenery rather than only a larger output image.
Implementation spans decompbound and mono-retro-player geometry handling. Initial
testing is local on desktop; handheld deployment is deferred.

In scope:

- Select all listed presets and validated custom dimensions at launch/reload.
  Keep the original 256×224 mode as the default and comparison baseline.
- Present the game and companion in separate desktop windows with integer
  scaling, correct crops and pointer mapping. Retain the companion's existing
  layout independently of the expanded game dimensions.
- Trace the camera and draw additional base scenery around one representative
  outdoor scene in both axes. Preserve the original game image and its existing
  actors/UI in the correct position; offscreen actor preparation is deferred.
- Load a private local screenstate through the existing import path for repeatable
  comparisons. Keep all screenstates and diagnostic images outside tracked paths.
- Verify geometry with synthetic inputs, compare the original background area
  against vanilla, and test scrolling across tile/sector boundaries at each preset.
  Record initial desktop frame-time measurements and known visual limitations.
- Add concrete desktop launch commands and Run/Pass-if rows to
  [human-verify.md](human-verify.md) when the prototype is runnable. Agent checks
  are headless and muted; desktop window launches are for manual testing.

The first usable milestone is a configurable outdoor view that reveals additional
terrain in every direction while ordinary movement and the companion still work.
It does not claim complete scene rendering: newly visible actors, room boundaries,
transitions, special effects, expanded battles and UI redesign remain later layers.
Scenes outside the verified prototype coverage may remain visibly unpolished;
document their behavior without presenting them as supported coverage.

### Desktop launch and transport

Build mono-retro's `monofuel/expanded-viewport` branch with its normal
`make player-desktop` environment. From decompbound, the manual test is:

```sh
make libretro-viewport-play \
  STATE="$HOME/Pictures/Screenshots/earthbound_20260818-021632.png" \
  VIEWPORT=336x256
```

Select `VIEWPORT=256x224`, `320x240`, `336x256`, `448x252` or `512x384` to
compare presets. Custom dimensions use the same syntax, for example `257x225`.
`VIEWPORT_SCALE=2` fixes the game scale for comparison; `auto` is the default.
The target uses normal audio, disables achievements and uses a separate ignored
`bin/libretro/earthbound-viewport-saves/` directory. Add
`MONO_RETRO_ARGS=--mute` to request silence. Automated checks must explicitly
select mute/null audio; agents must not launch desktop windows.

The player arguments are `--earthbound-ds --earthbound-viewport:WIDTHxHEIGHT`
and optional `--earthbound-scale:auto|N`. Core options
`decompbound_viewport_width` and `decompbound_viewport_height` accept decimal
integers in 256–1024 and 224–1024 respectively, with every accepted value
advertised through libretro's existing option interface. These allocation limits
do not depend on the handheld's physical display. Changes take effect on reload.

For a game viewport `W×H`, the dual-screen frame is `W×(H+224)`, with pitch
`W*4`. The Game crop is `(0,0,W,H)`; the Party crop is
`((W-256) div 2,H,256,224)`. Remaining pixels are opaque black. Pointer input is
normalized against this full frame, then translated to the companion's original
coordinate space by the core. The default remains exactly 256×448. Single-screen
frontends can select core dimensions directly and receive just the game viewport.

Headless reproduction:

```sh
make libretro-viewport-test \
  STATE="$HOME/Pictures/Screenshots/earthbound_20260818-021632.png"
```

## Implementation layers and staged verification

Solve and document the layers below incrementally. Stage 1 has headless coverage;
Stage 2 is partial, with Winters base scenery covered. Later rendering layers are
planned. A working earlier stage remains available while later stages are incomplete. Completion
applies to the recorded scenes and dimensions, not automatically the whole game.

For each stage, replace its findings placeholder with the hypothesis, routine
addresses/field contracts, implementation links, reproduction commands, observed
results and remaining gaps. Track status as planned, in progress, partial or
verified for the stated coverage. Keep horizontal and vertical coverage explicit,
and distinguish automated evidence from human confirmation. Link canonical
subsystem research instead of copying its findings into this document.

Increasing framebuffer dimensions alone cannot reveal a correct live scene.
The original game prepares graphics for its original view; the extension must
obtain scenery and objects outside those limits. Vertical expansion has the
same general requirement as horizontal expansion, with its own camera and
scrolling boundaries to investigate.

### Stage 1 — Configuration, geometry and presentation

The core validates dimensions using [viewport_geometry.nim](../src/decompbound/viewport_geometry.nim).
Mono-retro's `playergeometry` module describes the unequal crops used by its
splitter, pointer and overlay paths. The companion stays 256×224.

**Completion check:** every suggested preset and representative custom dimensions
can be selected on reload; synthetic images verify crop boundaries, centering,
integer scale and pointer mapping. Invalid sizes/scales fail clearly. The original
mode still works. This establishes transport, not correct expanded game scenery.

**Findings and remaining gaps:** headless geometry, pixel transport, pointer,
legacy DS and overlay tests pass. Default dimensions need only the original
companion option, preserving the updated player's compatibility with older cores.
Explicit game scaling works with X11 GPU or CPU presentation; native forced-scale
experiments still use CPU. Resizing below the requested scale raises a clear error.
Mono-retro's X11 default now uploads native-size textures and uses GPU nearest
scaling with double-buffered GLX vsync. Build against the updated Windy checkout
(`MONO_RETRO_WINDY=../windy-gpu-player` in the current shared workspace).
The GPU/CPU Xvfb suites passed colour readback, separate windows, resizing, input,
state drops and a paced 180-frame real-core run at 336x256 with null audio.
Physical vsync cannot be tested under Xvfb. Monofuel confirms basic desktop play;
the full matrix, desktop tearing retest and native device testing remain open.

### Stage 2 — Camera and base scenery

Start with one scrolling outdoor scene. Derive live world coordinates and trace
map streaming across both axes. The [Pocket Atlas](world-map.md) provides decoded
base scenery and verified story-dependent palette/arrangement substitutions;
determine how to use that foundation with the live scene. Use configurable
dimensions from the outset, with 336×256 as the first comparison size.

**Completion check:** the original 256×224 background area matches a vanilla
reference for the chosen scene and frame, with extra scenery aligned on all four
sides. Scrolling across tile/sector boundaries produces no seams or stale tiles
at each preset. Actor and effect coverage remain separate claims.

**Findings and remaining gaps:** the renderer is
[expanded_viewport.nim](../src/decompbound/expanded_viewport.nim). The reference
screenstate has logical tileset 13, drawing resource 17, and Winters lighting
flag `$011F` set. The ROM identifies this logical family through its palette-0
condition; it occupies 94 atlas sectors. This identifies the family, not a claim
that all 94 sectors have been tested.

Original scroll publication matters for frame alignment:

| Mechanism | Evidence and contract |
|---|---|
| Working camera | `$0031/$0033` can already describe a later frame. |
| Publication | `$C08B26`, file `0x008B26`, snapshots scroll into two lanes: H at `$0041/$0043`, V at `$0045/$0047`. |
| Display consumption | `$C08278`, file `0x008278`, applies one lane to PPU scroll ports. See [graphics.md](graphics.md#published-buffer-transfer-and-scroll-snapshots). |
| Prototype selection | At the end of visible rendering, select the published full-coordinate pair whose low ten bits match latched BG1 scroll. Missing or ambiguous matches use padding. |

In the reference's first visible frame, the working pair is `(131,4793)`, but
latched scroll is `(130,696)` and the displayed full-coordinate pair is
`(130,4792)`. Using the working pair shifted the extension by one pixel. The
independent PPU background comparison caught this; checking only the copied
center or comparing two atlas renders would not.

Capture runs after the original sprites/foreground and before NMI. It copies
active CHR from VRAM, arrangements from `$7F8000`, and CGRAM into owned presentation
storage. The restored reference has 227 CHR bytes different from ROM-decoded CHR,
so ROM defaults alone are insufficient. Relevant map event bits are read from
`$9C08` using the existing one-based flag codec. No game state is written.

Original strip loaders `$C00B82/$C00C92` reject neighboring logical families;
the extension uses the same family boundary and black outside the atlas.
Eligibility is conservative: Winters family, matching camera region, mode 1,
full brightness, expected CHR bases, tilemap registers `$39/$59` (64×32 maps at
VRAM word bases `$3800/$5800`), equal BG1/BG2 scroll, both scenery layers enabled, and no mosaic,
windows, color math, subscreen or HDMA. Other scenes use the original center on
black. Coverage beyond the documented Winters route and lighting state is unverified.

`tests/integration_expanded_viewport.nim` compares every original background
pixel with a separate PPU snapshot, in addition to preserving the complete game
image. Its 480-frame route crosses both tile and sector boundaries on each axis
at 320×240, 336×256, 448×252, 512×384 and odd custom 257×225. All 2,400 frames
extend successfully and preserve PCM and complete serialized machine/CPU state.
Forced blank, battle-mode, independent BG scrolling, changed tilemap-base and
ambiguous-camera fixtures clear the added scenery.
Temporary investigation/preview probes are retired into these retained checks
and the evidence above; no captured pixels or states are tracked.

### Stage 3 — Characters, objects and gameplay isolation

Separate placement, visibility/culling and graphics uploads from gameplay
activation. Draw offscreen actors where resources and scene state support them,
without activating enemies earlier or changing scripts, collisions or RNG.

**Completion check:** representative actors cross all extended edges with correct
position, animation and ordering. Identical input replays from the same initial
state preserve relevant game-memory, RNG and event behavior against vanilla.
Any unavailable actor resources or unverified activation rules remain explicit.

**Findings and remaining gaps:** the prototype preserves original actors only.
Its 2,400-frame differential route proves presentation isolation, including CPU,
memory and PCM; preparation and rendering of new offscreen actors remain planned.

### Stage 4 — Room boundaries and transitions

Determine valid room bounds, camera locks and black exterior regions. Prevent
unrelated neighboring atlas rooms from appearing. Investigate doors, scrolling
transitions, fades, teleports and cutscene camera movement.

**Completion check:** selected small/large interiors and outdoor transitions keep
valid framing at every preset, with no unrelated rooms or stale previous-scene
pixels exposed. Record which room and transition types have actually been tested.

**Findings and remaining gaps:** unsupported scene configurations use black
padding with the original image intact. Synthetic transition/battle-mode checks
verify that old terrain clears; full room-boundary and transition expansion remain
planned. Private `earthbound_20260818-022023.png` takes the `padded color-math`
path, with exposed memory and PCM hashes matching the original viewport.

### Stage 5 — Composition, animation and special effects

Preserve tile priority, object occlusion, animated tiles, palette changes,
scrolling layers and scanline effects in both the original and extended areas.
The unresolved [Deep Darkness masking investigation](world-map.md#deep-darkness-investigation)
remains relevant; do not substitute a guessed extension mask for missing evidence.

**Completion check:** representative effects agree with vanilla in the original
area and cover the expanded area consistently. Record coverage per effect and
story state; ordinary outdoor scenery passing does not verify these effects.

**Findings and remaining gaps:** live CHR, arrangements and palette snapshots are
covered by the Winters background comparison. Special effects are conservatively
excluded from expansion; this does not resolve the independent Deep Darkness bug.

### Stage 6 — Original UI and battle presentation

Decide how dialogue, menus, battle backgrounds and battle effects occupy a larger
panel while preserving the working companion. World-camera expansion does not
automatically extend battle scenes or relocate the original UI correctly.
Centering the original presentation with black padding can be an initial policy
for scenes that are not extended; document that policy explicitly.

**Completion check:** dialogue, menus and battles remain readable and usable at
every preset, companion input stays aligned, and scene changes obey the documented
presentation policy. Distinguish intentionally padded scenes from fully expanded
ones rather than counting both as completed expansion.

**Findings and remaining gaps:** original UI/battle pixels remain centered and the
companion is unchanged. ABI tests cover both transports, companion pixels and
state imports; frontend synthetic tests cover overlay crops and input mapping.
UI relocation and expanded battle backgrounds remain pending. Basic desktop play
is confirmed; the full UI/input matrix is not independently confirmed.

### Stage 7 — Device performance and coverage

Measure performance from the first runnable stage and repeat after meaningful
rendering changes; this stage consolidates those results rather than postponing
profiling. Compare presets on the RG DS Plus, keeping core work separate from
frontend scaling. Record representative custom-size checks for future devices.

**Completion check:** a coverage table records dimensions, scenes, visual gaps,
mean and tail frame times, build settings and test device. Default selection is
based on measured results; slower or unpolished presets remain selectable for
experimentation. Link profiling evidence to [libretro-performance.md](libretro-performance.md).

**Findings and remaining gaps:** [desktop measurements](libretro-performance.md#measured-desktop-expanded-viewport-prototype)
cover idle/walking at every suggested preset. Walking CPU mean rises from
0.844 ms at 256×224 to 1.536 ms at 336×256 and 3.719 ms at 512×384 on the
Ryzen 9 7950X. The unmodified default also passes the 3,480-capture × three-frame
reference corpus. Basic desktop play is confirmed; handheld timing and a tearing
fix remain pending. See [the presentation issue](issues.md#open-not-yet-assigned).

Later stages remain future work. Derive engine claims from our own traces and
tooling; external projects are references, not evidence for EarthBound's behavior
or sources of code/assets.

## Related work

- [Phase Distorter](https://github.com/TheRunaway5/Phase-Distorter) documents
  EarthBound widescreen support and preparation of offscreen objects separately
  from their original gameplay activation. It is a useful comparison for the
  EarthBound-specific problem, not an implementation dependency.
- [Zelda3](https://github.com/snesrev/zelda3) lists a 240-line vertical mode
  among the enhancements in its reverse-engineered native implementation.
- [ActRaiser recompilation](https://github.com/DerrickGold/ar-recomp) documents
  taller windows revealing additional rows in supported scenes, including
  extension above and below the original 224-line action-stage view.

These demonstrate that vertical expansion has precedents. They do not establish
that an arbitrary SNES game can support it through a generic resolution switch.

## Verification rules across stages

Preserve the existing mode as a baseline. Exercise every listed preset and
representative custom dimensions, including non-tile-aligned heights, with both
automatic scaling and explicit scale selection. Keep visual coverage and
performance separate so selectable experimental sizes are not mistaken for
fully polished modes. Put concrete visual checks in
[human-verify.md](human-verify.md) when a runnable prototype exists. Automated
checks must remain muted; audible runs require immediate permission.
