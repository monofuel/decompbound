## The deterministic one-frame stepper shared by the player, the Lua policy
## harness, replays and the bench referee. Lua-free so headless tools link
## without vendor/lua.

import
  pixie,
  ./[cpu, ppu, snesbus]

const
  InstrPerLine* {.intdefine.} = 150  # match play.nim's frame budget; at 40 the game is CPU-starved
                       # and never boots past force-blank (black frames in llm_ai/play).
  ApuSamplesPerFrame* = 533  # 2 per scanline + 9 top-up; equals replay.ReplayApuTicksPerFrame.

type
  FramePcm* = array[ApuSamplesPerFrame * 2, int16]
    ## One frame of interleaved stereo APU output (533 left/right pairs).

proc readRomFile*(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc stepOneFrame*(snes: SnesBus, cpu: var Cpu, image: Image, render = true,
    pcm: ptr FramePcm = nil) =
  ## Advance the emulator by exactly one frame (262 scanlines).
  ## Mirrors play.nim (NMI at line 224, InstrPerLine=150). Pass render=false
  ## to skip PPU draws (headless TAS reports). When `pcm` is given, the 524
  ## in-frame APU samples are stored there (slots 0..523, interleaved L/R).
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if render and not forceBlank:
    let backdrop = ppu.bgr555ToColor(snes.cgram[0])
    image.fill(backdrop)
  var l = 0
  var smp = 0
  while l < 262:
    snes.tickScanline(l)
    if l == 224:
      # Sprites must render from OAM as it stands at the END of the visible
      # frame, BEFORE the game's NMI handler DMAs next frame's positions in —
      # else sprites lead the background by one frame (1px ghost when moving).
      if render:
        ppu.renderSprites(snes, image)
        ppu.overlayForegroundBg(snes, image)
      if (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if l < 224:
      snes.runHdma()
      if render and (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      let (left, right) = snes.tickApu()
      if pcm != nil:
        pcm[smp * 2] = left
        pcm[smp * 2 + 1] = right
        inc smp
    inc l
    if l >= 262:
      snes.initHdma()
      break
