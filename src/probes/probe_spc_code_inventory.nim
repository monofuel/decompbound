## Reproduce the open SPC code inventory, including the current eighteen copied native bodies.
## Inputs are the user's ROM, manifest-registered SPC sources and our assembler grammar.
## Nominal startup roots and source control edges are checked; full executable closure is not claimed.
## Run: nim r -d:debug --nimcache:bin/nimcache/spc-code-inventory-worker src/probes/probe_spc_code_inventory.nim
import
  std/[algorithm, sequtils, sets, strformat, strutils, tables],
  ../decompbound/[apu, manifest, music_player, rom_pipeline, spc700, spc_asm]

const
  DriverMap = 0x25FB42
  DriverStart = 0x0500
  DriverLength = 16779
  ReturnAddress = 0x5000'u16
  PointerTables = [0x180D, 0x17D5, 0x17C5, 0x16C7]
  PortEntries = [0x1184, 0x1198, 0x11BA, 0x11DC]

type
  Instruction = object
    address, length, opcode, line: int
    owner: string
  Inventory = object
    layout: Manifest
    instructions: Table[int, Instruction]
    codeBytes, dataBytes: Table[int, string]
    lengths: array[256, int]
    forms: array[256, string]
  Edge = tuple[source, target: int, kind: string]

proc word(spc: Spc, address: int): int =
  ## Read an original runtime structural pointer without exporting record contents.
  spc.ram[address and 65535].int + 256 * spc.ram[(address + 1) and 65535].int

proc deriveLengths(inventory: var Inventory) =
  ## Derive instruction widths from our own assembler's operand grammar, not asset bytes.
  var reading = false
  var opcode = 0
  for raw in readFile("src/decompbound/spc_asm.nim").splitLines():
    let line = raw.strip()
    if line == "OpcodeRows = [":
      reading = true
    elif reading and line == "]":
      break
    elif reading and line.startsWith("\""):
      let row = line[1 ..< line.rfind('"')]
      for form in row.split('|'):
        var length = 1
        let space = form.find(' ')
        if space >= 0:
          for letter in form[space + 1 .. ^1]:
            case letter
            of 'w', 'b': length += 2
            of 'd', 'i', 'r', 'q': inc length
            else: discard
        doAssert opcode < 256 and length in 1 .. 3
        inventory.lengths[opcode] = length
        inventory.forms[opcode] = form
        inc opcode
  doAssert opcode == 256

proc addSource(inventory: var Inventory, image: seq[uint8], name, source: string,
    origin, length: int) =
  ## Byte-check each source and distinguish instruction starts from explicit word data.
  let
    text = readFile(source)
    bytes = assembleSpcAsm(text)
  doAssert bytes.len == length, name
  for index, value in bytes:
    doAssert value == image[DriverMap + origin + index], name
  var address = origin
  var seenOrigin = false
  for lineNumber, raw in text.splitLines.toSeq:
    var line = raw.split(';')[0].strip()
    if line.len == 0: continue
    if ':' in line:
      line = line[line.find(':') + 1 .. ^1].strip()
      if line.len == 0: continue
    if line.startsWith(".org"):
      doAssert not seenOrigin
      let declared = parseHexInt(line.splitWhitespace()[1].replace("$", ""))
      doAssert declared == origin
      seenOrigin = true
    elif line.startsWith(".word"):
      let count = line[5 .. ^1].split(',').len * 2
      for offset in 0 ..< count: inventory.dataBytes[address + offset] = name
      address += count
    else:
      doAssert seenOrigin and not line.startsWith("."), source & ":" & $lineNumber
      let opcode = image[DriverMap + address].int
      let size = inventory.lengths[opcode]
      doAssert line.splitWhitespace()[0].toUpperAscii ==
        inventory.forms[opcode].splitWhitespace()[0], source & ":" & $lineNumber
      doAssert address notin inventory.instructions
      inventory.instructions[address] = Instruction(address: address, length: size,
        opcode: opcode, line: lineNumber + 1, owner: name)
      for offset in 0 ..< size:
        doAssert address + offset notin inventory.codeBytes
        inventory.codeBytes[address + offset] = name
      address += size
  doAssert address == origin + length and seenOrigin, source

proc classify(inventory: Inventory, address: int): string =
  ## Identify reproduced instruction boundaries and intentional copied aliases.
  if address in inventory.instructions:
    let instruction = inventory.instructions[address]
    return "REPRODUCED " & instruction.owner
  if address == 0x2E48:
    return "INTENTIONAL COPIED CODE/DATA BEQ; sequence-pointer table entry zero"
  if address in inventory.codeBytes:
    return "INSIDE REPRODUCED OPERAND " & inventory.codeBytes[address]
  if address in inventory.dataBytes:
    return "REPRODUCED STRUCTURAL DATA " & inventory.dataBytes[address]
  if address < DriverStart or address >= DriverStart + DriverLength:
    return "OUTSIDE RESIDENT PACKAGE-ONE DRIVER"
  let file = DriverMap + address
  for region in inventory.layout.regions:
    if file >= region.offset and file < region.offset + region.length:
      return &"{region.build}/{region.kind}/{region.comprehension} {region.name}"
  "NO MANIFEST COVERAGE"

proc boot(image: seq[uint8], withSong: bool): Spc =
  ## Build actual startup tables with real APU hooks; never advance timers or generate samples.
  let machine = newApu()
  applyPackageBlocks(machine.spc.ram[], image, packFileOffset(image, 1))
  if withSong:
    for package in songPackIndices(image, 3):
      applyPackageBlocks(machine.spc.ram[], image, packFileOffset(image, package))
  machine.spc.pc = DriverStart.uint16
  var instructions = 0
  while machine.spc.pc != 0x546:
    doAssert instructions < 40000
    machine.spc.step()
    inc instructions
  result = machine.spc
  result.readHook = nil
  result.writeHook = nil

proc rootCovered(inventory: Inventory, address: int): bool =
  ## Require an actual instruction start rather than merely landing within a source span.
  address in inventory.instructions

proc relativeBranch(opcode: int): bool =
  ## Recognize encoded control transfers without treating arbitrary data as instructions.
  opcode in [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x2F,
    0x2E, 0xDE, 0x6E, 0xFE] or (opcode and 15) == 3

proc nativePrefix(inventory: Inventory, image: seq[uint8], actual: var Spc, pointer: int) =
  ## Execute the uncovered straight-line prefix and first direct transfer, stopping before its callee.
  var
    executed = 0
    io = 0
    last = pointer
  actual.readHook = proc(address: uint16): int =
    inc io
    0
  actual.writeHook = proc(address: uint16, value: uint8): bool =
    inc io
    true
  while executed < 64:
    let address = actual.pc.int
    if address in inventory.instructions:
      echo &"PREFIX {pointer:04X} reached reproduced {address:04X} after {executed} instructions"
      break
    if address < DriverStart or address >= DriverStart + DriverLength:
      echo &"PREFIX {pointer:04X} leaves resident mapping at {address:04X}"
      break
    let
      opcode = actual.ram[address].int
      length = inventory.lengths[opcode]
      form = inventory.forms[opcode]
    for offset in 0 ..< length:
      doAssert actual.ram[address + offset] == image[DriverMap + address + offset],
        "runtime prefix differs from the cited package-one file mapping"
    last = address + length - 1
    let transfer = opcode in [0x3F, 0x5F, 0x1F, 0x4F, 0x6F, 0x7F, 0x0F, 0xEF, 0xFF] or
      (opcode and 15) == 1 or relativeBranch(opcode)
    if transfer:
      var target = "dynamic/return"
      if opcode in [0x3F, 0x5F]:
        let destination = actual.word(address + 1)
        target = &"{destination:04X} {inventory.classify(destination)}"
      elif relativeBranch(opcode):
        let raw = actual.ram[address + length - 1].int
        let destination = (address + length + (if raw >= 128: raw - 256 else: raw)) and 65535
        target = &"{destination:04X} {inventory.classify(destination)}"
      echo &"PREFIX {pointer:04X}..{last:04X} file {DriverMap + pointer:06X}..{DriverMap + last:06X}: executed {executed} straight-line instructions; first transfer {address:04X} {form} -> {target}"
      if opcode in [0x3F, 0x5F]:
        let destination = actual.word(address + 1)
        actual.step()       # Prove the real transfer, then stop before its callee body.
        doAssert actual.pc.int == destination
      break
    actual.step()
    doAssert actual.pc.int == address + length,
      "core instruction width disagrees with the assembler grammar"
    inc executed
    if io != 0:
      echo &"PREFIX {pointer:04X}..{last:04X}: MMIO encountered; no later path inferred"
      break
  doAssert executed < 64, "native prefix needs a separately bounded investigation"
  actual.readHook = nil
  actual.writeHook = nil

proc checkNative(inventory: Inventory, image: seq[uint8], withSong: bool): HashSet[int] =
  ## Prove original adapter/native handoffs and report unique body/callback coverage.
  let baseline = boot(image, withSong)
  var
    references = initTable[int, seq[string]]()
    callbacks = initTable[int, HashSet[int]]()
    continuationRoots: HashSet[int]
    seenReferences = 0
    acceptedRecords = 0
    recordPointers: HashSet[int]
  for port in 1 .. 3:
    let capacity = baseline.ram[0x4D0 + port].int
    doAssert capacity == [0, 29, 9, 128][port]
    for command in 1 ..< capacity:
      let
        pointer = baseline.word(PointerTables[port] + 2 * (command - 1))
        kind = baseline.ram[pointer - 1].int
      doAssert kind in [0, 2, 4, 6, 8, 10, 12, 14, 16]
      inc acceptedRecords
      recordPointers.incl pointer
      if kind != 8: continue
      let continuation = baseline.word(pointer - 3)
      for offset in -3 .. 0:
        doAssert baseline.ram[pointer + offset] == image[DriverMap + pointer + offset],
          "runtime native header/entry does not match the cited resident file mapping"
      references.mgetOrPut(pointer, @[]).add(&"p{port}:{command}")
      callbacks.mgetOrPut(pointer, initHashSet[int]()).incl continuation
      continuationRoots.incl continuation
      result.incl pointer
      var actual = newSpc()
      actual.ram[] = baseline.ram[]
      actual.sp = 0xEF
      actual.ram[0x1F0] = 0
      actual.ram[0x1F1] = 0x50
      actual.ram[0x4B0 + port] = command.uint8
      actual.pc = PortEntries[port].uint16
      var steps = 0
      while actual.pc.int != pointer:
        doAssert steps < 160
        actual.step()
        inc steps
      doAssert actual.sp == 0xEF and actual.word(0x440 + 2 * port) == continuation
      doAssert actual.x.int == 2 * (command - 1)
      doAssert actual.word(0x1F0) == ReturnAddress.int
      if not withSong and not inventory.rootCovered(pointer):
        inventory.nativePrefix(image, actual, pointer)
      inc seenReferences
  doAssert result.len == 25 and seenReferences == 37
  doAssert acceptedRecords == 163 and recordPointers.len == 151
  var covered = 0
  var headersIdentified = 0
  for pointer in toSeq(result.items).sorted():
    if inventory.rootCovered(pointer): inc covered
    let file = DriverMap + pointer - 3
    for region in inventory.layout.regions:
      if file >= region.offset and file + 3 <= region.offset + region.length and
          region.build == blCopy and region.kind == rkData and region.comprehension != clUnknown:
        inc headersIdentified
    var callbackText: seq[string]
    for callback in toSeq(callbacks[pointer].items).sorted():
      callbackText.add(&"{callback:04X}({inventory.classify(callback)})")
    echo &"NATIVE {pointer:04X} file {DriverMap + pointer:06X}: {inventory.classify(pointer)}; refs={references[pointer].join(\", \")}; callbacks={callbackText.join(\", \")}"
  echo &"NATIVE SUMMARY song3={withSong}: {covered}/{result.len} entry starts reproduced, {headersIdentified}/{result.len} headers identified; {seenReferences} executed native handoffs, {acceptedRecords} structurally checked record references with {recordPointers.len} unique pointers"
  for callback in toSeq(continuationRoots.items).sorted():
    echo &"NATIVE CONTINUATION {callback:04X} file {DriverMap + callback:06X}: {inventory.classify(callback)}"

proc edges(inventory: Inventory, spc: Spc): seq[Edge] =
  ## Decode only control transfers from reproduced instruction starts, never linear-decode assets.
  for address, instruction in inventory.instructions:
    let
      opcode = instruction.opcode
      next = (address + instruction.length) and 65535
    if opcode in [0x3F, 0x5F]:
      result.add((address, spc.word(address + 1), if opcode == 0x3F: "CALL" else: "JMP"))
      if opcode == 0x3F: result.add((address, next, "CALL_RETURN_SITE"))
    elif opcode == 0x4F:
      result.add((address, 0xFF00 + spc.ram[address + 1].int, "PCALL"))
    elif opcode in [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0, 0x2F,
        0x2E, 0xDE, 0x6E, 0xFE] or (opcode and 15) == 3:
      let raw = spc.ram[next - 1].int
      let relative = if raw >= 128: raw - 256 else: raw
      result.add((address, (next + relative) and 65535, "BRANCH"))
    if opcode notin [0x6F, 0x7F, 0x5F, 0x1F, 0x2F, 0x0F, 0xEF, 0xFF] and
        next notin inventory.instructions:
      # Only report a module-ending/open fall-through, not ordinary instruction links.
      result.add((address, next, "OPEN_FALLTHROUGH"))

proc forcedLocalBranch(inventory: Inventory, spc: Spc, address: int): string =
  ## Recognize a constant N/Z producer across flag-preserving stores in one source unit.
  let branch = inventory.instructions[address]
  if branch.opcode notin [0x10, 0x30, 0xD0, 0xF0]: return ""
  var cursor = address
  for step in 0 ..< 8:
    var previous = -1
    for distance in 1 .. 3:
      let candidate = cursor - distance
      if candidate in inventory.instructions and
          inventory.instructions[candidate].length == distance:
        previous = candidate
        break
    if previous < 0: return ""
    let instruction = inventory.instructions[previous]
    if instruction.owner != branch.owner: return ""
    if instruction.opcode in [0xC4, 0xC5, 0xD4, 0xD5, 0xDA]:
      cursor = previous
    elif instruction.opcode in [0xE8, 0x8D, 0xCD]:
      let value = spc.ram[previous + 1].int
      let taken = case branch.opcode
        of 0xD0: value != 0
        of 0xF0: value == 0
        of 0x10: value < 128
        else: value >= 128
      if taken: return &"constant N/Z from {previous:04X}, immediate {value:02X}"
      return ""
    else:
      return ""

proc main() =
  ## Inventory bounded nominal roots and reproducible source control edges, not the whole executable driver.
  let
    image = readGoldBaserom()
    layout = parseManifestFile(ManifestDefaultPath)
  var inventory = Inventory(layout: layout)
  inventory.deriveLengths()
  var units = 0
  for region in layout.regions:
    if region.build != blCopy and region.source.endsWith(".spc.asm"):
      inventory.addSource(image, region.name, region.source, region.offset - DriverMap,
        region.length)
      inc units
  let original = boot(image, false)
  let
    aliasOpcode = original.ram[0x2E48].int
    aliasSize = inventory.lengths[aliasOpcode]
    aliasRelative = original.ram[0x2E48 + aliasSize - 1].int
    aliasTarget = (0x2E48 + aliasSize +
      (if aliasRelative >= 128: aliasRelative - 256 else: aliasRelative)) and 65535
  doAssert inventory.forms[aliasOpcode] == "BEQ r" and aliasTarget == 0x2E25
  doAssert aliasTarget in inventory.instructions
  echo &"INTENTIONAL ALIAS 2E48 file 26298A: original copied BEQ -> {aliasTarget:04X} ({inventory.classify(aliasTarget)}); bytes remain owned by sequence-pointer data"
  let natives = inventory.checkNative(image, false)
  let songNatives = inventory.checkNative(image, true)
  doAssert natives == songNatives
  var handlersCovered = 0
  for command in 0xE0 .. 0xFE:
    let target = original.word(0xB23 + ((2 * command) and 255))
    if inventory.rootCovered(target): inc handlersCovered
    echo &"SEQUENCE {command:02X} -> {target:04X}: {inventory.classify(target)}"
  echo &"SEQUENCE SUMMARY {handlersCovered}/31 nominal handlers reproduced"
  for (label, base) in [("KIND", 0x125B), ("CONTINUATION", 0x132E)]:
    var covered = 0
    for offset in countup(0, 16, 2):
      let target = original.word(base + offset)
      if inventory.rootCovered(target): inc covered
      echo &"{label} {offset:02X} -> {target:04X}: {inventory.classify(target)}"
    echo &"{label} SUMMARY {covered}/9 nominal even-offset targets reproduced"
  var
    direct, closed, aliasEdges, returns, indirect, vectorCalls, deadFalls = 0
    openEdges: seq[Edge]
  for edge in inventory.edges(original):
    if edge.kind == "OPEN_FALLTHROUGH":
      let proof = inventory.forcedLocalBranch(original, edge.source)
      if proof.len > 0:
        echo &"DEAD LOCAL FALLTHROUGH {edge.source:04X}->{edge.target:04X}: {proof}; nominal arm entry takes branch"
        inc deadFalls
        continue
    inc direct
    if inventory.rootCovered(edge.target):
      inc closed
    elif edge.target == 0x2E48:
      inc aliasEdges
      openEdges.add edge
    else:
      openEdges.add edge
  openEdges.sort(proc(left, right: Edge): int = cmp(left.source, right.source))
  for edge in openEdges:
    let destination = if edge.target in DriverStart ..< DriverStart + DriverLength:
      &"file {DriverMap + edge.target:06X}" else: "not resident-file mapped"
    echo &"OPEN {edge.kind} {edge.source:04X} file {DriverMap + edge.source:06X} -> {edge.target:04X} {destination}: {inventory.classify(edge.target)}"
  for address, instruction in inventory.instructions:
    if instruction.opcode in [0x6F, 0x7F]: inc returns
    if instruction.opcode == 0x1F:
      inc indirect
      echo &"INDIRECT {address:04X}: base={original.word(address + 1):04X} owner={instruction.owner}"
    if (instruction.opcode and 15) == 1 or instruction.opcode == 0x0F: inc vectorCalls
  echo &"SOURCE SUMMARY {units} units checked byte for byte, {inventory.instructions.len} instruction starts; {direct} direct transfers, call return sites and open fall-through edges; {closed} reproduced targets, {aliasEdges} intentional copied alias, {deadFalls} proved dead local fall-throughs"
  echo &"DYNAMIC LIMITS: {indirect} indexed JMP sites, {returns} RET/RETI sites, {vectorCalls} vector-call/BRK sites. Only nominal startup native records, their callback words and explicit table domains above are checked; mutable retarget/uploaded pointers, unchecked odd/out-of-range kinds, port-zero capacity-zero records, arbitrary RET frames and unsampled indirect roots are excluded."

when isMainModule:
  main()
