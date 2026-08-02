## Re-export adopted regions from currently assembled asm (identity refresh).
## Prefer editing asm/*.asm directly; this tool only rewrites from live assemble.

import
  std/[os, strformat],
  ../decompbound/[adopted, asm_export, opcodes]

proc main() =
  ## Rewrite asm/*.asm from the current assembleAdoptedFile output (round-trip).
  createDir(AsmRoot)
  for r in allAdoptedRegions():
    let isData = r.name in [
      "actionScriptDispatchTable", "jmpTable8C65", "jmpTableA1AE", "jmpTableA350"
    ]
    let evidence = &"Adopted region {r.name}; file offset 0x{r.offset:06X}."
    let body =
      if isData: dataBytesToCa65(r.data, r.offset.uint32, evidence)
      else: bytesToCa65(r.data, r.offset.uint32, NativeFlags16, evidence)
    writeFile(asmPath(r.name), body)
    echo &"wrote {asmPath(r.name)} ({r.data.len} B)"
  echo "export done"

main()
