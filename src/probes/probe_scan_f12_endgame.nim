## Full F12 corpus scan for Magicant/Giygas candidates: high ma, high bp, dream proxies.
## Grades every ebSt PNG under Screenshots; prints outliers for RE.

import
  std/[os, strformat, strutils, algorithm, options, sequtils],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  ShotDir = "/home/monofuel/Pictures/Screenshots"

type Row = object
  path: string
  fo, ma, gi, bp, lv, py, px: int
  party: string
  soft: bool

proc gradePng(path: string): Option[Row] =
  ## Grade one F12 with ebSt; none if no state or load fails.
  let png = cast[seq[uint8]](readFile(path))
  let stOpt = extractState(png)
  if stOpt.isNone:
    return none(Row)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  try:
    deserializeState(stOpt.get, snes, cpu)
  except CatchableError:
    return none(Row)
  let i = PlayerSlot * SlotIndexStride
  let pr0 = readU8(snes, 0x988B)
  let pr1 = readU8(snes, 0x988C)
  let pr2 = readU8(snes, 0x988D)
  let pr3 = readU8(snes, 0x988E)
  result = some(Row(
    path: extractFilename(path),
    fo: foursidePercent(snes),
    ma: magicantPercent(snes),
    gi: giygasPercent(snes),
    bp: eventFlagBitPop(snes),
    lv: partyLeaderLevel(snes),
    px: readU16(snes, WorldXBase + i),
    py: readU16(snes, WorldYBase + i),
    party: fmt"{pr0:02X},{pr1:02X},{pr2:02X},{pr3:02X}",
    soft: hasAllSanctuarySoft(snes)))

proc main() =
  ## Scan all earthbound F12s; report soft ceiling, top bitpop, top ma.
  doAssert fileExists(Rom)
  var rows: seq[Row]
  for k in walkDir(ShotDir):
    if k.kind != pcFile: continue
    if "earthbound_" notin k.path or not k.path.endsWith(".png"): continue
    if getFileSize(k.path) < 80_000: continue
    let r = gradePng(k.path)
    if r.isSome:
      rows.add r.get
  echo "scanned_with_ebSt=", rows.len
  rows.sort(proc(a, b: Row): int =
    if a.ma != b.ma: return cmp(b.ma, a.ma)
    if a.bp != b.bp: return cmp(b.bp, a.bp)
    cmp(a.path, b.path))
  echo "=== TOP by magicant then bitpop (max 40) ==="
  for i, r in rows:
    if i >= 40: break
    echo fmt"{r.path}: ma={r.ma} gi={r.gi} fo={r.fo} bp={r.bp} lv={r.lv} " &
      fmt"pos=(0x{r.px:04X},0x{r.py:04X}) party={r.party} soft={r.soft}"
  var maxMa, maxGi, maxBp = 0
  var softN, ma98n = 0
  for r in rows:
    if r.ma > maxMa: maxMa = r.ma
    if r.gi > maxGi: maxGi = r.gi
    if r.bp > maxBp: maxBp = r.bp
    if r.soft: softN.inc
    if r.ma >= 98: ma98n.inc
  echo fmt"SUMMARY max_ma={maxMa} max_gi={maxGi} max_bp={maxBp} soft_n={softN} ma98_n={ma98n}"
  # Dream-like: solo Ness high level, or unusual party, or ma would be 100 if flag
  echo "=== OUTLIERS soft=true highest bp ==="
  var softRows = rows.filterIt(it.soft)
  softRows.sort(proc(a, b: Row): int = cmp(b.bp, a.bp))
  for i, r in softRows:
    if i >= 15: break
    echo fmt"  {r.path}: bp={r.bp} ma={r.ma} pos=(0x{r.px:04X},0x{r.py:04X}) party={r.party}"
  echo "=== OUTLIERS lv>=22 party has 04 high bp non-soft ==="
  var n = 0
  for r in rows:
    if r.soft: continue
    if r.lv < 22: continue
    if "04" notin r.party: continue
    if r.bp < 580: continue
    echo fmt"  {r.path}: bp={r.bp} ma={r.ma} lv={r.lv} pos=(0x{r.px:04X},0x{r.py:04X})"
    n.inc
    if n >= 15: break
  echo "OK probe_scan_f12_endgame"

when isMainModule:
  main()
