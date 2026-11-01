import
  std/[sets, strformat, tables],
  decompbound/[apu, manifest, music_player, spc700],
  ./engine/rebuilt_rom

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  StartupDone = 0x0546
  PointerTables = [0x180D, 0x17D5, 0x17C5, 0x16C7]
  PortEntries = [0x1184, 0x1198, 0x11BA, 0x11DC]
  LookupJump = 0x1258
  KindTable = 0x125B
  NativeKind = 8
  ReturnAddress = 0x5000
  SongId = 3

proc word(spc: Spc, address: int): int =
  ## Read a wrapping structural word without exporting record content.
  spc.ram[address and 65535].int or
    (spc.ram[(address + 1) and 65535].int shl 8)

proc boot(image: seq[uint8], withSong: bool): Spc =
  ## Execute the real package initialization without mixing audio or opening a device.
  let machine = newApu()
  applyPackageBlocks(machine.spc.ram[], image, packFileOffset(image, 1))
  if withSong:
    for package in songPackIndices(image, SongId):
      applyPackageBlocks(machine.spc.ram[], image, packFileOffset(image, package))
  machine.spc.pc = DriverStart.uint16
  var instructions = 0
  while machine.spc.pc.int != StartupDone:
    doAssert instructions < 40000
    machine.spc.step()
    inc instructions
  result = machine.spc
  result.readHook = nil
  result.writeHook = nil

proc checkInventory(image: seq[uint8], withSong: bool,
    layout: Manifest): tuple[lookups, nativeHeaders: int] =
  ## Cross-check a linear record inventory against every accepted original adapter lookup.
  let baseline = boot(image, withSong)
  var allPointers, nativePointers: HashSet[int]
  for port, tableAddress in PointerTables:
    let capacity = baseline.ram[0x4D0 + port].int
    doAssert capacity == [0, 29, 9, 128][port]
    var
      kinds: CountTable[int]
      unique: HashSet[int]
      continuations: HashSet[int]
    for command in 1 ..< capacity:
      let
        pointer = baseline.word(tableAddress + 2 * (command - 1))
        kind = baseline.ram[pointer - 1].int
      doAssert pointer >= DriverStart and pointer < DriverStart + DriverLength
      doAssert kind in [0, 2, 4, 6, 8, 10, 12, 14, 16]
      kinds.inc(kind)
      unique.incl(pointer)
      allPointers.incl(pointer)
      var actual = newSpc()
      actual.ram[] = baseline.ram[]
      actual.sp = 0xEF
      actual.ram[0x1F0] = (ReturnAddress and 255).uint8
      actual.ram[0x1F1] = (ReturnAddress shr 8).uint8
      actual.ram[0x4B0 + port] = command.uint8
      actual.pc = PortEntries[port].uint16
      var steps = 0
      while actual.pc.int != LookupJump:
        doAssert steps < 100, &"port={port} command={command} PC=${actual.pc:04X}"
        actual.step()
        inc steps
      doAssert actual.word(0x20) == pointer
      doAssert actual.ram[0x48C + port].int == kind
      doAssert actual.sp == 0xEE and actual.ram[0x1EF].int == 2 * (command - 1)
      doAssert actual.word(0x1F0) == ReturnAddress
      let target = baseline.word(KindTable + kind)
      actual.step()
      doAssert actual.pc.int == target and actual.sp == 0xEE
      inc result.lookups
      if kind == NativeKind:
        nativePointers.incl(pointer)
        continuations.incl(baseline.word(pointer - 3))
        for headerAddress in pointer - 3 .. pointer - 1:
          doAssert baseline.ram[headerAddress] == image[DriverMap + headerAddress],
            "A runtime header must match its claimed package-one file placement."
          let fileAddress = DriverMap + headerAddress
          var found = false
          for region in layout.regions:
            if fileAddress >= region.offset and fileAddress < region.offset + region.length:
              doAssert region.build == blCopy or region.kind != rkCode,
                &"native header ${headerAddress:04X} overlaps code {region.name}"
              found = true
              break
          doAssert found
        inc result.nativeHeaders
    doAssert unique.len == [0, 23, 3, 127][port]
    doAssert continuations.len == [0, 1, 1, 2][port]
    var expected: CountTable[int]
    case port
    of 0: discard
    of 1: expected[8] = 28
    of 2:
      expected[2] = 1
      expected[8] = 7
    else:
      for pair in [(2, 13), (4, 25), (6, 16), (8, 2), (10, 60), (12, 8), (16, 3)]:
        expected[pair[0]] = pair[1]
    doAssert kinds == expected
    echo &"port={port}: accepted={max(0, capacity-1)}, unique={unique.len}, kinds={kinds}"
  doAssert result.lookups == 163 and result.nativeHeaders == 37
  doAssert allPointers.len == 151 and nativePointers.len == 25
  echo &"withSong={withSong}: unique pointers={allPointers.len}, native headers={nativePointers.len}"

proc main() =
  ## Require both ROMs and both package configurations; stop before executing record bodies.
  let layout = parseManifestFile(ManifestDefaultPath)
  var lookups, nativeHeaders: int
  for image in engineImages("bin/spc_service_inventory_extract"):
    for withSong in [false, true]:
      let counts = checkInventory(image, withSong, layout)
      lookups += counts.lookups
      nativeHeaders += counts.nativeHeaders
  echo &"SPC service inventory passed: {lookups} original adapter handoffs, " &
    &"{nativeHeaders} native header references across two ROMs/two package configurations; no audio device."

when isMainModule:
  main()
