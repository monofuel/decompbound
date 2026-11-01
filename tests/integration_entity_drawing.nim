import
  std/[algorithm, strformat],
  decompbound/[asm_parse, cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

type
  Actor = object
    id, group, depth, screenX, screenY, selector: int

const
  Callback = 0x1D00
  ProgramBank = 0x80'u8
  CallerPage = 0x0300'u16
  StepLimit = 30000
  Ids = [0, 5, 22, 23, 29]
  DepthSets = [[100, 80, 140, 80, 60], [100, 100, 100, 100, 100],
    [0xFFFF, 0, 0x8000, 0x7FFF, 1]]
  GroupSets = [[0, 1, 2, 1, 3], [1, 1, 1, 1, 1], [2, 2, 2, 2, 2],
    [0xC005, 1, 0, 1, 2]]

proc expectedOrder(actors: seq[Actor], links: seq[int], alternate: bool): seq[int] =
  ## Specify immediate draws and stable descending unsigned-depth draws separately.
  if links.len == 0:
    return
  var
    traversal: seq[Actor]
    deferred: seq[tuple[id, depth, position: int]]
  if alternate:
    traversal = actors
    traversal.sort(proc(a, b: Actor): int = cmp(a.id, b.id))
  else:
    for id in links:
      for actor in actors:
        if actor.id == id:
          traversal.add actor
  for position, actor in traversal:
    if alternate:
      if actor.selector == 0xFFFF:
        continue
    elif actor.screenX < -64 or actor.screenX > 319 or
        actor.screenY < -64 or actor.screenY > 255:
      continue
    let queueForDepth = actor.group == 1 and
      (not alternate or actor.screenY in -8 .. 503)
    if queueForDepth:
      deferred.add (actor.id, actor.depth, position)
    else:
      result.add actor.id
  deferred.sort(proc(a, b: tuple[id, depth, position: int]): int =
    result = cmp(b.depth, a.depth)
    if result == 0:
      result = cmp(a.position, b.position))
  for actor in deferred:
    result.add actor.id

proc checkDraw(snes: SnesBus, actors: seq[Actor], links: seq[int], alternate: bool) =
  ## Observe the real dispatcher calls while synthetic return callbacks isolate ordering.
  snes.putBytes(Caller, assembleAsm(".a16\n.i16\nJSR $DB0F\n", Caller))
  for id in 0 .. 29:
    snes.putWord(0x0A62 + id * 2, 0xFFFF)
    snes.putWord(0x0A9E + id * 2, 0xFFFF)
    snes.putWord(0x280C + id * 2, 0x5AA5)
  for actor in actors:
    let offset = actor.id * 2
    snes.putWord(0x0A62 + offset, actor.selector)
    snes.putWord(0x103E + offset, actor.group)
    snes.putWord(0x0BCA + offset, actor.depth)
    snes.putWord(0x0B16 + offset, actor.screenX and 0xFFFF)
    snes.putWord(0x0B52 + offset, actor.screenY and 0xFFFF)
    snes.putWord(0x116A + offset, 0x7F)
    snes.putWord(0x112E + offset, 0x4000)
    snes.putWord(0x10F2 + offset, 0)
    snes.putWord(0x11E2 + offset, Callback)
  for index, id in links:
    snes.putWord(0x0A9E + id * 2, if index == links.high: 0xFFFF else: links[index + 1] * 2)
  snes.putWord(0x0A50, if links.len == 0: 0xFFFF else: links[0] * 2)
  snes.putWord(0x67, if alternate: 0x2000 else: 0)
  var
    state = Cpu(pbr: ProgramBank, pc: Caller.uint16, s: StackTop, d: CallerPage, dbr: 0x7E)
    steps = 0
    actual: seq[int]
  while state.pbr != ProgramBank or state.pc != (Caller + 3).uint16:
    doAssert steps < StepLimit
    if state.pbr == ProgramBank and state.pc == Callback:
      let offset = snes.word(state.d.int + 0x88)
      doAssert state.d == 0x200 and state.x.int == offset
      doAssert (state.p and (FlagM or FlagX or FlagD)) == 0
      actual.add offset div 2
    state.step(snes.bus)
    inc steps
  doAssert state.s == StackTop and state.d == CallerPage and state.dbr == 0x7E
  let expected = expectedOrder(actors, links, alternate)
  doAssert actual == expected,
    &"alternate {alternate}, links {links}, actual {actual}, expected {expected}"

proc checkWrapper(snes: SnesBus, entity: int, directPage: uint16) =
  ## Verify nested scratch allocation and all dispatcher rejection paths through the wrapper.
  let expectedPage = (directPage.int - 0xA0) and 0xFF00
  for bankWord in [0x7F, 0x807F]:
    for frame in [0, 0xFFFF]:
      for overflow in [false, true]:
        snes.putWord(0x116A + entity * 2, bankWord)
        snes.putWord(0x112E + entity * 2, 0x4000)
        snes.putWord(0x10F2 + entity * 2, frame)
        snes.putWord(0x11E2 + entity * 2, Callback)
        snes.putBytes(Caller, assembleAsm(".a16\n.i16\nJSR $A0CA\n", Caller))
        var
          state = Cpu(pbr: ProgramBank, pc: Caller.uint16, s: StackTop, d: directPage, dbr: 0x7E,
            a: entity.uint16, p: (if overflow: FlagV else: 0'u8))
          reached = false
          steps = 0
        while state.pbr != ProgramBank or state.pc != (Caller + 3).uint16:
          doAssert steps < StepLimit
          if state.pc == Callback:
            reached = true
            doAssert state.d.int == expectedPage and state.x.int == entity * 2
          state.step(snes.bus)
          inc steps
        # The wrapper's SBC sets V from its own scratch-address arithmetic.
        doAssert reached == (bankWord == 0x7F and frame == 0)
        doAssert snes.word(expectedPage + 0x88) == entity * 2
        doAssert state.d == directPage and state.s == StackTop and state.dbr == 0x7E

proc checkPublishedOrder(snes: SnesBus, links: seq[int], alternate: bool,
    selector: int) =
  ## Exercise traversal with the real default callback and check the published hardware table.
  const DefinitionBase = 0x7F4000'u32
  var actors: seq[Actor]
  for index, id in Ids:
    actors.add Actor(id: id, group: GroupSets[0][index], depth: DepthSets[0][index],
      screenX: 80, screenY: 96, selector: 0)
  snes.checkDraw(actors, links, alternate)
  for actor in actors:
    let
      offset = actor.id * 2
      pointer = 0x4000 + actor.id * 8
    snes.putWord(0x112E + offset, pointer)
    snes.putWord(0x11E2 + offset, 0xA3A4)
    snes.putWord(0x2BE6 + offset, 0x0100)
    snes.putWord(0x2BAA + offset, 0)
    snes.putWord(0x2E7A + offset, 0)
    snes.putWord(0x341A + offset, 0)
    snes.putBytes(DefinitionBase + (actor.id * 8).uint32,
      [0'u8, actor.id.uint8, 5'u8, 0'u8, 0x80'u8])
  snes.putWord(0x2E, selector)
  snes.call("JSL $C088B1")
  snes.call("JSR $DB0F", directPage = CallerPage)
  snes.call("JSL $C08B26")
  let
    traversal = expectedOrder(actors, links, alternate)
    low = if selector == 1: 0x500 else: 0x800
  var expected: seq[int]
  for queue in 0 .. 3:
    for id in traversal:
      for actor in actors:
        if actor.id == id and actor.group == queue:
          expected.add id
  doAssert snes.word(3) == low + expected.len * 4
  for index, id in expected:
    let address = Wram + (low + index * 4).uint32
    doAssert snes.bus.read8(address) == 80 and snes.bus.read8(address + 1) == 95
    doAssert snes.bus.read8(address + 2) == id.uint8
    doAssert snes.bus.read8(address + 3) == 0x35
  for index in expected.len ..< 128:
    doAssert snes.bus.read8(Wram + (low + index * 4 + 1).uint32) == 0xE0

proc main() =
  ## Check every active-list permutation, depth ties, clipping limits and alternate slot scan.
  var cases = 0
  for image in engineImages("bin/entity_drawing_extract"):
    let snes = newSnesBus(image)
    snes.putBytes(Callback.uint32, assembleAsm("RTS\n", Callback.uint32))
    for id in 0 .. 29:
      for directPage in [0x300'u16, 0x600'u16, 0x6F0'u16]:
        snes.checkWrapper(id, directPage)
        cases += 8
    var permutation = @Ids
    while true:
      for depths in DepthSets:
        for groups in GroupSets:
          var actors: seq[Actor]
          for index, id in Ids:
            actors.add Actor(id: id, group: groups[index], depth: depths[index],
              screenX: 80, screenY: 96, selector: 0)
          for alternate in [false, true]:
            snes.checkDraw(actors, permutation, alternate)
            inc cases
      for alternate in [false, true]:
        for selector in 1 .. 2:
          snes.checkPublishedOrder(permutation, alternate, selector)
          inc cases
      if not permutation.nextPermutation():
        break
    for x in [-65, -64, -1, 0, 255, 319, 320]:
      for y in [-65, -64, -9, -8, -1, 0, 255, 256, 503, 504]:
        for group in [0, 1]:
          let actors = @[Actor(id: 23, group: group, depth: 0xFFFF,
            screenX: x, screenY: y, selector: 0)]
          for alternate in [false, true]:
            snes.checkDraw(actors, @[23], alternate)
            inc cases
    let actors = @[Actor(id: 0, group: 1, depth: 40, screenX: 80, screenY: 96,
      selector: 0xFFFF), Actor(id: 29, group: 1, depth: 80,
      screenX: 80, screenY: 96, selector: 0)]
    for alternate in [false, true]:
      for links in [newSeq[int](), @[0], @[0, 29]]:
        snes.checkDraw(actors, links, alternate)
        inc cases
    var
      fullActors: seq[Actor]
      ascending: seq[int]
    for id in 0 .. 29:
      fullActors.add Actor(id: id, group: 1, depth: (id mod 3) * 100,
        screenX: 80, screenY: 96, selector: 0)
      ascending.add id
    var descending = ascending
    descending.reverse()
    for links in [ascending, descending, @[29] & ascending[0 ..< 29]]:
      for alternate in [false, true]:
        snes.checkDraw(fullActors, links, alternate)
        inc cases
  echo &"entity drawing: {cases} original/rebuilt ordering, boundary and wrapper cases passed"

when isMainModule:
  main()
