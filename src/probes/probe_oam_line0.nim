## List sprites that paint screen Y=0 under current Y+1 formula.
import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, ppu]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  var s = 0
  if d.len mod 1024 == 512: s = 512
  result = newSeq[uint8](d.len - s)
  for i in 0..<result.len: result[i] = d[s+i].uint8

proc main() =
  let path = if paramCount()>=1: paramStr(1) else: "bin/states/slot1_battle.state"
  let snes = newSnesBus(readRom("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let obsel = snes.ppuRegs[0x01]
  let sizeSelect = (obsel.int shr 5) and 7
  let sizes = case sizeSelect
    of 0: (8, 16)
    of 1: (8, 32)
    of 2: (8, 64)
    of 3: (16, 32)
    of 4: (16, 64)
    of 5: (32, 64)
    else: (16, 32)
  echo fmt"OBSEL sizeSelect={sizeSelect} small={sizes[0]} large={sizes[1]}"
  for sp in 0..127:
    let base = sp * 4
    let extra = snes.oam[512 + sp div 4]
    let es = (sp mod 4) * 2
    let large = ((extra shr (es + 1)) and 1) != 0
    let size = if large: sizes[1] else: sizes[0]
    let y = snes.oam[base + 1].int
    var x = snes.oam[base].int or (((extra shr es) and 1).int shl 8)
    if x >= 256: x -= 512
    let tile = snes.oam[base + 2]
    for py in 0..<size:
      let screenY = (y + py + 1) and 0xFF
      if screenY == 0:
        echo fmt"  spr{sp}: x={x} y={y} size={size} py={py} tile={tile:02X} paints line 0"
        break

when isMainModule: main()
