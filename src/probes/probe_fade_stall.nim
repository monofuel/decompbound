## Walk out front door; log every INIDISP change + whether CPU is progressing.
import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, llm_mock_policies]

proc loadChunk(L: lua53.PState, src: string, label: string): bool =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    L.pop(1); return false
  if L.pcall(0, 0, 0) != lua53.OK:
    L.pop(1); return false
  true

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/bedroom.state")), snes, cpu)
  let img = newImage(256, 224)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  discard loadChunk(L, touch_grass.EscapeMenuSkillLua & "\n" & touch_grass.WalkToSkillLua, "s")
  discard loadChunk(L, llm_mock_policies.NavHousePolicy, "n")

  var prevInidisp = snes.ppuRegs[0x00]
  var hitOut = false
  var outF = -1
  var prevPc = cpu.pc
  var pcChanges = 0

  for f in 0 .. 5000:
    ctx.frameCount = f
    # After door: try zero joy to let fade scripts run
    if hitOut and f >= outF + 2:
      ctx.joy1 = 0
      snes.joy1 = 0
      # still step without policy input
      policy.stepOneFrame(snes, cpu, img)
    else:
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, cpu, img)

    let tg = touch_grass.touchGrassPercent(snes)
    let inidisp = snes.ppuRegs[0x00]
    if cpu.pc != prevPc:
      inc pcChanges
      prevPc = cpu.pc

    if tg == 100 and not hitOut:
      hitOut = true
      outF = f
      echo fmt"OUT f={f} INIDISP={inidisp:02X} PC={cpu.pbr:02X}:{cpu.pc:04X} nmi={snes.nmitimen:02X}"

    if inidisp != prevInidisp:
      echo fmt"INIDISP {prevInidisp:02X}->{inidisp:02X} f={f} tg={tg} PC={cpu.pbr:02X}:{cpu.pc:04X} joy={snes.joy1:04X}"
      prevInidisp = inidisp

    if hitOut and (f - outF) mod 60 == 0:
      echo fmt"  f={f} INIDISP={inidisp:02X} PC={cpu.pbr:02X}:{cpu.pc:04X} pcDelta60f={pcChanges} stopped={cpu.stopped}"
      pcChanges = 0

    if hitOut and f >= outF + 600:
      # experiment: force clear blank and see if game continues writing INIDISP
      if f == outF + 600:
        echo "EXPERIMENT: clear force blank, set bright=0F"
        snes.ppuRegs[0x00] = 0x0F
      if f == outF + 601:
        echo fmt"  next frame INIDISP={snes.ppuRegs[0x00]:02X}"
      if f >= outF + 720:
        break

  echo fmt"final INIDISP={snes.ppuRegs[0x00]:02X}"

when isMainModule: main()
