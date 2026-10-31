# Pocket Backgrounds and the battle-background format

Pocket Backgrounds is a music-free Nim companion to [Pocket Jukebox](jukebox.md).
It browses enemies in ROM record order and previews the backgrounds of encounters
that actually spawn them. Controls and artwork have separate resizable windows.

```sh
make battle-bg-app
make battle-bg-app ARGS="--enemy:2 --variant:1"
make battle-bg-build                 # Build only; no desktop windows.
```

Use the normal development shell (`nix develop` on this machine). `ROM=...`
selects a user-supplied 3 MiB US ROM, with or without a 512-byte copier header.
The application reads/decompresses its graphics at runtime. No game assets,
frames, states, audio, or enemy-name database ship in the repository.

## Windows and controls

The controls start at 800×600 and share the jukebox's cream/navy/pink theme.
The second window starts at 768×672 and contains only the animated 256×224
background: no controls, enemy sprite, battle UI or letterbox. Preview scaling
uses the smallest integer scale that covers the framebuffer, with nearest
sampling and centered cropping. Resizing to a different aspect ratio therefore
crops artwork instead of stretching it or adding bars.

Closing the preview keeps the controls alive. **P** or **show preview** reopens
it at the current animation time. Closing the controls or pressing Escape exits
both. Playback continues when both windows lose focus; input is accepted while
either is focused. Run the jukebox alongside it for music.

| Action | Keyboard | Paddy |
|---|---|---|
| Enemy / page | Up, Down / PageUp, PageDown; Home, End | D-pad Up/Down or left stick / L2, R2 |
| Encounter background variant | Left, Right | L1, R1 |
| Pause / resume | Space | Start |
| Restart and play | Enter | Bottom face button (A) |
| Reset, preserving pause | R | Right face button (B) |
| Step one frame when paused | Period | Left face button (X) |
| Speed: 0.25×, 0.5×, 1×, 2× | Minus, Plus/Equal | D-pad Left, Right |
| Preview fullscreen | F11 | Top face button (Y); also reopens a closed preview |
| Reopen / focus preview | P | Y |
| Exit | Escape | Select + Start |

Mouse selection, wheel browsing, page buttons and all transport controls live in
the controls window. Selecting another enemy or variant resets to frame zero;
pause and speed are retained. Transport buttons are edge-triggered; held enemy
navigation repeats after a delay.

## What identifies a background

An enemy record does **not** contain a unique background id. The catalog walks:

`enemy ← positively spawned battle-group member → ordered (layer A, layer B)`

The headerless US ROM has **484 groups**, **327 layer records** (zero means no
layer), and the existing enemy-name decoder's **230-record window** (ids 1–230).
That enemy bound is a named-record window, not a proven expander clamp. All
positively spawned ids in the audited group lists fit it (maximum 229).

The current sweep finds **174 mapped enemies**, **56 unmapped rows**, and **454
per-enemy variants**. There are 704 distinct enemy/group associations. Twenty-four
member records have spawn count zero and are excluded; notably they do not turn
ids 34 and 83 into spawned enemies. Unmapped rows remain selectable. Groups
0, 425, 473 and 481 legitimately select `(0,0)`; group 0 still maps enemy 159.
An empty pair is different from a missing mapping.

Variants deduplicate only identical **ordered A/B plus letterbox class**; source
group ids are retained and sorted. Variants follow their first group id. Thus
an enemy with several encounter presets remains browsable without collapsing
reversed layers or different encounter framing. The unmasked preview does not
apply that framing, but it remains part of variant identity.

## Verified ROM layout

All offsets below are **headerless file offsets**. Older versions of this document
and the old exporter mixed copier-header offsets into SNES addresses (+`0x200`);
those claims are superseded here.

| Table | File offset | Shape / meaning |
|---|---|---|
| Enemy records | `0x159589` | `0x5E` bytes; names through `battle_formation.decodeEnemyName` |
| Battle groups | `0x10C60D` | 484 × 8 bytes; +0 u24 member pointer, +7 flags |
| Member lists | `0x10D52D..0x10DFB4` | Repeated u8 spawn count + u16 enemy id; `FF` terminator |
| Group background pair | `0x0BD89A` | 484 × (u16 A, u16 B) |
| Compressed CHR pointers | `0x0AD7A1` | 103 × 4-byte far-pointer entries |
| Compressed arrangement pointers | `0x0AD93D` | 103 × 4-byte far-pointer entries |
| Palette pointers | `0x0ADAD9` | 114 × 4-byte entries; each points to 16 raw BGR555 colors |
| Layer records | `0x0ADCA1` | 327 × 17 bytes |
| Scroll programs | `0x0AF258` | 120 × 10 bytes |
| Distortion programs | `0x0AF708` | 135 × 17 bytes |
| Signed sine samples | `0x00B425` | 256 bytes; read from the ROM, never embedded |

The group span ends exactly at the member-list base; layer span ends exactly at
the scroll base. The pair consumer at `$C2489D` (file `0x02489D`) loads
`$CB:D89A`, indexes `group*4`, and reads both words at `$C248BB/$C248C8`.
The layer loader at `$C2D1CF` indexes `$CA:DCA1` by `layer*17`. Group bounds also
have the `CMP #$01E3` sites `$C2C309/$C2C236`. The expander at `$C1E3CF` reaches
its countdown before appending a member, so a zero count appends nobody.
Letterbox selection is `group+7 & 3` at `$C2D148`; the in-battle vertical ranges
are 0/224, 47/176, 57/166, and 67/156 (`$ADB2/$ADB4`).

Layer bytes: +0 graphics/arrangement index, +1 palette index, +2 bpp (2 or 4),
+3 palette-cycle type, +4/+5 first inclusive range, +6/+7 second range, +8 speed,
+9..12 four scroll slots, +13..16 four distortion slots. Arrangements decode to
exactly 2048 bytes (32×32 u16 tile attributes). All 103 audited arrangements have
palette-selector bits zero; maximum tile index is 441. All 326 nonzero layers
fit their decoded CHR. Nonzero palette selectors are rejected explicitly rather than ignored.
The loader rejects truncated streams/tables, invalid
indices, unsupported bpp, and malformed catalog member lists.

Scroll entries contain duration u16, followed by signed h/v velocity and h/v
acceleration words. The original update `$C2CBB9..$C2CCEC` adds acceleration to
velocity **before** adding velocity to position, wrapping at 16 bits. Startup
slot=0/counter=1 advances before loading; slot 1 is first if nonzero, otherwise
slot 0. A zero next index returns to slot 0; a zero duration holds indefinitely.
The decoder resolves this slot order. Rendering integrates segments in bounded
time using modular arithmetic, without replaying every earlier frame.

Distortion entries: +0 duration u16, +2 kind u8, +3 frequency u16, +5 amplitude
u16, **+7 initial angle u8**, **+8 compression u16**, +10 frequency acceleration
s16, +12 amplitude acceleration s16, **+14 speed u8**, +15 compression
acceleration s16. The old packing was one byte off. `$C2CF29..$C2CFDF` updates
frequency/amplitude/compression modulo 65536 and angle modulo 256 before
rendering. It passes only the **high byte** of amplitude to `$C0AE5A`.

The four kinds generate horizontal, alternating horizontal, vertical, and
alternating vertical scroll-register words. Signed wave displacement is
`(amplitudeHighByte * sine[angleIndex]) >> 8`. Horizontal phase includes vertical
scroll; vertical phase does not. Compression advances its 8.8 accumulator
**before** each vertical scanline. The engine's kind is record kind minus one.

Live-driver routing differs from those generator equations: `$C2CF02` selects
VOFS only for record kind 3; kind 4's vertical accumulator is published to HOFS.
The expanded live viewport observes and verifies that actual axis. The standalone
preset preview still applies kind 4 to vertical sampling; correcting that mapping
and adding a whole-driver routing oracle remain follow-up work. The existing
original-CPU generator oracle alone does not verify this routing step.

Palette update `$C2C94F..$C2CBA2` first writes phase zero, then advances phase;
subsequent writes occur every speed ticks. Speed zero freezes after that first
write. Types 1 and 2 copy backwards through one or two inclusive ranges. Type 3
is a mirrored traversal over `2*rangeLength`, including repeated endpoints;
it is not a rotated palette with a ping-pong shift. Render calls do not mutate
decoded palettes, so restart and random access are deterministic.

## Composition, coverage, and open research

All **52 two-layer catalog groups** use two 2bpp layers. Original loader execution
for group 39 takes `$C2D714`: A is main-screen BG3, B is subscreen BG4, mode 0,
preset 3 (`CGWSEL=02`, `CGADSUB=64`; `$C2D899..$C2D8A8`). Separate palettes are
staged for CGRAM indices 64 and 96. B's transparent index zero uses black fixed
color and disables halving; an opaque B half-adds with A or the backdrop.
`$C2E9ED → $C0B01A` clears the fixed color. The distinct 4bpp path uses BG1/BG2
and optional preset 7; it is not the path taken by those 52 groups.

The standalone preview deliberately uses a **black backdrop**, omits battle
letterboxing/UI and starts the preset's local clock at zero. The loader leaves
CGRAM entry zero inherited from its caller, so this is a defined preview choice,
not a claim of pixel identity with every captured battle. Frame 1 represents
one original update; frame 0 exposes the initial parameters. All ordinary layer
programs are supported, but a passing sweep does not establish every whole-battle
frame or special script effect as faithful.

Scripted phases are **not yet catalog variants**. Independently located overrides:

- Group **478 (`01DE`)** takes larger VRAM uploads at `$C2D205`, using `$5C00/$5000`
  and size `$3000`. Its ordinary decoded pair is a preset preview; the special
  arrangement/upload behavior still needs a dedicated whole-scene comparison.
- `$C4AD34` explicitly loads pair **228+229** with Y=4; `$C473A1` also calls the
  loader with Y=4. Their enemy/phase reachability is not yet established.
- `$C426ED..$C42796` applies an 8.8 RGB palette ramp and requests CGRAM DMA index
  `$18`. It is separate from the ordinary palette-cycle driver.

Do not invent boss-phase names or attach script-only pairs to enemies without
proving their call context. Next research is to trace those callers, identify
phase transitions and the inherited backdrop, and compare whole-scene output
with live PPU frames. `src/probes/probe_background_composition.nim` remains a
reproducible loader/PPU investigation for these open questions; it accepts a
group id and optional second-layer/flags overrides. Closed palette, scroll and
distortion experiments graduated into the integration suite below.

The dependency lock uses monofuel's Windy fork at `0c34bd7`. Its X11 event
predicate and `XCheckIfEvent` use C `int` rather than Nim `bool`; the old ABI
could route preview events to the controls window in release builds. The real
two-window lifecycle check is a regression test for that fix.

## Verification and export

```sh
make battle-bg-test
make battle-bg-window-test
nim r src/probes/probe_background_composition.nim 39
make battle-bg BG=39 FRAMES=30
make compare
```

`battle-bg-test` runs ROM-independent synthetic catalog, input/clock/hit-testing,
scroll, palette, tile-flip, transparency and crop checks, then the required-ROM
integration sweep (missing ROM is an error). It renders every group at frames
0/15/30 and every nonzero layer at 0/1/15/30/180/1000000001, checks deterministic
random access, checks decode/encode/decode for all 103 CHR and arrangement
resources, and executes the original palette/scroll/distortion CPU routines
against independent synthetic oracles and production palette/scroll/distortion output.
The greedy codec's semantic round trips are not a claim of original compressed-byte
identity. A synthetic PPU comparison independently checks the renderer's four transparency
combinations. Distortion multi-record reload currently has disassembly evidence;
its original-CPU oracle covers scanline equations and per-frame wrapping.

The isolated Xvfb suite exercises real input through both windows, resized mouse
coordinates, animation without focus, preview close/reopen and controls-window
shutdown. A separate two-context GL check reads framebuffer pixels and verifies
integer nearest crop using authored colors. It never opens the user's desktop.
Physical controller hotplug/fullscreen/visual feel remain in
[human verification](human-verify.md).

The headless exporter now uses the same renderer and outputs local frames to
ignored `bin/battle_bg/bg_NNN/`. `make battle-bg BG=N FRAMES=N ROM=...` preserves
its existing entry point. Do not commit exported images or ROM-derived data.
