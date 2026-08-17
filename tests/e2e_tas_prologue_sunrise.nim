## Gold opening TAS must leave the machine at day Onett with the Sound Stone.

import
  std/os,
  decompbound/[policy, replay, replay_run, save_state, snesbus],
  ../src/tools/[story_percents, touch_grass]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  PrologueTas =
    "../decompbound_secret/sessions/20260816-223148/20260816-223148.tas"

if not fileExists(GoldMasterRom):
  echo "[e2e_tas_prologue_sunrise] no gold ROM; skipping"
elif not fileExists(PrologueTas):
  echo "[e2e_tas_prologue_sunrise] no gold TAS; skipping"
else:
  let (header, deltas) = parseReplay(PrologueTas)
  doAssert not isLegacyReplay(header), "prologue TAS must be cadence emu"
  doAssert fileExists(header.startStateRef), "missing TAS start state"
  let snes = newSnesBus(policy.readRomFile(GoldMasterRom))
  var cpu = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(header.startStateRef)), snes, cpu)
  doAssert not partyHasSoundStone(snes), "start seat must not already have the stone"
  doAssert sunrisePercent(snes) < 100
  discard applyTas(snes, cpu, deltas, lastDeltaFrame(deltas),
    checkpoints = header.checkpoints)
  doAssert partyHasSoundStone(snes), "TAS end must have Sound Stone"
  doAssert sunrisePercent(snes) == 100, "opening sunrise must latch 100"
  doAssert touchGrassPercent(snes) == 100, "must be outdoor"
  echo "[e2e_tas_prologue_sunrise] ok sunrise=100 outdoor stone=true"