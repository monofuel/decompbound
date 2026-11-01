# Audio

Goal 5 in [GOAL.md](../GOAL.md) is to explain the path from game commands to
SPC700 driver execution, sequences, instruments, samples, and DSP output.
The emulator already has SPC700/APU/DSP playback. Working audio is evidence
about playback, not proof that the uploaded driver or sequence language is
understood.

## Existing tools and evidence

- `src/decompbound/spc700.nim`, `apu.nim`, and `dsp.nim` implement the audio
  machine. `tests/integration_spc700.nim` exercises CPU vectors;
  `tests/integration_apu_upload_starvation.nim` exercises full-game boot/upload.
- `src/decompbound/music_player.nim` validates the song/package tables and loads
  packages into a fresh APU. It is shared by both standalone music tools.
- `src/tools/sound_explore.nim` uses that engine and
  renders a WAV under ignored `bin/` or another explicitly selected local path.
- `src/tools/jukebox_app.nim` provides [Pocket Jukebox](jukebox.md), a mouse,
  keyboard and Paddy GUI for that standalone loading path.
  Its numeric song list is not a verified soundtrack identity catalog.
- `src/probes/songstart_dig.nim` compares package targets and driver state for
  two songs, including the deliberately incomplete case without package 1.
  Run `nim r src/probes/songstart_dig.nim --a:1 --b:3`.
- [Music](music.md) tracks standalone playback gaps; [DSP research](sfx.md)
  covers synthesis behavior. Human listening checks belong in
  [human-verify.md](human-verify.md).

Direct package loading does not execute the S-CPU/IPL handshake or reproduce
all resident-state/cache behavior of a song change during play. The standalone
tools share a parser that rejects truncated packages and out-of-range references
and APU destinations. Direct loading still does not establish every runtime
upload boundary or resident-state contract.

## Song selection and resident packages

The song table at file `$04F70A..04F946` has 191 three-byte rows, indexed
`(songId - 1) * 3`. Each byte is a package index or `$FF` for an unused slot.
The adjacent pointer table `$04F947..04FB41` has 169 entries, each three bytes
in **bank, address-low, address-high** order. Local inspection finds all 169
indices referenced by the song table, with maximum index 168. These are table
extents, not runtime bounds checks: the loader does not validate IDs this way.

`$C4FB58` initializes resident audio data using the first song's third package
index, seeds caches `$B543/$B53F`, and uploads it at `$C4FBB1`. The checked ROM
selects package 1 here.

`$C4FBBD` handles later song selection:

- Matching current song `$B53B` returns without reloading.
- The three package slots compare against caches `$B53D/$B53F/$B541`.
- `$FF` entries and matching cached indices skip uploading. Slot 1 also skips
  when its index matches alternate cache `$B543`.
- Changed packages go through `$C0AB06`; the tail sends the song command to
  APU port 0 through `$C0ABBD`.

Thus a song change does **not** imply reuploading the driver or all three
packages. Shared resident data is part of the playback contract. The exact
roles of `$B4B6` and special song IDs `$A0..A7` remain open; the latter skip
the ordinary stop handshake. See `asm/loadSong.asm` and the port helpers.

## Package format and upload protocol

At `$C0AB06`, A supplies the package address and X its bank. The streamer uses
the four S-CPU APU ports `$2140..2143`, disables NMI during transfer, and walks:

```
u16 length
if length != 0:
    u16 destination
    length payload bytes
    repeat
else:
    finish; execute at APU $0500
```

The terminator is **two bytes**, the zero length alone. At `$C0AB62..AB73`,
the zero branch substitutes `$0500` without consuming a destination word.
Bytes following that terminator must not be interpreted as an entrypoint.
For nonempty blocks, destination and payload follow the length. `$C0AB78`
tests `length >= 1` to form the transfer flag, not `length == 1`.
The final path forces NMI enabled; it does not restore a saved enable bit.
These are S-CPU disassembly findings, independently checked against the local
ROM. They do not yet establish all package boundary/cross-bank corner cases.

## Bootstrap provenance

Package 1 starts at file `$260000`. Its block header at `$26003E` describes
16,779 bytes destined for APU `$0500`; payload begins at `$260042`. The bootstrap
is part of this ROM package, not something deposited by the IPL protocol.

Standalone players prepend package 1 when a song omits it, because a fresh APU
has no resident driver. Inspection of all 191 song-table rows with that loading
policy confirms that the first 32 entry bytes remain those from `$260042`.
The tools therefore use the user's ROM directly; no captured bootstrap byte
array is needed or retained in source.

Verification of that cleanup included a one-second song-1 render whose WAV
was byte-identical before and after removal, and the song-start probe for songs
1 and 3. Both complete loading paths produced nonzero audio and a running SPC;
the intentional song-3 case without package 1 still halted. This does not prove
all 191 songs sound correct or that their sequences are fully decoded.

## Reproduced SPC700 source

The fixed-layout build now assembles sixteen annotated `.spc.asm` files with our
Nim SPC700 assembler. They reproduce **488 executable bytes** in package 1.
The upload block header at file `$26003E` declares 16,779 bytes from file
`$260042` to APU `$0500`; therefore `file = apuAddress + $25FB42` within it.
Each source's `.org` is its APU execution address, not a ROM padding request.

| Source | APU range | File range | Bytes |
|---|---|---|---:|
| `spcInitializeDriverRam.spc.asm` | `$0500..050B` | `$260042..26004D` | 12 |
| `spcAdvancePhase.spc.asm` | `$05CD..05D7` | `$26010F..260119` | 11 |
| `spcPitchScale.spc.asm` | `$070E..0732` | `$260250..260274` | 37 |
| `spcWritePitch.spc.asm` | `$0733..0740` | `$260275..260282` | 14 |
| `spcWriteDsp.spc.asm` | `$0741..074F` | `$260283..260291` | 15 |
| `spcDispatchCommand.spc.asm` | `$0943..0954` | `$260485..260496` | 18 |
| `spcSequenceFetch.spc.asm` | `$0955..095E` | `$260497..2604A0` | 10 |
| `spcSelectInstrument.spc.asm` | `$095F..09B7` | `$2604A1..2604F9` | 89 |
| `spcSetPan.spc.asm` | `$09B8..09D5` | `$2604FA..260517` | 30 |
| `spcSetPanTransition.spc.asm` | `$09D6..09FC` | `$260518..26053E` | 39 |
| `spcDivideStep.spc.asm` | `$0BC7..0BE2` | `$260709..260724` | 28 |
| `spcTickPanTransition.spc.asm` | `$0C79..0C8B` | `$2607BB..2607CD` | 19 |
| `spcWriteStereo.spc.asm` | `$0C8C..0CD2` | `$2607CE..260814` | 71 |
| `spcApplyPanStep.spc.asm` | `$0CD3..0CF6` | `$260815..260838` | 36 |
| `spcPreviewPan.spc.asm` | `$0DDF..0DFB` | `$260921..26093D` | 29 |
| `spcScaleSignedStep.spc.asm` | `$0E2B..0E48` | `$26096D..26098A` | 30 |

The pitch scale and pitch writer share fall-through tails; the stereo writer
also exposes scratch-coordinate entry `$0C95`. Their contracts are kept next
to those entries. The E2 tick prelude ends at `$0C8B`: `$0C8A` is the opcode
of a two-byte branch, so stopping there would split an instruction. The division
region also owns callable conditional-negation entry `$0BD9`; its contract is
documented beside that entry.

`nim r tests/test_spc_asm.nim` checks all 256 opcode encodings against independent
literal synthetic fixtures, plus operand order, origins, labels, signed branch
limits/wrap, bit packing and rejection of invalid or oversized operands.
`nim r tests/integration_rom_pipeline.nim` independently checks SPC label origin
versus ROM placement in a mixed 65816/SPC build, exact-length rejection and the
whole-ROM gold rebuild. Source adoption compared every one of the 488 bytes
at the file offsets above; the completed carving probe was retired afterward.

The sequence-fetch, pitch-scale, pan, pan-transition, arithmetic and phase tests execute
both original and freshly rebuilt driver images, checking mathematical results,
state effects and ordered DSP-port writes. No audio output is needed for those
gates. Remaining code, curves, instruments, songs and effects still enter the
build through the user's local extraction; reproducing these routines does not
claim full driver understanding, musical correctness or complete audio timing.

## Driver initialization and phase generation

The bootstrap at APU `$0500..050B` selects direct page zero, resets hardware
SP to `$CF`, and clears exactly `$0000..00DF` using `(X)+` until X reaches `$E0`.
It establishes the zero word at `$0E/$0F` and phase byte `$51` even from dirty
RAM with PSW page one. `$00E0..00FF` and page one remain untouched by this block;
initialization continues at `$050C`, outside the adopted fragment.

At `$0579` (file `$2600BB`) the driver reads timer-0 counter `$00FD`. Zero
keeps it polling; `$057E` pushes the nonzero count. A separate `count*32`
accumulator at `$0581..0587` may run service calls before the saved byte is
recovered at `$05CF`. The adopted phase fragment starts at `$05CD`:

```
product = savedTimerCount * byte[$53]
sum = oldPhase + (product & 255)
phase[$51] = sum & 255
```

Only the low product participates in ADC and its carry. Y retains the product's
high byte, but it does not affect routing. Carry falls through at `$05D8` to
calls `$07F9` and `$0625`; no carry branches to `$05E0`, where active byte `$04`
permits channel preview through `$0DD0`. The timer target and `$53` are initially
set to `$10` at `$0535..053A`; `$07E0` also writes `$20` to `$53`. Complete tempo
command semantics, the earlier service path and absolute scheduling rate remain
open. `$51` is a fractional accumulator, not a wall-clock sample counter.

`nim r tests/integration_spc_phase.nim` runs **2,102,264 cases** across original
and rebuilt images: all dirty RAM/status byte seeds,
every four-bit timer-count/tempo/phase combination, larger authored counts that
distinguish low-product carry, and every hardware stack pointer. It injects the
pending timer byte and stops at the branch exits; it does not claim coverage of
the polling loop, service calls or `$04` gate. The retained sequence trace below
also checks phase arithmetic and branch routing during actual silent song-3
driver execution using the shared product package loader.

## Verified SPC700 sequence fetch and dispatch

Package 1 maps its large payload to APU `$0500`, so addresses in that block
map back to ROM as `file = apuAddress + $25FB42`.

| APU address | ROM file offset | Verified role |
|---|---|---|
| `$0955..095E` | `$260497..2604A0` | Advancing byte fetch through pointer `$30+X` |
| `$08C0` | `$260402` | Compare an event/command byte with `$E0` |
| `$0943` | `$260485` | Command handler dispatch and optional first-operand fetch |
| `$0D10/$0D19` | `$260852/$26085B` | Separate lookahead reads through `$14+Y` |

The advancing fetch returns the byte in A and Y, increments the pointer as a
16-bit word (including `$FFFF` to zero), and preserves X and status except N/Z.
X indexes the channel pointer pairs; the observed driver uses even offsets.
The instruction helper also honors the SPC direct-page flag, though the traced
song uses page zero.

The main path starts fetching at `$0882`. Zero takes termination/repeat
handling. A positive first byte becomes the field at `$0200+X`; optional
following prefix metadata uses `$6F80/$6F88` to populate `$0201+X/$0210+X`.
Bytes `$80..DF` reach the event path at `$08C9`; `$E0..FF` enter `$0943`.
Thus the older hypothesis that bytes below `$80` directly encode note pitch is
inconsistent with this execution path. Exact musical meanings still require
following the prefix and event consumers.

The command dispatcher doubles the byte with eight-bit wrap, reads a target
word using bases `$0B23/$0B24`, and pushes it for RET-based dispatch. Metadata
at `$0BC1 + (command & $7F)` determines whether it fetches the first operand.
If it does, A/Y carry that operand and the channel cursor advances once;
otherwise A/Y are zero and the cursor stays put. Individual handlers may read
more operands. Testing dispatch does not establish total command widths or
that every byte in `$E0..FF` denotes a valid command.

`nim r tests/integration_spc_sequence_fetch.nim` loads original and freshly rebuilt
driver code and executes each image with synthetic streams: 40,960 advancing
fetch cases (all byte values, eight channel offsets, both direct pages, carry,
and pointer boundaries), plus 2,560 dispatch cases stopping at handler entry.
The latter check target addresses, optional fetches, register results, and stack
balance without claiming to execute the handlers.

`nim r -d:debug src/probes/probe_spc_sequence_fetch.nim` reproduces the two-second song-3
investigation. It emits only read-site and dispatch metadata, not payload dumps.
The trace observes `$0955` reading sequence addresses and dispatches to twelve
command IDs, including `$E0->$095F`, `$E1->$09B8`, `$ED->$0A86`, and `$EF->$0AAC`.
Instrument-area reads occur at `$0986/$099D/$09AC/$09B2` into `$6E30..6E4D`.
The same run verifies **382** phase additions and update/preview branch routes,
along with **655** pitch multiplications. These are bounded live-trace counts,
not an absolute timer rate or an exhaustive song/command inventory.
The `$0D10/$0D19` path scans ahead and skips command operands using metadata;
those reads do not themselves advance the channel pointer at `$30+X`.

### Command E0: six-byte instrument records

The handler at APU `$095F..09B7` (file `$2604A1..2604F9`) consumes one
operand through dispatch and stores it at `$0211+X`. Operands below `$80`
select a record directly. High-bit operands instead select
`(operand - $CA + ram[$5F]) & $FF`. Multiplication at `$096D` and pointer
construction at `$096E..0975` produce `$6E00 + 6 * index`; the driver does
not validate whether that record is present in the uploaded package.
This contract uses direct page zero, as observed during playback; the scratch
addresses honor the SPC direct-page flag, while `$F2/$F3` writes are absolute.

If `ram[$1A] & ram[$47]` is nonzero, the branch at `$097B` returns without
reading the record or changing DSP/channel parameters. The operand store and
record-pointer calculation still happen. Otherwise, for X = twice the voice
number, the record has these consumers:

| Byte | Consumer |
|---|---|
| 0 | Voice DSP register `voice * $10 + 4` (sample number), with special high-bit handling below |
| 1 | Voice DSP register `voice * $10 + 5` (ADSR1) |
| 2 | Voice DSP register `voice * $10 + 6` (ADSR2) |
| 3 | Voice DSP register `voice * $10 + 7` (GAIN) |
| 4 | Pitch multiplier high byte at `$0221+X` |
| 5 | Pitch multiplier low byte at `$0220+X` |

The write loop at `$099D..09A9` writes register select `$F2` then data `$F3`
for each of the four registers. Their roles agree with the sample-directory
and envelope consumers in our DSP implementation. The final two bytes are
copied at `$09AC..09B6`; their pitch consumer is verified below.

When record byte 0 has bit 7 set, `$098A..0996` updates scratch/state
`$48 = ($48 & $20) | (byte0 & $1F)` and `$49 |= $47`, and writes zero to
the sample-number register. Otherwise `$0999` clears the `$47` bits in `$49`
and preserves `$48`. The later consumers of these global fields still need
tracing before assigning them stronger semantic names.

The integration test executes 24,576 E0 cases per image through dispatch and
handler code: every operand, eight voices, three remapping bases, both guard
outcomes, and both high-bit record branches. Synthetic records exercise the
exact ordered eight port writes, final channel fields, index wraparound,
cursor advancement and stack balance. The complete test file now runs 84,480
cases per image, **168,960** across original and rebuilt. This proves the handler
contract, not correctness of all uploaded instrument data or audible playback.

### Instrument pitch multiplier

APU `$070E..0732` (file `$260250..260274`) consumes the word at `$0220+X`
as an unsigned 8.8 pitch multiplier. Consequently, record bytes 4/5 are stored
high-byte first in the six-byte instrument record. Given input pitch P in
scratch `$14/$15` and multiplier M, the four byte multiplications and additions
produce scratch `$16/$17 = ((P * M) >> 8) & $FFFF`. A multiplier of `$0100`
is unity. Intermediate overflow wraps; this routine does not clamp pitch.

At `$0733..074F` (file `$260275..260291`), the driver selects voice registers
`voice * $10 + 2` and `+3` and writes the low and high result bytes through
`$F2/$F3`. The helper at `$0741` suppresses each write when `$47 & $1A` is
nonzero, while the arithmetic still completes. Our DSP pitch consumer uses
only the low 14 bits of these registers. Thus full 16-bit port output and the
pitch subsequently consumed by the DSP are distinct values.

`nim r tests/integration_spc_pitch_scale.nim` executes original and rebuilt
instructions from `$070E` with synthetic pitch/multiplier words and a normal
direct-page-zero contract. It verifies all 65,536 pitches against seven multipliers, plus twelve
boundary values for both words across eight voices and both write-guard states:
461,056 cases per image (**922,112** total), checking the product, ordered port
writes, X preservation, and stack balance. It does not verify the preceding
pitch-table interpolation.
The two-second song-3 probe independently checks 655 observed multiplications
against the same mathematical formula during driver playback.

### Command E1: verified channel-state assignment

The handler at APU `$09B8..09D5` (file `$2604FA..260517`) consumes exactly
one operand, fetched by the dispatcher. It stores the original operand in
scratch `$20`, then tests global byte `$0431`. If that byte is nonzero, the
effective value is decimal 10; otherwise it is the operand. With X equal to
the even channel offset, it writes:

| Destination | Value |
|---|---|
| `$0351+X` | Full effective value |
| `$0331+X` | Effective value masked to five bits |
| `$0330+X` | Zero |

The branch at `$09C0` selects the original operand when `$0431` is zero;
the stores at `$09C8/$09CD/$09D2` establish the three fields. This path makes
no DSP-register writes and fetches no additional operands. The downstream
consumer below establishes stereo positioning and phase controls. The reason
for the global override remains open.

The sequence-fetch integration test adds 16,384 full E1 executions per image through
dispatch: eight channel offsets, all 256 operands, four override values
(`0`, `1`, `128`, `255`), and two cursor boundaries. It checks return-stack
balance, one-byte cursor advancement, scratch preservation, all three fields,
and unchanged neighboring channel fields. Together with the fetch/dispatch
sweeps, these sweeps execute 59,904 cases per image before the E0 checks.

### E1 consumer: stereo position and phase

APU `$0C8C..0CD2` (file `$2607CE..260814`) consumes the E1 fields and writes
the voice's left/right volume registers. With X equal to an even channel
offset, define the 8.8 position `p = word[$0330+X]`, gain byte
`v = byte[$0321+X]`, and full control byte `f = byte[$0351+X]`. The lookup
curve T begins at APU `$0E73` (file `$2609B5`). For `0 <= p <= 20*256`:

```
i = p div 256
r = p mod 256
curve(p) = T[i] + floor((T[i+1] - T[i]) * r / 256)
left  = floor(v * curve(p) / 256)
right = floor(v * curve(20*256 - p) / 256)
```

Bit 7 of f negates the left result and bit 6 negates the right, modulo 256;
the resulting bytes go to DSP `VOLL` then `VOLR`. Bits 0–5 of f do not affect
this consumer independently of the position fields. E1 puts its low five bits
into the integer position and clears the fraction. Other writers can supply
fractional positions; those writers are not all explained here. The original
curve is monotonic through indexes 0–20 with endpoint values 0 and 127; its
contents remain local ROM data, not test fixtures or source constants.

Instruction evidence: `$0C8C/$0C90/$0C93` load the coordinate; `$0C9C..0CAA`
interpolates the curve; `$0CAE/$0CB1` applies gain; `$0CB2..0CBF` selects the
phase bit and conditionally negates. `$0CC5..0CCB` reflects the coordinate
around 20, and `$0CCD/$0CCF` advances to the right volume register. The guarded
writer at `$0741..074F` (file `$260283..260291`) writes ports `$F2` then `$F3`
only when `byte[$47] & byte[$1A] == 0`. `$47` is caller-supplied and is not
derived from X by this consumer.

Entry requires direct page zero, X even in 0..14 and a valid return stack.
RET preserves X and consumes one return address; A/Y/PSW and scratch `$10..12`
are clobbered. After both reflections scratch `$10/$11` again holds the
original coordinate and `$12` is voice*16+2. Enabled calls make four ordered
port writes; inhibited calls make none. The coordinate and control fields
remain unchanged.

`nim r tests/integration_spc_pan.nim` executes **2,658,624 consumer cases**
and **89,856 E1-through-dispatch-to-DSP cases** on original and rebuilt ROMs.
It checks an authored nonlinear curve, representative original-curve positions,
fractional interpolation, all 256 phase/control bytes, gains, all eight voices,
caller-mask independence, override behavior and cursor wrapping. It verifies
register/stack results and exact ordered DSP-port writes without speakers,
WAVs, captured RAM or extracted sequence fixtures. The exploratory probe was
retired after preserving its offsets and formula here.

Positions 21–31 accepted by E1's five-bit mask are **unchecked**, not clamped;
the formula above is not claimed for them. E2's `$09EE` target read and the
`$0DDF/$0DE3` preview path are explained below. The override's gameplay purpose,
the later position reader at `$157F`, and complete volume-envelope/mixing behavior
remain open. E1 and its stereo consumer have formally reproduced source in the
inventory above; that adoption does not extend the verified position bounds.

### E2: persistent pan transitions and sub-tick preview

Command E2 dispatches to APU `$09D6..09FC` (file `$260518..26053E`) and consumes
two bytes: duration d and target integer position. The target is stored at
`$0350+X` without E1's five-bit mask; nonzero `$0431` substitutes 10. Duration
goes to DP `$91+X`, and the computed step word goes to `$0340/$0341+X`.
Current position `$0330/$0331` and phase flags `$0351` are preserved.

The command ignores the current fractional position when calculating its step.
With `delta = targetByte - currentIntegerByte` (range −255..255), duration d>0
gives `step = sign(delta) * floor(abs(delta)*256/d)` modulo 65536. The sign is
the full unsigned subtraction borrow, not an eight-bit signed interpretation.
Helper `$0BC7..0BE2` (file `$260709..260724`) carries that sign through NOTC/ROR.
When d=0, the two SPC divisions yield signed magnitude `65535-abs(delta)`;
the zero counter nevertheless disables persistent updates. Entry requires
DP zero, even X in 0..14, **DP `$44` equal to X**, and the bootstrap's zero word
at **DP `$0E/$0F` equal to zero**. Division restores the channel offset from
`$44`. Its shared tail at `$0BD9` subtracts YA from the word at `$0E`; with a
nonzero word this is base-minus-quotient, not intrinsic two's-complement negation.

The persistent updater `$0C79..0C8B` (file `$2607BB..2607CD`) skips a zero
counter, otherwise decrements it and calls `$0CD3..0CF6`. That helper ORs caller
mask `$47` into dirty mask `$5E`. The OR instruction sets N/Z, so the later
branch at `$0CDD` uses this OR result, not the earlier duration decrement:

```
if (callerMask | oldDirtyMask) != 0:
    position = (position + step) mod 65536
else:
    position = target * 256
```

A normal nonzero channel mask therefore produces **no final-tick snap**. After
d steps, the position is `initialPosition + d*step` modulo 65536, retaining
division rounding residue and any initial fractional position. Dirty mask
`$47 & $5E` permits the existing stereo writer to run even after the counter
has reached zero. The original CALL at `$0939` into `$0C40` reaches this updater
once per enclosing channel-update invocation; an absolute tick rate is not
established here.

`nim r tests/integration_spc_step_apply.nim` checks **10,368 direct helper calls**
on original and rebuilt images. It covers both observed YA bases (`$0330` for
pan and `$0300` for the neighboring caller), all channels, word carry/wrap,
zero/nonzero dirty-mask combinations, incoming-Z independence, target snaps,
guarded neighboring arrays and stack/register effects. The pointer adjustment
changes only its low byte; arbitrary bases are not part of this contract. The
game-level role of the `$0300` array remains a separate question.

Sub-tick code `$0DDF..0DFB` (file `$260921..26093D`) and helper `$0E2B..0E48`
(file `$26096D..26098A`) calculate a preview using caller phase byte `$51`:
`preview = current + sign(signed16(step))*floor(abs(signed16(step))*phase/256)`
when duration remains. It marks DP `$13` bit 7 and invokes the pan writer
through `$0C95` using scratch coordinates, without modifying persistent
position or remaining duration. Both conditional-negation calls require the
same zero word. The preview fragment continues at `$0DFC`, rather than RET.

`nim r tests/integration_spc_arithmetic.nim` adds **1,205,488 direct helper cases**
across original and rebuilt drivers: every magnitude/divisor/sign combination,
every signed sixteen-bit step against seven phases, and boundary accumulation,
status, restored-X and nonzero subtraction-base checks. Assertions cover scratch
preservation, stack guards and absence of I/O. This proves the arithmetic helpers
over those domains without sending unsupported coordinates to the stereo curve.

`nim r tests/integration_spc_pan_transition.nim` verifies **56,448 command
cases**, **2,400 complete transitions**, **9,600 previews**, **36 branch cases**
and **16 enclosing-call cases** on original and rebuilt ROMs. Arbitrary target bytes and
zero divisors are checked at field level; exact DSP output is checked only for
supported positions 0..20×256. The test executes the original channel-update
CALL and preview return path without patched driver instructions. All inputs
and curves are synthetic, and no audio or memory captures are written.

Before accepting the OR-sensitive branch, independent local SPC vectors passed
all 1,000 opcode `$09` cases and all 1,000 DIV `$9E` cases using
`src/tools/run_spc_vectors.nim` with the existing local vector directory. OR's
N/Z behavior also agrees with the original Nintendo development manual,
[Book I, Table C-8, page C-6](https://floating.muncher.se/bot/manual/book1_text.pdf#page=232).
No core flags were changed to obtain the driver result. The phase accumulator
is explained above; absolute timing, tempo writers, override purpose and the
other transition/envelope writers remain open.

## Uploaded data and the next research boundary

Package 5 at file `$2B520C` contains blocks targeting APU `$6C00`, `$7000`, and
`$6E00`. Package 1 supplies the large `$0500` driver block. A `$7000` upload
alone is not evidence that its payload is driver code.

Existing research identifies a sample-directory area at `$6C00` (four-byte
start/loop pairs), instrument parameters near `$6E00`, and song/sample data in
package payloads, with `$4800/$5000/$6000` overlays in some combinations. Several
instrument fields and driver consumers still need traced evidence. Package 4
at file `$1FEC46`, targeting `$4800`, is an existing sequence-table candidate.

The dispatcher, E0 instrument path, pitch multiplier, E1 stereo consumer and
E2 transition now have bounded executed checks. Next questions are the other
sequence commands, prefix/event consumers, remaining position/envelope writers,
tempo-command semantics and the global override's purpose. Derive operand widths and
DSP effects from those consumers; preserve source offsets and package-to-APU
mappings.

All ROM payloads, extracted sequences, BRR samples, WAVs, and APU snapshots remain
local and untracked. Commit our format descriptions, tools, annotated code, and
synthetic tests. Byte-preserving package reconstruction and musical correctness
are separate claims; neither follows merely from producing a WAV.
