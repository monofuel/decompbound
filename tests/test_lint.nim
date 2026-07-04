## The byte-literal lint (docs/goal-1.md definition-of-done item).
## Code region modules must express every byte through the assembler DSL.
## This is a whitelist: any line in a generated module that is not a known
## DSL construct fails the build. Raw byte literals are only legal in the
## single declared data-tail line, so "temporary" byte-banging cannot
## sneak back into code regions.

import
  std/[os, strutils]

const
  GeneratedDir = "src/decompbound/generated"

proc isAllowedLine(line: string): bool =
  ## Whitelist of line shapes a generated code module may contain.
  let l = line.strip()
  if l.len == 0 or l.startsWith("#"):
    return true
  if l.startsWith("import") or l.startsWith("./[") or l.startsWith("../["):
    return true
  if l.startsWith("proc generate") or l.startsWith("## "):
    return true
  if l == "var nodes: seq[AsmNode]":
    return true
  if l.startsWith("nodes.add instr(") or l.startsWith("nodes.add instrTo(") or
     l.startsWith("nodes.add label("):
    return true
  if l.startsWith("result = assemble(nodes,") or l.startsWith("FlagState("):
    return true
  if l.startsWith("result.add @[0x"):
    return true  # Declared data tail; counted separately below.
  result = false

block generatedModuleLint:
  doAssert dirExists(GeneratedDir), "generated dir missing: " & GeneratedDir
  var moduleCount = 0
  for path in walkFiles(GeneratedDir / "code_*.nim"):
    moduleCount += 1
    var dataTails = 0
    var lineNumber = 0
    for line in readFile(path).splitLines():
      lineNumber += 1
      doAssert isAllowedLine(line),
        path & ":" & $lineNumber & " contains a non-DSL line: " & line.strip()
      if line.strip().startsWith("result.add @[0x"):
        dataTails += 1
    doAssert dataTails <= 1,
      path & " has " & $dataTails & " data tails; at most one is allowed"
  doAssert moduleCount > 200, "suspiciously few generated modules: " & $moduleCount

block registryLint:
  # The registry must contain no byte literals at all.
  let registry = readFile(GeneratedDir / "registry.nim")
  doAssert "'u8, 0x" notin registry
  for line in registry.splitLines():
    doAssert "@[0x" notin line, "registry contains raw bytes: " & line

block frontierArtifact:
  # The frontier report must exist and record a plausible number of
  # computed-jump sites (goal-1.md: the frontier is explicit, not implied).
  let frontierPath = GeneratedDir / "frontier.md"
  doAssert fileExists(frontierPath), "frontier.md missing - rerun convert_all"
  let frontier = readFile(frontierPath)
  var sites = 0
  for line in frontier.splitLines():
    if line.startsWith("- `$"):
      sites += 1
  doAssert sites > 10, "suspiciously few frontier sites: " & $sites
