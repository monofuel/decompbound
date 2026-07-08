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
    prevPc: uint16  ## For detecting transition into driver entry on IPL kick.

proc newApu*(): Apu =
  ## Build the APU with I/O hooks installed.
  let apu = Apu()
  apu.spc = newSpc()
  apu.dsp = newDsp(apu.spc.ram)
  apu.prevPc = 0'u16

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
  # Kick-to-driver hook (IPL path): when IPL lands exec at $0500 (via 1F 00 00
  # after len=0), normalize to the entry state the stub/driver expects (as used
  # in sound_explore direct start and captured during real IPL+pack1 upload).
  # This makes the post-upload ack (write 0 to port) happen promptly so
  # $C0AB90 exits. The data bytes themselves come from preload of pack 1.
  let curPc = apu.spc.pc
  if (curPc >= 0x0500'u16 and curPc < 0x0600'u16) and not (apu.prevPc >= 0x0500'u16 and apu.prevPc < 0x0600'u16):
    # Transition into driver area (IPL kick). Set entry state once.
    apu.spc.sp = 0xEF'u8
    apu.spc.a = 0
    apu.spc.x = 0
    apu.spc.y = 0
    apu.spc.psw = 0
  apu.prevPc = curPc

  let startCycles = apu.spc.cycles
  while apu.spc.cycles - startCycles < CyclesPerSample and not apu.spc.stopped:
    apu.spc.step()
  # A stopped/sleeping core still lets timers advance.
  if apu.spc.stopped:
    apu.spc.cycles += CyclesPerSample
  apu.tickTimers(CyclesPerSample)
  result = apu.dsp.mixSample()

proc loadPack*(apu: Apu, rom: seq[uint8], packIdx: int) =
  ## Load one music data pack's blocks directly into APU RAM (the same
  ## [len, target, payload...] format streamed by $C0AB06). Call this at boot
  ## to place pack 1 (the engine/driver) so the $0500 entry point and init
  ## code are present before the first song load that omits pack 1 from its
  ## list. The game relies on prior residency for such songs; our fresh IPL
  ## path does not perform that prior load.
  const PackTableFile = 0x04F947
  if packIdx < 0 or packIdx > 255: return
  let base = PackTableFile + packIdx * 3
  if base + 2 >= rom.len: return
  let bank = rom[base]
  let lo = rom[base + 1]
  let hi = rom[base + 2]
  let fileOff = ((bank and 0x3F).int shl 16) or ((hi.int shl 8) or lo.int)
  if fileOff <= 0 or fileOff >= rom.len: return
  var pos = fileOff
  while pos + 3 < rom.len:
    let len = (rom[pos + 0].int) or (rom[pos + 1].int shl 8)
    let tgt = (rom[pos + 2].int) or (rom[pos + 3].int shl 8)
    pos += 4
    if len == 0: break
    if pos + len > rom.len: break
    for i in 0..<len:
      let a = tgt + i
      if a >= 0 and a < 0x10000:
        apu.spc.ram[a] = rom[pos + i]
    pos += len
