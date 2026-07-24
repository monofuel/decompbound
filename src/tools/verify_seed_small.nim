import std/strformat,
  ../decompbound/[baserom_extract, common],
  ../decompbound/generated/code_bank00

let gold = readGoldBaseromBytes()
let d = generateCode00922F()
echo &"len {d.len}"
var mism=0
for i,b in d:
  if gold[0x00922F+i] != b:
    mism+=1
    echo &"mis +{i} {b:02X} vs {gold[0x00922F+i]:02X}"
echo if mism==0: "OK 00922F exact" else: &"FAIL {mism}"
# also print first 12 assembled
var hx=""
for i in 0..<min(12,d.len): hx.add &"{d[i]:02X} "
echo hx
