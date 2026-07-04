## Runs SingleStepTests 65816 vectors against the CPU core and reports a
## per-opcode failure summary. The bring-up loop: run, fix the worst
## opcode, repeat until zero. tests/test_cpu.nim asserts the same thing;
## this tool exists to see all failures at once instead of first-failure.
## Usage: nim r src/tools/run_vectors.nim [limit-per-file] [opcode-filter]

import
  std/[algorithm, json, os, strformat, strutils],
  ../decompbound/cpu

let
  vectorDir = if getEnv("VECTOR_DIR").len > 0: getEnv("VECTOR_DIR")
              else: "bin/65816-vectors/v1"

type
  FileResult* = object
    name*: string
    passed*: int
    failed*: int
    firstFailure*: string

proc loadCpu(node: JsonNode): Cpu =
  ## Build CPU state from a vector's initial/final block.
  result.pc = node["pc"].getInt().uint16
  result.s = node["s"].getInt().uint16
  result.p = node["p"].getInt().uint8
  result.a = node["a"].getInt().uint16
  result.x = node["x"].getInt().uint16
  result.y = node["y"].getInt().uint16
  result.dbr = node["dbr"].getInt().uint8
  result.d = node["d"].getInt().uint16
  result.pbr = node["pbr"].getInt().uint8
  result.emulation = node["e"].getInt() == 1

proc describeDiff(cpu: Cpu, expected: Cpu, bus: Bus, finalRam: JsonNode): string =
  ## Human-readable first-difference description, empty when states match.
  if cpu.pc != expected.pc: return &"pc: got {cpu.pc:04X} want {expected.pc:04X}"
  if cpu.s != expected.s: return &"s: got {cpu.s:04X} want {expected.s:04X}"
  if cpu.p != expected.p: return &"p: got {cpu.p:02X} want {expected.p:02X}"
  if cpu.a != expected.a: return &"a: got {cpu.a:04X} want {expected.a:04X}"
  if cpu.x != expected.x: return &"x: got {cpu.x:04X} want {expected.x:04X}"
  if cpu.y != expected.y: return &"y: got {cpu.y:04X} want {expected.y:04X}"
  if cpu.dbr != expected.dbr: return &"dbr: got {cpu.dbr:02X} want {expected.dbr:02X}"
  if cpu.d != expected.d: return &"d: got {cpu.d:04X} want {expected.d:04X}"
  if cpu.pbr != expected.pbr: return &"pbr: got {cpu.pbr:02X} want {expected.pbr:02X}"
  if cpu.emulation != expected.emulation:
    return &"e: got {cpu.emulation} want {expected.emulation}"
  for pair in finalRam:
    let address = pair[0].getInt().uint32
    let want = pair[1].getInt().uint8
    let got = bus.read8(address)
    if got != want:
      return &"ram[{address:06X}]: got {got:02X} want {want:02X}"
  result = ""

proc runFile*(bus: Bus, path: string, limit: int): FileResult =
  ## Run one vector file; reuses the shared bus, resetting dirtied bytes.
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
      bus.mem[address] = pair[1].getInt().uint8
      touched.add address

    var cpu = loadCpu(test["initial"])
    # SingleStepTests snapshots block moves after a 100-cycle budget.
    cpu.mvnBudget = 100
    var expected = loadCpu(test["final"])
    expected.mvnBudget = 100
    cpu.step(bus)

    let diff = describeDiff(cpu, expected, bus, test["final"]["ram"])
    if diff.len == 0:
      result.passed += 1
    else:
      result.failed += 1
      if result.firstFailure.len == 0:
        result.firstFailure = test["name"].getStr() & ": " & diff

    for address in touched:
      bus.mem[address] = 0
    for address in bus.dirty:
      bus.mem[address] = 0
    bus.dirty.setLen(0)

proc main() =
  var limit = 200
  var filter = ""
  if paramCount() >= 1:
    limit = parseInt(paramStr(1))
  if paramCount() >= 2:
    filter = paramStr(2).toLowerAscii()

  if not dirExists(vectorDir):
    echo "Vector directory not found: ", vectorDir
    echo "Clone with: git clone --depth 1 https://github.com/SingleStepTests/65816 bin/65816-vectors"
    quit(1)

  var files: seq[string]
  for path in walkFiles(vectorDir / "*.json"):
    if filter.len == 0 or path.extractFilename().startsWith(filter):
      files.add path
  files.sort()

  let bus = newBus()
  var totalPassed = 0
  var totalFailed = 0
  var failing: seq[FileResult]
  for path in files:
    let r = runFile(bus, path, limit)
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
