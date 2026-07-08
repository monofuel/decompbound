## Analyze Giygas palette thrash buffers from an ebSt screenshot.
import
  std/[os, options, strformat],
  ../decompbound/[cpu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc w16(m: seq[uint8], a: int): uint16 =
  ## Little-endian u16 from bus mem.
  m[a].uint16 or (m[a + 1].uint16 shl 8)

proc main() =
  ## Print thrash velocity/position distribution and sample entries.
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let m = snes.bus.mem
  var velZero = 0
  var pos6318 = 0
  var posOther = 0
  for i in 0 ..< 256:
    let vr = w16(m, 0x7F0200 + i * 2)
    let vg = w16(m, 0x7F0400 + i * 2)
    let vb = w16(m, 0x7F0600 + i * 2)
    if vr == 0 and vg == 0 and vb == 0:
      inc velZero
    let pr = (w16(m, 0x7F0800 + i * 2).int shr 8) and 0x1F
    let pg = (w16(m, 0x7F0A00 + i * 2).int shr 8) and 0x1F
    let pb = (w16(m, 0x7F0C00 + i * 2).int shr 8) and 0x1F
    let packed = pr.uint16 or (pg.uint16 shl 5) or (pb.uint16 shl 10)
    if packed == 0x6318: inc pos6318
    else: inc posOther
  echo &"vel all-zero entries={velZero}/256"
  echo &"pos packs to 6318={pos6318} other={posOther}"
  for i in [0, 16, 80, 128, 200, 255]:
    let vr = w16(m, 0x7F0200 + i * 2)
    let vg = w16(m, 0x7F0400 + i * 2)
    let vb = w16(m, 0x7F0600 + i * 2)
    let pr = w16(m, 0x7F0800 + i * 2)
    let pg = w16(m, 0x7F0A00 + i * 2)
    let pb = w16(m, 0x7F0C00 + i * 2)
    let cg = snes.cgram[i]
    echo &"i={i:3} vel=({vr:04X},{vg:04X},{vb:04X}) pos=({pr:04X},{pg:04X},{pb:04X}) cgram={cg:04X}"

when isMainModule:
  main()
