## Public interface for the decompbound decompilation project.
# nim r src/decompbound.nim

import decompbound/common

const outputRom = "bin/Decompbound.smc"

var recompRom = ""

when isMainModule:
  echo "Hello, World!"

  writeFile(outputRom, "")
