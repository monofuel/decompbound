## CLI for generating a single region module from ROM disassembly.
## Usage: nim r src/tools/gen_source.nim <rom> <offset> <length> <procName> [--emu|--m8|--x8]
## The batch equivalent (every traced region at once) is convert_all.nim.

import
  std/[os, strformat, strutils],
  ../decompbound/[opcodes, sourcegen]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc main() =
  var positional: seq[string]
  var entryFlags = FlagState(m8: false, x8: false, emulation: false)
  for i in 1..paramCount():
    let arg = paramStr(i)
    case arg:
    of "--emu":
      entryFlags = initFlagState()
    of "--m8":
      entryFlags.m8 = true
    of "--x8":
      entryFlags.x8 = true
    else:
      positional.add arg

  if positional.len < 4:
    echo "Usage: nim r src/tools/gen_source.nim <rom> <offset> <length> <procName> [--emu|--m8|--x8]"
    quit(1)

  let romFile = positional[0]
  var offsetStr = positional[1]
  if offsetStr.startsWith("0x"):
    offsetStr = offsetStr[2..^1]
  let offset = parseHexInt(offsetStr)
  let length = parseInt(positional[2])
  let procName = positional[3]

  let rom = readRomFile(romFile)
  let (source, covered, instructions) = generateModuleSource(
    rom, offset, length, procName, entryFlags)
  stdout.write source
  stderr.writeLine &"covered {covered}/{length} bytes, {instructions} instructions"

when isMainModule:
  main()
