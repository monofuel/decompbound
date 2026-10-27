## Compare emulator changes against all locally available state captures.
## Run before and after a change, then diff the two hash-only TSV files:
## nim r -d:release src/probes/probe_integration_corpus.nim /tmp/corpus.tsv
## Inputs: the user's ROM, bin/states, ../decompbound_secret, and the Pictures
## screenshot archive. Image-only PNGs are counted separately; incompatible
## states produce explicit ERROR rows. No game pixels or state bytes are written.

import
  std/[algorithm, options, os, strformat, strutils],
  pixie,
  zippy/crc,
  ../decompbound/[cpu, png_state, policy, ppu, save_state, snesbus]

const
  FramesPerCapture = 3
  ProgressInterval = 100

proc main() =
  ## Compare rendered frames and machine states across every local capture.
  doAssert paramCount() == 1, "Supply an ignored output TSV path."
  let
    rom = policy.readRomFile("bin/Earthbound (U) [!].smc")
    output = open(paramStr(1), fmWrite)
    roots = @["bin/states", "../decompbound_secret", getHomeDir() / "Pictures/Screenshots"]
  defer: output.close()
  var paths: seq[string]
  for root in roots:
    if dirExists(root):
      for path in walkDirRec(root):
        if path.endsWith(".state") or path.endsWith(".png"):
          paths.add(path)
  paths.sort()
  var checked, imageOnly, failed: int
  for path in paths:
    var data = cast[seq[uint8]](readFile(path))
    if path.endsWith(".png"):
      let state = extractState(data)
      if state.isNone:
        inc imageOnly
        continue
      data = state.get()
    let
      snes = newSnesBus(rom)
      img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var cpu = snes.resetCpu()
    try:
      deserializeState(data, snes, cpu)
    except CatchableError as e:
      output.writeLine(path & "\tERROR\t" & $e.name & "\t" & e.msg.replace('\n', ' '))
      inc failed
      continue
    var hashes: seq[string]
    for frame in 0 ..< FramesPerCapture:
      policy.stepOneFrame(snes, cpu, img)
      let
        pixels = crc32(img.data[0].addr, img.data.len * sizeof(img.data[0]))
        state = serializeState(snes, cpu)
        machine = crc32(state[0].unsafeAddr, state.len)
      hashes.add(&"{pixels:08x}/{machine:08x}")
    output.writeLine(path & "\t" & hashes.join("\t"))
    inc checked
    if checked mod ProgressInterval == 0:
      output.flushFile()
      echo &"checked {checked} captures; incompatible {failed}; image-only {imageOnly}"
  echo &"completed: {checked} captures, {failed} incompatible, {imageOnly} image-only"

main()
