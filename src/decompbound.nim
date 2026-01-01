## Public interface for the decompbound decompilation project.
## This generates the ROM based on our reverse-engineered understanding.
## The gold master ROM is only used by compare.nim for validation.

# nim r src/decompbound.nim

import
  std/[strformat, parseopt, osproc],
  decompbound/[common, header, vectors, init]

proc generateRom(): string =
  ## Generate the decomp ROM from our reverse-engineered code and data.
  ## This builds the ROM based on our understanding, not by copying from the gold master.
  let headerData = generateEarthboundHeader()
  let resetVectors = generateResetVectors()
  let initCode = generateInitCode()
  
  var rom = newString(EarthboundRomSize)
  for i in 0..<rom.len:
    rom[i] = '\x00'
  
  for i in 0..<headerData.len:
    rom[HiRomHeaderOffset + i] = headerData[i].char
  
  for i in 0..<resetVectors.len:
    rom[ResetVectorOffset + i] = resetVectors[i].char
  
  for i in 0..<initCode.len:
    rom[InitCodeOffset + i] = initCode[i].char
  
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
