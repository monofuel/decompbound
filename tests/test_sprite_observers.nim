import
  decompbound/[cpu, save_state, snesbus]

const
  Wram = 0x7E0000'u32
  Source = 0x0500
  OamBytes = 544

proc transfer(machine: SnesBus, source: uint32, length: int, mode = 0'u8) =
  ## Execute a real OAM DMA request through the public MMIO bus.
  machine.bus.write8(0x2102, 0)
  machine.bus.write8(0x2103, 0)
  machine.bus.write8(0x4300, mode)
  machine.bus.write8(0x4301, 4)
  machine.bus.write8(0x4302, (source and 255).uint8)
  machine.bus.write8(0x4303, ((source shr 8) and 255).uint8)
  machine.bus.write8(0x4304, (source shr 16).uint8)
  machine.bus.write8(0x4305, (length and 255).uint8)
  machine.bus.write8(0x4306, ((length shr 8) and 255).uint8)
  machine.bus.write8(0x420B, 1)

proc release(machine: SnesBus) =
  ## Remove callbacks before releasing synthetic machines.
  machine.wramWriteObserver = nil
  machine.oamDmaObserver = nil
  machine.resetObserver = nil
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc main() =
  ## Prove observer timing, mirror handling and DMA events do not change emulation.
  let
    rom = newSeq[uint8](3 * 1024 * 1024)
    candidate = newSnesBus(rom)
    reference = newSnesBus(rom)
  defer: candidate.release()
  defer: reference.release()
  var
    writes: seq[tuple[before, value: uint8]]
    instructions: seq[uint32]
    events: seq[OamDmaEvent]
    resets = 0
  candidate.observedWramBytes = {0x2C'u16}
  candidate.wramWriteObserver = proc(machine: SnesBus, address: uint16, value: uint8) =
    ## Observe the old value and the pending byte before either mirror writes it.
    doAssert address == 0x2C
    writes.add((machine.bus.mem[(Wram + address.uint32).int], value))
    instructions.add(machine.bus.storeInstructionAddress)
  candidate.oamDmaObserver = proc(machine: SnesBus, event: OamDmaEvent) =
    ## Inspect post-transfer bytes before copying the event.
    if event.executed and event.length == OamBytes:
      doAssert machine.oam[543] == uint8(543 and 255)
      doAssert machine.dmaRegs[5] == 0 and machine.dmaRegs[6] == 0
    events.add(event)
  candidate.resetObserver = proc(machine: SnesBus) =
    ## Count discontinuities without modifying the supplied bus.
    inc resets
  for index, address in [0x2C'u32, 0x7E002C, 0x80002C, 0x3F002C, 0xBF002C]:
    let value = (index + 1).uint8
    candidate.bus.write8(address, value)
    reference.bus.write8(address, value)
    doAssert writes[^1] == (index.uint8, value)
  candidate.bus.write8(0x7F002C, 99)
  reference.bus.write8(0x7F002C, 99)
  doAssert writes.len == 5
  candidate.bus.recordDirty = true
  reference.bus.recordDirty = true
  candidate.bus.write8(Wram + 0x2C, 9)
  reference.bus.write8(Wram + 0x2C, 9)
  doAssert candidate.bus.dirty == reference.bus.dirty
  candidate.bus.recordDirty = false
  reference.bus.recordDirty = false
  for index in 0 ..< OamBytes:
    candidate.bus.write8(Wram + Source.uint32 + index.uint32, uint8(index and 255))
    reference.bus.write8(Wram + Source.uint32 + index.uint32, uint8(index and 255))
  for bank in [0'u32, 0x7E, 0x80]:
    let source = (bank shl 16) or Source.uint32
    candidate.transfer(source, OamBytes)
    reference.transfer(source, OamBytes)
    doAssert events[^1] == OamDmaEvent(source: source, length: OamBytes,
      firstAddress: 0, mode: 0, executed: true)
    doAssert candidate.oam == reference.oam
    doAssert candidate.oamWriteSerial == reference.oamWriteSerial
    doAssert serializeState(candidate, Cpu()) == serializeState(reference, Cpu())
  candidate.transfer(Wram + Source.uint32, 1)
  reference.transfer(Wram + Source.uint32, 1)
  doAssert events[^1].length == 1
  candidate.dmaBytesThisFrame = MaxDmaBytesPerFrame
  reference.dmaBytesThisFrame = MaxDmaBytesPerFrame
  let previous = candidate.oamWriteSerial
  candidate.transfer(Wram + Source.uint32, OamBytes)
  reference.transfer(Wram + Source.uint32, OamBytes)
  doAssert not events[^1].executed
  doAssert candidate.oamWriteSerial == previous
  doAssert serializeState(candidate, Cpu()) == serializeState(reference, Cpu())
  candidate.bus.observeStoreInstructions = true
  for index, value in [0x9C'u8, 0x2C, 0, 0x8D, 0x2C, 0]:
    candidate.bus.write8(0x1E00'u32 + index.uint32, value)
    reference.bus.write8(0x1E00'u32 + index.uint32, value)
  var
    observedCpu = Cpu(pc: 0x1E00, dbr: 0x7E, a: 7)
    referenceCpu = observedCpu
  observedCpu.step(candidate.bus)
  referenceCpu.step(reference.bus)
  doAssert instructions[^1] == 0x1E00
  doAssert candidate.bus.storeInstructionAddress == 0
  observedCpu.step(candidate.bus)
  referenceCpu.step(reference.bus)
  doAssert instructions[^1] == 0x1E03
  doAssert candidate.bus.storeInstructionAddress == 0
  doAssert serializeState(candidate, observedCpu) == serializeState(reference, referenceCpu)
  candidate.bus.write8(0x2C, 0)
  reference.bus.write8(0x2C, 0)
  doAssert instructions[^1] == 0, "Direct writes must not inherit CPU provenance"
  candidate.bus.observeStoreInstructions = false
  candidate.resetUnserialized()
  reference.resetUnserialized()
  doAssert resets == 1 and candidate.oamWriteSerial == 0
  doAssert serializeState(candidate, Cpu()) == serializeState(reference, Cpu())

main()
