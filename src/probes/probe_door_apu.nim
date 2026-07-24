## Door exit APU stall dig: log $2140 ports + SPC while outdoor force-blank.
## Experiments: zero port0, extra APU ticks, HLE apu=nil.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy, apu],
  ../tools/[touch_grass, llm_mock_policies]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/bedroom.state"

proc loadChunk(L: lua53.PState, src: string, label: string): bool =
  ## Load and exec a Lua chunk; return false on error.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    echo "load fail ", label, ": ", L.toString(-1)
    L.pop(1)
    return false
  if L.pcall(0, 0, 0) != lua53.OK:
    echo "pcall fail ", label, ": ", L.toString(-1)
    L.pop(1)
    return false
  true

proc apuSnap(snes: SnesBus): string =
  ## Format APU port + SPC status.
  if snes.apu == nil:
    return "apu=nil"
  let a = snes.apu
  let spc = a.spc
  fmt"in=[{a.portsIn[0]:02X},{a.portsIn[1]:02X},{a.portsIn[2]:02X},{a.portsIn[3]:02X}] out=[{a.portsOut[0]:02X},{a.portsOut[1]:02X},{a.portsOut[2]:02X},{a.portsOut[3]:02X}] spcPC={spc.pc:04X} stop={spc.stopped} ipl={spc.iplEnabled}"

proc runNav(snes: SnesBus, cpu: var Cpu, extraApuPerLine: int, killApu: bool,
    zeroPortAtOut: bool, topUp533: bool): void =
  ## Drive NavHouse from bedroom until outside; log stall diagnostics.
  if killApu:
    snes.apu = nil
  let img = newImage(256, 224)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  discard loadChunk(L, touch_grass.EscapeMenuSkillLua & "\n" & touch_grass.WalkToSkillLua, "s")
  discard loadChunk(L, llm_mock_policies.NavHousePolicy, "n")
  echo fmt"start {apuSnap(snes)}"
  var outF = -1
  var didZero = false
  for f in 0 .. 1400:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = if outF >= 0 and f >= outF + 2: 0'u16 else: ctx.joy1
    # Custom step matching policy + optional extra APU
    let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
    if not forceBlank:
      img.fill(ppu.bgr555ToColor(snes.cgram[0]))
    var l = 0
    var apuTicks = 0
    while l < 262:
      snes.setScanline(l)
      if l == 224 and (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
        snes.raiseNmi()
      for i in 0 ..< policy.InstrPerLine:
        cpu.step(snes.bus)
        if cpu.stopped: break
      if l < 224:
        snes.runHdma()
        if (snes.ppuRegs[0x00] and 0x80) == 0:
          ppu.renderScanline(snes, img, l)
      for k in 0 ..< (2 + extraApuPerLine):
        discard snes.tickApu()
        inc apuTicks
      inc l
      if l >= 262:
        snes.initHdma()
        break
    if topUp533:
      while apuTicks < 533:
        discard snes.tickApu()
        inc apuTicks
    ppu.renderSprites(snes, img)
    ppu.overlayForegroundBg(snes, img)

    let tg = touch_grass.touchGrassPercent(snes)
    let inidisp = snes.ppuRegs[0x00]
    if tg == 100 and outF < 0:
      outF = f
      echo fmt"OUT f={f} INIDISP={inidisp:02X} PC={cpu.pbr:02X}:{cpu.pc:04X} {apuSnap(snes)}"
    if outF >= 0 and zeroPortAtOut and not didZero and f == outF + 5:
      if snes.apu != nil:
        echo fmt"ZERO portsOut[0] was {snes.apu.portsOut[0]:02X}"
        snes.apu.portsOut[0] = 0
        didZero = true
    if outF >= 0 and (f - outF) mod 30 == 0:
      echo fmt"  f={f} INIDISP={inidisp:02X} PC={cpu.pbr:02X}:{cpu.pc:04X} {apuSnap(snes)}"
    if outF >= 0 and (inidisp and 0x80) == 0 and (inidisp and 0x0F) > 0:
      echo fmt"RECOVERED f={f} INIDISP={inidisp:02X}"
      break
    if outF >= 0 and f >= outF + 240:
      echo "give up after 240f outside"
      break
  echo fmt"end INIDISP={snes.ppuRegs[0x00]:02X} {apuSnap(snes)}"

proc main() =
  ## Args: [mode] — baseline|zero|extra|topup|hle (ignore a leading -- from nim r).
  var mode = "baseline"
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--":
      continue
    mode = a
    break
  echo "mode=", mode, " state=", DefaultState
  let snes = newSnesBus(policy.readRomFile(DefaultRom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(DefaultState)), snes, cpu)
  case mode
  of "baseline":
    runNav(snes, cpu, 0, false, false, false)
  of "zero":
    runNav(snes, cpu, 0, false, true, false)
  of "extra":
    runNav(snes, cpu, 8, false, false, false)
  of "topup":
    runNav(snes, cpu, 0, false, false, true)
  of "hle":
    runNav(snes, cpu, 0, true, false, false)
  else:
    echo "modes: baseline|zero|extra|topup|hle"
    quit(1)

when isMainModule:
  main()
