## S-DSP: the SNES audio mixer (Goal 2a, docs/audio.md).
## BRR decode (filters 0-3, range, loop/end), 4-tap Gaussian interp, ADSR/GAIN
## envelopes (incl. edge rates), 14-bit VxPITCH + pitch counter, noise (NON + LFSR),
## echo (EON/FIR/EFB), and pitch modulation (PMON $2D). PMON: voices 1-7 can have
## pitch stepped modulated by prior voice's post-env output sample (factor =
## (prevOut>>4)+0x400; step=(step*factor)>>10 per fullsnes/anomie). 8-voice 32kHz
## stereo. Clamp everywhere (no wrap) to preserve working audio paths.

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
    firHistL: array[8, int32]   ## Echo FIR delay line (left channel).
    firHistR: array[8, int32]   ## Echo FIR delay line (right channel).
    echoOffset: int             ## Byte offset into the echo buffer; wraps at EDL size.
    noiseLfsr: uint16           ## 15-bit noise LFSR (must stay non-zero to run).
    noiseCounter: int           ## Samples since the last noise-LFSR step.

const
  # Envelope rate table: samples per step for rates 0-31 (approximate
  # hardware periods). Matches fullsnes.
  RatePeriods = [
    0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160,
    128, 96, 80, 64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]

  # 4-tap Gaussian interpolation table (512 entries). Source: fullsnes spec
  # (cross-checked against blargg snes_spc and Mesen2). Used for BRR
  # resampling with pitch counter frac; fixes rich/enveloped samples vs linear.
  # (Not magic; derived from SNES hardware filter coefficients.)
  Gaussian = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5,
    6, 6, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10,
    11, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 15, 16, 16, 17, 17,
    18, 19, 19, 20, 20, 21, 21, 22, 23, 23, 24, 24, 25, 26, 27, 27,
    28, 29, 29, 30, 31, 32, 32, 33, 34, 35, 36, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
    58, 59, 60, 61, 62, 64, 65, 66, 67, 69, 70, 71, 73, 74, 76, 77,
    78, 80, 81, 83, 84, 86, 87, 89, 90, 92, 94, 95, 97, 99, 100, 102,
    104, 106, 107, 109, 111, 113, 115, 117, 118, 120, 122, 124, 126, 128, 130, 132,
    134, 137, 139, 141, 143, 145, 147, 150, 152, 154, 156, 159, 161, 163, 166, 168,
    171, 173, 175, 178, 180, 183, 186, 188, 191, 193, 196, 199, 201, 204, 207, 210,
    212, 215, 218, 221, 224, 227, 230, 233, 236, 239, 242, 245, 248, 251, 254, 257,
    260, 263, 267, 270, 273, 276, 280, 283, 286, 290, 293, 297, 300, 304, 307, 311,
    314, 318, 321, 325, 328, 332, 336, 339, 343, 347, 351, 354, 358, 362, 366, 370,
    374, 378, 381, 385, 389, 393, 397, 401, 405, 410, 414, 418, 422, 426, 430, 434,
    439, 443, 447, 451, 456, 460, 464, 469, 473, 477, 482, 486, 491, 495, 499, 504,
    508, 513, 517, 522, 527, 531, 536, 540, 545, 550, 554, 559, 563, 568, 573, 577,
    582, 587, 592, 596, 601, 606, 611, 615, 620, 625, 630, 635, 640, 644, 649, 654,
    659, 664, 669, 674, 678, 683, 688, 693, 698, 703, 708, 713, 718, 723, 728, 732,
    737, 742, 747, 752, 757, 762, 767, 772, 777, 782, 787, 792, 797, 802, 806, 811,
    816, 821, 826, 831, 836, 841, 846, 851, 855, 860, 865, 870, 875, 880, 884, 889,
    894, 899, 904, 908, 913, 918, 923, 927, 932, 937, 941, 946, 951, 955, 960, 965,
    969, 974, 978, 983, 988, 992, 997, 1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305]

proc newDsp*(ram: ref array[0x10000, uint8]): Dsp =
  ## DSP sharing the SPC700's RAM. Power-on register state is
  ## unpredictable on hardware; nonzero values here matter because the
  ## N-SPC driver uses a DSP register compare as a warm/cold boot check
  ## and must take the cold path on first boot.
  result = Dsp(ram: ram)
  for i in 0..<128:
    result.regs[i] = 0xFF
  result.regs[0x6C] = 0xE0  # FLG: reset + mute + echo disable.
  result.noiseLfsr = 0x4000  # Non-zero seed; a zero LFSR would never advance.

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

proc clampS16(v: int32): int32 =
  ## Clamp a value to the signed 16-bit range.
  max(-32768'i32, min(32767'i32, v))

proc decodeBrrNibble(v: var Voice, ram: ref array[0x10000, uint8]): int32 =
  ## (Loop target comes from the sample directory, latched at key-on.)
  ## Decode the next 4-bit BRR sample, applying range and filter.
  ## Math is blargg SPC_DSP.cpp decode_brr() exact: the decoded sample is
  ## clamped to 16-bit then DOUBLED with int16 wrap (the hardware 15-bit
  ## wrap quirk), and the filter history holds the stored (doubled) values
  ## (p1 at stored scale, p2 halved). Samples in the interp window are thus
  ## full 16-bit scale, matching the reference bit-for-bit.
  let byteOffset = v.brrAddr + 1 + (v.brrIndex div 2).uint16
  let raw = ram[byteOffset]
  var nibble = if v.brrIndex mod 2 == 0: (raw shr 4).int32 else: (raw and 0x0F).int32
  if nibble > 7:
    nibble -= 16
  let shift = (v.brrHeader shr 4).int
  var sample = if shift <= 12: (nibble shl shift) shr 1
               else: (if nibble < 0: -0x800'i32 else: 0'i32)
  # BRR prediction filters (blargg-exact; history is at stored x2 scale).
  let p1 = v.prev1
  let p2 = v.prev2 shr 1
  case (v.brrHeader shr 2) and 3:
  of 1:  # s += p1 * 0.46875 (of stored scale) = old * 15/16
    sample += p1 shr 1
    sample += (-p1) shr 5
  of 2:  # s += old * 61/32 - older * 15/16
    sample += p1
    sample -= p2
    sample += p2 shr 4
    sample += (p1 * -3) shr 6
  of 3:  # s += old * 115/64 - older * 13/16
    sample += p1
    sample -= p2
    sample += (p1 * -13) shr 7
    sample += (p2 * 3) shr 4
  else: discard
  # CLAMP16 then double with int16 wrap (hardware 15-bit wrap behavior).
  sample = clampS16(sample)
  sample = cast[int16]((sample * 2) and 0xFFFF).int32
  v.prev2 = v.prev1
  v.prev1 = sample
  v.brrIndex += 1
  if v.brrIndex >= 16:
    # Block done: advance or loop/end per header flags (END=bit0, LOOP=bit1).
    # Per fullsnes: code1 (end+!loop)=End+Mute: jump loop, release, env=0.
    # code3 (end+loop): jump loop, continue. Set at block start on hw, here after.
    let endFlag = (v.brrHeader and 0x01) != 0
    let loopFlag = (v.brrHeader and 0x02) != 0
    if endFlag:
      v.brrAddr = v.loopAddr
      if not loopFlag:
        v.envLevel = 0
        v.envPhase = epRelease
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

  if (adsr1 and 0x80) == 0:
    # GAIN mode (ADSR1 bit7=0 overrides; direct or one of 4 custom curves).
    # Direct gain sets fixed level every sample. Custom uses rate+mode.
    # Matches fullsnes GAIN modes exactly (fixes enveloped SFX).
    if (gain and 0x80) == 0:
      v.envLevel = (gain and 0x7F).int32 shl 4
    else:
      let r = (gain and 0x1F).int
      if rateReady(v, r):
        let m = (gain shr 5) and 3
        case m:
        of 0: v.envLevel -= 32'i32  # linear decrease
        of 1: v.envLevel -= ((v.envLevel - 1) shr 8) + 1  # exp decrease
        of 2: v.envLevel += 32'i32  # linear increase
        of 3:  # bent increase
          if v.envLevel < 0x600'i32:
            v.envLevel += 32'i32
          else:
            v.envLevel += 8'i32
        else: discard
    if v.envLevel < 0: v.envLevel = 0
    if v.envLevel > 0x7FF: v.envLevel = 0x7FF
  else:
    case v.envPhase:
    of epRelease:
      v.envLevel -= 8
      if v.envLevel <= 0:
        v.envLevel = 0
        v.active = false
    of epAttack:
      let rate = ((adsr1 and 0x0F).int shl 1) + 1
      if rate >= 31:
        v.envLevel += 0x400
      elif rateReady(v, rate):
        v.envLevel += 0x20
      # Blargg: decay begins only once the level overflows past 0x7FF.
      if v.envLevel > 0x7FF:
        v.envLevel = 0x7FF
        v.envPhase = epDecay
    of epDecay:
      let rate = (((adsr1 shr 4) and 0x07).int shl 1) + 0x10
      if rateReady(v, rate):
        v.envLevel -= ((v.envLevel - 1) shr 8) + 1
      # Blargg sustain-level check: top 3 bits of the level equal SL.
      if (v.envLevel shr 8) == ((adsr2 shr 5).int32):
        v.envPhase = epSustain
    of epSustain:
      let rate = (adsr2 and 0x1F).int
      if rate != 0 and rateReady(v, rate):
        v.envLevel -= ((v.envLevel - 1) shr 8) + 1
        if v.envLevel < 0:
          v.envLevel = 0

proc forceKeyOnForTest*(dsp: Dsp, voice: int, sampleAddrHint: uint16 = 0) =
  ## Temporary helper so the music render path can emit audible game BRR
  ## while the port command / song start logic is completed. Sets up one
  ## voice to play from a BRR location.
  if voice < 0 or voice > 7: return
  var v = dsp.voices[voice]
  v.active = true
  v.srcn = dsp.regs[voice * 0x10 + 4]
  let entry = dsp.sampleTableAddr(voice)
  v.brrAddr = dsp.ram[entry].uint16 or (dsp.ram[entry + 1].uint16 shl 8)
  if sampleAddrHint != 0:
    v.brrAddr = sampleAddrHint
  v.loopAddr = dsp.ram[entry + 2].uint16 or (dsp.ram[entry + 3].uint16 shl 8)
  v.brrHeader = dsp.ram[v.brrAddr]
  v.brrIndex = 0
  v.envPhase = epAttack
  v.envLevel = 0x7FF
  dsp.voices[voice] = v
  dsp.regs[0x4C] = dsp.regs[0x4C] or (1'u8 shl voice)

proc mixSample*(dsp: Dsp): tuple[left: int16, right: int16] =
  ## Produce one 32kHz stereo output sample: the dry voice mix (scaled by the
  ## master volume) plus the echo return (the FIR-filtered echo buffer scaled by
  ## the echo volume). Echo-enabled voices (EON) also feed the echo buffer.
  var dryL = 0'i32
  var dryR = 0'i32
  var echoInL = 0'i32
  var echoInR = 0'i32
  let pmon = dsp.regs[0x2D]   # Per-voice pitch modulation enable (voices 1-7).
  let non = dsp.regs[0x3D]    # Per-voice noise enable.
  let eon = dsp.regs[0x4D]    # Per-voice echo enable.

  # Advance the noise LFSR at the rate selected by FLG bits 0-4, then form the
  # signed noise sample (used by any voice whose NON bit is set).
  let noiseRate = (dsp.regs[0x6C] and 0x1F).int
  if noiseRate != 0:
    dsp.noiseCounter += 1
    if dsp.noiseCounter >= RatePeriods[noiseRate]:
      dsp.noiseCounter = 0
      let feedback = (dsp.noiseLfsr xor (dsp.noiseLfsr shr 1)) and 1
      dsp.noiseLfsr = (dsp.noiseLfsr shr 1) or (feedback shl 14)
  let noiseSample = cast[int16](dsp.noiseLfsr shl 1).int32

  # prevOut holds the post-envelope (pre-VOL) sample from the prior voice in this
  # tick. Used only for PMON; OUTX of prev modulates current pitch step.
  # Per fullsnes/anomie: only applies to !NON voices 1-7; factor=(out>>4)+0x400
  # gives 0.0..~2.0 range; (step * factor)>>10 .
  var prevOut = 0'i32

  for i in 0..7:
    if not dsp.voices[i].active:
      prevOut = 0'i32
      continue
    let v = addr dsp.voices[i]
    var sample: int32
    if ((non shr i) and 1) != 0:
      # Noise voice: ignore BRR + pitch, just envelope the global noise source.
      dsp.stepEnvelope(i)
      if not v.active:
        prevOut = 0'i32
        continue
      sample = noiseSample
    else:
      var pitch = (dsp.regs[i * 0x10 + 2].int32 or
        ((dsp.regs[i * 0x10 + 3].int32 and 0x3F) shl 8))
      # Pitch modulation (PMON): if enabled for this voice, adjust the pitch by
      # the prior voice's post-env output. Voice 0 never modulated (PMON bit 0
      # unused). Blargg-exact: pitch += ((prevOut >> 5) * pitch) >> 10, i.e.
      # modulation depth is +/-1.0x pitch (the old >>4 form was 2x too strong).
      if i > 0 and ((pmon shr i) and 1) != 0 and ((non shr i) and 1) == 0:
        pitch += ((prevOut shr 5) * pitch) shr 10
        if pitch < 0: pitch = 0
      # Advance the pitch counter, capped like hardware so PMOD extremes can't
      # skip ahead more than ~8 samples (blargg: interp_pos capped at 0x7FFF).
      var pos = v.pitchCounter.int32 + pitch
      if pos > 0x7FFF: pos = 0x7FFF
      while pos >= 0x1000:
        pos -= 0x1000
        # Shift the interpolation window and decode the next BRR sample.
        v.samples[0] = v.samples[1]
        v.samples[1] = v.samples[2]
        v.samples[2] = v.samples[3]
        v.samples[3] = decodeBrrNibble(v[], dsp.ram)
        if not v.active:
          break
      v.pitchCounter = pos.uint32
      if not v.active:
        prevOut = 0'i32
        continue
      dsp.stepEnvelope(i)
      # 4-tap Gaussian interpolation using pitch frac bits. Blargg-exact:
      # taps run on the full 16-bit (doubled) BRR samples, each tap >>11,
      # with a 16-bit wrap after the first three taps, then clamp and &~1.
      let frac = (v.pitchCounter and 0xFFF).uint32
      let ii = ((frac shr 4) and 0xFF).int   # 'i' is loop var; avoid shadow
      var interp = (Gaussian[0xFF - ii].int32 * v.samples[0]) shr 11
      interp += (Gaussian[0x1FF - ii].int32 * v.samples[1]) shr 11
      interp += (Gaussian[0x100 + ii].int32 * v.samples[2]) shr 11
      interp = cast[int16](interp and 0xFFFF).int32  # hw 16-bit wrap after 3 taps
      interp += (Gaussian[0x000 + ii].int32 * v.samples[3]) shr 11
      sample = clampS16(interp) and (not 1'i32)
    # Apply the envelope (blargg: (out * env) >> 11 & ~1). Samples are already
    # full 16-bit scale from the doubled BRR decode / noise, so no extra shift.
    let enveloped = ((sample * v.envLevel) shr 11) and (not 1'i32)
    prevOut = enveloped   # OUTX (post-env, pre-vol) for next voice's PMON if any.
    let volL = cast[int8](dsp.regs[i * 0x10 + 0]).int32
    let volR = cast[int8](dsp.regs[i * 0x10 + 1]).int32
    let contribL = (enveloped * volL) shr 7
    let contribR = (enveloped * volR) shr 7
    # Accumulate with per-voice 16-bit clamp (blargg voice_output).
    dryL = clampS16(dryL + contribL)
    dryR = clampS16(dryR + contribR)
    if ((eon shr i) and 1) != 0:
      echoInL = clampS16(echoInL + contribL)
      echoInR = clampS16(echoInR + contribR)

  # Echo: read the delayed sample from the buffer (ESA<<8, size EDL*2KB, 4 bytes
  # per stereo sample), run the 8-tap FIR, add the return to the mix, and write
  # (echo input + feedback) back into the buffer unless FLG bit 5 disables it.
  let esa = dsp.regs[0x6D].int
  let edl = (dsp.regs[0x7D] and 0x0F).int
  let bufBytes = if edl == 0: 4 else: edl * 0x800
  let echoPtr = ((esa shl 8) + dsp.echoOffset) and 0xFFFF
  let bufL = cast[int16](dsp.ram[echoPtr].uint16 or
    (dsp.ram[(echoPtr + 1) and 0xFFFF].uint16 shl 8)).int32
  let bufR = cast[int16](dsp.ram[(echoPtr + 2) and 0xFFFF].uint16 or
    (dsp.ram[(echoPtr + 3) and 0xFFFF].uint16 shl 8)).int32
  for t in 0..6:
    dsp.firHistL[t] = dsp.firHistL[t + 1]
    dsp.firHistR[t] = dsp.firHistR[t + 1]
  dsp.firHistL[7] = bufL
  dsp.firHistR[7] = bufR
  var firL = 0'i32
  var firR = 0'i32
  for t in 0..7:
    let coef = cast[int8](dsp.regs[t * 0x10 + 0x0F]).int32
    firL += (dsp.firHistL[t] * coef) shr 7
    firR += (dsp.firHistR[t] * coef) shr 7
  firL = clampS16(firL)
  firR = clampS16(firR)
  if (dsp.regs[0x6C] and 0x20) == 0:   # Echo write enabled.
    let efb = cast[int8](dsp.regs[0x0D]).int32
    let wL = clampS16(echoInL + ((firL * efb) shr 7))
    let wR = clampS16(echoInR + ((firR * efb) shr 7))
    dsp.ram[echoPtr] = (wL and 0xFF).uint8
    dsp.ram[(echoPtr + 1) and 0xFFFF] = ((wL shr 8) and 0xFF).uint8
    dsp.ram[(echoPtr + 2) and 0xFFFF] = (wR and 0xFF).uint8
    dsp.ram[(echoPtr + 3) and 0xFFFF] = ((wR shr 8) and 0xFF).uint8
  dsp.echoOffset += 4
  if dsp.echoOffset >= bufBytes:
    dsp.echoOffset = 0

  # Final DAC mix: dry * master volume + echo return * echo volume.
  let mvolL = cast[int8](dsp.regs[0x0C]).int32
  let mvolR = cast[int8](dsp.regs[0x1C]).int32
  let evolL = cast[int8](dsp.regs[0x2C]).int32
  let evolR = cast[int8](dsp.regs[0x3C]).int32
  let outL = ((dryL * mvolL) shr 7) + ((firL * evolL) shr 7)
  let outR = ((dryR * mvolR) shr 7) + ((firR * evolR) shr 7)
  result.left = int16(clampS16(outL))
  result.right = int16(clampS16(outR))
