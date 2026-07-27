## Dump the opcode loop at hang PC 00:5FFF and related vectors.
import
  std/[options, strformat],
  ../decompbound/[cpu, png_state, save_state, snesbus]

const
  HangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-202823.png"
  RomPath = "bin/Earthbound (U) [!].smc"

proc main() =
  ## Print bytes and stepped ops at the hang PC.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  let snes = newSnesBus(d)
  var c = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(HangPng))).get, snes, c)
  echo &"CPU {c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} P={c.p:02X} e={c.emulation}"
  echo "bytes $7E5FF0..$7E601F:"
  for a in 0x5FF0 .. 0x601F:
    let v = snes.bus.mem[0x7E0000 + a]
    stdout.write &"{v:02X} "
    if (a and 15) == 15: echo &"  ; {(a-15):04X}"
  echo ""
  echo "step 20:"
  for i in 0 .. 19:
    let op = snes.bus.read8((c.pbr.uint32 shl 16) or c.pc)
    echo &"  {i:2d}: PC={c.pbr:02X}:{c.pc:04X} op={op:02X} A={c.a:04X} S={c.s:04X} P={c.p:02X}"
    c.step(snes.bus)
  # Native NMI vector via HiROM
  proc rb(a: uint32): uint8 = snes.bus.read8(a)
  echo &"native NMI $00FFEA = {rb(0xFFEB):02X}{rb(0xFFEA):02X}"
  echo &"emu NMI $00FFFA = {rb(0xFFFB):02X}{rb(0xFFFA):02X}"
  # What is at bank0 $5FFF via bus read
  echo &"bus read 00:5FFF = {rb(0x5FFF):02X}  7E:5FFF = {snes.bus.mem[0x7E5FFF]:02X}"
  # Scan stack for plausible return addresses (C0xx patterns)
  echo "stack scan $1E00..$1FFF for ROM returns (sample high water near S):"
  let s0 = max(0, c.s.int - 0x100)
  for a in countup(s0, min(0x1FFF, c.s.int + 0x40)):
    let lo = snes.bus.mem[0x7E0000 + a]
    let hi = snes.bus.mem[0x7E0000 + a + 1]
    let bk = snes.bus.mem[0x7E0000 + a + 2]
    if bk >= 0xC0 and bk <= 0xFF:
      echo &"  ${a:04X}: return? {bk:02X}:{hi:02X}{lo:02X}"

main()
