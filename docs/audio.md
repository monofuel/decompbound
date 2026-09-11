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
- `src/tools/sound_explore.nim` loads packages directly into a fresh APU and
  renders a WAV under ignored `bin/` or another explicitly selected local path.
- `src/tools/jukebox_app.nim` provides a GUI for that standalone loading path.
  Its numeric song list is not a verified soundtrack identity catalog.
- `src/probes/songstart_dig.nim` compares package targets and driver state for
  two songs, including the deliberately incomplete case without package 1.
  Run `nim r src/probes/songstart_dig.nim --a:1 --b:3`.
- [Music](music.md) tracks standalone playback gaps; [DSP research](sfx.md)
  covers synthesis behavior. Human listening checks belong in
  [human-verify.md](human-verify.md).

Direct package loading does not execute the S-CPU/IPL handshake or reproduce
all resident-state/cache behavior of a song change during play. The standalone
tools currently duplicate parsers and have permissive truncated-input handling;
consolidating and validating those parsers remains open.

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

## Uploaded data and the next research boundary

Package 5 at file `$2B520C` contains blocks targeting APU `$6C00`, `$7000`, and
`$6E00`. Package 1 supplies the large `$0500` driver block. A `$7000` upload
alone is not evidence that its payload is driver code.

Existing research identifies a sample-directory area at `$6C00` (four-byte
start/loop pairs), instrument parameters near `$6E00`, and song/sample data in
package payloads, with `$4800/$5000/$6000` overlays in some combinations. Exact
instrument fields and driver consumers still need traced evidence. Package 4
at file `$1FEC46`, targeting `$4800`, is an existing sequence-table candidate.

Older opcode guesses based on byte frequency are unverified: note/duration
splitting, instrument/volume/pan commands, calls, and loops require the actual
SPC700 dispatch path. Next work should locate that dispatcher in the uploaded
package-1 image, trace a known song's reads and DSP writes, and derive operand
widths and state changes. Preserve source offsets and package-to-APU mappings.

All ROM payloads, extracted sequences, BRR samples, WAVs, and APU snapshots remain
local and untracked. Commit our format descriptions, tools, annotated code, and
synthetic tests. Byte-preserving package reconstruction and musical correctness
are separate claims; neither follows merely from producing a WAV.
