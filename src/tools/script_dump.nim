## Script / dialogue block dump tool.
## Given a user ROM, decode and print dialogue block(s) by raw file offset or by pointer-table ID via 0x8CDED far-ptr table.
## By-ID mode: resolve id*4 at 0x8CDED -> far ptr -> block start, then decodeText.
## Output to stdout only; never written to repo (copyright: dialogue text is user+ROM derived, not committed).
## See docs/scripts.md for encoding and dispatch rules.
##
## Run directly (per project override; Makefile target added separately):
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --offset 0x63040
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --id 0
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --from 30 --to 35
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --scan 20

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
  ## By-ID modes use resolveDialogueBlock via 0x8CDED table then decodeText.
  ## Robust to the "nix ... -- rom --offset" form (leading -- from shell separator is skipped).
  var romPath = "bin/Earthbound (U) [!].smc"
  var offset = -1
  var id = -1
  var fromId = -1
  var toId = -1
  var scanCount = -1
  var idList: seq[int] = @[]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "" or a == "--":
      continue
    if a.startsWith("--"):
      let keyVal = a[2 .. ^1]
      let parts = keyVal.split('=', 1)
      let k = parts[0]
      let v = if parts.len > 1: parts[1] else: (if i+1 <= paramCount(): paramStr(i+1) else: "")
      case k:
      of "rom", "r":
        romPath = if v != "": v else: romPath
      of "offset", "o", "at":
        let vv = if v != "": v else: (if i+1 <= paramCount() and not paramStr(i+1).startsWith("-"): paramStr(i+1) else: "")
        offset = parseHexInt(vv)
      of "id", "i":
        let vv = if v != "": v else: (if i+1 <= paramCount() and not paramStr(i+1).startsWith("-"): paramStr(i+1) else: "")
        # support comma list for id list e.g. --id 1,5,10
        if "," in vv:
          for p in vv.split(','):
            let trimmed = p.strip()
            if trimmed.len > 0:
              try: idList.add(parseInt(trimmed)) except: discard
        else:
          try:
            id = parseInt(vv)
          except:
            # ignore bad
            discard
      of "from", "f":
        let vv = if v != "": v else: (if i+1 <= paramCount() and not paramStr(i+1).startsWith("-"): paramStr(i+1) else: "")
        try: fromId = parseInt(vv) except: discard
      of "to", "t":
        let vv = if v != "": v else: (if i+1 <= paramCount() and not paramStr(i+1).startsWith("-"): paramStr(i+1) else: "")
        try: toId = parseInt(vv) except: discard
      of "scan", "s", "head":
        let vv = if v != "": v else: (if i+1 <= paramCount() and not paramStr(i+1).startsWith("-"): paramStr(i+1) else: "")
        try: scanCount = parseInt(vv) except: discard
      else:
        echo &"Unknown option: {k}"
        quit(1)
    elif romPath == "bin/Earthbound (U) [!].smc" and (a.endsWith(".smc") or a.endsWith(".sfc")):
      romPath = a
    elif offset == -1 and a.startsWith("0x"):
      offset = parseHexInt(a)
    elif offset == -1:
      # try plain number as offset
      try:
        offset = parseInt(a)
      except:
        discard
  if not fileExists(romPath):
    echo &"ERROR: ROM not found: {romPath}"
    echo "Supply path to your own legally obtained EarthBound ROM."
    quit(1)
  let rom = readRomFile(romPath)

  # Collect target ids for by-ID dump modes (preferred over raw offset).
  # Supports: single --id, --id 1,3,7 (list), --from/--to range, --scan K (first K).
  var targetIds: seq[int] = @[]
  if scanCount >= 0:
    for i in 0 ..< scanCount:
      targetIds.add(i)
  elif fromId >= 0 or toId >= 0:
    let lo = if fromId >= 0: fromId else: 0
    let hi = if toId >= 0: toId else: lo
    if hi < lo:
      echo &"ERROR: --to {hi} must be >= --from {lo}"
      quit(1)
    for i in lo .. hi:
      targetIds.add(i)
  elif idList.len > 0:
    targetIds = idList
  elif id >= 0:
    targetIds.add(id)

  if targetIds.len > 0:
    # By-ID mode: resolve each via 0x8CDED table, decode, print tagged "[id N] text"
    for tid in targetIds:
      let startOff = resolveDialogueBlock(rom, tid)
      if startOff < 0:
        echo &"[id {tid}] ERROR: failed to resolve via table at 0x8CDED"
        continue
      let decoded = decodeText(rom, startOff)
      echo &"[id {tid}] {decoded}"
    return

  # Fallback: raw offset mode (unchanged behavior)
  var startOff = offset
  if startOff < 0:
    echo "Usage: script_dump.nim [rom.smc] [--offset 0xNNNNNN | --id N | --from F --to T | --scan K | --id 1,2,5]"
    echo "  --offset : decode raw file offset (e.g. 0x63040)"
    echo "  --id N   : decode single via 0x8CDED pointer table id"
    echo "  --from F --to T : dump inclusive range of ids (table 0)"
    echo "  --scan K : dump first K ids (0 .. K-1) for browsing"
    echo "  --id 1,3,9 : dump explicit id list"
    quit(1)
  echo &"--- block @ 0x{startOff:05X} ---"
  let decoded = decodeText(rom, startOff)
  echo decoded
  echo "--- end block ---"

when isMainModule:
  main()
