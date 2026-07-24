## Scan residual unclaimed gaps for action-script / script-stream claims.
##
## Prints candidate BaseromExtractSpan entries (offset/length only). Does not
## modify baserom_extract.nim — review and paste after gold checks.
##
## Usage (repo root):
##   nim r src/tools/scan_residual_as_ss.nim
##   nim r src/tools/scan_residual_as_ss.nim --as-only
##   nim r src/tools/scan_residual_as_ss.nim --ss-only

import
  std/[algorithm, os, strformat, strutils],
  ../decompbound/[
    action_script, baserom_extract, rom_chunks, text_decode]

proc freeMask(goldLen: int): seq[bool] =
  ## True on residual unclaimed bytes not already in a baserom extract.
  result = newSeq[bool](goldLen)
  for c in allRomChunksMeta():
    if c.kind == ckUnclaimed:
      for i in c.offset ..< c.offset + c.length:
        if i < goldLen:
          result[i] = true
  for s in allBaseromExtractSpans():
    for i in s.offset ..< s.offset + s.length:
      if i < goldLen:
        result[i] = false

proc scanScriptStreams(gold: seq[uint8]; free: var seq[bool]): seq[(int, int)] =
  ## Residual script_stream runs under current controlOperandBytes widths.
  result = @[]
  var i = 0
  while i < gold.len:
    if not free[i]:
      inc i
      continue
    let start = i
    while i < gold.len and free[i]:
      inc i
    let gapLen = i - start
    if gapLen < ScriptStreamMinLen:
      continue
    var p = start
    while p < start + gapLen:
      let w = walkScriptStream(gold, p, start + gapLen)
      if isGoodScriptStream(w):
        var q = p + w.length
        while q < start + gapLen:
          let w2 = walkScriptStream(gold, q, start + gapLen)
          if not isGoodScriptStream(w2):
            break
          q += w2.length
        let spanLen = q - p
        if spanLen >= ScriptStreamMinLen:
          result.add (p, spanLen)
          for j in p ..< q:
            free[j] = false
          p = q
          continue
      inc p

proc scanActionScripts(gold: seq[uint8]; free: var seq[bool]): seq[(int, int)] =
  ## Residual action-script runs under ActionScriptOperandWidths.
  result = @[]
  var i = 0
  while i < gold.len:
    if not free[i]:
      inc i
      continue
    let start = i
    while i < gold.len and free[i]:
      inc i
    let gapLen = i - start
    if gapLen < ActionScriptMinLen:
      continue
    var p = start
    while p + ActionScriptMinLen <= start + gapLen:
      let room = start + gapLen - p
      let consumed = consumeActionScriptRun(gold, p, room)
      if consumed >= ActionScriptMinLen and isGoodActionScriptSpan(gold, p, consumed):
        result.add (p, consumed)
        for j in p ..< p + consumed:
          free[j] = false
        p += consumed
      else:
        inc p

proc emitSs(o, l: int) =
  ## Print one script_stream claim stub.
  echo &"""  BaseromExtractSpan(
    name: "scriptStream_0x{o:06X}",
    offset: 0x{o:06X},
    length: {l},
    kind: ekScriptStream,
    note: "text CC walk (multi-byte collectors + sub-op extras); residual only"),"""

proc emitAs(o, l: int) =
  ## Print one action_script claim stub.
  echo &"""  BaseromExtractSpan(
    name: "actionScript_0x{o:06X}",
    offset: 0x{o:06X},
    length: {l},
    kind: ekActionScript,
    note: "action-script bytecode walk (WAIT/GOTO/GOSUB/FAR CALL + known widths; residual only)"),"""

proc main() =
  ## Scan residual gaps and print claim stubs.
  let args = commandLineParams()
  let asOnly = "--as-only" in args
  let ssOnly = "--ss-only" in args
  if not goldBaseromAvailable():
    echo "gold baserom missing"
    quit(1)
  let gold = readGoldBaseromBytes()
  var freeSs = freeMask(gold.len)
  var freeAs = freeMask(gold.len)
  var ssB, asB = 0
  if not asOnly:
    let ss = scanScriptStreams(gold, freeSs)
    for (o, l) in ss.sorted(proc(a, b: (int, int)): int = cmp(a[0], b[0])):
      emitSs(o, l)
      ssB += l
    echo &"# script_stream candidates: {ss.len} spans, {ssB} bytes"
  if not ssOnly:
    let asC = scanActionScripts(gold, freeAs)
    for (o, l) in asC.sorted(proc(a, b: (int, int)): int = cmp(a[0], b[0])):
      emitAs(o, l)
      asB += l
    echo &"# action_script candidates: {asC.len} spans, {asB} bytes"
  echo &"# total candidate bytes: {ssB + asB}"

when isMainModule:
  main()
