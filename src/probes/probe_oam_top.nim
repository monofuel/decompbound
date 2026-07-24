## Dump OAM Y values that would paint scanline 0 under sprite Y+1.
import
  std/[os, strformat, sequtils, algorithm],
  ../decompbound/[cpu, snesbus, save_state]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  var s = 0
  if d.len mod 1024 == 512: s = 512
  result = newSeq[uint8](d.len - s)
  for i in 0 ..< result.len: result[i] = d[s + i].uint8

proc main() =
  let path = if paramCount() >= 1: paramStr(1) else: "bin/states/slot1_battle.state"
  if not fileExists(path):
    echo "missing ", path
    quit(1)
  let snes = newSnesBus(readRom("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  echo "state=", path
  var yHist: array[256, int]
  for sp in 0 .. 127:
    let y = snes.oam[sp * 4 + 1].int
    yHist[y].inc
  var high = 0
  for y in 0xE0 .. 0xFF: high += yHist[y]
  echo fmt"Y in E0-FF (offscreen band): {high}  Y=FF: {yHist[0xFF]}  Y=FE: {yHist[0xFE]}  Y=E0: {yHist[0xE0]}  Y=00: {yHist[0]}"
  echo "sprites whose first drawn line (y+1) is 0..2:"
  for sp in 0 .. 127:
    let y = snes.oam[sp * 4 + 1].int
    let x = snes.oam[sp * 4].int
    let tile = snes.oam[sp * 4 + 2]
    let first = (y + 1) and 0xFF
    if first <= 2 or y >= 0xF0:
      echo fmt"  spr{sp:3}: x={x:3} y={y:3} firstLine={first} tile={tile:02X}"

when isMainModule: main()
