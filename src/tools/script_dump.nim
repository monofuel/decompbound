## Script / dialogue block dump tool.
## Given a user ROM, decode and print one dialogue block (by raw file offset or by id via 0x8CDED table).
## Output is to stdout only; never written to repo (copyright: dialogue text is user+ROM derived, not committed).
## See docs/scripts.md for encoding and dispatch rules.
##
## Run directly (per project override; Makefile target added separately):
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --offset 0x63040
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --offset 0x45B67
##   nix develop -c nim c -r src/tools/script_dump.nim -- "bin/Earthbound (U) [!].smc" --id 0

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
  ## Parse args and dump the requested block decode to stdout.
  ## Robust to the "nix ... -- rom --offset" form (leading -- from shell separator is skipped).
  var romPath = "bin/Earthbound (U) [!].smc"
  var offset = -1
  var id = -1
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
        id = parseInt(vv)
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
  echo &"loaded ROM: {romPath} ({rom.len} bytes)"
  var startOff = offset
  if id >= 0:
    startOff = resolveDialogueBlock(rom, id)
    if startOff < 0:
      echo &"ERROR: id {id} failed to resolve via table at 0x8CDED"
      quit(1)
    echo &"id {id} resolves to file offset 0x{startOff:05X}"
  if startOff < 0:
    echo "Usage: script_dump.nim [rom.smc] [--offset 0xNNNNNN | --id N]"
    echo "  --offset : decode raw file offset (e.g. 0x63040)"
    echo "  --id     : decode via 0x8CDED pointer table id"
    quit(1)
  echo &"--- block @ 0x{startOff:05X} ---"
  let decoded = decodeText(rom, startOff)
  echo decoded
  echo "--- end block ---"

when isMainModule:
  main()
