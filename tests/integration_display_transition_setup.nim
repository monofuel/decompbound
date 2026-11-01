## Original display-transition setter widths/banks and produced-state NMI consumption.
## Uses core CPU/PPU hooks only; no frontend, audio device, game assets or patched instructions.
## Hardware-NMI contexts stop after brightness; complete interrupt return, visuals and cadence are excluded.
import
  std/strformat,
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/rebuilt_rom

const
  Caller = 0x1E00'u32
  StackTop = 0x1FFF'u16
  Guard = 0xA5'u8
  Setter = 0xC0886C'u32
  ConsumerStart = 0x81F7'u16
  ConsumerEnd = 0x8226'u16
  Banks = [0'u8, 0x7E, 0x7F]
  DirectPages = [0'u16, 0x0200, 0x1200]
  Edges = [0, 1, 127, 128, 129, 255]

type Totals = object
  setters, ticks, chains, completedTransitions, callers, nmis: int

proc runUntil(snes: SnesBus, state: var Cpu, bank: uint8, pc: uint16) =
  ## Execute unchanged cartridge instructions to an explicit native return or fragment boundary.
  var steps = 0
  while state.pbr != bank or state.pc != pc:
    doAssert steps < 64
    state.step(snes.bus)
    inc steps

proc checkSetter(snes: SnesBus, step, reload: int, status, bank: uint8,
    direct: uint16) =
  ## Verify low-byte stores, restored status and permanent index truncation in a real JSL frame.
  let
    destination = bank.uint32 shl 16
    a = (0xB600 or step).uint16
    x = (if (status and FlagX) == 0: 0xA700 or reload else: reload).uint16
    y = (if (status and FlagX) == 0: 0xCD83 else: 0x83).uint16
  for address in 0x25 .. 0x2D: snes.bus.write8(destination + address.uint32, Guard)
  if direct != 0:
    for offset in 0x28 .. 0x2A: snes.bus.write8(direct.uint32 + offset.uint32, 0x6C)
  snes.bus.write8(0x1FFB, Guard)
  snes.bus.write8(0x1F00, Guard)
  var state = Cpu(pc: Caller.uint16, a: a, x: x, y: y, p: status,
    dbr: bank, d: direct, s: StackTop)
  snes.runUntil(state, 0, (Caller + 4).uint16)
  doAssert state.a == a and state.x.int == reload and state.y == 0x83
  doAssert state.p == status and state.d == direct and state.dbr == bank
  doAssert state.s == StackTop and not state.emulation
  for address in 0x25 .. 0x2D:
    let expected = case address
      of 0x28: step.uint8
      of 0x29, 0x2A: reload.uint8
      else: Guard
    doAssert snes.bus.read8(destination + address.uint32) == expected
  if direct != 0:
    for offset in 0x28 .. 0x2A:
      doAssert snes.bus.read8(direct.uint32 + offset.uint32) == 0x6C
  doAssert snes.bus.read8(0x1FFB) == Guard and snes.bus.read8(0x1F00) == Guard

proc tick(snes: SnesBus, step, reload, count, brightness, hdma: var int) =
  ## Apply an independent byte-arithmetic brightness oracle to the actual NMI fragment.
  if step != 0:
    count = (count - 1) and 255
    if count >= 128:
      count = reload
      let sum = ((brightness and 15) + step) and 255
      if sum >= 128:
        brightness = 128
        hdma = 0
        step = 0
      elif sum >= 16:
        brightness = 15
        step = 0
      else:
        brightness = sum
  var state = Cpu(pbr: 0xC0, pc: ConsumerStart, p: 0, d: 0, dbr: 0,
    s: StackTop, a: 0xBEEF, x: 0x1234, y: 0x5678)
  snes.runUntil(state, 0xC0, ConsumerEnd)
  doAssert state.s == StackTop and state.d == 0 and state.dbr == 0
  doAssert snes.bus.read8(0x28).int == step
  doAssert snes.bus.read8(0x29).int == reload
  doAssert snes.bus.read8(0x2A).int == count
  doAssert snes.bus.read8(0x0D).int == brightness
  doAssert snes.bus.read8(0x1F).int == hdma
  doAssert snes.ppuRegs[0].int == brightness

proc checkNmiSetup(snes: SnesBus, status: uint8) =
  ## Enter the original hardware vector/prologue and preserve its real frame through brightness only.
  for address in 0 .. 0x3F: snes.bus.write8(address.uint32, 0)
  var state = Cpu(pbr: 0xC0, pc: 0x1234, s: StackTop, d: 0xB700, dbr: 0x7F,
    a: 0xBEEF, x: 0x1234, y: 0x5678, p: status, nmiPending: true)
  var steps = 0
  while state.pc != ConsumerStart or state.pbr != 0xC0:
    doAssert steps < 128
    state.step(snes.bus)
    inc steps
  doAssert state.d == 0 and state.dbr == 0 and state.s == 0x1FF1
  doAssert (state.p and (FlagM or FlagX or FlagD)) == FlagX
  doAssert (state.p and FlagI) != 0
  # The hardware frame contains the interrupted native PC/bank and original P.
  doAssert snes.bus.read8(0x1FFF) == 0xC0
  doAssert snes.bus.read8(0x1FFE) == 0x12 and snes.bus.read8(0x1FFD) == 0x34
  doAssert snes.bus.read8(0x1FFC) == status
  let
    frame = snes.bus.mem[0x7E1F00 .. 0x7E1FFF]
    savedX = state.x
    savedY = state.y
  while state.pc != ConsumerEnd or state.pbr != 0xC0:
    doAssert steps < 160
    state.step(snes.bus)
    inc steps
  doAssert state.s == 0x1FF1 and state.d == 0 and state.dbr == 0
  doAssert state.x == savedX and state.y == savedY
  doAssert (state.p and (FlagM or FlagX or FlagD)) == FlagM
  doAssert snes.bus.mem[0x7E1F00 .. 0x7E1FFF] == frame
  doAssert snes.ppuRegs[0] == 0

proc checkImage(image: seq[uint8]): Totals =
  ## Cover complete byte inputs, all statuses and actual setter-to-NMI state transfer.
  let snes = newSnesBus(image)
  let wrapper = assembleAsm(".a16\n.i16\nJSL $C0886C\n", Caller)
  for index, value in wrapper: snes.bus.write8(Caller + index.uint32, value)
  for step in 0 .. 255:
    for reload in 0 .. 255:
      snes.checkSetter(step, reload, 0, 0, 0x0200)
      inc result.setters
  for status in 0 .. 255:
    for bank in Banks:
      for direct in DirectPages:
        for edge in Edges:
          snes.checkSetter(edge, edge xor 255, status.uint8, bank, direct)
          inc result.setters
  for bank in Banks:
    for stepValue in 0 .. 255:
      for reloadValue in Edges:
        for initial in [0, 1, 7, 14, 15, 0x8F]:
          snes.bus.write8(0x28, 0)
          snes.bus.write8(0x29, 0x36)
          snes.bus.write8(0x2A, 0x42)
          snes.checkSetter(stepValue, reloadValue, 0, bank, 0x0200)
          snes.bus.write8(0x0D, initial.uint8)
          snes.bus.write8(0x1F, 0x5A)
          var
            step = if bank == 0x7F: 0 else: stepValue
            reload = if bank == 0x7F: 0x36 else: reloadValue
            count = if bank == 0x7F: 0x42 else: reloadValue
            brightness = initial
            hdma = 0x5A
          for iteration in 0 .. 2:
            snes.tick(step, reload, count, brightness, hdma)
            inc result.ticks
          inc result.chains
  for stepValue in [1, 255]:
    for reloadValue in Edges:
      for initial in [0, 7, 15, 0x80]:
        snes.checkSetter(stepValue, reloadValue, 0, 0, 0x0200)
        snes.bus.write8(0x0D, initial.uint8)
        snes.bus.write8(0x1F, 0x5A)
        var
          step = stepValue
          reload = reloadValue
          count = reloadValue
          brightness = initial
          hdma = 0x5A
          ticks = 0
        while step != 0:
          doAssert ticks < 4096
          snes.tick(step, reload, count, brightness, hdma)
          inc ticks
          inc result.ticks
        doAssert brightness == (if stepValue == 1: 15 else: 128)
        if stepValue == 255: doAssert hdma == 0
        inc result.completedTransitions
  # The original B7FD caller sets A=X=1 before invoking the setter itself.
  var state = Cpu(pbr: 0xC0, pc: 0xB7FD, p: 0, dbr: 0, d: 0x0200,
    s: StackTop, a: 0xFFFF, x: 0xFFFF, y: 0xABCD)
  snes.runUntil(state, 0xC0, 0xB805)
  doAssert state.a == 1 and state.x == 1 and state.y == 0xCD
  doAssert state.s == StackTop and state.d == 0x0200
  for address in 0x28 .. 0x2A: doAssert snes.bus.read8(address.uint32) == 1
  inc result.callers
  for status in [0'u8, FlagD or FlagN or FlagV or FlagC]:
    snes.checkNmiSetup(status)
    inc result.nmis

proc main() =
  ## Require original and independently rebuilt images to pass the same mathematical contracts.
  var totals: Totals
  for image in engineImages("bin/engine-display-transition-setup"):
    let checked = checkImage(image)
    totals.setters += checked.setters
    totals.ticks += checked.ticks
    totals.chains += checked.chains
    totals.completedTransitions += checked.completedTransitions
    totals.callers += checked.callers
    totals.nmis += checked.nmis
  echo &"Display transition setup passed: {totals.setters} direct setter cases, {totals.chains} three-tick produced-state chains, {totals.completedTransitions} complete transitions, {totals.ticks} oracle fragment ticks, {totals.callers} original callers and {totals.nmis} hardware-NMI/prologue contexts."

when isMainModule:
  main()
