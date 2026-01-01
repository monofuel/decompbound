## Public interface for the decompbound decompilation project.
# nim r src/decompbound.nim

import decompbound/common

const outputRom = "bin/Decompbound.smc"

# TODO should probably use some sort of struct or binary blob for rom data
var recompRom = "TODO"

when isMainModule:
  echo "Hello, World!"

  writeFile(outputRom, "")
