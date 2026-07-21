## Headless live-trace tool: frame-to-frame observation of WRAM, PPU regs,
## DMA/HDMA and APU port activity without modifying the emulator core.
## Snapshots public state each frame and diffs to log only interesting changes.
## Traces land in bin/trace.log (git-ignored per AGENTS.md). Use to crack
## dynamic frontiers (enemy AI, sector recompute, overworld loads, song start).
##
## Usage:
##   nim r src/tools/trace_tool.nim <rom> [--frames N] [--load-srm] [--watch LO-HI|addr,addr] [--from-frame N]
##
## --frames N        Stop after N frames (default 300).
## --load-srm        Load matching .srm next to ROM (like play.nim) to reach real game state.
## --watch LO-HI     WRAM filter range (hex). LO/HI may be 0000-FFFF (implies 7E), 7E0000-7EFFFF,
##                   7F0000-..., or full. Only log WRAM changes inside range. Comma list also
##                   supported for discrete addrs (e.g. 7E00B4,7E0024).
## --from-frame N    Begin emitting log entries only after this frame (default 0).
##
## The tool is read-only on emulator state: copy + diff only. No hooks, no mutation of snesbus.

import
  std/[os, sets, strformat, strutils],
  ../decompbound/[cpu, snesbus]

const
  DefaultFrames = 300
  InstrPerLine = 30

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc sramPathFor(romPath: string): string =
  ## The battery-save sits next to the ROM with .srm extension.
  romPath.changeFileExt("srm")

proc loadSram(snes: SnesBus, path: string) =
  ## Load battery save into SRAM if the file exists.
  if fileExists(path):
    let data = readFile(path)
    for i in 0 ..< min(data.len, snes.sram.len):
      snes.sram[i] = data[i].uint8
    echo "loaded save: ", path, " (", data.len, " bytes)"

proc normalizeWramAddr(a: uint32): uint32 =
  ## Treat bare offsets < 0x10000 as 7E:xxxx. Pass through 7E/7F full addresses.
  if a <= 0xFFFF'u32:
    return 0x7E0000'u32 or a
  let bank = (a shr 16) and 0xFF
  if bank == 0x7E or bank == 0x7F:
    return a and 0x00FFFFFF'u32
  a

proc main() =
  ## Run emulator headless for requested frames, diff public state each frame end,
  ## and append detailed change log to bin/trace.log.
  if paramCount() < 1:
    echo "Usage: nim r src/tools/trace_tool.nim <rom> [--frames N] [--load-srm] [--watch LO-HI|list] [--from-frame N]"
    quit(1)

  var
    romPath = ""
    maxFrames = DefaultFrames
    loadSrm = false
    watchStr = ""
    fromFrame = 0
    i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif arg.startsWith("--frames="):
      maxFrames = parseInt(arg[9 .. ^1])
    elif arg == "--load-srm":
      loadSrm = true
    elif arg == "--watch" and i < paramCount():
      inc i
      watchStr = paramStr(i)
    elif arg.startsWith("--watch="):
      watchStr = arg[8 .. ^1]
    elif arg == "--from-frame" and i < paramCount():
      inc i
      fromFrame = parseInt(paramStr(i))
    elif arg.startsWith("--from-frame="):
      fromFrame = parseInt(arg[13 .. ^1])
    elif romPath.len == 0 and not arg.startsWith("--"):
      romPath = arg
    elif arg == "--":
      discard  # bare separator passed through by `nim r ... --`; ignore
    else:
      echo "Unknown arg or missing value: ", arg
      quit(1)
    inc i

  if romPath.len == 0:
    echo "Usage: nim r src/tools/trace_tool.nim <rom> [--frames N] [--load-srm] [--watch LO-HI|list] [--from-frame N]"
    quit(1)

  # Parse optional watch filter. Supports single range (LO-HI), comma list of addrs, or mixed.
  # Internally always a set (range expansion at startup is fine for useful sizes).
  var
    useWatch = watchStr.len > 0
    watchedAddrs = initHashSet[uint32]()
  if useWatch:
    let s = watchStr.strip()
    for token in s.split(','):
      let t = token.strip()
      if t.len == 0: continue
      if t.contains('-'):
        let ps = t.split('-', maxsplit = 1)
        var lo = normalizeWramAddr(parseHexInt(ps[0].strip()).uint32)
        var hi = normalizeWramAddr(parseHexInt(ps[1].strip()).uint32)
        if lo > hi: swap(lo, hi)
        # Expand inclusive range into set (4k entries is cheap; user ranges are small).
        for a in lo .. hi:
          watchedAddrs.incl(a)
      else:
        let a = normalizeWramAddr(parseHexInt(t).uint32)
        watchedAddrs.incl(a)

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  snes.recordMmioTrace = true  # this tool reads hdmaWrites; opt into the trace.
  if loadSrm:
    let sp = sramPathFor(romPath)
    loadSram(snes, sp)
  var cpu = snes.resetCpu()

  createDir("bin")
  let tracePath = "bin/trace.log"
  var traceFile: File
  let opened = open(traceFile, tracePath, fmWrite)
  if not opened:
    echo "ERROR: could not open ", tracePath, " for write"
    quit(1)

  proc tlog(msg: string) =
    ## Write one line to trace log (flushed for live tailing).
    traceFile.writeLine(msg)
    traceFile.flushFile()

  tlog("TRACE START")
  tlog(&"  ROM={romPath}")
  tlog(&"  frames={maxFrames} from-frame={fromFrame} load-srm={loadSrm}")
  if useWatch:
    tlog(&"  watch={watchedAddrs.len} addresses (range or list expanded)")
  else:
    tlog("  watch=ALL-WRAM (pass --watch to filter noise)")
  tlog("")

  # Snapshot previous state for frame-to-frame diffs (full 128KB WRAM slice + arrays).
  var prevWram = newSeq[uint8](0x20000)
  for j in 0 ..< 0x10000:
    prevWram[j] = snes.bus.mem[(0x7E0000 + j).int]
    prevWram[0x10000 + j] = snes.bus.mem[(0x7F0000 + j).int]
  var prevPpu = snes.ppuRegs
  var prevDmaTransfers = snes.dmaTransfers
  var prevHdmaen = snes.hdmaen
  var prevHdmaWrites = snes.hdmaWrites.len
  var prevApuPorts: array[4, uint8]
  for p in 0 ..< 4:
    prevApuPorts[p] = if snes.apu != nil: snes.apu.portsIn[p] else: snes.ppuRegs[0x40 + p]

  snes.initHdma()

  var executed = 0
  var line = 0
  var frameNum = 0
  var loggingActive = false

  while frameNum < maxFrames and not cpu.stopped:
    for ii in 0 ..< InstrPerLine:
      if (snes.nmitimen and 0x80) != 0 and line == 240 and ii == 0:
        cpu.nmiPending = true
      cpu.step(snes.bus)
      executed += 1
      if executed >= maxFrames * 9000 or cpu.stopped:
        break
    for k in 0 ..< 2:
      discard snes.tickApu()
    if line < 224:
      snes.runHdma()
    line += 1
    if line >= 262:
      line = 0
      frameNum += 1
      snes.initHdma()

      # Frame complete: diff and log if past --from-frame threshold.
      if frameNum >= fromFrame:
        if not loggingActive:
          loggingActive = true
          tlog(&"=== logging active starting frame {frameNum} ===")
          tlog("")

        tlog(&"FRAME {frameNum}")

        # 1. WRAM diffs (7E/7F banks) filtered by watch.
        var wramLogged = 0
        for j in 0 ..< 0x20000:
          let phys = if j < 0x10000: 0x7E0000'u32 + j.uint32 else: 0x7F0000'u32 + (j - 0x10000).uint32
          let cur = snes.bus.mem[phys.int]
          let old = prevWram[j]
          if cur != old:
            let bank = if j < 0x10000: 0x7E'u8 else: 0x7F'u8
            let off = (phys and 0xFFFF).uint16
            let inFilter = (not useWatch) or (phys in watchedAddrs)
            if inFilter:
              if wramLogged == 0:
                tlog("  WRAM changes:")
              tlog(&"    ${bank:02X}:{off:04X} {old:02X}->{cur:02X}")
              wramLogged += 1
            # Always track latest for next frame (even outside filter).
            prevWram[j] = cur
        if wramLogged == 0:
          tlog("  WRAM: no changes in filter range this frame")

        # 2. PPU $21xx register changes (APU ports $2140-43 logged in dedicated APU section).
        var ppuLogged = 0
        for r in 0 ..< 0x100:
          if r >= 0x40 and r <= 0x43: continue  # APU ports handled below
          let cur = snes.ppuRegs[r]
          let old = prevPpu[r]
          if cur != old:
            if ppuLogged == 0:
              tlog("  PPU reg changes:")
            tlog(&"    ${0x2100 + r:04X} {old:02X}->{cur:02X}")
            ppuLogged += 1
            prevPpu[r] = cur
        if ppuLogged == 0:
          tlog("  PPU: no changes this frame")

        # 3. DMA/HDMA channel activity on transfer count or hdmaen edge.
        let dmaDelta = snes.dmaTransfers - prevDmaTransfers
        let hdmaChanged = snes.hdmaen != prevHdmaen
        if dmaDelta > 0 or hdmaChanged:
          tlog(&"  DMA/HDMA activity: transfers+={dmaDelta} hdmaen={snes.hdmaen:02X}")
          for ch in 0 ..< 8:
            let base = ch * 0x10
            let dmap = snes.dmaRegs[base]
            let bbad = snes.dmaRegs[base + 1]
            let abank = snes.dmaRegs[base + 4]
            let ahi = snes.dmaRegs[base + 3]
            let alo = snes.dmaRegs[base + 2]
            let isHdma = (snes.hdmaen and (1'u8 shl ch)) != 0
            if isHdma or dmap != 0 or bbad != 0:
              tlog(&"    ch{ch}: ${abank:02X}:{ahi:02X}{alo:02X} -> $21{bbad:02X} DMAP={dmap:02X} (hdma={isHdma})")
          prevDmaTransfers = snes.dmaTransfers
          prevHdmaen = snes.hdmaen
        else:
          tlog("  DMA/HDMA: no new transfers or hdmaen change")

        # HDMA B-bus write volume (per-scanline activity indicator).
        let hw = snes.hdmaWrites.len
        if hw > prevHdmaWrites:
          tlog(&"    HDMA B-bus writes this frame: +{hw - prevHdmaWrites}")
          prevHdmaWrites = hw

        # 4. APU port writes ($2140-$2143) observed via live apu or ppuRegs shadow.
        var apuLogged = 0
        for p in 0 ..< 4:
          let cur = if snes.apu != nil: snes.apu.portsIn[p] else: snes.ppuRegs[0x40 + p]
          let old = prevApuPorts[p]
          if cur != old:
            if apuLogged == 0:
              tlog("  APU port writes:")
            tlog(&"    $214{p} {old:02X}->{cur:02X}")
            apuLogged += 1
            prevApuPorts[p] = cur
        if apuLogged == 0:
          tlog("  APU: no port changes this frame")

        tlog("")  # frame separator

  tlog(&"TRACE END frames={frameNum} executed={executed} total-dma={snes.dmaTransfers} final-hdmaen={snes.hdmaen:02X}")
  traceFile.close()

  echo &"Trace written to {tracePath}"
  echo &"Frames run: {frameNum}  DMA transfers: {snes.dmaTransfers}  HDMA writes recorded: {snes.hdmaWrites.len}"
  echo &"Watched WRAM range active: {useWatch}"

when isMainModule:
  main()
