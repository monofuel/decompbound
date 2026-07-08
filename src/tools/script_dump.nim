## Script / dialogue block dump tool.
## Given a user ROM, decode and print dialogue block(s) by raw file offset or by
## pointer-table ID (tables at 0x8CDED / 0x8D1ED / 0x8D5ED).
## Output to stdout only; never written to repo (copyright: dialogue text is
## user+ROM derived, not committed). See docs/scripts.md.
##
##   nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --id 0
##   nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --offset 0x63040
##   nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --from 30 --to 35
##   nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --table 1 --id 0
##   nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --scan 20

import
  std/[os, strformat, strutils],
  ../decompbound/text_decode

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file bytes. Strips a leading 512-byte copier header if present (len mod 1024 == 512).
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc main() =
  ## Parse args and dump the requested block decode(s) to stdout.
  ## By-ID modes use resolveDialogueBlock then decodeText.
  var romPath = "bin/Earthbound (U) [!].smc"
  var offset = -1
  var id = -1
  var fromId = -1
  var toId = -1
  var scanCount = -1
  var table = 0
  var idList: seq[int] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "" or a == "--":
      inc i
      continue
    if a.startsWith("--"):
      let keyVal = a[2 .. ^1]
      let parts = keyVal.split('=', 1)
      let k = parts[0]
      var v = if parts.len > 1: parts[1] else: ""
      if v.len == 0 and i + 1 <= paramCount() and not paramStr(i + 1).startsWith("-"):
        v = paramStr(i + 1)
        inc i
      case k:
      of "rom", "r":
        if v.len > 0: romPath = v
      of "offset", "o", "at":
        if v.len > 0: offset = parseHexInt(v)
      of "id", "i":
        if "," in v:
          for p in v.split(','):
            let trimmed = p.strip()
            if trimmed.len > 0:
              idList.add(parseInt(trimmed))
        elif v.len > 0:
          id = parseInt(v)
      of "from", "f":
        if v.len > 0: fromId = parseInt(v)
      of "to", "t":
        if v.len > 0: toId = parseInt(v)
      of "scan", "s", "head":
        if v.len > 0: scanCount = parseInt(v)
      of "table":
        if v.len > 0: table = parseInt(v)
      else:
        echo &"Unknown option: {k}"
        quit(1)
    elif romPath == "bin/Earthbound (U) [!].smc" and (a.endsWith(".smc") or a.endsWith(".sfc")):
      romPath = a
    elif offset == -1 and a.startsWith("0x"):
      offset = parseHexInt(a)
    elif offset == -1:
      try:
        offset = parseInt(a)
      except:
        discard
    inc i
  if not fileExists(romPath):
    echo &"ERROR: ROM not found: {romPath}"
    echo "Supply path to your own legally obtained EarthBound ROM."
    quit(1)
  if table < 0 or table > 2:
    echo &"ERROR: --table must be 0, 1, or 2 (got {table})"
    quit(1)
  let rom = readRomFile(romPath)

  var targetIds: seq[int] = @[]
  if scanCount >= 0:
    for n in 0 ..< scanCount:
      targetIds.add(n)
  elif fromId >= 0 or toId >= 0:
    let lo = if fromId >= 0: fromId else: 0
    let hi = if toId >= 0: toId else: lo
    if hi < lo:
      echo &"ERROR: --to {hi} must be >= --from {lo}"
      quit(1)
    for n in lo .. hi:
      targetIds.add(n)
  elif idList.len > 0:
    targetIds = idList
  elif id >= 0:
    targetIds.add(id)

  if targetIds.len > 0:
    for tid in targetIds:
      let startOff = resolveDialogueBlock(rom, tid, table)
      if startOff < 0:
        echo &"[t{table} id {tid}] ERROR: failed to resolve via table"
        continue
      let decoded = decodeText(rom, startOff)
      echo &"[t{table} id {tid} @0x{startOff:05X}] {decoded}"
    return

  var startOff = offset
  if startOff < 0:
    echo "Usage: script_dump.nim [rom.smc] [--offset 0xN | --id N | --from F --to T | --scan K | --table T]"
    echo "  --offset  decode raw file offset (e.g. 0x63040)"
    echo "  --id N    decode via pointer table id (default table 0 = 0x8CDED)"
    echo "  --table T select table 0/1/2 (0x8CDED / 0x8D1ED / 0x8D5ED)"
    echo "  --from/--to  inclusive id range"
    echo "  --scan K  first K ids"
    echo "  --id 1,3,9 explicit id list"
    echo "Stdout only — do not redirect into the repo (copyright hygiene)."
    quit(1)
  echo &"--- block @ 0x{startOff:05X} ---"
  echo decodeText(rom, startOff)
  echo "--- end block ---"

when isMainModule:
  main()
