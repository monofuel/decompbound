## Confirm play.nim's live scanline loop matches stepReplayFrame.
## Not a product test — one-shot gate before a long human TAS.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, policy, ppu, replay, replay_run, save_state, snesbus]

const
  Gold = "bin/Earthbound (U) [!].smc"
  Bedroom = "bin/states/llm/bedroom.state"
  WalkFrames = 180
  JoyRight = 0x0100'u16
  InstrPerLine = 150
  SamplesPerFrame = 533

proc stepPlayLike(snes: SnesBus, cpu: var Cpu, image: Image) =
  ## Same cadence as play.nim: 262 lines, NMI@224, 150 instr, 533 APU.
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if not forceBlank:
    image.fill(ppu.bgr555ToColor(snes.cgram[0]))
  var smp = 0
  var l = 0
  while l < 262:
    snes.tickScanline(l)
    if l == 224:
      ppu.renderSprites(snes, image)
      ppu.overlayForegroundBg(snes, image)
      if (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if l < 224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      discard snes.tickApu()
      inc smp
    inc l
    if l >= 262:
      snes.initHdma()
      break
  while smp < SamplesPerFrame:
    discard snes.tickApu()
    inc smp

proc loadBedroom(): tuple[snes: SnesBus, c: Cpu, start: seq[byte]] =
  ## Gold ROM + bedroom fixture, normalized through serialize.
  var rom = cast[seq[uint8]](readFile(Gold))
  if rom.len mod 1024 == 512:
    rom = rom[512 .. ^1]
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(Bedroom)), snes, c)
  let start = serializeState(snes, c)
  deserializeState(start, snes, c)
  (snes, c, start)

if not fileExists(Gold) or not fileExists(Bedroom):
  echo "missing ROM or bedroom.state"
  quit(1)

let (snes, c0, start) = loadBedroom()
var c = c0
var img = newImage(256, 224)
for frame in 0 ..< WalkFrames:
  snes.joy1 = if frame == 0: 0'u16 else: JoyRight
  stepPlayLike(snes, c, img)
let playBlob = serializeState(snes, c)
let playPos = playerPos(snes)
let playHash = wramHash(snes)

deserializeState(start, snes, c)
for frame in 0 ..< WalkFrames:
  snes.joy1 = if frame == 0: 0'u16 else: JoyRight
  stepReplayFrame(snes, c)
let headBlob = serializeState(snes, c)
let headPos = playerPos(snes)
let headHash = wramHash(snes)

echo &"play  pos=({playPos.x:04X},{playPos.y:04X}) hash=0x{playHash:08X}"
echo &"head  pos=({headPos.x:04X},{headPos.y:04X}) hash=0x{headHash:08X}"
if playBlob == headBlob:
  echo "MATCH serialize after ", WalkFrames, " frames"
else:
  echo "MISMATCH serialize"
  quit(1)
