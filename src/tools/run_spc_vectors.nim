## Runs SingleStepTests spc700 vectors against the SPC700 core and
## reports a per-opcode failure summary, like run_vectors.nim for the
## 65816. Usage: nim r src/tools/run_spc_vectors.nim [limit] [filter]

import
  std/[algorithm, json, os, strformat, strutils],
  ../decompbound/spc700

let
  vectorDir = if getEnv("SPC_VECTOR_DIR").len > 0: getEnv("SPC_VECTOR_DIR")
              else: "bin/spc700-vectors/v1"

type
  FileResult* = object
    name*: string
    passed*: int
    failed*: int
    firstFailure*: string

proc loadState(spc: var Spc, node: JsonNode) =
  ## Set CPU registers from a vector state block.
  spc.pc = node["pc"].getInt().uint16
  spc.a = node["a"].getInt().uint8
  spc.x = node["x"].getInt().uint8
  spc.y = node["y"].getInt().uint8
  spc.sp = node["sp"].getInt().uint8
  spc.psw = node["psw"].getInt().uint8

proc describeDiff(spc: Spc, final: JsonNode): string =
  ## First difference against the expected final state, or empty.
  if spc.pc.int != final["pc"].getInt(): return &"pc: got {spc.pc:04X} want {final[\"pc\"].getInt():04X}"
  if spc.a.int != final["a"].getInt(): return &"a: got {spc.a:02X} want {final[\"a\"].getInt():02X}"
  if spc.x.int != final["x"].getInt(): return &"x: got {spc.x:02X} want {final[\"x\"].getInt():02X}"
  if spc.y.int != final["y"].getInt(): return &"y: got {spc.y:02X} want {final[\"y\"].getInt():02X}"
  if spc.sp.int != final["sp"].getInt(): return &"sp: got {spc.sp:02X} want {final[\"sp\"].getInt():02X}"
  if spc.psw.int != final["psw"].getInt(): return &"psw: got {spc.psw:02X} want {final[\"psw\"].getInt():02X}"
  for pair in final["ram"]:
    let address = pair[0].getInt()
    let want = pair[1].getInt()
    if spc.ram[address].int != want:
      return &"ram[{address:04X}]: got {spc.ram[address]:02X} want {want:02X}"
  result = ""

proc runFile*(spc: var Spc, path: string, limit: int): FileResult =
  ## Run one vector file, resetting touched RAM between tests.
  result.name = path.extractFilename()
  let tests = parseFile(path)
  var count = 0
  for test in tests:
    if limit > 0 and count >= limit:
      break
    count += 1

    var touched: seq[int]
    for pair in test["initial"]["ram"]:
      let address = pair[0].getInt()
      spc.ram[address] = pair[1].getInt().uint8
      touched.add address
    for pair in test["final"]["ram"]:
      touched.add pair[0].getInt()

    spc.loadState(test["initial"])
    spc.stopped = false
    spc.step()

    let diff = describeDiff(spc, test["final"])
    if diff.len == 0:
      result.passed += 1
    else:
      result.failed += 1
      if result.firstFailure.len == 0:
        result.firstFailure = test["name"].getStr() & ": " & diff

    for address in touched:
      spc.ram[address] = 0
    # Stack writes land near the SP; clear that page defensively.
    for i in 0x100..0x1FF:
      spc.ram[i] = 0

proc main() =
  var limit = 200
  var filter = ""
  if paramCount() >= 1:
    limit = parseInt(paramStr(1))
  if paramCount() >= 2:
    filter = paramStr(2).toLowerAscii()

  if not dirExists(vectorDir):
    echo "Vector directory not found: ", vectorDir
    quit(1)

  var files: seq[string]
  for path in walkFiles(vectorDir / "*.json"):
    if filter.len == 0 or path.extractFilename().startsWith(filter):
      files.add path
  files.sort()

  var spc = newSpc()
  var totalPassed = 0
  var totalFailed = 0
  var failing: seq[FileResult]
  for path in files:
    let r = spc.runFile(path, limit)
    totalPassed += r.passed
    totalFailed += r.failed
    if r.failed > 0:
      failing.add r

  failing.sort(proc(a, b: FileResult): int = cmp(b.failed, a.failed))
  for r in failing:
    echo &"{r.name}: {r.failed} failed / {r.failed + r.passed}  ({r.firstFailure})"
  echo &"total: {totalPassed} passed, {totalFailed} failed across {files.len} files"

when isMainModule:
  main()
