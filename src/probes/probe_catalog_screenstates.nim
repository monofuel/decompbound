## Catalog every unique earthbound_*.png screenstate (ebSt metadata only).
## Writes markdown with room/pos/spine — no pixels, no dialogue.

import
  std/[algorithm, options, os, strformat, strutils, tables],
  ../decompbound/[cpu, party_wram, png_state, policy, replay, save_state, snesbus],
  ../decompbound/run_report,
  ../tools/[story_percents, touch_grass]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PicturesDir = "/home/monofuel/Pictures/Screenshots"
  SecretFlat = "../decompbound_secret/screenstates"
  SessionsRoot = "../decompbound_secret/sessions"
  OutPath = "docs/screenstates-catalog.md"

type
  Hit = object
    name: string
    paths: seq[string]
    hasEbSt: bool
    room: string
    px, py: int
    battle: bool
    tg, pokey, knock, sunrise, frank, giant: int
    nessLv, nessHp, nessHpMax: int
    err: string

proc addPng(tab: var OrderedTable[string, seq[string]], dir: string) =
  ## Add earthbound_*.png from `dir` into the name → paths table.
  if not dirExists(dir):
    return
  for kind, p in walkDir(dir):
    if kind != pcFile or not p.endsWith(".png"):
      continue
    let n = p.extractFilename
    if not n.startsWith("earthbound_"):
      continue
    if n in tab:
      tab[n].add p
    else:
      tab[n] = @[p]

proc collectPaths(): OrderedTable[string, seq[string]] =
  ## Filename → source paths, first-seen wins for sampling.
  result = initOrderedTable[string, seq[string]]()
  if dirExists(SessionsRoot):
    for kind, sdir in walkDir(SessionsRoot):
      if kind == pcDir and dirExists(sdir / "f12"):
        addPng(result, sdir / "f12")
  addPng(result, SecretFlat)
  addPng(result, PicturesDir)

proc sampleOne(snes: SnesBus, c: var Cpu, path: string, h: var Hit) =
  ## Fill WRAM fields from the first path that has a valid ebSt.
  let png = cast[seq[uint8]](readFile(path))
  let stOpt = extractState(png)
  if stOpt.isNone:
    h.hasEbSt = false
    h.room = "(no ebSt)"
    return
  h.hasEbSt = true
  deserializeState(cast[seq[byte]](stOpt.get), snes, c)
  let (px, py) = playerPos(snes)
  h.px = px.int
  h.py = py.int
  h.battle = isInBattle(snes)
  h.room = reportRoomLabel(h.px, h.py, h.battle)
  h.tg = touchGrassPercent(snes)
  h.pokey = pokeyPercent(snes)
  h.knock = pokeyKnockPercent(snes)
  h.sunrise = sunrisePercent(snes)
  h.frank = frankPercent(snes)
  h.giant = giantStepPercent(snes)
  let vitals = readPartyVitalsFromWram(snes)
  for m in vitals.members:
    if m.role == "Ness" or m.name == "Ness":
      h.nessLv = m.level
      h.nessHp = m.hp
      h.nessHpMax = m.hpMax
      break

proc whereTag(paths: seq[string]): string =
  ## Compact source list: sess stamp, secret, pictures.
  var bits: seq[string] = @[]
  for p in paths:
    if "/sessions/" in p and "/f12/" in p:
      let sess = p.split("/sessions/")[1].split("/")[0]
      bits.add sess
    elif "/screenstates/" in p:
      bits.add "secret"
    elif "/Pictures/" in p:
      bits.add "pictures"
    else:
      bits.add p.extractFilename
  bits.join(",")

proc main() =
  ## Scan unique F12 names and write the catalog markdown.
  if not fileExists(RomPath):
    echo "no ROM"
    quit(1)
  var rom = cast[seq[uint8]](readFile(RomPath))
  if rom.len mod 1024 == 512:
    rom = rom[512 .. ^1]
  let tab = collectPaths()
  var names: seq[string] = @[]
  for n in tab.keys:
    names.add n
  names.sort()
  echo "unique names: ", names.len
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  var hits: seq[Hit] = @[]
  var nEb, nFail = 0
  for i, n in names:
    var h = Hit(name: n, paths: tab[n])
    try:
      sampleOne(snes, c, tab[n][0], h)
    except CatchableError as e:
      h.err = e.msg
      inc nFail
    if h.hasEbSt:
      inc nEb
    hits.add h
    if (i + 1) mod 50 == 0:
      echo "  ", i + 1, "/", names.len, " ebSt=", nEb
  var lines: seq[string] = @[]
  lines.add "# Screenstate catalog"
  lines.add ""
  lines.add "Unique `earthbound_*.png` names under session `f12/`, "
  lines.add "`../decompbound_secret/screenstates/`, and `~/Pictures/Screenshots/`."
  lines.add "Metadata only (room / pos / story percents). **No pixels, no dialogue.**"
  lines.add "Files stay local — never commit the PNGs."
  lines.add ""
  lines.add &"Scanned {names.len} names, {nEb} with `ebSt`, {nFail} deserialize errors."
  lines.add ""
  lines.add "| file | where | room | pos | battle | tg | pokey | knock | sunrise | frank | giant | Ness |"
  lines.add "|--|--|--|--|--|--|--|--|--|--|--|--|"
  for h in hits:
    let pos =
      if h.hasEbSt: &"(0x{h.px:04X},0x{h.py:04X})"
      else: "—"
    let ness =
      if h.hasEbSt: &"L{h.nessLv} {h.nessHp}/{h.nessHpMax}"
      else: "—"
    let note = if h.err.len > 0: h.err else: ""
    lines.add &"| `{h.name}` | {whereTag(h.paths)} | {h.room} | {pos} | {h.battle} | " &
      &"{h.tg} | {h.pokey} | {h.knock} | {h.sunrise} | {h.frank} | {h.giant} | {ness} {note} |"
  writeFile(OutPath, lines.join("\n") & "\n")
  echo "wrote ", OutPath, " rows=", hits.len

when isMainModule:
  main()
