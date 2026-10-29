import
  std/[options, os, strutils],
  pixie,
  decompbound/[cpu, ds_companion, eb_ui_assets, party_sram, party_wram,
    png_state, rom_pipeline, save_state, snesbus]

const
  Wram = 0x7E0000
  WramSize = 0x20000
  PreviewPath = "bin/earthbound-ds-ui-preview.png"

proc main() =
  ## Render a generated party or optional local capture and verify read-only behavior.
  let
    rom = readGoldBaserom()
    machine = newSnesBus(rom)
    view = newDsCompanion(rom)
  var state = machine.resetCpu()
  if paramCount() > 0:
    let
      path = paramStr(1)
      data = cast[seq[uint8]](readFile(path))
      raw = if path.endsWith(".png"): extractState(data).get else: data
    deserializeState(raw, machine, state)
  else:
    machine.bus.mem[Wram + PartyCountWram] = PlayableCharCount.uint8
    machine.bus.mem[Wram + UiFlavorWram] = 1
    for id in 1 .. PlayableCharCount:
      let base = Wram + PartyCharTableWram + (id - 1) * CharStride
      machine.bus.mem[Wram + PartyRosterWram + id - 1] = id.uint8
      machine.bus.mem[base] = uint8(0x70 + id)
      machine.bus.mem[base + CharLevelOff] = 1
      machine.bus.mem[base + CharHpCurOff] = uint8(100 + id)
      machine.bus.mem[base + CharPpCurOff] = uint8(id * 10)
      for slot in 0 ..< CharInventoryLen:
        machine.bus.mem[base + CharInventoryOff + slot] = uint8(slot + 1)
      machine.bus.mem[base + CharEquipOff] = 14
  let before = serializeState(machine, state)
  let battle = partyBattleVisible(machine.bus.mem.toOpenArray(Wram, Wram + WramSize - 1),
    (machine.ppuRegs[0x05] and 7).int)
  if paramCount() > 0:
    view.update(machine.bus.mem.toOpenArray(Wram, Wram + WramSize - 1), 0,
      DsPointer(), battle, machine.cgram.toOpenArray(0, 31))
  else:
    view.update(machine.bus.mem.toOpenArray(Wram, Wram + WramSize - 1), 0,
      DsPointer(), battle)
  doAssert serializeState(machine, state) == before, "UI rendering changed machine state"
  doAssert view.image.width == DsPanelWidth and view.image.height == DsPanelHeight
  if paramCount() > 0:
    createDir("bin")
    view.image.writeFile(PreviewPath)
  block sparseGoods:
    var
      sparse = DsMember(id: 1, name: "A", hp: 99, pp: 12)
      packed: DsMember
    sparse.inventory[3] = DsItem(id: 1, name: "A")
    sparse.inventory[13] = DsItem(id: 2, name: "B", equipped: true)
    packed = sparse
    packed.inventory = default(typeof(packed.inventory))
    packed.inventory[0] = sparse.inventory[3]
    packed.inventory[1] = sparse.inventory[13]
    let
      sparseView = newDsCompanion(rom)
      packedView = newDsCompanion(rom)
    sparseView.update(@[sparse], 0, DsPointer())
    packedView.update(@[packed], 0, DsPointer())
    doAssert sparseView.image.data == packedView.image.data,
      "Goods must compact nonempty slots in storage order, including equipped slot 14"
    packed.inventory[0].name = "AA"
    packedView.update(@[packed], 0, DsPointer(), tracking = 0)
    let compactPixels = packedView.image.data & @[]
    packedView.update(@[packed], 0, DsPointer(), tracking = 1)
    doAssert compactPixels != packedView.image.data,
      "A spacing-only change must redraw proportional Goods text"

main()
