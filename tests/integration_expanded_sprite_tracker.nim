import
  decompbound/[asm_parse, cpu, expanded_sprite_tracker, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Init = 0x200'u32
  Publish = 0x220'u32
  Enqueue = 0x240'u32
  Definition = 0x7F4000'u32

proc writeWord(machine: SnesBus, address: uint32, value: int) =
  ## Write a little-endian word through the normal bus interface.
  machine.bus.write8(address, (value and 255).uint8)
  machine.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc put(machine: SnesBus, address, value: int) =
  ## Install a synthetic WRAM word through the normal mirror interface.
  machine.writeWord(Wram + address.uint32, value)

proc run(machine: SnesBus, caller: uint32, a = 0, x = 0, y = 0, length = 4) =
  ## Execute an original ROM routine via a four-byte trampoline.
  var cpu = Cpu(pc: caller.uint16, s: 0x1FFF, dbr: 0x7E,
    a: a.uint16, x: x.uint16, y: y.uint16)
  var steps = 0
  while cpu.pbr != 0 or cpu.pc != (caller + length.uint32).uint16:
    doAssert steps < 10000
    cpu.step(machine.bus)
    inc steps

proc transfer(machine: SnesBus, lane: int, length = 544) =
  ## Transfer one published buffer with the same ordinary OAM DMA shape as NMI.
  machine.bus.write8(0x2102, 0)
  machine.bus.write8(0x2103, 0)
  machine.bus.write8(0x4300, 0)
  machine.bus.write8(0x4301, 4)
  machine.writeWord(0x4302, [0x500, 0x800][lane - 1])
  machine.bus.write8(0x4304, 0x7E)
  machine.writeWord(0x4305, length)
  machine.bus.write8(0x420B, 1)
  machine.bus.write8(0x2C, 0)

proc actor(machine: SnesBus, slot, x, y, group: int) =
  ## Define an ordinary active body with a tiny authored one-record definition.
  let offset = slot * 2
  machine.put(0x0A9E + offset, if slot == 2: 0xFFFF else: offset + 2)
  for field in [0x0B8E, 0x0B16]: machine.put(field + offset, x)
  for field in [0x0BCA, 0x0B52]: machine.put(field + offset, y)
  machine.put(0x103E + offset, group)
  machine.put(0x10F2 + offset, 0)
  machine.put(0x112E + offset, 0x4000 + slot * 8)
  machine.put(0x116A + offset, 0x7F)
  machine.put(0x11A6 + offset, 0xA023)
  machine.put(0x11E2 + offset, 0xA3A4)
  machine.put(0x2CD6 + offset, slot)
  machine.put(0x2BE6 + offset, 0x0100)
  let address = Definition + (slot * 8).uint32
  for index, value in [0'u8, slot.uint8, 0x30, 0, 0x80]:
    machine.bus.write8(address + index.uint32, value)

proc publish(machine: SnesBus, lane: int) =
  ## Build empty native OAM while presentation reconstructs only genuinely culled bodies.
  machine.put(0x2E, lane)
  machine.run(Init)
  machine.bus.write8(Wram + 9, if lane == 1: 0'u8 else: 0x7E'u8)
  machine.run(Publish)

proc requestPhase(machine: SnesBus, phase: int) =
  ## Execute the original phase request; offscreen C711 rejects its hardware upload.
  let code = assembleAsm(".a16\n.i16\nJSL $C0A4" &
    (if phase == 0: "A8" else: "B2") & "\n", 0x260)
  for index, value in code: machine.bus.write8(0x260'u32 + index.uint32, value)
  machine.run(0x260)

proc checkAnimation(machine: SnesBus, tracker: ExpandedSpriteTracker, slot: int) =
  ## Rebuild skipped phase requests privately and invalidate provenance on resource release.
  let offset = slot * 2
  machine.actor(slot, 350, 60, 1)
  machine.put(0x0A50, offset)
  machine.put(0x0A9E + offset, 0xFFFF)
  machine.put(0x1A42, slot)
  machine.put(0x1A44, offset)
  machine.put(0x88, offset)
  machine.put(0x2ABA + offset, 2)
  machine.put(0x2A7E + offset, 64)
  machine.put(0x298E + offset, 0x4000)
  machine.put(0x29CA + offset, 0x5000)
  machine.put(0x2A06 + offset, 0x7F)
  machine.put(0x2A42 + offset, 0x7F)
  machine.put(0x2AF6 + offset, 0)
  machine.put(0x341A + offset, 0)
  machine.put(0x2892, 0xFFFF)
  for index in 0 ..< 32:
    machine.writeWord(0x7F5000'u32 + (index * 2).uint32,
      if index mod 2 == 0: 0x6002 else: 0x6102)
  for index in 0 ..< 128:
    machine.bus.write8(0x7F6000'u32 + index.uint32, 0x11)
    machine.bus.write8(0x7F6100'u32 + index.uint32, 0x22)
  let before = machine.vram
  machine.requestPhase(0)
  doAssert machine.vram == before
  machine.publish(1)
  machine.transfer(1)
  let first = tracker.displayed(machine, 0, 0)
  doAssert first != nil and first.textures.len == 1
  doAssert first.textures[0].entry == 0x6002
  doAssert first.textures[0].words[0] == 0x1111
  machine.requestPhase(1)
  doAssert machine.vram == before
  machine.publish(2)
  machine.transfer(2)
  let second = tracker.displayed(machine, 0, 0)
  doAssert second.textures.len == 1
  doAssert second.textures[0].entry == 0x6102
  doAssert second.textures[0].words[0] == 0x2222
  doAssert first.textures[0].words[0] == 0x1111, "Published private textures must remain frozen"
  machine.bus.write8(0x7F6100, 0x33)
  machine.requestPhase(1)
  machine.publish(1)
  machine.transfer(1)
  doAssert tracker.displayed(machine, 0, 0).textures[0].words[0] == 0x2233,
    "Mutable source bytes must not reuse a stale texture cache"
  doAssert machine.bus.read16(Wram + (0x341A + offset).uint32) == 0
  machine.put(0x2CD6 + offset, 0xFFFF)
  machine.put(0x2CD6 + offset, slot)
  machine.publish(1)
  machine.transfer(1)
  doAssert tracker.displayed(machine, 0, 0).textures.len == 0

proc checkIndirectQueues(machine: SnesBus, tracker: ExpandedSpriteTracker) =
  ## Distinguish raw IDs from doubled offsets and retain queues cleared by native drawing.
  machine.put(0x0A50, 0)
  for target in [1, 2, 29]:
    machine.actor(0, 350, 60, 0xC000 or target)
    machine.put(0x0A9E, 0xFFFF)
    machine.put(0x103E + target * 2, 2)
    machine.publish(1)
    machine.transfer(1)
    let frame = tracker.displayed(machine, 0, 0)
    doAssert frame.elements.len == 1 and frame.elements[0].queue == 2
  machine.actor(0, 300, 60, 0x8001)
  machine.put(0x0A9E, 0xFFFF)
  machine.put(0x103E + 2, 1)
  machine.put(0x2E, 2)
  machine.run(Init)
  machine.bus.write8(Wram + 9, 0x7E)
  machine.put(0x88, 0)
  machine.put(0x8C, 0x4000)
  machine.bus.write8(Wram + 0x8E, 0x7F)
  let code = assembleAsm(".a16\n.i16\nJSR $A3A4\n", 0x280)
  for index, value in code: machine.bus.write8(0x280'u32 + index.uint32, value)
  machine.run(0x280, length = 3)
  doAssert machine.bus.read16(Wram + 0x103E) == 0
  machine.run(Publish)
  machine.transfer(2)
  let frame = tracker.displayed(machine, 0, 0)
  doAssert frame != nil and frame.elements.len == 1
  doAssert frame.elements[0].queue == 1 and frame.elements[0].x == 300

proc main() =
  ## Exercise publication ownership, snapshots, draw gates, sorting and reset boundaries.
  let
    machine = newSnesBus(readGoldBaserom())
    tracker = newExpandedSpriteTracker()
  defer:
    tracker.detach(machine)
    machine.bus.readHook = nil
    machine.bus.writeHook = nil
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil
  for entry in [(Init, "JSL $C088B1"), (Publish, "JSL $C08B26"),
      (Enqueue, "JSL $C08C54")]:
    let code = assembleAsm(".a16\n.i16\n" & entry[1] & "\n", entry[0])
    for index, value in code: machine.bus.write8(entry[0] + index.uint32, value)
  tracker.attach(machine)
  machine.put(0x0A50, 0)
  machine.put(0x0A5E, 0xDB0F)
  machine.actor(0, 350, 60, 1)
  machine.actor(1, 360, 90, 1)
  machine.actor(2, -90, 50, 0)
  machine.publish(1)
  machine.transfer(1)
  let first = tracker.displayed(machine, 0, 0)
  doAssert first != nil, tracker.status
  doAssert first.elements.len == 3
  doAssert first.elements[0].tile == 2
  doAssert first.elements[1].tile == 1
  doAssert first.elements[2].tile == 0
  doAssert first.elements[2].x == 350
  machine.actor(0, 370, 60, 1)
  machine.bus.write8(Definition + 1, 9)
  machine.publish(2)
  machine.transfer(1)
  let frozen = tracker.displayed(machine, 0, 0)
  doAssert frozen == first
  doAssert frozen.elements[2].x == 350 and frozen.elements[2].tile == 0
  machine.transfer(2)
  let second = tracker.displayed(machine, 0, 0)
  doAssert second != nil and second != first
  doAssert second.elements[2].x == 370 and second.elements[2].tile == 9
  doAssert tracker.displayed(machine, 1, 0) == nil
  doAssert tracker.displayed(machine, 0, 0) == second
  machine.bus.write8(0x2104, machine.oam[0])
  doAssert tracker.displayed(machine, 0, 0) == nil
  machine.transfer(2)
  doAssert tracker.displayed(machine, 0, 0) == second
  machine.transfer(2, 4)
  doAssert tracker.displayed(machine, 0, 0) == nil
  machine.put(0x2CD6, 0xFFFF)
  machine.put(0x10F2 + 2, 0xFFFF)
  machine.publish(1)
  machine.transfer(1)
  doAssert tracker.displayed(machine, 0, 0).elements.len == 1
  machine.put(0x0067, 0x2000)
  machine.publish(2)
  machine.transfer(2)
  doAssert tracker.displayed(machine, 0, 0).elements.len == 0
  machine.put(0x0067, 0)
  machine.put(0x0A5E, 0)
  machine.publish(1)
  machine.transfer(1)
  doAssert tracker.displayed(machine, 0, 0).elements.len == 0
  machine.put(0x0A5E, 0xDB0F)
  machine.actor(2, 20, 50, 0)
  machine.publish(2)
  machine.transfer(2)
  doAssert tracker.displayed(machine, 0, 0).elements.len == 0,
    "An in-window actor suppressed by the game must stay suppressed"
  checkIndirectQueues(machine, tracker)
  for slot in [0, 1, 2, 29]: checkAnimation(machine, tracker, slot)
  machine.put(0x31, -19)
  machine.put(0x33, -1)
  machine.publish(1)
  machine.transfer(1)
  let edge = tracker.displayed(machine, -19, -1)
  doAssert edge != nil, "Signed camera did not match the native published words"
  doAssert edge.published.camera[0] == 0xFFED and edge.published.camera[1] == 0xFFFF
  doAssert tracker.displayed(machine, -20, -1) == nil
  doAssert tracker.displayed(machine, -19, -1) == edge
  machine.resetUnserialized()
  doAssert tracker.displayed(machine, 0, 0) == nil
  doAssert tracker.status == "awaiting-publication"

main()
