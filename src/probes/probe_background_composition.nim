## Inspect original battle-background loader paths and execute a selected group.
## Run with: nim r src/probes/probe_background_composition.nim [group-id [layer-b [flags]]].
## The explicit $000D=$80 requests the game's immediate DMA path, avoiding
## the NMI-dependent queue in this isolated original-CPU execution.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[asm_parse, cpu, ppu, rom_pipeline, snesbus]

const
  PairBase = 0x0BD89A
  GroupBase = 0x10C60D
  LayerBase = 0x0ADCA1
  StepLimit = 3000000
  Caller = 0x1F00'u32
  ReturnPc = 0x1F04'u16

proc word(rom: openArray[uint8], p: int): int =
  ## Read one little-endian ROM word.
  rom[p].int or (rom[p + 1].int shl 8)

proc checkSyntheticPixels(snes: SnesBus) =
  ## Check all transparency combinations with loader-selected mode and math.
  let image = newImage(256, 224)
  snes.ppuRegs[0] = 15
  snes.ppuRegs[0x2C] = 0x04
  snes.ppuRegs[0x2D] = 0x08
  snes.cgram[0] = 0x03E0
  snes.cgram[65] = 0x001F
  snes.cgram[97] = 0x7C00
  snes.vram[0x5C00] = 0
  snes.vram[0x0C00] = 0
  snes.vram[0x1000] = 0x00C0
  snes.vram[0x3000] = 0x00A0
  for fixedRed in [0'u8, 5'u8]:
    snes.fixedColorR = fixedRed
    snes.fixedColorG = 0
    snes.fixedColorB = 0
    let fixedR = if fixedRed == 0: 0'u8 else: 41'u8
    let expected = [(123'u8, 0'u8, 123'u8), (255'u8, 0'u8, 0'u8),
      (0'u8, 123'u8, 123'u8), (fixedR, 255'u8, 0'u8)]
    snes.renderScanline(image, 0)
    for i in 0 .. 3:
      let actual = image.data[i]
      doAssert (actual.r, actual.g, actual.b) == expected[i],
        &"pixel {i}, fixed red {fixedRed}: {actual} != {expected[i]}"
  echo "synthetic PPU: four main/sub transparency cases pass, including nonblack fixed color"

proc main() =
  ## Inventory ordinary groups and run the original loader for one pair.
  let
    rom = readGoldBaserom()
    gid = if paramCount() > 0: parseInt(paramStr(1)) else: 39
  if gid < 0 or gid >= 484: raise newException(ValueError, "Invalid group id.")
  let
    a = word(rom, PairBase + gid * 4)
    b = if paramCount() > 1: parseInt(paramStr(2)) else: word(rom, PairBase + gid * 4 + 2)
    opt = if paramCount() > 2: parseInt(paramStr(3)) else: rom[GroupBase + gid * 8 + 7].int
  var pairs, second: array[5, int]
  for g in 0 ..< 484:
    let x = word(rom, PairBase + g * 4)
    let y = word(rom, PairBase + g * 4 + 2)
    if x > 0 and y > 0:
      let bpp = rom[LayerBase + x * 17 + 2].int
      if bpp < pairs.len: inc pairs[bpp]
      let otherBpp = rom[LayerBase + y * 17 + 2].int
      if otherBpp < second.len: inc second[otherBpp]
  echo &"two-layer group counts by first-layer bpp: {pairs}; second: {second}"
  echo &"group={gid} layers={a},{b} first-bpp={rom[LayerBase + a * 17 + 2]} second-bpp={rom[LayerBase + b * 17 + 2]} options={opt}"
  let
    snes = newSnesBus(rom)
    code = assembleAsm(".a16\n.i16\nJSL $C2D121\n", Caller)
  for i, value in code: snes.bus.write8(Caller + i.uint32, value)
  snes.cgram[0] = 0x1234
  snes.fixedColorR = 5
  snes.fixedColorG = 6
  snes.fixedColorB = 7
  snes.bus.write8(0x7E000D, 0x80)
  snes.bus.write8(0x7E0200, 0x34)
  snes.bus.write8(0x7E0201, 0x12)
  snes.bus.write8(0x7E4A8C, uint8(gid and 255))
  snes.bus.write8(0x7E4A8D, uint8(gid shr 8))
  var c = Cpu(pc: Caller.uint16, s: 0x1FFF, d: 0x1A00, dbr: 0x7E,
    a: uint16(a), x: uint16(b), y: uint16(opt))
  var steps = 0
  var seen: array[5, int]
  while c.pbr != 0 or c.pc != ReturnPc:
    if steps >= StepLimit:
      raise newException(ValueError, &"Loader did not return: {c.pbr:02X}:{c.pc:04X}")
    if c.pbr == 0xC2:
      case c.pc
      of 0xD317: inc seen[0]
      of 0xD714: inc seen[1]
      of 0xD4B5: inc seen[2]
      of 0xD6DF: inc seen[3]
      of 0xDAB2: inc seen[4]
      else: discard
    let before = (snes.fixedColorR, snes.fixedColorG, snes.fixedColorB)
    let oldBank = c.pbr
    let oldPc = c.pc
    c.step(snes.bus)
    let after = (snes.fixedColorR, snes.fixedColorG, snes.fixedColorB)
    if before != after:
      echo &"COLDATA at {oldBank:02X}:{oldPc:04X}: {before} -> {after}"
    inc steps
  echo &"steps={steps} done={c.pbr == 0 and c.pc == ReturnPc} path=[4bpp,2bpp,preset7,second-params,finish]={seen}"
  echo &"ppu BGMODE={snes.ppuRegs[5]:02X} BG3SC={snes.ppuRegs[9]:02X} BG4SC={snes.ppuRegs[10]:02X} BG34NBA={snes.ppuRegs[12]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} CGADSUB={snes.ppuRegs[0x31]:02X}"
  if gid == 39 and paramCount() < 2:
    doAssert seen == [0, 1, 0, 0, 1]
    doAssert snes.ppuRegs[5] == 0x08 and snes.ppuRegs[9] == 0x5C
    doAssert snes.ppuRegs[10] == 0x0C and snes.ppuRegs[12] == 0x31
    doAssert snes.ppuRegs[0x30] == 0x02 and snes.ppuRegs[0x31] == 0x64
    doAssert snes.bus.read8(0x7E0200) == 0x34 and snes.bus.read8(0x7E0201) == 0x12
    echo &"loader CGRAM0={snes.cgram[0]:04X}; fixed={snes.fixedColorR},{snes.fixedColorG},{snes.fixedColorB}"
    echo "loader leaves synthetic palette-staging CGRAM0 sentinel unchanged"
    snes.checkSyntheticPixels()
  for address in [0x001A, 0x001B, 0xAD8A, 0xADAE, 0xADB0, 0xAE4B, 0xAE4D]:
    let value = snes.bus.read8(0x7E0000'u32 + address.uint32)
    echo &"WRAM {address:04X}={value:02X}"

when isMainModule: main()
