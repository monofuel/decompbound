import std/strutils, ../decompbound/baserom_extract
for s in KnownBaseromExtracts:
  doAssert not s.name.startsWith("residualFree_"), s.name
echo "noBlind residualFree_*: OK"
