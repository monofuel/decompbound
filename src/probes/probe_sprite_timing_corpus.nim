## Corpus render for the sprite/OAM frame-coherence fix: load every state in
## bin/states/, step N frames via policy.stepOneFrame, write PNGs to a dir.
## Run once on the old code and once on the fix, then diff the two dirs —
## static scenes must be identical; moving-sprite scenes may shift by ~1px.
## Usage: nim r src/probes/probe_sprite_timing_corpus.nim <outdir> [frames]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, policy, ppu, save_state, snesbus]

const RomPath = "bin/Earthbound (U) [!].smc"

proc main() =
  doAssert paramCount() >= 1, "usage: probe_sprite_timing_corpus <outdir> [frames]"
  let outDir = paramStr(1)
  let frames = if paramCount() >= 2: parseInt(paramStr(2)) else: 3
  createDir(outDir)
  let rom = policy.readRomFile(RomPath)
  var statePaths: seq[string]
  for f in walkFiles("bin/states/*.state"):
    statePaths.add f
  for f in walkFiles("bin/states/llm/*.state"):
    statePaths.add f
  doAssert statePaths.len > 0, "no states found"
  var rendered = 0
  for sp in statePaths:
    var snes = newSnesBus(rom)
    var cpu = snes.resetCpu()
    try:
      deserializeState(cast[seq[byte]](readFile(sp)), snes, cpu)
    except CatchableError as e:
      echo &"SKIP {sp}: {e.msg}"
      continue
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for _ in 0 ..< frames:
      policy.stepOneFrame(snes, cpu, img)
    let name = sp.replace("bin/states/", "").replace("/", "_").replace(".state", ".png")
    img.writeFile(outDir / name)
    inc rendered
  echo &"rendered {rendered}/{statePaths.len} states x {frames} frames -> {outDir}"

main()
