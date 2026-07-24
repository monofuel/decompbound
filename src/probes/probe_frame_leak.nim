## Headless per-frame memory-leak repro: mirrors play.nim's per-frame core
## (emulate + render + audio tick) in a tight loop and prints getOccupiedMem so we
## can localize the ~37KB/frame leak seen in live play. Untracked dig tool.
## Toggle render/audio via args to bisect. Uses a real state (bin/) for the dig;
## the committed unit test will use a synthetic bus.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

proc readRssAnonKb(): int =
  ## Linux-only: anonymous resident set (KB) from /proc/self/status; -1 if absent.
  ## getOccupiedMem() only sees the Nim GC heap — RssAnon also catches C-library
  ## (OpenAL/GL driver) allocations, which is where the live-only leak may hide.
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith("RssAnon:"):
        for tok in line.splitWhitespace():
          if tok.len > 0 and tok[0].isDigit:
            return parseInt(tok)
  except CatchableError:
    discard
  -1

const
  Rom = "bin/Earthbound (U) [!].smc"
  State = "bin/states/game_start.state"
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60

proc stepFrame(snes: SnesBus, cpu: var Cpu, image: Image, doRender, doAudio, doHdma: bool) =
  ## One emulated frame, mirroring play.nim's inner loop.
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if doRender and not forceBlank:
    image.fill(ppu.bgr555ToColor(snes.cgram[0]))
  var pcm: seq[uint8]
  if doAudio:
    pcm = newSeq[uint8](SamplesPerFrame * 4)
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped: break
    if l < 224:
      if doHdma: snes.runHdma()
      if doRender and (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    if doAudio:
      for k in 0 ..< 2:
        discard snes.tickApu()
    l += 1
    if l >= 262:
      if doHdma: snes.initHdma()
      break
  if doRender:
    ppu.renderSprites(snes, image)
    ppu.overlayForegroundBg(snes, image)
  if pcm.len > 0: discard pcm[0]

proc main() =
  let doRender = "norender" notin commandLineParams()
  let doAudio = "noaudio" notin commandLineParams()
  let emuOnly = "emuonly" in commandLineParams()
  let doHdma = "nohdma" notin commandLineParams()
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(State)), snes, cpu)
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  echo &"mode: render={doRender and not emuOnly} audio={doAudio and not emuOnly} emuOnly={emuOnly}"

  for i in 0 ..< 120:  # warmup — let one-time buffers settle.
    stepFrame(snes, cpu, image, doRender and not emuOnly, doAudio and not emuOnly, doHdma)
  let before = getOccupiedMem()
  let rssBefore = readRssAnonKb()
  const Frames = 1800
  for i in 0 ..< Frames:
    stepFrame(snes, cpu, image, doRender and not emuOnly, doAudio and not emuOnly, doHdma)
    if (i + 1) mod 300 == 0:
      echo &"  frame {i+1}: occupied={getOccupiedMem() div 1024} KB rssAnon={readRssAnonKb()} KB"
  let after = getOccupiedMem()
  let rssAfter = readRssAnonKb()
  echo "seq lens: mmioReads=", snes.mmioReads.len, " mmioWrites=", snes.mmioWrites.len, " apuPostBoot=", snes.apuPostBoot.len, " apuJumps=", snes.apuJumps.len, " hdmaWrites=", snes.hdmaWrites.len
  let perFrame = (after - before) div Frames
  echo &"NIM-HEAP: {(after - before) div 1024} KB over {Frames} frames = {perFrame} B/frame"
  if rssBefore >= 0 and rssAfter >= 0:
    echo &"RSS-ANON: {rssAfter - rssBefore} KB over {Frames} frames = {(rssAfter - rssBefore) * 1024 div Frames} B/frame"
    echo "  ^ RSS > NIM-HEAP => allocator fragmentation / non-Nim buffers on top of the heap leak."

main()
