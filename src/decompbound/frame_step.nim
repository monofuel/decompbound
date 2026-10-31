## The deterministic one-frame stepper shared by the player, the Lua policy
## harness, replays and the bench referee. Lua-free so headless tools link
## without vendor/lua.

import
  pixie,
  ./[core_profile, cpu, cpu_polling, ppu, snesbus]

const
  InstrPerLine* {.intdefine.} = 150  # match play.nim's frame budget; at 40 the game is CPU-starved
                       # and never boots past force-blank (black frames in llm_ai/play).
  ApuSamplesPerFrame* = 533  # 2 per scanline + 9 top-up; equals replay.ReplayApuTicksPerFrame.

type
  FramePcm* = array[ApuSamplesPerFrame * 2, int16]
    ## One frame of interleaved stereo APU output (533 left/right pairs).
  VisibleFrameHook* = proc(snes: SnesBus) {.closure.}
    ## Observe completed visible-frame data before NMI prepares the next frame.

when defined(coreProfile):
  const
    VblankPollBank = 0xC0'u8
    VblankPollLoad = 0x875F'u16
    VblankPollBranch = 0x8762'u16
    VblankEventWram = 0x7E002B
    WramBank = (VblankEventWram shr 16).uint8
    SystemBankFoldMask = 0x7F'u8
    SystemBankLimit = 0x40'u8

  proc cpuProfileStage*(snes: SnesBus, state: Cpu): CoreProfileStage =
    ## Classify whole instruction batches inside the verified C0875F/C08762 polling loop.
    result = MainCpu
    let
      eventBank = state.dbr == WramBank or
        (state.dbr and SystemBankFoldMask) < SystemBankLimit
      byteAccumulator = state.emulation or (state.p and FlagM) != 0
    if state.pbr == VblankPollBank and eventBank and
        not state.nmiPending and not state.waiting and not state.stopped and
        (state.pc == VblankPollLoad or
          (state.pc == VblankPollBranch and (state.p and FlagZ) != 0)) and
        snes.bus.mem[VblankEventWram] == 0 and
        (byteAccumulator or snes.bus.mem[VblankEventWram + 1] == 0):
      result = MainCpuWait

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
    pcm: ptr FramePcm = nil, polling: CpuPollingContext = nil,
    onVisibleFrame: VisibleFrameHook = nil) =
  ## Advance the emulator by exactly one frame (262 scanlines).
  ## Mirrors play.nim (NMI at line 224, InstrPerLine=150). Pass render=false
  ## to skip PPU draws (headless TAS reports). When `pcm` is given, the 524
  ## in-frame APU samples are stored there (slots 0..523, interleaved L/R).
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if render and not forceBlank:
    profileStage(VideoScanline):
      let backdrop = ppu.bgr555ToColor(snes.cgram[0])
      image.fill(backdrop)
  var l = 0
  var smp = 0
  while l < 262:
    profileStage(SystemTasks): snes.tickScanline(l)
    if l == 224:
      # Sprites must render from OAM as it stands at the END of the visible
      # frame, BEFORE the game's NMI handler DMAs next frame's positions in —
      # else sprites lead the background by one frame (1px ghost when moving).
      if render:
        profileStage(VideoSprites): ppu.renderSprites(snes, image)
        profileStage(VideoForeground): ppu.overlayForegroundBg(snes, image)
      if onVisibleFrame != nil: onVisibleFrame(snes)
      if (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
    when defined(coreProfile):
      let cpuStage = snes.cpuProfileStage(cpu)
    else:
      const cpuStage = MainCpu
    profileStage(cpuStage):
      if polling != nil:
        discard stepCpuBatch(snes, cpu, InstrPerLine, polling)
      else:
        for i in 0 ..< InstrPerLine:
          cpu.step(snes.bus)
          if cpu.stopped:
            break
    if l < 224:
      profileStage(SystemTasks): snes.runHdma()
      if render and (snes.ppuRegs[0x00] and 0x80) == 0:
        profileStage(VideoScanline): ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      let (left, right) = snes.tickApu()
      if pcm != nil:
        pcm[smp * 2] = left
        pcm[smp * 2 + 1] = right
        inc smp
    inc l
    if l >= 262:
      profileStage(SystemTasks): snes.initHdma()
      break
