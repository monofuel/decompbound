## Referee: the F6 dial executes EXACTLY what sword_recipe validated.
##
## Replays buildDialQueue(N=32, left) against the known slot230 reference
## state (monofuel's fleeing capture) and asserts the seed at the close
## index equals the tool's published CB694A66 and the init roll lands the
## Sword in $AA10. SKIPs cleanly (exit 0) when the local state is absent —
## it derives from the commercial ROM and is never committed.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, snesbus, save_state, policy, ppu, sword_dial]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/slot230.state"
  KnownDwell = 32
  KnownSeedAtClose = 0xCB694A66'u32
  SwordItemId = 0x23

proc readRomFile(filepath: string): seq[uint8] =
  ## Read the ROM, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc seedOf(snes: SnesBus): uint32 =
  ## 32-bit LE seed at $7E0024.
  snes.bus.mem[0x7E0024].uint32 or (snes.bus.mem[0x7E0025].uint32 shl 8) or
    (snes.bus.mem[0x7E0026].uint32 shl 16) or (snes.bus.mem[0x7E0027].uint32 shl 24)

proc main() =
  # Pure queue-shape checks (always run).
  let q = buildDialQueue(KnownDwell, sword_dial.BtnLeft, walkFrames = 700)
  doAssert q.len == (BPressFrames + 1) * 2 + KnownDwell + 1 + 700
  doAssert q[0] == sword_dial.BtnB and q[1] == sword_dial.BtnB
  doAssert q[BPressFrames + 1] == 0'u16
  doAssert q[dialCloseIndex(KnownDwell)] == sword_dial.BtnB
  doAssert q[dialCloseIndex(KnownDwell) + 1] == sword_dial.BtnLeft
  doAssert dirToBtn("up-left") == (sword_dial.BtnUp or sword_dial.BtnLeft)
  # Recipe file round-trip.
  let tmp = getTempDir() / "test_dial_recipe.txt"
  writeRecipeFile(tmp, DialRecipe(capture: "x.png", dwell: 32, dir: "left",
                                  seedAtClose: KnownSeedAtClose, item: "Sword of kings"))
  let rr = parseRecipeFile(tmp)
  doAssert rr.dwell == 32 and rr.dir == "left" and
    rr.seedAtClose == KnownSeedAtClose
  removeFile(tmp)

  if not fileExists(RomPath) or not fileExists(StatePath):
    echo "[test_sword_dial] SKIP e2e (local ROM/state absent); shape checks OK"
    return

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let rom = readRomFile(RomPath)
  var snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  loadState(snes, cpu, 230)
  let closeAt = dialCloseIndex(KnownDwell)
  var closeSeed = 0'u32
  var idx = 0
  for joy in q:
    if idx == closeAt:
      closeSeed = seedOf(snes)
    snes.joy1 = joy
    var line = 0
    while line < 262:
      if line == 224 and (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
      for _ in 0 ..< policy.InstrPerLine:
        cpu.step(snes.bus)
      discard snes.tickApu()
      discard snes.tickApu()
      inc line
    snes.initHdma()
    inc idx
  # Settle, then check the rolled drop.
  for _ in 0 ..< 300:
    snes.joy1 = 0
    var line = 0
    while line < 262:
      if line == 224 and (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
      for _ in 0 ..< policy.InstrPerLine:
        cpu.step(snes.bus)
      discard snes.tickApu()
      discard snes.tickApu()
      inc line
    snes.initHdma()
  let aa10 = snes.bus.mem[0x7EAA10].int
  doAssert closeSeed == KnownSeedAtClose,
    &"dial close seed {closeSeed:08X} != published {KnownSeedAtClose:08X}"
  doAssert aa10 == SwordItemId, &"AA10={aa10:02X} != Sword ($23)"
  echo "[test_sword_dial] OK e2e: close seed + Sword drop reproduced via dial queue"

main()
