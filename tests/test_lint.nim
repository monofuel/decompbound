## Phase-2 structural lint: no resurrected generated bank tree; asm/ manifest ok.

import
  std/[os, strutils, tables],
  decompbound/[adopted, manifest]

block noGeneratedBanks:
  ## M2.5 deleted the bank-monster tree; it must stay gone.
  doAssert not dirExists("src/decompbound/generated"),
    "src/decompbound/generated must not exist after M2.5"
  doAssert not fileExists("src/decompbound/generated/registry.nim")

block manifestTiles:
  doAssert fileExists("manifest.json")
  let r = validateManifest(parseManifestFile("manifest.json"))
  doAssert r.ok, r.message
  doAssert r.covered == 3_145_728

block codeSpansLightweight:
  ## Scaffold inventory may remain as offsets-only (no bank imports).
  doAssert fileExists("src/decompbound/code_spans.nim")
  let body = readFile("src/decompbound/code_spans.nim")
  doAssert "import" notin body.splitLines()[0 .. min(20, body.splitLines().len-1)].join("\n") or
    "code_bank" notin body
  doAssert "code_bank" notin body

block adoptionInventoryMatchesManifest:
  let layout = parseManifestFile("manifest.json")
  var expected = initTable[string, tuple[offset, length: int]]()
  for region in layout.regions:
    if region.build == blReproduce:
      doAssert region.source == asmPath(region.name)
      expected[region.name] = (region.offset, region.length)
  for region in allAdoptedRegions():
    doAssert expected.hasKey(region.name), "Unexpected or duplicate adoption: " & region.name
    doAssert (region.offset, region.data.len) == expected[region.name], region.name
    expected.del(region.name)
  doAssert expected.len == 0, "Compatibility inventory omits manifest adoptions: " & $expected

echo "[test_lint] ok"
