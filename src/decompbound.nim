## Public interface for the decompbound decompilation project.
## This generates the ROM based on our reverse-engineered understanding.
## The gold master ROM is only used by compare.nim for validation.

# nim r src/decompbound.nim

import
  std/[strformat, parseopt, osproc],
  decompbound/[common, regions]

proc generateRom(): string =
  ## Generate the decomp ROM from our reverse-engineered code and data.
  ## Every region comes from the central registry: code regions are
  ## assembled from disassembled mnemonics, data regions are declared data.
  ## Regions stream one at a time so assembled bank bytes are not retained.
  var rom = newString(EarthboundRomSize)
  for i in 0..<rom.len:
    rom[i] = '\x00'

  for region in eachRegion():
    for i in 0..<region.data.len:
      rom[region.offset + i] = region.data[i].char

  result = rom

when isMainModule:
  var runCompare = false

  var p = initOptParser()
  for kind, key, val in p.getOpt():
    case kind:
    of cmdLongOption, cmdShortOption:
      if key == "compare" or key == "c":
        runCompare = true
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdArgument:
      discard
    of cmdEnd:
      discard

  echo "Generating decomp ROM from reverse-engineered code..."

  let rom = generateRom()
  writeFile(outputRom, rom)

  echo &"Generated ROM: {outputRom} ({rom.len} bytes)"

  if runCompare:
    echo ""
    echo "Running comparison against gold master ROM..."
    let (output, exitCode) = execCmdEx("nim r src/compare.nim")
    echo output
    if exitCode != 0:
      quit(exitCode)
  else:
    echo "Use --compare or -c to validate against the gold master ROM."
