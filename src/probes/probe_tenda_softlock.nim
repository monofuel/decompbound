## Headless autopsy of the 2026-07-26 Tenda Village softlock.
## Loads the F12 hang PNG (ebSt), the dropped pre-session PNG, and replays
## session B's .tas. No GUI. Usage:
##   nim r -d:release src/probes/probe_tenda_softlock.nim [phase]
## phase: hang | drop | replay | all (default)

import
  std/[algorithm, options, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[apu, cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  HangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-202823.png"
  DropPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260725-190533.png"
  SessionBTas = "bin/sessions/20260726-202718/20260726-202722.tas"
  InstrHistN = 20_000
  FrameHistN = 30
  DropStepFrames = 600
  ReplaySampleEvery = 30
  ReplayStuckWindow = 120
  ## Known APU wait sites (SNES addr, name).
  WaitSites = [
    (0xC0AB80'u32, 0xC0AB95'u32, "upload_handshake_AB8x"),
    (0xC0ABBD'u32, 0xC0ABC5'u32, "writeApuPort0"),
    (0xC0ABC6'u32, 0xC0ABDF'u32, "waitApuIdleClearSong"),
    (0xC0ABE0'u32, 0xC0AC00'u32, "queueApuCommand"),
    (0xC0AC01'u32, 0xC0AC0B'u32, "writeApuPort3Cmd57"),
    (0xC0AC0C'u32, 0xC0AC1F'u32, "writeApuPort1Toggled"),
    (0xC0AC20'u32, 0xC0AC2F'u32, "readApuPort0"),
    (0xC4FBBD'u32, 0xC4FD40'u32, "loadSong"),
  ]

type
  Snap = object
    pbr: uint8
    pc: uint16
    a, x, y, s: uint16
    p: uint8
    stopped: bool
    nmi: bool
    spcPc: uint16
    spcStopped: bool
    ipl: bool
    portsIn: array[4, uint8]
    portsOut: array[4, uint8]
    t0: bool
    inidisp: uint8
    catchup: int
    topPc: string
    topPct: float
    mmio214x: int
    nonzeroSamples: int
    peakAbs: int

proc fullAddr(pbr: uint8, pc: uint16): uint32 =
  ## 24-bit SNES address from PBR:PC.
  (pbr.uint32 shl 16) or pc.uint32

proc nameSite(pbr: uint8, pc: uint16): string =
  ## Match PC against known wait / audio sites.
  let a = fullAddr(pbr, pc)
  for (lo, hi, name) in WaitSites:
    if a >= lo and a <= hi:
      return name
  if pbr >= 0xC0 and pbr <= 0xFF:
    return "rom_code"
  if pbr == 0x7E or pbr == 0x7F:
    return "WRAM_exec"
  if pbr <= 0x3F or (pbr >= 0x80 and pbr <= 0xBF):
    if pc < 0x8000:
      return "LOW_RAM_or_mmio"
    return "lo_rom_mirror"
  if pbr >= 0x40 and pbr <= 0x7D:
    return "exhirom_or_sram"
  &"other_bank_{pbr:02X}"

proc dumpSnap(label: string, snes: SnesBus, c: Cpu, s: Snap) =
  ## Print a machine-state snapshot.
  echo &"=== {label} ==="
  echo &"  CPU  {c.pbr:02X}:{c.pc:04X}  A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} P={c.p:02X}"
  echo &"       stopped={c.stopped} nmiPending={c.nmiPending} site={nameSite(c.pbr, c.pc)}"
  echo &"  SPC  pc={snes.apu.spc.pc:04X} stopped={snes.apu.spc.stopped} ipl={snes.apu.spc.iplEnabled}"
  echo &"  T0   enabled={snes.apu.timer0Enabled()}"
  echo &"  portsIn  [{snes.apu.portsIn[0]:02X} {snes.apu.portsIn[1]:02X} {snes.apu.portsIn[2]:02X} {snes.apu.portsIn[3]:02X}]"
  echo &"  portsOut [{snes.apu.portsOut[0]:02X} {snes.apu.portsOut[1]:02X} {snes.apu.portsOut[2]:02X} {snes.apu.portsOut[3]:02X}]"
  echo &"  INIDISP={snes.ppuRegs[0x00]:02X} catchup={snes.apuPortCatchup}"
  if s.topPc.len > 0:
    echo &"  topPC {s.topPc} ({s.topPct*100:.1f}%) mmio214x={s.mmio214x}"
  if s.nonzeroSamples > 0 or s.peakAbs > 0:
    echo &"  audio samples nonzero={s.nonzeroSamples} peakAbs={s.peakAbs}"

proc takeSnap(snes: SnesBus, c: Cpu): Snap =
  ## Capture current state fields into a Snap.
  result.pbr = c.pbr
  result.pc = c.pc
  result.a = c.a
  result.x = c.x
  result.y = c.y
  result.s = c.s
  result.p = c.p
  result.stopped = c.stopped
  result.nmi = c.nmiPending
  result.spcPc = snes.apu.spc.pc
  result.spcStopped = snes.apu.spc.stopped
  result.ipl = snes.apu.spc.iplEnabled
  result.portsIn = snes.apu.portsIn
  result.portsOut = snes.apu.portsOut
  result.t0 = snes.apu.timer0Enabled()
  result.inidisp = snes.ppuRegs[0x00]
  result.catchup = snes.apuPortCatchup

proc loadRom(): seq[uint8] =
  ## ROM bytes without optional copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc loadPngState(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Extract ebSt from PNG and deserialize into a fresh bus+cpu.
  doAssert fileExists(path), &"missing {path}"
  let raw = cast[seq[uint8]](readFile(path))
  let st = extractState(raw)
  doAssert st.isSome, &"no ebSt chunk in {path}"
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  (snes, c)

proc loadFileState(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Deserialize a .state file into a fresh bus+cpu.
  doAssert fileExists(path), &"missing {path}"
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc histogramPc(snes: SnesBus, c: var Cpu, n: int): seq[(uint32, int)] =
  ## Step `n` instructions; return (addr, count) sorted by count desc.
  var hist = initTable[uint32, int]()
  for _ in 0 ..< n:
    let a = fullAddr(c.pbr, c.pc)
    hist.mgetOrPut(a, 0) = hist.getOrDefault(a) + 1
    c.step(snes.bus)
    if c.stopped:
      break
  var pairs: seq[(uint32, int)]
  for k, v in hist:
    pairs.add (k, v)
  pairs.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))
  pairs

proc count214xInFrame(snes: SnesBus): int =
  ## Count $214x entries currently in mmioReads (call before next clear).
  for a in snes.mmioReads:
    if a >= 0x2140 and a <= 0x2143:
      inc result

proc countMmio214x(snes: SnesBus, c: var Cpu, frames: int): tuple[polls: int, peakPerFrame: int, framesAtCap: int] =
  ## Step frames with MMIO trace; count $214x reads (catchup resets in initHdma).
  snes.recordMmioTrace = true
  snes.mmioReads.setLen(0)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 ..< frames:
    snes.mmioReads.setLen(0)
    policy.stepOneFrame(snes, c, img)
    # Catchup is zeroed in initHdma at end of frame — use poll count as proxy.
    let n = count214xInFrame(snes)
    result.polls += n
    if n > result.peakPerFrame:
      result.peakPerFrame = n
    if n >= 512:
      inc result.framesAtCap
  snes.recordMmioTrace = false

proc measureAudio(snes: SnesBus, ticks: int): tuple[nonzero: int, peak: int] =
  ## Tick APU `ticks` times; count nonzero samples and peak abs.
  var nonzero = 0
  var peak = 0
  for _ in 0 ..< ticks:
    let (l, r) = snes.tickApu()
    let al = if l < 0: -l.int else: l.int
    let ar = if r < 0: -r.int else: r.int
    if al > 0 or ar > 0:
      inc nonzero
    if al > peak: peak = al
    if ar > peak: peak = ar
  (nonzero, peak)

proc spcHist(snes: SnesBus, ticks: int): seq[(uint16, int)] =
  ## Tick APU; histogram SPC PC.
  var hist = initTable[uint16, int]()
  for _ in 0 ..< ticks:
    discard snes.tickApu()
    let p = snes.apu.spc.pc
    hist.mgetOrPut(p, 0) = hist.getOrDefault(p) + 1
  var pairs: seq[(uint16, int)]
  for k, v in hist:
    pairs.add (k, v)
  pairs.sort(proc(a, b: (uint16, int)): int = cmp(b[1], a[1]))
  pairs

proc printHist(pairs: seq[(uint32, int)], total: int, limit = 15) =
  ## Print top PC histogram rows.
  let n = min(limit, pairs.len)
  for i in 0 ..< n:
    let (a, cnt) = pairs[i]
    let pbr = (a shr 16).uint8
    let pc = (a and 0xFFFF).uint16
    let pct = 100.0 * cnt.float / total.float
    echo &"    {pbr:02X}:{pc:04X}  n={cnt:6d} ({pct:5.1f}%)  {nameSite(pbr, pc)}"

proc printSpcHist(pairs: seq[(uint16, int)], total: int, limit = 10) =
  ## Print top SPC PC rows.
  let n = min(limit, pairs.len)
  for i in 0 ..< n:
    let (pc, cnt) = pairs[i]
    let pct = 100.0 * cnt.float / total.float
    echo &"    SPC {pc:04X}  n={cnt:6d} ({pct:5.1f}%)"

proc phaseHang() =
  ## Autopsy the F12-at-hang PNG.
  echo "########## PHASE hang: F12 at softlock ##########"
  var (snes, c) = loadPngState(HangPng)
  var snap = takeSnap(snes, c)
  dumpSnap("hang load (immediate)", snes, c, snap)

  # Instruction-level PC histogram (tight loop finder).
  let pairs = histogramPc(snes, c, InstrHistN)
  echo &"  PC histogram over {InstrHistN} instructions after hang load:"
  printHist(pairs, InstrHistN)
  if pairs.len > 0:
    let (topA, topN) = pairs[0]
    snap.topPc = &"{(topA shr 16):02X}:{(topA and 0xFFFF):04X}"
    snap.topPct = topN.float / InstrHistN.float

  # Reload for clean frame-level poll count (histogram already stepped).
  (snes, c) = loadPngState(HangPng)
  let (polls, peak, atCap) = countMmio214x(snes, c, FrameHistN)
  echo &"  over {FrameHistN} frames: $214x polls={polls} peak/frame={peak} framesAtCap(>=512)={atCap}"
  snap = takeSnap(snes, c)
  dumpSnap(&"hang after {FrameHistN} idle frames", snes, c, snap)

  # SPC activity + audio energy without CPU driving.
  (snes, c) = loadPngState(HangPng)
  let (nz, peakAbs) = measureAudio(snes, 8000)
  echo &"  APU-only 8000 ticks: nonzeroSamples={nz} peakAbs={peakAbs}"
  let sh = spcHist(snes, 4000)
  echo "  SPC PC histogram (4000 more ticks):"
  printSpcHist(sh, 4000)

  # Stack peek near S (bank 0 mirrors WRAM low).
  (snes, c) = loadPngState(HangPng)
  echo &"  stack near S={c.s:04X} (bank 0 / $7E):"
  let sBase = c.s.int
  for off in -8 .. 8:
    let stackOff = (sBase + off) and 0xFFFF
    let v = snes.bus.mem[0x7E0000 + stackOff]
    echo &"    ${stackOff:04X}: {v:02X}"

  # WRAM flags commonly involved in dialogue / APU.
  echo "  WRAM APU-related:"
  for (name, off) in [
    ("CurrentSongId $B53B", 0xB53B),
    ("MusicWarmFlag $B4B6", 0xB4B6),
    ("ApuCmdQueueIndex $00CA", 0x00CA),
    ("ApuCmdPhaseLatch $1ACA", 0x1ACA),
    ("ApuPort1PhaseLatch $1ACB", 0x1ACB),
  ]:
    let lo = snes.bus.mem[0x7E0000 + off]
    let hi = snes.bus.mem[0x7E0000 + off + 1]
    if off in [0xB53B, 0xB4B6]:
      echo &"    {name} = {lo:02X}{hi:02X} (le word {lo.int or (hi.int shl 8):04X})"
    else:
      echo &"    {name} = {lo:02X}"

proc phaseDrop() =
  ## Check whether the dropped Tenda savestate already has a dead APU.
  echo "########## PHASE drop: pre-session PNG (no audio from load) ##########"
  var (snes, c) = loadPngState(DropPng)
  var snap = takeSnap(snes, c)
  dumpSnap("drop load (immediate)", snes, c, snap)

  let pairs0 = histogramPc(snes, c, 5000)
  echo "  PC hist 5k instr right after load:"
  printHist(pairs0, 5000, 8)

  (snes, c) = loadPngState(DropPng)
  let (nz0, peak0) = measureAudio(snes, 4000)
  echo &"  APU-only at load: nonzero={nz0} peakAbs={peak0}"
  let sh0 = spcHist(snes, 2000)
  echo "  SPC hist at load:"
  printSpcHist(sh0, 2000, 8)

  # Step 600 frames with no input (user: is music playing?).
  (snes, c) = loadPngState(DropPng)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var totalNz = 0
  var totalPeak = 0
  var pollsPeak = 0
  var pollsSum = 0
  var pollsFrames = 0
  var framesAtCap = 0
  snes.recordMmioTrace = true
  for f in 0 ..< DropStepFrames:
    snes.mmioReads.setLen(0)
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    let n = count214xInFrame(snes)
    pollsSum += n
    if n > pollsPeak: pollsPeak = n
    if n > 0: inc pollsFrames
    if n >= 512: inc framesAtCap
    if f mod 60 == 59:
      let (nz, pk) = measureAudio(snes, 533)
      totalNz += nz
      if pk > totalPeak: totalPeak = pk
  snes.recordMmioTrace = false
  snap = takeSnap(snes, c)
  dumpSnap(&"drop after {DropStepFrames} idle frames", snes, c, snap)
  echo &"  audio energy samples (every 60f x533): nonzero={totalNz} peakAbs={totalPeak}"
  echo &"  frames with any $214x poll: {pollsFrames}/{DropStepFrames}"
  echo &"  $214x peak/frame={pollsPeak} avg={pollsSum.float / DropStepFrames.float:.1f} atCap={framesAtCap}"

  let pairs1 = histogramPc(snes, c, 5000)
  echo "  PC hist 5k instr after idle:"
  printHist(pairs1, 5000, 8)
  let sh1 = spcHist(snes, 2000)
  echo "  SPC hist after idle:"
  printSpcHist(sh1, 2000, 8)

proc phaseReplay() =
  ## Replay session B TAS; find divergence into hang.
  echo "########## PHASE replay: session B TAS ##########"
  doAssert fileExists(SessionBTas), &"missing {SessionBTas}"
  let (hdr, deltas) = parseReplay(SessionBTas)
  echo &"  tas={SessionBTas}"
  echo &"  start_state={hdr.startStateRef} build={hdr.buildCommit}"
  doAssert fileExists(hdr.startStateRef), &"missing start state {hdr.startStateRef}"
  let lastDelta = if deltas.len > 0: deltas[^1].frame else: 0
  let lastF = lastDelta + 180  # a few extra seconds after last input
  echo &"  last delta frame={lastDelta}; replaying to {lastF}"

  var (snes, c) = loadFileState(hdr.startStateRef)
  var snap0 = takeSnap(snes, c)
  dumpSnap("replay start", snes, c, snap0)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var prevTop = 0'u32
  var stuckFrames = 0
  var hangFrame = -1
  var hangSnap = Snap()
  var preHangFrame = -1
  var preHangSnap = Snap()
  var firstA = -1
  var lastA = -1

  # Also track when PC top becomes a single address >90%.
  snes.recordMmioTrace = true
  for f in 0 .. lastF:
    let joy = joyAtFrame(deltas, f)
    snes.joy1 = joy
    if (joy and 0x0080) != 0:
      if firstA < 0: firstA = f
      lastA = f
    snes.mmioReads.setLen(0)
    policy.stepOneFrame(snes, c, img)
    let polls = count214xInFrame(snes)

    if f mod ReplaySampleEvery == 0 or f == lastF or f == lastDelta:
      let a = fullAddr(c.pbr, c.pc)
      if a == prevTop:
        stuckFrames += ReplaySampleEvery
      else:
        stuckFrames = 0
        prevTop = a
      let (nz, pk) = measureAudio(snes, 64)
      echo &"  f={f:5d} joy={joy:04X} cpu={c.pbr:02X}:{c.pc:04X} site={nameSite(c.pbr, c.pc)} " &
        &"spc={snes.apu.spc.pc:04X} pin=[{snes.apu.portsIn[0]:02X}{snes.apu.portsIn[1]:02X}" &
        &"{snes.apu.portsIn[2]:02X}{snes.apu.portsIn[3]:02X}] " &
        &"pout=[{snes.apu.portsOut[0]:02X}{snes.apu.portsOut[1]:02X}" &
        &"{snes.apu.portsOut[2]:02X}{snes.apu.portsOut[3]:02X}] " &
        &"polls214x={polls} t0={snes.apu.timer0Enabled()} " &
        &"inidisp={snes.ppuRegs[0x00]:02X} audio64 nz={nz} pk={pk}"

    # Hang candidate: known wait site, or heavy $214x poll, after last input settled.
    if f >= lastDelta and hangFrame < 0 and (f - lastDelta) mod 30 == 0:
      let site = nameSite(c.pbr, c.pc)
      let waitish =
        site in ["waitApuIdleClearSong", "readApuPort0", "upload_handshake_AB8x"] or
        polls >= 400 or
        c.stopped
      if waitish and (f - lastDelta) > 60:
        hangFrame = f
        hangSnap = takeSnap(snes, c)
        echo &"  ** hang candidate at f={f}: site={site} polls214x={polls}"
  snes.recordMmioTrace = false

  echo &"  first A frame={firstA} last A frame={lastA}"
  echo &"  hangFrame={hangFrame}"

  # Deep hist at end of replay.
  echo "  end-of-replay PC hist 20k instr:"
  let pairs = histogramPc(snes, c, InstrHistN)
  printHist(pairs, InstrHistN)
  let snapE = takeSnap(snes, c)
  dumpSnap("replay end", snes, c, snapE)

  # Second pass: find first frame where PC enters the hang loop and dump N frames before.
  echo "  --- second pass: find first entry into top hang PC ---"
  (snes, c) = loadFileState(hdr.startStateRef)
  # First get hang top PC from a full run end... use pairs[0] if available.
  var hangTop = 0'u32
  if pairs.len > 0:
    hangTop = pairs[0][0]
  echo &"  tracking hang top addr {hangTop shr 16:02X}:{hangTop and 0xFFFF:04X}"

  var entered = -1
  var snapshots: seq[(int, Snap)]
  for f in 0 .. lastF:
    snes.joy1 = joyAtFrame(deltas, f)
    policy.stepOneFrame(snes, c, img)
    let a = fullAddr(c.pbr, c.pc)
    if entered < 0 and hangTop != 0 and a == hangTop:
      entered = f
      hangSnap = takeSnap(snes, c)
      echo &"  first saw hang-top PC at f={f}"
      dumpSnap(&"at hang entry f={f}", snes, c, hangSnap)
      # Keep going a bit to confirm stuck.
    if entered >= 0 and f == entered + 5:
      let pairsConfirm = histogramPc(snes, c, 2000)
      echo "  +5 frames hist:"
      printHist(pairsConfirm, 2000, 5)
      break
    # Keep rolling pre-hang window of snaps every 10 frames near last A.
    if lastA > 0 and f >= lastA - 90 and f <= lastA + 30 and f mod 10 == 0:
      snapshots.add (f, takeSnap(snes, c))

  if entered < 0:
    echo "  never saw exact hang-top PC during replay; dumping near last A presses"
    (snes, c) = loadFileState(hdr.startStateRef)
    for f in 0 .. lastF:
      snes.joy1 = joyAtFrame(deltas, f)
      policy.stepOneFrame(snes, c, img)
      if lastA > 0 and f >= lastA - 30 and f <= min(lastF, lastA + 180) and f mod 15 == 0:
        let s = takeSnap(snes, c)
        echo &"  f={f} cpu={c.pbr:02X}:{c.pc:04X} site={nameSite(c.pbr, c.pc)} " &
          &"spc={snes.apu.spc.pc:04X} pout0={snes.apu.portsOut[0]:02X} pin0={snes.apu.portsIn[0]:02X} " &
          &"catch={snes.apuPortCatchup}"
    echo "  final hist:"
    let p2 = histogramPc(snes, c, InstrHistN)
    printHist(p2, InstrHistN)

  # Pre-hang dump: reload and stop N frames before hang entry.
  if entered > 30:
    echo &"  --- dump ~30 frames before hang entry ({entered - 30}) ---"
    (snes, c) = loadFileState(hdr.startStateRef)
    for f in 0 ..< entered - 30:
      snes.joy1 = joyAtFrame(deltas, f)
      policy.stepOneFrame(snes, c, img)
    preHangFrame = entered - 30
    preHangSnap = takeSnap(snes, c)
    dumpSnap(&"pre-hang f={preHangFrame}", snes, c, preHangSnap)
    let ph = histogramPc(snes, c, 5000)
    echo "  pre-hang PC hist:"
    printHist(ph, 5000, 10)
    let (nz, pk) = measureAudio(snes, 2000)
    echo &"  pre-hang audio: nonzero={nz} peakAbs={pk}"
    let sh = spcHist(snes, 1000)
    echo "  pre-hang SPC hist:"
    printSpcHist(sh, 1000, 8)

  discard preHangSnap
  discard hangSnap
  discard snapshots

proc main() =
  ## Run selected diagnostic phase(s).
  let phase =
    if paramCount() >= 1: paramStr(1).toLowerAscii()
    else: "all"
  doAssert fileExists(RomPath), &"need ROM at {RomPath}"
  case phase
  of "hang":
    phaseHang()
  of "drop":
    phaseDrop()
  of "replay":
    phaseReplay()
  of "all":
    phaseHang()
    phaseDrop()
    phaseReplay()
  else:
    quit &"unknown phase {phase}; use hang|drop|replay|all"

when isMainModule:
  main()
