## Referee lock for getDialogueText — the EB dialogue-stream decoder.
## EB renders dialogue with a variable-width font (VRAM tiles are pixel glyphs,
## not char codes), and the ROM script is dictionary-compressed, so the ONLY
## reliable read is decoding the live script stream (cursor $96C5 + call tokens).
## Verifies against a known live screenstate via SHA-1 of the decoded string
## (no game dialogue text is stored in the public repo).
## Skips quietly when the user ROM or the screenstate PNG are absent (CI).

import
  std/[os, options, sha1, strutils],
  ../src/decompbound/[cpu, snesbus, save_state, png_state, policy]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  # SHA-1 (hex, lowercase) of the UTF-8 decoded line from the ground-truth
  # screenstate. Recompute privately if the fixture changes; never commit the
  # plaintext line into this repo.
  ExpectedSha1 = "3f36d6958cc2a98f3f18d11fe4c82ed431652f6d"

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  d

proc findScreenstate(): string =
  ## Locate the known-line screenstate PNG if it exists locally (gitignored).
  let candidates = [
    "bin/sessions/20260710-210243/f12/earthbound_20260710-210559.png",
    getHomeDir() / "Pictures/Screenshots/earthbound_20260710-210559.png",
  ]
  for c in candidates:
    if fileExists(c): return c
  ""

proc main() =
  ## Decode the known screenstate and assert the SHA-1 of the line.
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
  let digest = toLowerAscii($secureHash(got))
  doAssert digest == ExpectedSha1,
    "dialogue decode SHA-1 mismatch: got digest " & digest & " (len=" & $got.len &
    "). Update ExpectedSha1 only from a private fixture, never commit plaintext."
  echo "[test_dialogue_decode] ok: SHA-1 matched (len=", got.len, ")"

when isMainModule:
  main()
