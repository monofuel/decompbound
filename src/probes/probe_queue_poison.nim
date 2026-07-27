## §7D hunt: who writes poison into the $0400 CHR-DMA job queue.
## Phases: snap | idle | hunt | timing | apu | all
## Usage: nim r -d:release src/probes/probe_queue_poison.nim [phase] [extra]
## No product edits. No GUI. No audio.

import
  std/[algorithm, options, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, png_state, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PngHealthy = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212924.png"
  PngPoison = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"
  OutLog = "/tmp/queue_poison_probe.log"
  IdleFramesDefault = 900
  Align = 4500
  AlignMaxFrames = 80
  ## Legitimate enqueue STA sites (code_bank00 $C0865F core).
  EnqPcLo = 0x8681'u16
  EnqPcHi = 0x86A1'u16
  ## Drain updates $01 at $C08276.
  DrainStx01 = 0x8276'u16
  ## NMI CHR drain loop.
  DrainLoopLo = 0x8240'u16
  DrainLoopHi = 0x8276'u16
  ## APU ring drain / enqueue.
  ApuDrainLo = 0x8501'u16
  ApuDrainHi = 0x8515'u16
  ApuEnqLo = 0xABE0'u16
  ApuEnqHi = 0xAC00'u16

type
  WriteHit = object
    frame: int
    line: int
    busAddr: uint32
    value: uint8
    pbr: uint8
    pc: uint16
    regA, regX, regY, regS, regD: uint16
    dbr: uint8
    p: uint8
    nmiPending: bool
    q0, q1: uint8
    kind: string

proc loadRom(): seq[uint8] =
  ## ROM without optional copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc wram8(snes: SnesBus, off: int): uint8 =
  ## WRAM $7E byte.
  snes.bus.mem[0x7E0000 + off]

proc wram16(snes: SnesBus, off: int): uint16 =
  ## LE word in WRAM.
  wram8(snes, off).uint16 or (wram8(snes, off + 1).uint16 shl 8)

proc loadPng(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Load F12 ebSt into a fresh bus.
  doAssert fileExists(path), &"missing {path}"
  let st = extractState(cast[seq[uint8]](readFile(path)))
  doAssert st.isSome, &"no ebSt in {path}"
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  (snes, c)

proc classifyPc(pbr: uint8, pc: uint16, busAddr: uint32): string =
  ## Label write sites for queue hunt.
  let bank = busAddr shr 16
  let off = busAddr and 0xFFFF
  var p = pc
  if pbr == 0x00'u8 and pc >= 0x8000'u16:
    p = pc
  let inC0 = pbr == 0xC0'u8 or (pbr == 0x00'u8 and pc >= 0x8000'u16)
  if inC0:
    if p >= EnqPcLo and p <= EnqPcHi: return "enq_C0865F"
    if p == DrainStx01: return "drain_STX01"
    if p >= DrainLoopLo and p <= DrainLoopHi: return "drain_loop"
    if p >= ApuDrainLo and p <= ApuDrainHi: return "apu_drain"
    if p >= ApuEnqLo and p <= ApuEnqHi: return "apu_enq"
    if p >= 0x865F'u16 and p <= 0x86DD'u16: return "enq_wrapper"
    if p >= 0x8200'u16 and p <= 0x8390'u16: return "nmi_region"
  if off <= 0x01 and (bank == 0x7E or off < 0x2000):
    return "ptr_other"
  if off >= 0x0400 and off <= 0x04FF:
    return "slot_other"
  "other"

proc dumpJobs(snes: SnesBus, label: string, n = 32) =
  ## Hex-dump CHR-DMA job ring slots.
  echo &"=== jobs {label} $00={wram8(snes,0):02X} $01={wram8(snes,1):02X} ==="
  for i in 0 ..< n:
    let base = 0x400 + i * 8
    var line = &"  [{i:02}] @{base:04X}: "
    for b in 0 .. 7:
      line.add &"{wram8(snes, base + b):02X} "
    let typ = wram8(snes, base)
    let size = wram8(snes, base + 1).uint16 or (wram8(snes, base + 2).uint16 shl 8)
    let aLo = wram8(snes, base + 3).uint16 or (wram8(snes, base + 4).uint16 shl 8)
    let bank = wram8(snes, base + 5)
    let vram = wram8(snes, base + 6).uint16 or (wram8(snes, base + 7).uint16 shl 8)
    line.add &"  type={typ:02X} size={size:04X} A={bank:02X}:{aLo:04X} VRAM={vram:04X}"
    echo line

proc dumpApuRing(snes: SnesBus, label: string) =
  ## APU cmd ring + indices.
  echo &"=== apu ring {label} CA={wram8(snes,0xCA):02X} CB={wram8(snes,0xCB):02X} " &
    &"phase1ACA={wram8(snes,0x1ACA):02X} ==="
  var line = "  $1AC2: "
  for i in 0 .. 7:
    line.add &"{wram8(snes, 0x1AC2 + i):02X} "
  echo line

proc isWramLow(address: uint32): tuple[hit: bool, off: int] =
  ## Map bus addr → low-WRAM offset if in $0000–$04FF window.
  let bank = address shr 16
  let off = (address and 0xFFFF).int
  if bank == 0x7E or bank == 0x7F:
    if off <= 0x04FF:
      return (true, off)
  elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off <= 0x04FF:
    return (true, off)
  (false, -1)

proc stepFrameBudget(snes: SnesBus, cpu: var Cpu, image: Image, instrPerLine: int) =
  ## One frame with configurable InstrPerLine (NMI at line 224).
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if not forceBlank:
    let backdrop = ppu.bgr555ToColor(snes.cgram[0])
    image.fill(backdrop)
  var l = 0
  while l < 262:
    if l == 224:
      ppu.renderSprites(snes, image)
      ppu.overlayForegroundBg(snes, image)
      if (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
    for i in 0 ..< instrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if l < 224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc l
    if l >= 262:
      snes.initHdma()
      break

proc derailSig(snes: SnesBus, c: Cpu): string =
  ## Compact derail classifier.
  if c.pbr == 0 and c.pc == 0x5FFF: return "BRK_SINK"
  if c.pbr == 0 and c.pc == 0x9C69: return "FREE_LIST"
  if snes.dmaWramToA: return "DMA_WRAM_TOA"
  if wram16(snes, 0x20) == 0: return "NMI_VEC_ZERO"
  if (snes.nmitimen and 0x80) == 0 and c.pbr == 0: return "NMI_MASK_LO"
  ""

proc phaseSnap() =
  ## Compare $0400 poison presence on both F12 anchors.
  echo "======== SNAP ========"
  for (path, name) in [(PngHealthy, "212924"), (PngPoison, "212944")]:
    let (snes, c) = loadPng(path)
    echo &"--- {name} PC={c.pbr:02X}:{c.pc:04X} S={c.s:04X} D={c.d:04X} DBR={c.dbr:02X} ---"
    echo &"  $0020={wram16(snes,0x20):04X} NMITIMEN={snes.nmitimen:02X} " &
      &"INIDISP={snes.ppuRegs[0]:02X}"
    dumpJobs(snes, name, 32)
    dumpApuRing(snes, name)
    ## Count non-zero / "suspicious" types (bit7 of DMAP table often toA).
    var nonzero = 0
    var typeHist = initTable[uint8, int]()
    for i in 0 ..< 32:
      let base = 0x400 + i * 8
      var any = false
      for b in 0 .. 7:
        if wram8(snes, base + b) != 0: any = true
      if any: inc nonzero
      let t = wram8(snes, base)
      typeHist.mgetOrPut(t, 0) = typeHist.getOrDefault(t) + 1
    echo &"  non-empty slots: {nonzero}/32"
    var tops: seq[(int, uint8)] = @[]
    for t, n in typeHist:
      tops.add (n, t)
    tops.sort(proc(a, b: (int, uint8)): int = cmp(b[0], a[0]))
    var th = "  type hist: "
    for i, pair in tops:
      if i >= 8: break
      th.add &"{pair[1]:02X}x{pair[0]} "
    echo th

proc armQueueHook(snes: SnesBus, c: ptr Cpu, frame, line: ptr int,
    hits: ptr seq[WriteHit], logAll: bool, maxHits: int) =
  ## Install writeHook logger for $0000–$04FF.
  let prev = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let (hit, off) = isWramLow(address)
    if hit and hits[].len < maxHits:
      let kind = classifyPc(c.pbr, c.pc, address)
      let interesting =
        logAll or
        kind notin ["enq_C0865F", "drain_STX01", "drain_loop", "enq_wrapper"] or
        off <= 0x01 or
        (off >= 0x0400 and kind == "slot_other")
      ## Always log pointer writes and non-enqueue slot writes; sample enq if logAll.
      if interesting or (logAll and (off <= 0x01 or off >= 0x0400)):
        hits[].add WriteHit(
          frame: frame[],
          line: line[],
          busAddr: address,
          value: value,
          pbr: c.pbr,
          pc: c.pc,
          regA: c.a, regX: c.x, regY: c.y, regS: c.s, regD: c.d,
          dbr: c.dbr, p: c.p,
          nmiPending: c.nmiPending,
          q0: wram8(snes, 0), q1: wram8(snes, 1),
          kind: kind)
    if prev != nil:
      return prev(address, value)
    false

proc formatHit(h: WriteHit): string =
  ## One log line.
  &"f={h.frame} L={h.line} {h.kind} PC={h.pbr:02X}:{h.pc:04X} " &
    &"write ${h.busAddr:06X}={h.value:02X} A={h.regA:04X} X={h.regX:04X} Y={h.regY:04X} " &
    &"S={h.regS:04X} D={h.regD:04X} DBR={h.dbr:02X} P={h.p:02X} " &
    &"nmiP={h.nmiPending} q={h.q0:02X}/{h.q1:02X}"

proc runIdleHunt(png: string, frames, instrPerLine: int, logAll: bool,
    tag: string): tuple[derailAt: int, sig: string, hits: seq[WriteHit],
    endQ0, endQ1: uint8, firstAbnormal: string] =
  ## Idle from F12 with write logging.
  let (snes, c0) = loadPng(png)
  var c = c0
  var frame = 0
  var line = 0
  var hits: seq[WriteHit]
  armQueueHook(snes, c.addr, frame.addr, line.addr, hits.addr, logAll, 200_000)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var derailAt = -1
  var sig = ""
  var firstAbn = ""
  ## Track slot digests to detect first poison-looking type in active span later.
  for f in 0 ..< frames:
    frame = f
    snes.joy1 = 0
    ## Manual frame with line tracking for NMI window.
    let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
    if not forceBlank:
      img.fill(ppu.bgr555ToColor(snes.cgram[0]))
    var l = 0
    while l < 262:
      line = l
      if l == 224:
        ppu.renderSprites(snes, img)
        ppu.overlayForegroundBg(snes, img)
        if (snes.nmitimen and 0x80) != 0:
          c.nmiPending = true
      for i in 0 ..< instrPerLine:
        c.step(snes.bus)
        if c.stopped: break
      if l < 224:
        snes.runHdma()
        if (snes.ppuRegs[0x00] and 0x80) == 0:
          ppu.renderScanline(snes, img, l)
      for k in 0 ..< 2:
        discard snes.tickApu()
      inc l
      if l >= 262:
        snes.initHdma()
        break
    if firstAbn.len == 0:
      for h in hits:
        if h.frame == f and h.kind in ["slot_other", "ptr_other", "other"]:
          if (h.busAddr and 0xFFFF) <= 0x04FF:
            firstAbn = formatHit(h)
            break
    let d = derailSig(snes, c)
    if d.len > 0 and derailAt < 0:
      derailAt = f
      sig = d
      echo &"[{tag}] DERAIL f={f} {d} PC={c.pbr:02X}:{c.pc:04X} " &
        &"$0020={wram16(snes,0x20):04X} q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
        &"dmaWramToA={snes.dmaWramToA}"
      break
    if f mod 100 == 0 or f == frames - 1:
      echo &"[{tag}] f={f} PC={c.pbr:02X}:{c.pc:04X} q={wram8(snes,0):02X}/" &
        &"{wram8(snes,1):02X} $20={wram16(snes,0x20):04X} hits={hits.len}"
  result.derailAt = derailAt
  result.sig = sig
  result.hits = hits
  result.endQ0 = wram8(snes, 0)
  result.endQ1 = wram8(snes, 1)
  result.firstAbnormal = firstAbn

proc summarizeHits(hits: seq[WriteHit], tag: string) =
  ## Aggregate writers by kind/PC.
  var byKind = initTable[string, int]()
  var byPc = initTable[string, int]()
  var slotOther: seq[WriteHit]
  var ptrOther: seq[WriteHit]
  for h in hits:
    byKind.mgetOrPut(h.kind, 0) = byKind.getOrDefault(h.kind) + 1
    let key = &"{h.pbr:02X}:{h.pc:04X}/{h.kind}"
    byPc.mgetOrPut(key, 0) = byPc.getOrDefault(key) + 1
    if h.kind == "slot_other": slotOther.add h
    if h.kind == "ptr_other": ptrOther.add h
  echo &"=== hit summary {tag} total={hits.len} ==="
  for k, n in byKind:
    echo &"  kind {k}: {n}"
  var pcs: seq[(int, string)] = @[]
  for k, n in byPc:
    pcs.add (n, k)
  pcs.sort(proc(a, b: (int, string)): int = cmp(b[0], a[0]))
  echo "  top PCs:"
  for i, pair in pcs:
    if i >= 25: break
    echo &"    {pair[0]:5}  {pair[1]}"
  echo &"  slot_other samples ({min(40, slotOther.len)} of {slotOther.len}):"
  for i, h in slotOther:
    if i >= 40: break
    echo &"    {formatHit(h)}"
  echo &"  ptr_other samples ({min(40, ptrOther.len)} of {ptrOther.len}):"
  for i, h in ptrOther:
    if i >= 40: break
    echo &"    {formatHit(h)}"

proc phaseIdle() =
  ## Default idle 900f from 212924 with abnormal-only logging.
  echo "======== IDLE 212924 900f InstrPerLine=150 ========"
  let r = runIdleHunt(PngHealthy, IdleFramesDefault, 150, false, "idle150")
  summarizeHits(r.hits, "idle150")
  if r.firstAbnormal.len > 0:
    echo &"FIRST_ABNORMAL: {r.firstAbnormal}"
  echo &"result derailAt={r.derailAt} sig={r.sig} hits={r.hits.len}"

proc phaseHunt() =
  ## Full log of all queue-region writes; also ALIGN4500 path.
  echo "======== HUNT idle 212924 (logAll, 900f) ========"
  let r = runIdleHunt(PngHealthy, IdleFramesDefault, 150, true, "hunt150")
  summarizeHits(r.hits, "hunt150")
  ## Persist raw hits (capped).
  var lines: seq[string]
  lines.add &"# hunt150 derail={r.derailAt} sig={r.sig} n={r.hits.len}"
  let cap = min(r.hits.len, 50_000)
  for i in 0 ..< cap:
    lines.add formatHit(r.hits[i])
  writeFile(OutLog, lines.join("\n") & "\n")
  echo &"wrote {cap} hits to {OutLog}"

  echo "======== HUNT ALIGN4500 from 212944 ========"
  let (snes, c0) = loadPng(PngPoison)
  var c = c0
  let (_, deltas) = parseReplay(SessionTas)
  var frame = 0
  var line = 0
  var hits: seq[WriteHit]
  armQueueHook(snes, c.addr, frame.addr, line.addr, hits.addr, true, 200_000)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for f in 0 ..< AlignMaxFrames:
    frame = f
    let absF = Align + f
    snes.joy1 = joyAtFrame(deltas, absF)
    stepFrameBudget(snes, c, img, 150)
    let d = derailSig(snes, c)
    if d.len > 0:
      echo &"[align] DERAIL f=+{f} {d} PC={c.pbr:02X}:{c.pc:04X} " &
        &"q={wram8(snes,0):02X}/{wram8(snes,1):02X} $20={wram16(snes,0x20):04X}"
      break
    if f mod 10 == 0:
      echo &"[align] +{f} PC={c.pbr:02X}:{c.pc:04X} q={wram8(snes,0):02X}/" &
        &"{wram8(snes,1):02X} hits={hits.len}"
  summarizeHits(hits, "align4500")
  ## Last 80 abnormal slot writes before end.
  var ab: seq[WriteHit]
  for h in hits:
    if h.kind in ["slot_other", "ptr_other"]:
      ab.add h
  echo &"align abnormal total={ab.len}; last 60:"
  let start = max(0, ab.len - 60)
  for i in start ..< ab.len:
    echo &"  {formatHit(ab[i])}"

proc phaseTiming() =
  ## InstrPerLine sensitivity on 212924 idle.
  echo "======== TIMING InstrPerLine sweep ========"
  for ipl in [100, 150, 200, 250]:
    let r = runIdleHunt(PngHealthy, IdleFramesDefault, ipl, false, &"ipl{ipl}")
    echo &"RESULT ipl={ipl} derailAt={r.derailAt} sig={r.sig} " &
      &"hits_abn={r.hits.len} firstAbn={r.firstAbnormal}"
    ## Count kinds quickly.
    var kinds = initTable[string, int]()
    for h in r.hits:
      kinds.mgetOrPut(h.kind, 0) = kinds.getOrDefault(h.kind) + 1
    echo &"  kinds: {kinds}"

proc phaseApu() =
  ## Check shared-register coupling between APU ring and CHR queue.
  echo "======== APU vs CHR queue coupling ========"
  echo "APU enqueue $C0ABE0: uses X from $00CA, writes $1AC2,X; indices $CA/$CB."
  echo "CHR enqueue $C0865F: uses Y from $00, writes $0400,Y; pointers $00/$01."
  echo "APU NMI drain $C08501: X=$CB; CHR drain $C0823C: X=$01 (8-bit)."
  echo "Both NMI paths use X; sequential in NMI (CHR first then later APU) —"
  echo "not concurrent. Mid-append NMI would save/restore if game PHX/PHY…"
  ## Check whether enqueue disables IRQs / NMI.
  echo "Enqueue path C08643: PHP … PLP — does NOT SEI; NMI can fire mid-append."
  echo "Overflow spin C0869D: CPY $01 / BEQ -4 — waits for NMI drain of $01."
  ## Live: from 212944, watch $CA/$CB vs $00/$01 over ALIGN frames.
  let (snes, c0) = loadPng(PngPoison)
  var c = c0
  let (_, deltas) = parseReplay(SessionTas)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo "ALIGN4500 CA/CB vs q00/q01 samples:"
  for f in 0 ..< AlignMaxFrames:
    snes.joy1 = joyAtFrame(deltas, Align + f)
    stepFrameBudget(snes, c, img, 150)
    if f mod 5 == 0 or f < 5:
      echo &"  +{f} q={wram8(snes,0):02X}/{wram8(snes,1):02X} " &
        &"CA/CB={wram8(snes,0xCA):02X}/{wram8(snes,0xCB):02X} " &
        &"PC={c.pbr:02X}:{c.pc:04X} $20={wram16(snes,0x20):04X}"
    let d = derailSig(snes, c)
    if d.len > 0:
      echo &"  derail +{f} {d}"
      break

proc main() =
  ## Dispatch phase.
  doAssert fileExists(RomPath), "need ROM"
  let phase = if paramCount() >= 1: paramStr(1) else: "all"
  case phase
  of "snap": phaseSnap()
  of "idle": phaseIdle()
  of "hunt": phaseHunt()
  of "timing": phaseTiming()
  of "apu": phaseApu()
  of "all":
    phaseSnap()
    phaseIdle()
    phaseHunt()
    phaseTiming()
    phaseApu()
  else:
    echo &"unknown phase {phase}; use snap|idle|hunt|timing|apu|all"
    quit(1)

main()
