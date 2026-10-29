import
  std/[os, strformat],
  ../decompbound/[cpu, frame_step, png_state, rom_pipeline, save_state, snesbus,
    sprite_preview],
  ../../tests/world_map/original_cpu

const
  PrivateCapture = "earthbound_20260725-183101.png"
  GateTptId = 0x04CF
  GateResource = 0x01C8
  GateFlag = 0x0120
  GateX = 6016
  GateY = 7960
  ApproachY = 7940
  TptTableFile = 0x0F8985
  TptRecordBytes = 17
  SectorPointerFile = 0x0F61E7
  SectorColumns = 32
  SectorPixels = 256
  OriginalPopulation = 0xC0222B'u32
  OriginalRemoval = 0xC02140'u32
  ProbeDirectPage = 0x1A00
  PreservedFrameBase = 0x1C00
  PreservedFrameBytes = 0x400
  EventBits = 0x9C08
  GateFlagByte = EventBits + ((GateFlag - 1) div 8)
  GateFlagMask = 1'u8 shl ((GateFlag - 1) mod 8)
  PopulationMode = 0x4A58
  BlankShadow = 0x000D
  HeaderX = 0x9877
  HeaderY = 0x987B
  LeaderX = 0x0BBE
  LeaderY = 0x0BFA
  EntityTpt = 0x2C9A
  EntityX = 0x0B8E
  EntityY = 0x0BCA
  EntityLayout = 0x2B6E
  EntityCount = 30
  WarmupFrames = 60
  RemovalFrame = 210
  TotalFrames = 420
  JoyDown = 0x0400'u16

proc word(rom: seq[uint8], offset: int): int =
  ## Read original metadata without exporting the game asset it describes.
  rom[offset].int or (rom[offset + 1].int shl 8)

proc verifyMetadata(rom: seq[uint8]) =
  ## Verify the object and its sole placement against the independently derived formats.
  let
    record = TptTableFile + GateTptId * TptRecordBytes
    sector = (GateY div SectorPixels) * SectorColumns + GateX div SectorPixels
    list = 0x0F0000 + rom.word(SectorPointerFile + sector * 2)
    placement = list + 2
  doAssert record == 0x0FDB44 and placement == 0x0F82FD
  doAssert rom[record] == 1
  doAssert rom.word(record + 1) == GateResource
  doAssert rom.word(record + 6) == GateFlag and rom[record + 8] == 1
  doAssert rom.word(list) == 1 and rom.word(placement) == GateTptId
  doAssert (GateX div SectorPixels) * SectorPixels + rom[placement + 3].int == GateX
  doAssert (GateY div SectorPixels) * SectorPixels + rom[placement + 2].int == GateY
  for offset in 9 ..< TptRecordBytes: doAssert rom[record + offset] == 0
  echo &"Original TPT ${GateTptId:04X}, record ${record:06X}, placement ${placement:06X}: ({GateX},{GateY}), condition ${GateFlag:04X}."

proc callPreservingFrame(machine: SnesBus, target: uint32, a, x: int) =
  ## Preserve the suspended game's compiler scratch and stack around an original call.
  var originalFrame: array[PreservedFrameBytes, uint8]
  for index in 0 ..< originalFrame.len:
    originalFrame[index] = machine.bus.read8(OracleWram + (PreservedFrameBase + index).uint32)
  let blank = machine.bus.read8(OracleWram + BlankShadow.uint32)
  machine.bus.write8(OracleWram + BlankShadow.uint32, blank or 0x80)
  discard machine.callOriginal(target, a = a, x = x, directPage = ProbeDirectPage)
  machine.bus.write8(OracleWram + BlankShadow.uint32, blank)
  for index, value in originalFrame:
    machine.bus.write8(OracleWram + (PreservedFrameBase + index).uint32, value)

proc gateSlot(machine: SnesBus): int =
  ## Locate the original conditional object rather than assuming its allocator slot.
  result = -1
  for slot in 0 ..< EntityCount:
    if machine.wramWord(EntityTpt + slot * 2) == GateTptId: result = slot

proc main() =
  ## Reproduce the conditional invisible object's collision using a private original scene.
  if paramCount() > 1:
    raise newException(ValueError, "Usage: probe_story_hardware_gate [private pre-Hawk-Eye PNG]")
  let
    rom = readGoldBaserom()
    path = if paramCount() == 1: paramStr(1) else:
      getHomeDir() / "Pictures" / "Screenshots" / PrivateCapture
    state = extractStateForRom(cast[seq[uint8]](readFile(path)), romHashOf(rom))
    preview = buildSpritePreview(rom, GateResource, 0, 0)
  defer: preview.releaseOriginal()
  rom.verifyMetadata()
  for address in 0x4000 ..< 0x5800:
    doAssert preview.vram[address] == 0,
      "The gate graphics must be transparent rather than an opaque black cover."
  echo "Original sprite upload is entirely transparent."
  var blockedY, finalY: array[bool, int]
  for enabled in [false, true]:
    let machine = newSnesBus(rom)
    defer: machine.releaseOriginal()
    var core: Cpu
    deserializeState(state, machine, core)
    let oldFlag = machine.bus.read8(OracleWram + GateFlagByte.uint32)
    machine.bus.write8(OracleWram + GateFlagByte.uint32,
      if enabled: oldFlag or GateFlagMask else: oldFlag and not GateFlagMask)
    machine.putWord(HeaderX, GateX)
    machine.putWord(HeaderY, ApproachY)
    machine.putWord(LeaderX, GateX)
    machine.putWord(LeaderY, ApproachY)
    for frame in 0 ..< TotalFrames:
      machine.joy1 = if frame < WarmupFrames: 0 else: JoyDown
      machine.stepOneFrame(core, nil, render = false)
      if frame == WarmupFrames:
        let population = machine.wramWord(PopulationMode)
        # C0237A bypasses the incremental pass's visible-area skip in mode 1.
        machine.putWord(PopulationMode, 1)
        machine.callPreservingFrame(OriginalPopulation,
          GateX div SectorPixels, GateY div SectorPixels)
        machine.putWord(PopulationMode, population)
        let slot = machine.gateSlot()
        doAssert (slot >= 0) == not enabled
        echo &"Flag ${GateFlag:04X}={enabled}: original population gate slot={slot}."
        if slot >= 0:
          doAssert machine.wramWord(EntityX + slot * 2) == GateX
          doAssert machine.wramWord(EntityY + slot * 2) == GateY
          echo &"  Original entity layout={machine.wramWord(EntityLayout + slot * 2)}."
      if frame == RemovalFrame:
        blockedY[enabled] = machine.wramWord(LeaderY)
        if not enabled:
          let slot = machine.gateSlot()
          doAssert slot >= 0
          machine.callPreservingFrame(OriginalRemoval, slot, 0)
          doAssert machine.gateSlot() == -1
          echo &"Clear-state leader stopped atY={blockedY[enabled]}; removed only the original gate entity."
    finalY[enabled] = machine.wramWord(LeaderY)
    doAssert ((machine.bus.read8(OracleWram + GateFlagByte.uint32) and GateFlagMask) != 0) == enabled
  doAssert blockedY[false] == ApproachY + 1
  doAssert blockedY[true] == GateY
  doAssert finalY[false] > blockedY[false] and finalY[false] == finalY[true]
  echo &"Original gate witness passed: clear-state stopY={blockedY[false]}, set-stateY={blockedY[true]}, after removal both reachY={finalY[false]}."
  echo "This controlled local collision witness does not prove a complete natural travel route."

main()
