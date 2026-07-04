## S-DSP: the SNES audio mixer (Goal 2a, docs/audio.md).
## First-pass accuracy: BRR sample decoding, ADSR/GAIN envelopes, pitch
## stepping with gaussian-ish linear interpolation, 8-voice stereo mix at
## 32kHz. Echo/FIR and noise land later - docs/audio.md warns Earthbound
## leans on echo, so expect dry output until then.

type
  EnvPhase = enum
    epRelease
    epAttack
    epDecay
    epSustain

  Voice = object
    active: bool
    srcn: uint8
    brrAddr: uint16     ## Current BRR block address.
    brrHeader: uint8
    brrIndex: int       ## Nibble index within the block (0-15).
    prev1: int32        ## BRR filter history.
    prev2: int32
    loopAddr: uint16
    pitchCounter: uint32
    samples: array[4, int32]  ## Interpolation window.
    envPhase: EnvPhase
    envLevel: int32     ## 0..0x7FF.
    envCounter: int

  Dsp* = ref object
    writes*: int  ## Debug: count of register writes.
    regs*: array[128, uint8]
    ram*: ref array[0x10000, uint8]  ## Shared with the SPC700.
    voices: array[8, Voice]
    sampleCounter: int

const
  # Envelope rate table: samples per step for rates 0-31 (approximate
  # hardware periods).
  RatePeriods = [
    0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160,
    128, 96, 80, 64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]

proc newDsp*(ram: ref array[0x10000, uint8]): Dsp =
  ## DSP sharing the SPC700's RAM. Power-on register state is
  ## unpredictable on hardware; nonzero values here matter because the
  ## N-SPC driver uses a DSP register compare as a warm/cold boot check
  ## and must take the cold path on first boot.
  result = Dsp(ram: ram)
  for i in 0..<128:
    result.regs[i] = 0xFF
  result.regs[0x6C] = 0xE0  # FLG: reset + mute + echo disable.

proc sampleTableAddr(dsp: Dsp, voice: int): uint16 =
  ## Sample directory entry address for a voice's SRCN.
  let dir = dsp.regs[0x5D].uint16
  let srcn = dsp.regs[voice * 0x10 + 4].uint16
  (dir * 0x100) + (srcn * 4)

proc startVoice(dsp: Dsp, index: int) =
  ## Key on: reset BRR decode and envelope for a voice.
  let entry = dsp.sampleTableAddr(index)
  var v: Voice
  v.active = true
  v.srcn = dsp.regs[index * 0x10 + 4]
  v.brrAddr = dsp.ram[entry].uint16 or (dsp.ram[entry + 1].uint16 shl 8)
  v.loopAddr = dsp.ram[entry + 2].uint16 or (dsp.ram[entry + 3].uint16 shl 8)
  v.brrHeader = dsp.ram[v.brrAddr]
  v.brrIndex = 0
  v.envPhase = epAttack
  v.envLevel = 0
  dsp.voices[index] = v

proc stopVoice(dsp: Dsp, index: int) =
  ## Key off: enter release.
  dsp.voices[index].envPhase = epRelease

proc write*(dsp: Dsp, address: uint8, value: uint8) =
  ## DSP register write (via SPC700 $F2/$F3).
  let reg = address and 0x7F
  dsp.writes += 1
  dsp.regs[reg] = value
  case reg:
  of 0x4C:  # KON.
    for i in 0..7:
      if ((value shr i) and 1) != 0:
        dsp.startVoice(i)
  of 0x5C:  # KOF.
    for i in 0..7:
      if ((value shr i) and 1) != 0:
        dsp.stopVoice(i)
  else:
    discard

proc read*(dsp: Dsp, address: uint8): uint8 =
  ## DSP register read.
  dsp.regs[address and 0x7F]

proc decodeBrrNibble(v: var Voice, ram: ref array[0x10000, uint8]): int32 =
  ## (Loop target comes from the sample directory, latched at key-on.)
  ## Decode the next 4-bit BRR sample, applying range and filter.
  let byteOffset = v.brrAddr + 1 + (v.brrIndex div 2).uint16
  let raw = ram[byteOffset]
  var nibble = if v.brrIndex mod 2 == 0: (raw shr 4).int32 else: (raw and 0x0F).int32
  if nibble > 7:
    nibble -= 16
  let shift = (v.brrHeader shr 4).int
  var sample = if shift <= 12: (nibble shl shift) shr 1
               else: (if nibble < 0: -2048'i32 else: 2047'i32)
  # BRR prediction filters.
  case (v.brrHeader shr 2) and 3:
  of 1: sample += v.prev1 + (-v.prev1 shr 4)
  of 2: sample += (v.prev1 shl 1) + ((-((v.prev1 shl 1) + v.prev1)) shr 5) -
                  v.prev2 + (v.prev2 shr 4)
  of 3: sample += (v.prev1 shl 1) +
                  ((-(v.prev1 + (v.prev1 shl 2) + (v.prev1 shl 3))) shr 6) -
                  v.prev2 + (((v.prev2 shl 1) + v.prev2) shr 4)
  else: discard
  sample = max(-32768'i32, min(32767'i32, sample))
  v.prev2 = v.prev1
  v.prev1 = sample
  v.brrIndex += 1
  if v.brrIndex >= 16:
    # Block done: advance or loop/end per header flags.
    if (v.brrHeader and 0x01) != 0:  # END flag.
      if (v.brrHeader and 0x02) != 0:  # LOOP flag.
        v.brrAddr = v.loopAddr
      else:
        v.active = false
    else:
      v.brrAddr += 9
    v.brrHeader = ram[v.brrAddr]
    v.brrIndex = 0
  result = sample

proc stepEnvelope(dsp: Dsp, index: int) =
  ## Advance a voice's ADSR/GAIN envelope by one sample tick.
  var v = addr dsp.voices[index]
  let adsr1 = dsp.regs[index * 0x10 + 5]
  let adsr2 = dsp.regs[index * 0x10 + 6]
  let gain = dsp.regs[index * 0x10 + 7]

  proc rateReady(v: ptr Voice, rate: int): bool =
    if rate == 0:
      return false
    v.envCounter += 1
    let period = RatePeriods[rate and 31]
    if v.envCounter >= period:
      v.envCounter = 0
      return true
    false

  case v.envPhase:
  of epRelease:
    v.envLevel -= 8
    if v.envLevel <= 0:
      v.envLevel = 0
      v.active = false
  of epAttack:
    if (adsr1 and 0x80) != 0:
      let rate = ((adsr1 and 0x0F).int shl 1) + 1
      if rate >= 31:
        v.envLevel += 0x400
      elif rateReady(v, rate):
        v.envLevel += 0x20
      if v.envLevel >= 0x7E0:
        v.envLevel = 0x7FF
        v.envPhase = epDecay
    else:
      # GAIN mode: direct or increase modes approximated as direct.
      if (gain and 0x80) == 0:
        v.envLevel = (gain and 0x7F).int32 shl 4
        v.envPhase = epSustain
      else:
        v.envLevel = 0x7FF
        v.envPhase = epSustain
  of epDecay:
    let rate = (((adsr1 shr 4) and 0x07).int shl 1) + 0x10
    if rateReady(v, rate):
      v.envLevel -= ((v.envLevel - 1) shr 8) + 1
    let sustainLevel = (((adsr2 shr 5).int32) + 1) shl 8
    if v.envLevel <= sustainLevel:
      v.envPhase = epSustain
  of epSustain:
    if (adsr1 and 0x80) != 0:
      let rate = (adsr2 and 0x1F).int
      if rate != 0 and rateReady(v, rate):
        v.envLevel -= ((v.envLevel - 1) shr 8) + 1
        if v.envLevel < 0:
          v.envLevel = 0
    else:
      discard

proc mixSample*(dsp: Dsp): tuple[left: int16, right: int16] =
  ## Produce one 32kHz stereo output sample from all voices.
  var left = 0'i32
  var right = 0'i32
  for i in 0..7:
    if not dsp.voices[i].active:
      continue
    let v = addr dsp.voices[i]
    let pitch = (dsp.regs[i * 0x10 + 2].uint32 or
      ((dsp.regs[i * 0x10 + 3].uint32 and 0x3F) shl 8))
    v.pitchCounter += pitch
    while v.pitchCounter >= 0x1000:
      v.pitchCounter -= 0x1000
      # Shift the interpolation window and decode the next BRR sample.
      v.samples[0] = v.samples[1]
      v.samples[1] = v.samples[2]
      v.samples[2] = v.samples[3]
      v.samples[3] = decodeBrrNibble(v[], dsp.ram)
      if not v.active:
        break
    if not v.active:
      continue
    dsp.stepEnvelope(i)
    # Linear interpolation between the last two decoded samples.
    let frac = (v.pitchCounter and 0xFFF).int32
    let sample = (v.samples[2] * (0x1000 - frac) + v.samples[3] * frac) shr 12
    let enveloped = (sample * v.envLevel) shr 11
    let volL = cast[int8](dsp.regs[i * 0x10 + 0]).int32
    let volR = cast[int8](dsp.regs[i * 0x10 + 1]).int32
    left += (enveloped * volL) shr 7
    right += (enveloped * volR) shr 7
  let mvolL = cast[int8](dsp.regs[0x0C]).int32
  let mvolR = cast[int8](dsp.regs[0x1C]).int32
  left = (left * mvolL) shr 7
  right = (right * mvolR) shr 7
  result.left = int16(max(-32768'i32, min(32767'i32, left)))
  result.right = int16(max(-32768'i32, min(32767'i32, right)))
