## Extra hang/drop comparisons for the Tenda report.
import
  std/[options, strformat],
  ../decompbound/[cpu, png_state, save_state, snesbus]

const
  Hang = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-202823.png"
  Drop = "/home/monofuel/Pictures/Screenshots/earthbound_20260725-190533.png"
  Rom = "bin/Earthbound (U) [!].smc"

proc loadPng(png: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## Load ebSt PNG into a fresh bus.
  var d = cast[seq[uint8]](readFile(Rom))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  let snes = newSnesBus(d)
  var c = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(png))).get, snes, c)
  (snes, c)

proc vramZeros(snes: SnesBus, n: int): int =
  ## Count zero words in the first n VRAM words.
  for i in 0 ..< n:
    if snes.vram[i] == 0: inc result

proc main() =
  ## Compare hang vs drop extras.
  var (s, c) = loadPng(Hang)
  echo &"hang nmitimen={s.nmitimen:02X} INIDISP={s.ppuRegs[0]:02X}"
  echo &"hang VRAM zero words first 4k={vramZeros(s, 0x1000)}/4096"
  c.nmiPending = true
  c.step(s.bus)
  echo &"after forced NMI entry: {c.pbr:02X}:{c.pc:04X} S={c.s:04X}"
  for i in 0 .. 12:
    let op = s.bus.read8((c.pbr.uint32 shl 16) or c.pc)
    echo &"  {i}: {c.pbr:02X}:{c.pc:04X} op={op:02X} S={c.s:04X}"
    c.step(s.bus)
    if c.pbr == 0 and c.pc == 0x5FFF:
      echo "  (returned to BRK sink)"
      break
  (s, c) = loadPng(Drop)
  echo &"drop nmitimen={s.nmitimen:02X} INIDISP={s.ppuRegs[0]:02X}"
  echo &"drop VRAM zero words first 4k={vramZeros(s, 0x1000)}/4096"
  echo &"drop portsIn={s.apu.portsIn[0]:02X},{s.apu.portsIn[1]:02X}," &
    &"{s.apu.portsIn[2]:02X},{s.apu.portsIn[3]:02X}"

main()
