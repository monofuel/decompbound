## Verify pure advanceSeed against the live emulator's $C08E9A calls.
##
## Boots the user ROM, loads a local savestate when available (else cold-boots a
## few hundred frames), and at every RNG entry compares advanceSeed(pre) to the
## post-call WRAM seed + A return byte. Needs 50+ matches, exit 0, headless.
## Skips quietly (exit 0) when the ROM is absent (CI).

import
  std/[os, strformat, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, policy, rng_oracle]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  RngPbr = 0xC0'u8
  RngPc = 0x8E9A'u16
  RngPcEnd = 0x8ED1'u16  # RTL inclusive upper bound for the 56-byte body.
  SeedWram = 0x0024
  MinSamples = 50
  DefaultFrames = 900
  StateCandidates = [
    "bin/states/battle_menu_healthy.state",
    "bin/states/llm/home_indoor.state",
    "bin/states/llm/onett_start.state",
    "bin/states/game_start.state",
    "bin/states/slot1.state",
  ]

proc readSeed(snes: SnesBus): uint32 =
  ## 32-bit LE seed from WRAM $0024/$0026.
  let
    b0 = snes.bus.mem[0x7E0000 + SeedWram].uint32
    b1 = snes.bus.mem[0x7E0000 + SeedWram + 1].uint32
    b2 = snes.bus.mem[0x7E0000 + SeedWram + 2].uint32
    b3 = snes.bus.mem[0x7E0000 + SeedWram + 3].uint32
  b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc inRngBody(cpu: Cpu): bool =
  ## True while PBR:PC is inside the RNG routine (entry through RTL).
  cpu.pbr == RngPbr and cpu.pc >= RngPc and cpu.pc <= RngPcEnd

proc findState(): string =
  ## Prefer a local mid-game state so RNG fires often without long boot.
  for p in StateCandidates:
    if fileExists(p):
      return p
  ""

proc main() =
  ## Run frames, sample every $C08E9A entry, require 50+ pure-oracle matches.
  if not fileExists(RomPath):
    echo "[test_rng_oracle] SKIP (ROM absent)"
    return

  let
    rom = policy.readRomFile(RomPath)
    snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  let statePath = findState()
  if statePath.len > 0:
    deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  else:
    # Cold boot long enough for the fixed seed to be installed and game code to run.
    let imgBoot = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for _ in 0 ..< 400:
      snes.joy1 = 0
      policy.stepOneFrame(snes, cpu, imgBoot)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var
    samples = 0
    mismatches = 0
    inRoutine = false
    preSeed = 0'u32
    # Light stimulus so menus / confirm paths also call RNG.
    stimulus = [0x0000'u16, 0x0080'u16, 0x0100'u16, 0x1000'u16, 0x0400'u16]

  for f in 0 ..< DefaultFrames:
    snes.joy1 = stimulus[(f div 30) mod stimulus.len]
    var line = 0
    while line < 262:
      if line == 224 and (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
      for _ in 0 ..< policy.InstrPerLine:
        if not (cpu.stopped or cpu.waiting):
          if not inRoutine and cpu.pbr == RngPbr and cpu.pc == RngPc:
            preSeed = readSeed(snes)
            inRoutine = true
          cpu.step(snes.bus)
          if inRoutine and not inRngBody(cpu):
            let
              postSeed = readSeed(snes)
              retByte = uint8(cpu.a and 0xFF)
              predicted = advanceSeed(preSeed)
            if predicted.seed != postSeed or predicted.value != retByte:
              inc mismatches
              if mismatches <= 5:
                echo &"MISMATCH pre={preSeed:08X} emu_post={postSeed:08X} " &
                  &"emu_A={retByte:02X} pure_post={predicted.seed:08X} " &
                  &"pure_A={predicted.value:02X}"
            inc samples
            inRoutine = false
        if cpu.stopped:
          break
      if line < 224:
        snes.runHdma()
      for k in 0 ..< 2:
        discard snes.tickApu()
      inc line
      if line >= 262:
        snes.initHdma()
        break
    if samples >= MinSamples and mismatches == 0:
      break
    if cpu.stopped:
      break

  if samples < MinSamples:
    # Cold/idle may under-sample; force more idle+walk frames from any state.
    for f in 0 ..< 2000:
      snes.joy1 = if (f mod 8) < 4: 0x0100'u16 else: 0'u16
      var line = 0
      while line < 262:
        if line == 224 and (snes.nmitimen and 0x80) != 0:
          cpu.nmiPending = true
        for _ in 0 ..< policy.InstrPerLine:
          if not (cpu.stopped or cpu.waiting):
            if not inRoutine and cpu.pbr == RngPbr and cpu.pc == RngPc:
              preSeed = readSeed(snes)
              inRoutine = true
            cpu.step(snes.bus)
            if inRoutine and not inRngBody(cpu):
              let
                postSeed = readSeed(snes)
                retByte = uint8(cpu.a and 0xFF)
                predicted = advanceSeed(preSeed)
              if predicted.seed != postSeed or predicted.value != retByte:
                inc mismatches
                if mismatches <= 5:
                  echo &"MISMATCH pre={preSeed:08X} emu_post={postSeed:08X} " &
                    &"emu_A={retByte:02X} pure_post={predicted.seed:08X} " &
                    &"pure_A={predicted.value:02X}"
              inc samples
              inRoutine = false
          if cpu.stopped:
            break
        if line < 224:
          snes.runHdma()
        for k in 0 ..< 2:
          discard snes.tickApu()
        inc line
        if line >= 262:
          snes.initHdma()
          break
      if samples >= MinSamples and mismatches == 0:
        break
      if cpu.stopped:
        break

  doAssert samples >= MinSamples,
    &"need >={MinSamples} RNG calls, got {samples} (state={statePath})"
  doAssert mismatches == 0,
    &"{mismatches} advanceSeed mismatches in {samples} samples"
  # Quiet success (tests should not log on green).

when isMainModule:
  main()
