## Try to force the Tenda derail by varying per-line instruction budget
## (APU interleave / catch-up timing proxy). Headless only.
import
  std/[os, strformat],
  ../decompbound/[cpu, replay, save_state, snesbus, apu]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  TasPath = "bin/sessions/20260726-202718/20260726-202722.tas"

proc badPc(pbr: uint8, pc: uint16): bool =
  ## Plausible-code check (matches test_apu_handshake_derail).
  let bank = pbr.int
  if bank >= 0xC0: return false
  if bank >= 0x40 and bank <= 0x7D: return false
  if (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF): return pc < 0x8000
  if bank == 0x7E or bank == 0x7F: return false
  true

proc frameBudget(snes: SnesBus, c: var Cpu, instrPerLine: int) =
  ## One frame with a chosen instr/line budget (and standard 2 APU ticks/line).
  var l = 0
  var s = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< instrPerLine:
      c.step(snes.bus)
      if c.stopped: break
    if l < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
      inc s
    inc l
    if l >= 262:
      snes.initHdma()
      break
  while s < 533:
    discard snes.tickApu()
    inc s

proc runWith(instrPerLine: int): tuple[badAt: int, brkAt: int, final: string] =
  ## Replay session B under a given instr/line; return first bad/BRK frames.
  var rom = cast[seq[uint8]](readFile(RomPath))
  if rom.len mod 1024 == 512: rom = rom[512 .. ^1]
  let (hdr, deltas) = parseReplay(TasPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(hdr.startStateRef)), snes, c)
  let lastF = deltas[^1].frame + 120
  result.badAt = -1
  result.brkAt = -1
  for f in 0 .. lastF:
    snes.joy1 = joyAtFrame(deltas, f)
    frameBudget(snes, c, instrPerLine)
    if result.badAt < 0 and badPc(c.pbr, c.pc):
      result.badAt = f
    if result.brkAt < 0 and c.pbr == 0 and c.pc == 0x5FFF:
      result.brkAt = f
      break
  result.final = &"{c.pbr:02X}:{c.pc:04X}"

proc main() =
  ## Sweep a few instruction budgets.
  for n in [40, 80, 100, 120, 150, 200, 300]:
    let r = runWith(n)
    echo &"instrPerLine={n:3d}  badAt={r.badAt:5d}  brkAt={r.brkAt:5d}  final={r.final}"

main()
