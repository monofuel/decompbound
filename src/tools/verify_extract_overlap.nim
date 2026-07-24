## Verify baserom extracts do not overlap code_spans.
import
  std/[strformat, algorithm, strutils],
  ../decompbound/[baserom_extract, common, generated/code_spans, rom_chunks]

proc main() =
  var mask = newSeq[uint8](EarthboundRomSize) # 0 free, 1 code, 2 extract
  var codeBytes = 0
  for s in GeneratedCodeSpans:
    for j in 0..<s.length:
      if s.offset + j < mask.len:
        mask[s.offset + j] = 1
        codeBytes += 1
  var extractBytes = 0
  var overlap = 0
  var selfOverlap = 0
  for s in allBaseromExtractSpans():
    for j in 0..<s.length:
      let o = s.offset + j
      if o >= mask.len: continue
      if mask[o] == 1:
        overlap += 1
        if overlap <= 5:
          echo &"OVERLAP code∩extract @0x{o:06X} in {s.name}"
      elif mask[o] == 2:
        selfOverlap += 1
        if selfOverlap <= 5:
          echo &"SELF-OVERLAP extract @0x{o:06X} in {s.name}"
      else:
        mask[o] = 2
        extractBytes += 1
  echo &"code_spans bytes: {codeBytes}"
  echo &"extract unique bytes: {extractBytes}"
  echo &"code∩extract overlap: {overlap}"
  echo &"extract self-overlap: {selfOverlap}"
  # new wave totals
  var d7, ca, ce = 0
  for s in allBaseromExtractSpans():
    if s.name.startsWith("table_d7MapAttr_"): d7 += s.length
    elif s.name.startsWith("table_ca17_"): ca += s.length
    elif s.name == "table_cePtr_0x0EDD15": ce += s.length
  echo &"new wave: d7MapAttr={d7} ca17={ca} cePtr={ce} total={d7+ca+ce}"
  if overlap > 0 or selfOverlap > 0:
    quit(1)
  echo "OK: zero overlap"

main()
