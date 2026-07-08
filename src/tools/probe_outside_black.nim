## Run seed house-nav until outside; dump INIDISP/TM/lit pixels + PNGs at transition.
## Usage: nim r src/tools/probe_outside_black.nim [rom] [state]
## Diagnoses black exterior after front door (logic ok, fade/force-blank?).

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/bedroom.state"
  MaxFrames = 4000

proc loadChunk(L: lua53.PState, src: string, label: string): bool =
  ## Load and exec a Lua chunk.
  let ls = L.loadbuffer(src.cstring, src.len.cint, label.cstring)
  if ls != lua53.OK:
    echo "loadbuffer failed: ", L.toString(-1)
    L.pop(1)
    return false
  let ps = L.pcall(0, 0, 0)
  if ps != lua53.OK:
    echo "pcall failed: ", L.toString(-1)
    L.pop(1)
    return false
  true

proc countLit(img: Image): int =
  ## Count pixels brighter than near-black.
  result = 0
  for y in 0 ..< 224:
    for x in 0 ..< 256:
      let p = img[x, y]
      if p.r.int + p.g.int + p.b.int > 40:
        inc result

proc main() =
  let romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(statePath):
    echo "missing state ", statePath
    quit(1)

  let snes = newSnesBus(policy.readRomFile(romPath))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)

  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes,
    frameImage: frameImage,
    frameCount: 0,
    joy1: 0'u16,
    targetFps: 0
  )
  let L = lua53.newstate()
  if L == nil:
    echo "lua nil"
    quit(1)
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  let skills = touch_grass.EscapeMenuSkillLua & "\n" & touch_grass.WalkToSkillLua &
    "\n" & touch_grass.WinBattleSkillLua
  if not loadChunk(L, skills, "skills"):
    quit(1)
  if not loadChunk(L, llm_mock_policies.NavHousePolicy, "nav"):
    quit(1)

  var hitOutside = false
  var firstOut = -1
  var lines: seq[string]
  createDir("bin")

  for f in 0 ..< MaxFrames:
    ctx.frameCount = f
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 200 == 0:
      echo "policy err f=", f, ": ", err
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, frameImage)

    let tg = touch_grass.touchGrassPercent(snes)
    let room = touch_grass.currentRoomLabel(snes)
    let inidisp = snes.ppuRegs[0x00]
    let tm = snes.ppuRegs[0x2C]
    let ts = snes.ppuRegs[0x2D]
    let mode = snes.ppuRegs[0x05]
    let cgw = snes.ppuRegs[0x30]
    let cga = snes.ppuRegs[0x31]
    let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
    let px = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
    let py = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
    let lit = countLit(frameImage)
    let forceBlank = (inidisp and 0x80) != 0
    let bright = inidisp and 0x0F

    if tg == 100 and not hitOutside:
      hitOutside = true
      firstOut = f
      echo "HIT OUTSIDE at frame ", f

    # Clear joy shortly after door so we do not hold d-pad through the fade script.
    if hitOutside and f >= firstOut + 2:
      snes.joy1 = 0
      ctx.joy1 = 0

    let sample = (not hitOutside and f mod 100 == 0) or
      (hitOutside and (f - firstOut) mod 30 == 0) or
      (hitOutside and f - firstOut < 5)
    if sample:
      let row = fmt"f={f} tg={tg} room={room} pos=({px:04X},{py:04X}) INIDISP={inidisp:02X} fb={forceBlank} bright={bright} TM={tm:02X} TS={ts:02X} MODE={mode:02X} CGWSEL={cgw:02X} CGADSUB={cga:02X} lit={lit} cgram0={snes.cgram[0]:04X}"
      lines.add row
      echo row
      if hitOutside and not forceBlank and bright > 0:
        echo "FADE RECOVERED at f=", f
        frameImage.writeFile(fmt"bin/outside_black_recovered_f{f}.png")
      if hitOutside and (f - firstOut) in [0, 1, 30, 60, 120, 300, 600, 1200]:
        frameImage.writeFile(fmt"bin/outside_black_f{f}.png")

    if hitOutside and f >= firstOut + 3000:
      break

  if not hitOutside:
    echo "never reached tg=100"
    writeFile("bin/outside_black_probe.txt", lines.join("\n"))
    quit(1)

  writeFile("bin/outside_black_probe.txt", lines.join("\n") & "\n")
  frameImage.writeFile("bin/outside_black_probe.png")
  echo "done firstOutside=", firstOut, " wrote bin/outside_black_*"

when isMainModule:
  main()
