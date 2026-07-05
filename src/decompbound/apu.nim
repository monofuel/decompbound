## The full APU: SPC700 core + S-DSP + timers behind the $F0-$FF I/O
## window. Standalone (no S-CPU needed): load a RAM image, set the entry
## point, feed port bytes, collect stereo samples (docs/audio.md Goal 2a).

import
  ./[dsp, spc700]

const
  CyclesPerSample* = 32  ## 1.024MHz / 32kHz.

type
  Timer = object
    enabled: bool
    target: uint8
    internal: uint8
    counter: uint8  ## 4-bit up-counter, cleared on read.
    accum: int      ## Cycle accumulator toward the next divisor tick.

  Apu* = ref object
    spc*: Spc
    dsp*: Dsp
    dspAddr: uint8
    timers: array[3, Timer]
    portsIn*: array[4, uint8]   ## What the S-CPU wrote ($2140-$2143).
    portsOut*: array[4, uint8]  ## What the SPC700 wrote back.
    cycleRemainder: int

proc newApu*(): Apu =
  ## Build the APU with I/O hooks installed.
  let apu = Apu()
  apu.spc = newSpc()
  apu.dsp = newDsp(apu.spc.ram)

  apu.spc.readHook = proc(address: uint16): int =
    case address:
    of 0x00F2: apu.dspAddr.int
    of 0x00F3: apu.dsp.read(apu.dspAddr).int
    of 0x00F4: apu.portsIn[0].int
    of 0x00F5: apu.portsIn[1].int
    of 0x00F6: apu.portsIn[2].int
    of 0x00F7: apu.portsIn[3].int
    of 0x00FD, 0x00FE, 0x00FF:
      let index = (address - 0x00FD).int
      let value = apu.timers[index].counter.int
      apu.timers[index].counter = 0
      value
    else: -1  # $F8/$F9 and unhandled registers fall through to RAM.

  apu.spc.writeHook = proc(address: uint16, value: uint8): bool =
    case address:
    of 0x00F1:
      for i in 0..2:
        let enable = ((value shr i) and 1) != 0
        if enable and not apu.timers[i].enabled:
          apu.timers[i].internal = 0
          apu.timers[i].counter = 0
        apu.timers[i].enabled = enable
      if (value and 0x10) != 0:
        apu.portsIn[0] = 0
        apu.portsIn[1] = 0
      if (value and 0x20) != 0:
        apu.portsIn[2] = 0
        apu.portsIn[3] = 0
      # Bit 7 maps/unmaps the IPL ROM at $FFC0-$FFFF. The uploaded driver
      # clears it to reclaim that RAM once boot is done.
      apu.spc.iplEnabled = (value and 0x80) != 0
      true
    of 0x00F2:
      apu.dspAddr = value
      true
    of 0x00F3:
      apu.dsp.write(apu.dspAddr, value)
      true
    of 0x00F4: apu.portsOut[0] = value; true
    of 0x00F5: apu.portsOut[1] = value; true
    of 0x00F6: apu.portsOut[2] = value; true
    of 0x00F7: apu.portsOut[3] = value; true
    of 0x00FA: apu.timers[0].target = value; true
    of 0x00FB: apu.timers[1].target = value; true
    of 0x00FC: apu.timers[2].target = value; true
    else: false

  result = apu

proc bootWithIpl*(apu: Apu) =
  ## Cold-boot the APU so it runs the real IPL ROM handshake (for the live
  ## two-way path). The reset vector in the IPL points at $FFC0; from there the
  ## IPL clears low RAM, signals readiness on the ports, and services the main
  ## CPU's driver upload. Contrast the offline player, which warm-starts by
  ## loading a captured image and jumping straight to the driver entry.
  apu.spc.iplEnabled = true
  apu.spc.pc = 0xFFC0
  apu.spc.sp = 0xEF
  apu.spc.a = 0
  apu.spc.x = 0
  apu.spc.y = 0
  apu.spc.psw = 0
  apu.spc.stopped = false

proc tickTimers*(apu: Apu, cycles: int) =
  ## Advance timers: T0/T1 at 8kHz (128 cycles), T2 at 64kHz (16 cycles).
  for i in 0..2:
    if not apu.timers[i].enabled:
      continue
    let divisor = if i == 2: 16 else: 128
    apu.timers[i].accum += cycles
    while apu.timers[i].accum >= divisor:
      apu.timers[i].accum -= divisor
      apu.timers[i].internal = apu.timers[i].internal + 1
      if apu.timers[i].internal == apu.timers[i].target:
        apu.timers[i].internal = 0
        apu.timers[i].counter = (apu.timers[i].counter + 1) and 0x0F

proc runSample*(apu: Apu): tuple[left: int16, right: int16] =
  ## Run the SPC700 for one 32kHz sample worth of cycles, tick timers,
  ## and mix one output sample.
  let startCycles = apu.spc.cycles
  while apu.spc.cycles - startCycles < CyclesPerSample and not apu.spc.stopped:
    apu.spc.step()
  # A stopped/sleeping core still lets timers advance.
  if apu.spc.stopped:
    apu.spc.cycles += CyclesPerSample
  apu.tickTimers(CyclesPerSample)
  result = apu.dsp.mixSample()
