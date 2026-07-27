## Crash3 autopsy: Tenda derail with near-crash F12s (2026-07-26 21:29).
## Phases: snap | stack | replay | near | all
## Usage: nim r -d:release src/probes/probe_crash3.nim [phase]

import
  std/[algorithm, options, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[apu, cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PngNear20 = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212924.png"
  PngNear6 = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png"
  PngCrash = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212954.png"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"
  NearStepFrames = 720
  SampleEvery = 30
  ## Free-list / entity link table walked at $C09C68.
  FreeListHead = 0x0A50
  FreeListNext = 0x0A9E
  WaitSites = [
    (0xC0AB06'u32, 0xC0ABBC'u32, "uploadApuPackages"),
    (0xC0ABBD'u32, 0xC0ABC5'u32, "writeApuPort0"),
    (0xC0ABC6'u32, 0xC0ABDF'u32, "waitApuIdleClearSong"),
    (0xC0ABE0'u32, 0xC0AC00'u32, "queueApuCommand"),
    (0xC0AC01'u32, 0xC0AC0B'u32, "writeApuPort3Cmd57"),
    (0xC0AC0C'u32, 0xC0AC1F'u32, "writeApuPort1Toggled"),
    (0xC0AC20'u32, 0xC0AC2F'u32, "readApuPort0"),
    (0xC4FBBD'u32, 0xC4FD40'u32, "loadSong"),
    (0xC09C68'u32, 0xC09C6C'u32, "freeListWalk_9C68"),
    (0xC08240'u32, 0xC08274'u32, "nmiChrDmaQueue"),
  ]

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
  ## One WRAM byte at bank $7E.
  snes.bus.mem[0x7E0000 + off]

proc wram16(snes: SnesBus, off: int): uint16 =
  ## Little-endian WRAM word.
  wram8(snes, off).uint16 or (wram8(snes, off + 1).uint16 shl 8)

proc fullAddr(pbr: uint8, pc: uint16): uint32 =
  ## 24-bit SNES address.
  (pbr.uint32 shl 16) or pc.uint32

proc nameSite(pbr: uint8, pc: uint16): string =
  ## Match known wait / derail sites (also bank-0 HiROM mirrors of $C0).
  var a = fullAddr(pbr, pc)
  if pbr == 0x00'u8 and pc >= 0x8000'u16:
    a = 0xC00000'u32 or pc.uint32
  for (lo, hi, name) in WaitSites:
    if a >= lo and a <= hi:
      return name
  if pbr == 0 and pc == 0x5FFF:
    return "BRK_SINK_5FFF"
  if pbr >= 0xC0 and pbr <= 0xFF:
    return "rom_code"
  if pbr == 0x7E or pbr == 0x7F:
    return "WRAM_exec"
  if pc < 0x8000:
    return "LOW_RAM_or_mmio"
  "other"

proc dumpCpu(label: string, snes: SnesBus, c: Cpu) =
  ## Print CPU + APU + key shadows.
  echo &"=== {label} ==="
  echo &"  CPU {c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} " &
    &"S={c.s:04X} D={c.d:04X} DBR={c.dbr:02X} P={c.p:02X} site={nameSite(c.pbr, c.pc)}"
  echo &"  stopped={c.stopped} nmiPending={c.nmiPending} emu={c.emulation}"
  echo &"  NMITIMEN={snes.nmitimen:02X} HDMAEN={snes.hdmaen:02X} INIDISP={snes.ppuRegs[0]:02X}"
  if snes.apu != nil:
    echo &"  portsIn  [{snes.apu.portsIn[0]:02X} {snes.apu.portsIn[1]:02X} " &
      &"{snes.apu.portsIn[2]:02X} {snes.apu.portsIn[3]:02X}]"
    echo &"  portsOut [{snes.apu.portsOut[0]:02X} {snes.apu.portsOut[1]:02X} " &
      &"{snes.apu.portsOut[2]:02X} {snes.apu.portsOut[3]:02X}]"
    echo &"  SPC pc={snes.apu.spc.pc:04X} stopped={snes.apu.spc.stopped} " &
      &"ipl={snes.apu.spc.iplEnabled}"
  echo &"  DP $00={wram8(snes,0):02X} $01={wram8(snes,1):02X} " &
    &"$001E(NMI sh)={wram8(snes,0x1E):02X} $001F(HDMA sh)={wram8(snes,0x1F):02X}"
  echo &"  CurrentSongId $B53B={wram16(snes,0xB53B):04X} " &
    &"MusicWarm $B4B6={wram16(snes,0xB4B6):04X}"
  echo &"  ApuCmdIdx $00CA={wram8(snes,0xCA):02X} phase $1ACA={wram8(snes,0x1ACA):02X} " &
    &"port1phase $1ACB={wram8(snes,0x1ACB):02X}"
  echo &"  freeList head $0A50={wram16(snes, FreeListHead):04X}"

proc wordFillStats(snes: SnesBus, lo, hi: int): tuple[topWord: uint16, topCount: int, other: int] =
  ## Dominant LE word in WRAM [lo, hi).
  var hist = initTable[uint16, int]()
  var i = lo
  while i + 1 < hi:
    let w = wram16(snes, i)
    hist.mgetOrPut(w, 0) = hist.getOrDefault(w) + 1
    i += 2
  var bestW = 0'u16
  var bestN = 0
  var other = 0
  for w, n in hist:
    if n > bestN:
      bestN = n
      bestW = w
  for w, n in hist:
    if w != bestW:
      other += n
  (bestW, bestN, other)

proc dumpLowWram(snes: SnesBus, label: string) =
  ## Low-WRAM health + DMA queue jobs.
  echo &"--- low WRAM {label} ---"
  let (topW, topN, other) = wordFillStats(snes, 0, 0x2000)
  echo &"  low 8KB word fill: top=${topW:04X} n={topN} otherWords={other}"
  var line = "  $0000..$001F: "
  for i in 0 .. 31:
    line.add &"{wram8(snes, i):02X} "
  echo line
  echo &"  queue end=$00={wram8(snes,0):02X} start=$01={wram8(snes,1):02X}"
  for i in 0 ..< 4:
    let base = 0x400 + i * 8
    echo &"  job[{i}] @{base:04X}: " &
      &"{wram8(snes,base):02X} {wram8(snes,base+1):02X} {wram8(snes,base+2):02X} " &
      &"{wram8(snes,base+3):02X} {wram8(snes,base+4):02X} {wram8(snes,base+5):02X} " &
      &"{wram8(snes,base+6):02X} {wram8(snes,base+7):02X}"

proc dumpFreeList(snes: SnesBus, label: string) =
  ## Walk free-list next-table at $0A9E for cycles / terminators.
  echo &"--- free-list {label} head=$0A50={wram16(snes, FreeListHead):04X} ---"
  var seen = initTable[uint16, int]()
  var x = wram16(snes, FreeListHead)
  var steps = 0
  while steps < 64:
    if (x and 0x8000'u16) != 0:
      echo &"  step{steps}: X={x:04X} TERMINATOR (bit15)"
      break
    if x > 0x200:
      echo &"  step{steps}: X={x:04X} OUT OF RANGE"
      break
    if seen.hasKey(x):
      echo &"  step{steps}: X={x:04X} CYCLE (first seen step {seen[x]})"
      break
    seen[x] = steps
    let nxt = wram16(snes, FreeListNext + x.int)
    echo &"  step{steps}: X={x:04X} next[$0A9E+X]={nxt:04X}"
    x = nxt
    inc steps
  # dump slot $0060 region (crash X=Y=$0060)
  echo &"  $0A9E+$0060 ($0AFE) word={wram16(snes, FreeListNext + 0x60):04X}"
  echo &"  $0A9E+$0062 ($0B00) word={wram16(snes, FreeListNext + 0x62):04X}"
  echo &"  $0A50..$0A5F: "
  var line = "  "
  for i in 0xA50 .. 0xA5F:
    line.add &"{wram8(snes, i):02X} "
  echo line

proc dumpStackFlight(snes: SnesBus, c: Cpu, label: string) =
  ## Scan bank-0 stack region as a flight recorder.
  ## Native BRK pushes (our cpu.nim): PBR, PCH, PCL, P — 4 bytes, S decreases.
  echo &"=== STACK FLIGHT {label} S={c.s:04X} ==="
  echo &"  near S (S-32 .. S+32):"
  let sBase = c.s.int
  for off in countup(-32, 32, 1):
    let a = (sBase + off) and 0xFFFF
    let mark = if off == 0: '>' else: ' '
    echo &"  {mark}${a:04X}: {wram8(snes, a):02X}"

  # Scan classic native stack $1C00-$1FFF for non-zero / non-pattern frames.
  echo "  classic stack window $1C00-$1FFF: non-trivial 4-byte groups"
  var brkish = 0
  var samples: seq[string]
  var a = 0x1C00
  while a <= 0x1FFC:
    let b0 = wram8(snes, a)
    let b1 = wram8(snes, a + 1)
    let b2 = wram8(snes, a + 2)
    let b3 = wram8(snes, a + 3)
    # BRK return to 00:5FFF+2 → often 00 60 00 xx or 00 5F xx if mid-sink
    let isBrkRet =
      (b0 == 0x00 and b1 == 0x60 and b2 == 0x00) or  # PC=0060? unlikely
      (b0 == 0x00 and b1 == 0x5F) or
      (b0 == 0x00 and b1 == 0x60) or
      (b1 == 0x5F and b0 in [0x00'u8, 0xC0'u8])
    # ROM return: PBR in C0-FF or 00 with PC>=8000
    let looksRet =
      (b0 >= 0xC0) or
      (b0 == 0x00 and b1 >= 0x80) or
      (b0 == 0x00 and b1 == 0x5F)
    if looksRet or (b0.int or b1.int or b2.int or b3.int) != 0:
      if samples.len < 40 and looksRet:
        samples.add &"    ${a:04X}: {b0:02X} {b1:02X} {b2:02X} {b3:02X}  " &
          &"(pbr={b0:02X} pc={b1:02X}{b2:02X}? p={b3:02X})"
      if isBrkRet:
        inc brkish
    a += 4
  echo &"  brkish 4-byte slots in $1C00-$1FFF ≈ {brkish}"
  for s in samples:
    echo s

  # Also dump $1FE0-$1FFF always (normal stack top)
  echo "  $1FE0-$1FFF:"
  var line = "  "
  for i in 0x1FE0 .. 0x1FFF:
    line.add &"{wram8(snes, i):02X}"
    if (i and 0xF) == 0xF:
      echo line
      line = "  "
    else:
      line.add " "
  if line.len > 2:
    echo line

  # Scan for non-BRK return addresses: walk down from $1FFF looking for C0:xxxx frames
  echo "  candidate return frames (PBR in C0-FF or bank00 ROM) in $1800-$1FFF:"
  var found = 0
  a = 0x1FFF
  while a >= 0x1803 and found < 60:
    # try interpretation: [PBR][PCH][PCL][P] at a-3..a (top of frame)
    let pbr = wram8(snes, a - 3)
    let pch = wram8(snes, a - 2)
    let pcl = wram8(snes, a - 1)
    let p = wram8(snes, a)
    let pc = (pch.uint16 shl 8) or pcl.uint16
    let okBank = pbr >= 0xC0 or (pbr == 0x00 and pc >= 0x8000)
    let notSink = not (pbr == 0x00 and pc >= 0x5FF0 and pc <= 0x6005)
    if okBank and notSink and pc != 0:
      let frameBase = a - 3
      echo &"    S~{frameBase:04X}: {pbr:02X}:{pc:04X} P={p:02X} site={nameSite(pbr, pc)}"
      inc found
      a -= 4
    else:
      a -= 1

  # High S region if S is wild
  if c.s >= 0x2000'u16:
    echo &"  S is high (${c.s:04X}); dump $7FE0-$8010 and $1Fxx residual"
    for base in [0x7FE0, 0x8000, 0x1F00]:
      echo &"  ${base:04X}:"
      line = "  "
      for i in 0 .. 31:
        let wa = (base + i) and 0xFFFF
        line.add &"{wram8(snes, wa):02X} "
      echo line

proc dumpApuQueue(snes: SnesBus) =
  ## 8-slot APU cmd ring at $1AC2.
  echo "  ApuCmd queue $1AC2[8]:"
  var line = "  "
  for i in 0 .. 7:
    line.add &"{wram8(snes, 0x1AC2 + i):02X} "
  echo line

proc phaseSnap() =
  ## Snapshot all three F12s.
  echo "########## PHASE snap ##########"
  for (path, name) in [
    (PngNear20, "NEAR-20s 212924"),
    (PngNear6, "NEAR-6s 212944"),
    (PngCrash, "CRASH 212954"),
  ]:
    var (snes, c) = loadPngState(path)
    dumpCpu(name, snes, c)
    dumpLowWram(snes, name)
    dumpFreeList(snes, name)
    dumpApuQueue(snes)
    # PC histogram 2k instr
    var hist = initTable[uint32, int]()
    for _ in 0 ..< 2000:
      hist.mgetOrPut(fullAddr(c.pbr, c.pc), 0) = hist.getOrDefault(fullAddr(c.pbr, c.pc)) + 1
      c.step(snes.bus)
      if c.stopped: break
    var pairs: seq[(uint32, int)]
    for k, v in hist:
      pairs.add (k, v)
    pairs.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))
    echo "  PC hist top5:"
    for i in 0 ..< min(5, pairs.len):
      let (a, n) = pairs[i]
      let pbr = (a shr 16).uint8
      let pc = (a and 0xFFFF).uint16
      echo &"    {pbr:02X}:{pc:04X} n={n} {nameSite(pbr, pc)}"
    echo ""

proc phaseStack() =
  ## Deep stack flight-recorder on crash (+ near for contrast).
  echo "########## PHASE stack ##########"
  for (path, name) in [
    (PngCrash, "CRASH"),
    (PngNear6, "NEAR6"),
    (PngNear20, "NEAR20"),
  ]:
    let (snes, c) = loadPngState(path)
    dumpCpu(name, snes, c)
    dumpStackFlight(snes, c, name)
    echo ""

proc derailFlags(snes: SnesBus, c: Cpu): string =
  ## Compact derail indicators for a frame sample.
  var flags: seq[string]
  if c.pbr == 0 and c.pc == 0x5FFF:
    flags.add "BRK_SINK"
  if (snes.nmitimen and 0x80) == 0:
    let inUp = c.pbr == 0xC0 and c.pc >= 0xAB06 and c.pc <= 0xABBC
    if not inUp:
      flags.add &"NMI_MASK@{c.pbr:02X}:{c.pc:04X}"
  if c.s >= 0x2000'u16:
    flags.add &"S_HIGH={c.s:04X}"
  let (topW, topN, _) = wordFillStats(snes, 0, 0x2000)
  if topN >= 2000 and topW != 0:
    flags.add &"FILL={topW:04X}x{topN}"
  let q0 = wram8(snes, 0)
  let q1 = wram8(snes, 1)
  if q0 == 0x7C or q1 == 0x59:
    flags.add "QUEUE_7C59"
  if snes.dmaStorm:
    flags.add "DMA_STORM"
  flags.join(",")

proc runFrames(
    snes: SnesBus, c: var Cpu, frames: int, joyFn: proc(f: int): uint16,
    label: string, sampleEvery = SampleEvery
): tuple[derailed: bool, firstFrame: int, lastFlags: string] =
  ## Step frames; return first derail frame if any.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  result.derailed = false
  result.firstFrame = -1
  for f in 0 ..< frames:
    snes.joy1 = joyFn(f)
    policy.stepOneFrame(snes, c, img)
    let flags = derailFlags(snes, c)
    result.lastFlags = flags
    if flags.len > 0 and result.firstFrame < 0:
      result.derailed = true
      result.firstFrame = f
      echo &"  ** DERAIL {label} f={f} flags={flags} " &
        &"cpu={c.pbr:02X}:{c.pc:04X} S={c.s:04X} " &
        &"pin=[{snes.apu.portsIn[0]:02X}{snes.apu.portsIn[1]:02X}" &
        &"{snes.apu.portsIn[2]:02X}{snes.apu.portsIn[3]:02X}]"
      dumpCpu(&"{label} derail", snes, c)
      dumpLowWram(snes, label)
      dumpFreeList(snes, label)
      dumpStackFlight(snes, c, label)
    if f mod sampleEvery == 0 or f == frames - 1:
      echo &"  f={f:5d} joy={snes.joy1:04X} cpu={c.pbr:02X}:{c.pc:04X} " &
        &"site={nameSite(c.pbr, c.pc)} S={c.s:04X} nmi={snes.nmitimen:02X} " &
        &"pin3={snes.apu.portsIn[3]:02X} q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
        &"flags={flags}"
    if result.derailed and f > result.firstFrame + 5:
      break

proc phaseReplay() =
  ## Full TAS from start state; watch for derail.
  echo "########## PHASE replay (full TAS) ##########"
  doAssert fileExists(SessionTas), &"missing {SessionTas}"
  let (hdr, deltas) = parseReplay(SessionTas)
  echo &"  tas={SessionTas} start={hdr.startStateRef} build={hdr.buildCommit}"
  doAssert fileExists(hdr.startStateRef), &"missing {hdr.startStateRef}"
  let lastDelta = if deltas.len > 0: deltas[^1].frame else: 0
  let lastF = lastDelta + 120
  echo &"  lastDelta={lastDelta} replayTo={lastF}"
  var (snes, c) = loadFileState(hdr.startStateRef)
  dumpCpu("replay start", snes, c)
  let r = runFrames(
    snes, c, lastF + 1,
    proc(f: int): uint16 = joyAtFrame(deltas, f),
    "TAS", sampleEvery = 120
  )
  echo &"  TAS derailed={r.derailed} first={r.firstFrame} endFlags={r.lastFlags}"
  if not r.derailed:
    dumpCpu("replay end (healthy?)", snes, c)
    dumpLowWram(snes, "replay end")

proc phaseNear() =
  ## From 212944 (6s pre-crash): idle, A spam, and TAS tail alignment.
  echo "########## PHASE near (from 212944) ##########"
  let (hdr, deltas) = parseReplay(SessionTas)
  let lastDelta = if deltas.len > 0: deltas[^1].frame else: 0
  # Wall clock: session start 21:28:32, near F12 21:29:44 → ~72s ≈ 4320 frames
  # Crash ~21:29:50 → ~78s ≈ 4680. User said ~4680 for crash.
  # Try align offsets around that.
  const AlignGuesses = [4200, 4320, 4400, 4500, 4560, 4600, 4680, 0]

  echo "--- idle 720f from 212944 ---"
  block:
    var (snes, c) = loadPngState(PngNear6)
    dumpCpu("near6 load", snes, c)
    let r = runFrames(
      snes, c, NearStepFrames,
      proc(f: int): uint16 = 0'u16,
      "IDLE", sampleEvery = 60
    )
    echo &"  IDLE derailed={r.derailed} first={r.firstFrame}"

  echo "--- A-pulse 720f from 212944 (A 8f on / 8f off) ---"
  block:
    var (snes, c) = loadPngState(PngNear6)
    let r = runFrames(
      snes, c, NearStepFrames,
      proc(f: int): uint16 =
        if (f div 8) mod 2 == 0: 0x0080'u16 else: 0'u16,
      "APULSE", sampleEvery = 60
    )
    echo &"  APULSE derailed={r.derailed} first={r.firstFrame}"

  echo "--- TAS tail from 212944 with align offsets ---"
  for align in AlignGuesses:
    var (snes, c) = loadPngState(PngNear6)
    let maxF = min(NearStepFrames, lastDelta - align + 60)
    if maxF <= 0:
      echo &"  align={align}: skip (maxF={maxF})"
      continue
    echo &"  -- align={align} frames={maxF} (tas frame = align+f) --"
    let r = runFrames(
      snes, c, maxF,
      proc(f: int): uint16 = joyAtFrame(deltas, align + f),
      &"ALIGN{align}", sampleEvery = 120
    )
    echo &"  align={align} derailed={r.derailed} first={r.firstFrame} flags={r.lastFlags}"
    if r.derailed:
      break

  echo "--- also 212924 idle 900f ---"
  block:
    var (snes, c) = loadPngState(PngNear20)
    dumpCpu("near20 load", snes, c)
    let r = runFrames(
      snes, c, 900,
      proc(f: int): uint16 = 0'u16,
      "IDLE20", sampleEvery = 90
    )
    echo &"  IDLE20 derailed={r.derailed} first={r.firstFrame}"

proc phaseHook() =
  ## If we have a short repro path, re-run with writeHook tracing NMITIMEN / S-ish.
  ## Standalone: load crash + step 1 frame with hooks (post-mortem writes).
  echo "########## PHASE hook (post-crash + near6 watch) ##########"
  for (path, name, frames) in [
    (PngNear6, "near6", 360),
    (PngCrash, "crash", 30),
  ]:
    var (snes, c) = loadPngState(path)
    var nmiWrites: seq[string]
    var sWeird = 0
    var brkHits = 0
    var firstNmi = ""
    let prev = snes.bus.writeHook
    snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
      let bank = address shr 16
      let off = address and 0xFFFF
      # NMITIMEN $4200
      if off == 0x4200 and (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)):
        let line = &"  NMITIMEN write {value:02X} at PC={c.pbr:02X}:{c.pc:04X} S={c.s:04X}"
        if nmiWrites.len < 20:
          nmiWrites.add line
        if firstNmi.len == 0 and (value and 0x80) == 0:
          firstNmi = line
      if prev != nil:
        return prev(address, value)
      false
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for f in 0 ..< frames:
      snes.joy1 = 0
      # instruction-level watch inside frame via wrapping step is hard;
      # sample S and PC each frame
      policy.stepOneFrame(snes, c, img)
      if c.pbr == 0 and c.pc == 0x5FFF:
        inc brkHits
      if c.s >= 0x2000'u16:
        inc sWeird
      if f mod 60 == 0:
        echo &"  {name} f={f} cpu={c.pbr:02X}:{c.pc:04X} S={c.s:04X} nmi={snes.nmitimen:02X}"
    echo &"  {name}: brkHits={brkHits} sWeirdFrames={sWeird}"
    echo &"  first NMI-mask write: {firstNmi}"
    for line in nmiWrites:
      echo line

proc main() =
  ## Run selected phase(s).
  let phase =
    if paramCount() >= 1: paramStr(1).toLowerAscii()
    else: "all"
  doAssert fileExists(RomPath), &"need ROM at {RomPath}"
  case phase
  of "snap":
    phaseSnap()
  of "stack":
    phaseStack()
  of "replay":
    phaseReplay()
  of "near":
    phaseNear()
  of "hook":
    phaseHook()
  of "all":
    phaseSnap()
    phaseStack()
    phaseNear()
    phaseReplay()
    phaseHook()
  else:
    quit &"unknown phase {phase}; use snap|stack|replay|near|hook|all"

when isMainModule:
  main()
