import std/strformat
import ../decompbound/[rom_chunks, baserom_extract]

proc main() =
  ## Print residual free inventory after current claims.
  var free = 0
  var runs = 0
  var maxr = 0
  var codeB = 0
  var metaB = 0
  for c in allRomChunksMeta():
    case c.kind
    of ckUnclaimed:
      free += c.length
      runs += 1
      if c.length > maxr: maxr = c.length
    of ckImplementedCode:
      codeB += c.length
    of ckImplementedMeta:
      metaB += c.length
  echo &"free={free} runs={runs} max={maxr}"
  echo &"code={codeB} meta={metaB} sum={free+codeB+metaB}"
  echo &"extract total bytes={totalBaseromExtractBytes()}"
  let exact = (3145728 - free).float * 100.0 / 3145728.0
  echo &"inventory coverage if free unclaimed: {exact:.4f}%"

main()
