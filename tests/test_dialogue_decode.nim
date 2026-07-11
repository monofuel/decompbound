## Referee lock for getDialogueText — the EB dialogue-stream decoder.
## EB renders dialogue with a variable-width font (VRAM tiles are pixel glyphs,
## not char codes), and the ROM script is dictionary-compressed, so the ONLY
## reliable read is decoding the live script stream (cursor $96C5 + call tokens).
## Verifies against monofuel's F12 screenstate that shows a known line.
## Skips quietly when the user ROM or the screenstate PNG are absent (CI).

import
  std/[os, options],
  ../src/decompbound/[cpu, snesbus, save_state, png_state, policy]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  # The known-line screenstate lands in the session dir + ~/Pictures mirror;
  # both are local/gitignored. Try a few likely spots.
  ExpectedLine = "[redacted dialogue]"

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  d

proc findScreenstate(): string =
  ## Locate the [redacted] screenstate PNG if it exists locally.
  let candidates = [
    "bin/sessions/20260710-210243/f12/earthbound_20260710-210559.png",
    getHomeDir() / "Pictures/Screenshots/earthbound_20260710-210559.png",
  ]
  for c in candidates:
    if fileExists(c): return c
  ""

proc main() =
  ## Decode the known screenstate and assert the exact line.
  let png = findScreenstate()
  if not fileExists(RomPath) or png.len == 0:
    echo "[test_dialogue_decode] skipped (ROM or ground-truth screenstate absent)"
    return
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  let ex = extractState(cast[seq[uint8]](readFile(png)))
  doAssert ex.isSome, "screenstate PNG has no ebSt chunk"
  deserializeState(ex.get, snes, c)

  let got = getDialogueText(snes)
  doAssert got == ExpectedLine,
    "dialogue decode mismatch:\n  got:  [" & got & "]\n  want: [" & ExpectedLine & "]"
  echo "[test_dialogue_decode] ok: decoded [" & got & "]"

when isMainModule:
  main()
