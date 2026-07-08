## Dump brightness-fade DP + palette thrash stats from an ebSt screenshot.
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

proc main() =
  ## Print fade-related direct-page bytes and thrash position stats.
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let m = snes.bus.mem
  for a in [0x0D, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x30, 0x1A, 0x1B]:
    echo &"${a:02X}={m[0x7E0000 + a]:02X}"
  var r0 = 0
  var rMid = 0
  var g0 = 0
  var gMid = 0
  var b0 = 0
  var bMid = 0
  for i in 0 ..< 256:
    let pr = m[0x7F0800 + i*2].int or (m[0x7F0801 + i*2].int shl 8)
    let pg = m[0x7F0A00 + i*2].int or (m[0x7F0A01 + i*2].int shl 8)
    let pb = m[0x7F0C00 + i*2].int or (m[0x7F0C01 + i*2].int shl 8)
    let ri = (pr shr 8) and 0x1F
    let gi = (pg shr 8) and 0x1F
    let bi = (pb shr 8) and 0x1F
    if ri < 4: inc r0
    elif ri > 12: inc rMid
    if gi < 4: inc g0
    elif gi > 12: inc gMid
    if bi < 4: inc b0
    elif bi > 12: inc bMid
  echo &"pos intensity: R low={r0} high={rMid}  G low={g0} high={gMid}  B low={b0} high={bMid}"
  echo &"INIDISP={snes.ppuRegs[0x00]:02X}"

when isMainModule:
  main()
