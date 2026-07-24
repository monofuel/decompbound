## Scan a dir of F12 screenstate PNGs for a HEALTHY mid-battle capture
## ($4DBA != 0 AND BG mode 0) and dump pos/dialogue to spot the sleep->knock
## scene. Untracked dig tool. Usage: nim r -d:release src/probes/probe_scan_screenstates.nim [dir]
import
  std/[os, options, strformat, strutils, algorithm],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy, png_state],
  ./touch_grass

const
  Rom = "bin/Earthbound (U) [!].smc"

proc dumpOne(pngPath, outState: string) =
  ## Extract one PNG's ebSt, save to outState, dump all battle-relevant WRAM
  ## (the "healthy side" for the entry-abort diff). See docs/memory-map.md.
  let rom = policy.readRomFile(Rom)
  let opt = extractState(cast[seq[uint8]](readFile(pngPath)))
  if opt.isNone:
    echo "no ebSt in ", pngPath; return
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(opt.get, snes, c)
  writeFile(outState, cast[string](serializeState(snes, c)))
  echo "extracted ", pngPath, " -> ", outState
  let mode = snes.ppuRegs[0x05] and 0x7
  echo &"BGMODE(2105)={snes.ppuRegs[0x05]:02X} mode&7={mode} TM(212C)={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}"
  for (nm, a) in {"4DBA": 0x4DBA, "98A5": 0x98A5, "5D7C": 0x5D7C, "9883": 0x9883,
                  "5D60": 0x5D60, "5D98": 0x5D98, "5D9A": 0x5D9A, "5D74": 0x5D74,
                  "4DB6": 0x4DB6, "4DB8": 0x4DB8, "4DC2": 0x4DC2, "4DC6": 0x4DC6}.items:
    echo &"  ${nm} = {readU16(snes, a):04X}"
  echo "  party structs $4DC8 (stride $5F, HP+0x0A PP+0x0C):"
  for p in 0 ..< 4:
    let bptr = readU16(snes, 0x4DC8 + p*2)
    if bptr == 0 or bptr == 0xFFFF: continue
    let hp = readU16(snes, bptr + 0x0A)
    let pp = readU16(snes, bptr + 0x0C)
    echo &"    battler {p}: ptr=${bptr:04X} HP={hp} PP={pp}"

proc main() =
  if paramCount() >= 1 and paramStr(1).endsWith(".png"):
    let outState =
      if paramCount() >= 2: paramStr(2)
      else: "bin/states/battle_menu_healthy.state"
    dumpOne(paramStr(1), outState)
    return
  let dir =
    if paramCount() >= 1: paramStr(1)
    else: "../decompbound_secret/screenstates"
  let rom = policy.readRomFile(Rom)

  var files: seq[string]
  for f in walkFiles(dir / "*.png"):
    files.add f
  files.sort()

  echo &"scanning {files.len} PNGs in {dir}"
  var battleHits, knockHits: seq[string]
  for f in files:
    let pngBytes = cast[seq[uint8]](readFile(f))
    let opt = extractState(pngBytes)
    if opt.isNone: continue
    let snes = newSnesBus(rom)
    var c = snes.resetCpu()
    try:
      deserializeState(opt.get, snes, c)
    except CatchableError:
      continue
    let b4dba = readU8(snes, 0x4DBA)
    let mode = snes.ppuRegs[0x05] and 0x7
    let pidx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + pidx)
    let py = readU16(snes, WorldYBase + pidx)
    let d5d7c = readU16(snes, 0x5D7C)
    let p98a5 = readU8(snes, 0x98A5)
    let txt = policy.getDialogueText(snes).strip().replace("\n", " ")
    let base = f.extractFilename
    let battle = b4dba != 0
    let realBattle = battle and mode == 0
    let tag =
      if realBattle: "  <<< HEALTHY BATTLE (4DBA!=0 & mode0)"
      elif battle: "  << 4DBA set but mode!=0 (dead/entry)"
      else: ""
    let txtShort = if txt.len > 40: txt[0..39] else: txt
    echo &"{base}: 4DBA={b4dba:02X} mode={mode} phase98A5={p98a5:02X} 5D7C={d5d7c:04X} pos=(0x{px:04X},0x{py:04X}) txt=[{txtShort}]{tag}"
    if realBattle: battleHits.add base
    if txt.toLowerAscii.contains("knock") or txt.toLowerAscii.contains("pokey") or
       txt.toLowerAscii.contains("scoot") or txt.toLowerAscii.contains("bed"):
      knockHits.add &"{base} txt=[{txtShort}]"

  echo "\n===== SUMMARY ====="
  echo &"HEALTHY BATTLE captures ({battleHits.len}):"
  for b in battleHits: echo "  ", b
  echo &"KNOCK/bed/pokey dialogue candidates ({knockHits.len}):"
  for k in knockHits: echo "  ", k

when isMainModule:
  main()
