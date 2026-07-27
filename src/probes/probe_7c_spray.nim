## Diagnose the $7C register-spray crash (Tenda, build 30e832c).
## Replays session TAS with MMIO write tracing; autopsies hang F12.
## Usage: nim r -d:release src/probes/probe_7c_spray.nim [hang|replay|all]

import
  std/[monotimes, options, os, strformat, strutils, times],
  pixie,
  ../decompbound/[apu, cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  HangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-210013.png"
  SessionTas = "bin/sessions/20260726-205921/20260726-205927.tas"
  ## Log pins HDMAEN=7C at segframe ~5617.
  ReplayTo = 5650
  FineStart = 5500

proc loadRom(): seq[uint8] =
  ## ROM bytes without optional copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc loadPngState(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Extract ebSt from PNG and deserialize.
  doAssert fileExists(path), &"missing {path}"
  let raw = cast[seq[uint8]](readFile(path))
  let st = extractState(raw)
  doAssert st.isSome, &"no ebSt in {path}"
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  (snes, c)

proc loadFileState(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Deserialize a .state file.
  doAssert fileExists(path), &"missing {path}"
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc wram8(snes: SnesBus, off: int): uint8 =
  ## Read one WRAM byte at bank $7E offset.
  snes.bus.mem[0x7E0000 + off]

proc count7cInRange(snes: SnesBus, lo, hi: int): int =
  ## Count bytes equal to $7C in WRAM [lo, hi).
  for i in lo ..< hi:
    if snes.bus.mem[0x7E0000 + i] == 0x7C:
      inc result

proc dumpDmaQueue(snes: SnesBus, label: string) =
  ## Dump DP queue pointers $00/$01 and first DMA job slots at $0400.
  let qEnd = wram8(snes, 0x00)
  let qStart = wram8(snes, 0x01)
  echo &"=== {label}: DMA job queue ==="
  echo &"  DP $00 (end/X-stop)={qEnd:02X}  $01 (start/X)={qStart:02X}  delta={(qEnd.int - qStart.int) and 0xFF}"
  echo &"  $00 mod 8 = {qEnd.int mod 8}  (must be 0 for X-step-8 to terminate)"
  for i in 0 ..< 8:
    let base = 0x400 + i * 8
    let b0 = wram8(snes, base)
    let b1 = wram8(snes, base + 1)
    let b2 = wram8(snes, base + 2)
    let b3 = wram8(snes, base + 3)
    let b4 = wram8(snes, base + 4)
    let b5 = wram8(snes, base + 5)
    let b6 = wram8(snes, base + 6)
    let b7 = wram8(snes, base + 7)
    let size = b1.uint16 or (b2.uint16 shl 8)
    let a1 = b3.uint16 or (b4.uint16 shl 8)
    let bank = b5
    let vmadd = b6.uint16 or (b7.uint16 shl 8)
    echo &"  job[{i}] $0400+{i*8:02X}: type={b0:02X} size={size:04X} A1={bank:02X}:{a1:04X} VMADD={vmadd:04X}" &
      &" raw=[{b0:02X} {b1:02X} {b2:02X} {b3:02X} {b4:02X} {b5:02X} {b6:02X} {b7:02X}]"

proc dumpDmaRegs(snes: SnesBus, label: string) =
  ## Dump HDMAEN and all 8 DMA channel parameter blocks.
  echo &"=== {label}: DMA/HDMA regs ==="
  echo &"  HDMAEN={snes.hdmaen:02X} NMITIMEN={snes.nmitimen:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
  echo &"  CGWSEL={snes.ppuRegs[0x30]:02X} CGADSUB={snes.ppuRegs[0x31]:02X}"
  if snes.apu != nil:
    echo &"  portsIn=[{snes.apu.portsIn[0]:02X} {snes.apu.portsIn[1]:02X} {snes.apu.portsIn[2]:02X} {snes.apu.portsIn[3]:02X}]"
    echo &"  portsOut=[{snes.apu.portsOut[0]:02X} {snes.apu.portsOut[1]:02X} {snes.apu.portsOut[2]:02X} {snes.apu.portsOut[3]:02X}]"
  for ch in 0..7:
    let b = ch * 0x10
    let dmap = snes.dmaRegs[b]
    let bbad = snes.dmaRegs[b + 1]
    let a1 = snes.dmaRegs[b + 2].uint16 or (snes.dmaRegs[b + 3].uint16 shl 8)
    let bank = snes.dmaRegs[b + 4]
    let das = snes.dmaRegs[b + 5].uint16 or (snes.dmaRegs[b + 6].uint16 shl 8)
    let ibank = snes.dmaRegs[b + 7]
    let en = (snes.hdmaen and (1'u8 shl ch)) != 0
    if en or dmap != 0 or bbad != 0 or a1 != 0:
      echo &"  ch{ch}: DMAP={dmap:02X} BBAD={bbad:02X}(->$21{bbad:02X}) A1={bank:02X}:{a1:04X}" &
        &" DAS={das:04X} iBank={ibank:02X} hdmaEn={en} indir={(dmap and 0x40) != 0}"

proc isSprayFrame(snes: SnesBus): bool =
  ## True when the $7C spray signature is present.
  snes.hdmaen == 0x7C or snes.nmitimen == 0x7C or snes.ppuRegs[0x00] == 0x7C

proc isMmioWatch(offset: uint32, value: uint8): bool =
  ## Critical $7C spray targets (and first non-7C HDMAEN for context).
  if offset == 0x420C:
    return true
  if value != 0x7C:
    return false
  if offset in [0x2100'u32, 0x4200'u32, 0x2130'u32, 0x2131'u32]:
    return true
  if offset >= 0x2140 and offset <= 0x2143:
    return true
  if offset >= 0x4300 and offset <= 0x437F:
    return true
  false

proc phaseHang() =
  ## Autopsy F12 hang state: spray signature, DMA queue, loop cost.
  echo "########## PHASE hang ##########"
  var (snes, c) = loadPngState(HangPng)
  echo &"  CPU {c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} P={c.p:02X}"
  echo &"  stopped={c.stopped} nmiPending={c.nmiPending}"
  dumpDmaRegs(snes, "hang")
  dumpDmaQueue(snes, "hang")
  echo &"  WRAM $7C density: DP0-FF={count7cInRange(snes, 0, 0x100)}" &
    &" $400-47F={count7cInRange(snes, 0x400, 0x480)}" &
    &" $0-2000={count7cInRange(snes, 0, 0x2000)}"
  var dma7c = 0
  for i in 0 ..< snes.dmaRegs.len:
    if snes.dmaRegs[i] == 0x7C: inc dma7c
  echo &"  dmaRegs $7C count: {dma7c}/{snes.dmaRegs.len}"
  var ppu7c = 0
  for i in 0 ..< snes.ppuRegs.len:
    if snes.ppuRegs[i] == 0x7C: inc ppu7c
  echo &"  ppuRegs $7C count: {ppu7c}/{snes.ppuRegs.len}"

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var dmaBefore = snes.dmaTransfers
  let t0 = getMonoTime()
  policy.stepOneFrame(snes, c, img)
  let ms = (getMonoTime() - t0).inMilliseconds
  echo &"  one hang frame: {ms}ms  dmaTransfers delta={snes.dmaTransfers - dmaBefore}" &
    &"  PC after={c.pbr:02X}:{c.pc:04X} X={c.x:04X}"
  dumpDmaQueue(snes, "after 1 frame")

  (snes, c) = loadPngState(HangPng)
  var mdmaen = 0
  var sizeSum = 0
  for _ in 0 ..< 500:
    let pc = c.pc
    c.step(snes.bus)
    if pc == 0x826F:
      inc mdmaen
      let sz = snes.dmaRegs[5].int or (snes.dmaRegs[6].int shl 8)
      let real = if sz == 0: 0x10000 else: sz
      sizeSum += real
  echo &"  over 500 instr: MDMAEN fires={mdmaen} sizeSum={sizeSum}" &
    &" (~{sizeSum div max(1, mdmaen)} avg bytes/DMA)"

proc phaseReplay() =
  ## Replay TAS with write-hook logging of $7C critical MMIO.
  echo "########## PHASE replay (write-hook) ##########"
  doAssert fileExists(SessionTas), &"missing {SessionTas}"
  let (hdr, deltas) = parseReplay(SessionTas)
  echo &"  tas={SessionTas} start={hdr.startStateRef} build={hdr.buildCommit}"
  doAssert fileExists(hdr.startStateRef), &"missing {hdr.startStateRef}"
  let lastDelta = if deltas.len > 0: deltas[^1].frame else: 0
  echo &"  lastDelta={lastDelta} replaying to {ReplayTo}"

  var (snes, c) = loadFileState(hdr.startStateRef)
  echo &"  start CPU {c.pbr:02X}:{c.pc:04X} HDMAEN={snes.hdmaen:02X} NMITIMEN={snes.nmitimen:02X}" &
    &" INIDISP={snes.ppuRegs[0x00]:02X}"
  dumpDmaQueue(snes, "start")

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var frameNum = 0
  var writeLog: seq[string]
  var sprayFrame = -1
  let prevWrite = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let offset = address and 0xFFFF
    let isSys = (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF)
    if isSys and isMmioWatch(offset, value) and writeLog.len < 500:
      writeLog.add &"f={frameNum} {c.pbr:02X}:{c.pc:04X} W ${offset:04X}={value:02X}" &
        &" A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X}"
    prevWrite(address, value)

  for f in 0 .. ReplayTo:
    frameNum = f
    snes.joy1 = joyAtFrame(deltas, f)
    let t0 = getMonoTime()
    policy.stepOneFrame(snes, c, img)
    let ms = (getMonoTime() - t0).inMilliseconds

    if sprayFrame < 0 and isSprayFrame(snes):
      sprayFrame = f
      echo &"  ** SPRAY signature at f={f}: HDMAEN={snes.hdmaen:02X} NMITIMEN={snes.nmitimen:02X}" &
        &" INIDISP={snes.ppuRegs[0x00]:02X} PC={c.pbr:02X}:{c.pc:04X}"
      echo &"  CPU A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} P={c.p:02X}"
      dumpDmaRegs(snes, &"spray f={f}")
      dumpDmaQueue(snes, &"spray f={f}")
      echo "  --- write-hook hits (first 60) ---"
      let n = min(60, writeLog.len)
      for i in 0 ..< n:
        echo &"    {writeLog[i]}"
      echo &"  total watch hits so far: {writeLog.len}"

    let fine = f >= FineStart or sprayFrame >= 0
    if fine and (f mod 5 == 0 or ms >= 20 or f == ReplayTo or
        (sprayFrame >= 0 and f <= sprayFrame + 3)):
      let q0 = wram8(snes, 0x00)
      let q1 = wram8(snes, 0x01)
      echo &"  f={f:5d} joy={snes.joy1:04X} cpu={c.pbr:02X}:{c.pc:04X}" &
        &" A={c.a:04X} X={c.x:04X} Y={c.y:04X}" &
        &" HDMAEN={snes.hdmaen:02X} NMI={snes.nmitimen:02X} INI={snes.ppuRegs[0x00]:02X}" &
        &" q00={q0:02X} q01={q1:02X} dmaXfer={snes.dmaTransfers} ms={ms}"

    if sprayFrame >= 0 and f >= sprayFrame + 8:
      echo &"  stopping {f - sprayFrame} frames after spray"
      break

  if sprayFrame < 0:
    echo "  never hit spray signature; last writeLog:"
    for i in max(0, writeLog.len - 20) ..< writeLog.len:
      echo &"    {writeLog[i]}"
    dumpDmaRegs(snes, "end")
    dumpDmaQueue(snes, "end")
  else:
    echo "  --- write-hook hits (last 100) ---"
    let start = max(0, writeLog.len - 100)
    for i in start ..< writeLog.len:
      echo &"    {writeLog[i]}"

proc main() =
  ## Run selected phase.
  let phase =
    if paramCount() >= 1: paramStr(1).toLowerAscii()
    else: "all"
  doAssert fileExists(RomPath), &"need ROM at {RomPath}"
  case phase
  of "hang":
    phaseHang()
  of "replay":
    phaseReplay()
  of "all":
    phaseHang()
    phaseReplay()
  else:
    quit &"unknown phase {phase}"

when isMainModule:
  main()
