## Incomplete FAR CALL heads and AS partial free runs.
import
  std/[strformat, algorithm],
  ../decompbound/[rom_chunks, baserom_extract, action_script]

proc mark(c: var seq[bool]; o, n: int) =
  for j in 0 ..< n:
    if o + j >= 0 and o + j < c.len: c[o + j] = true

proc freeRuns(claimed: seq[bool]): seq[tuple[o, n: int]] =
  result = @[]
  var rs = -1; var rl = 0
  for o in 0 ..< claimed.len:
    if not claimed[o]:
      if rs < 0: rs = o; rl = 1
      else: rl += 1
    else:
      if rs >= 0: result.add (rs, rl); rs = -1
  if rs >= 0: result.add (rs, rl)

let g = readGoldBaseromBytes()
var claimed = newSeq[bool](g.len)
for c in allRomChunksMeta():
  if c.kind != ckUnclaimed: mark(claimed, c.offset, c.length)

# Incomplete FAR CALL: free starts with 0x42/0x4C but run shorter than 4
var farInc = 0; var farIncN = 0
var farHead = 0; var farHeadN = 0
for r in freeRuns(claimed):
  if g[r.o] in [0x42u8, 0x4Cu8]:
    if r.n < 4:
      farInc += r.n; farIncN += 1
    else:
      let bank = int(g[r.o + 3])
      if bank >= 0xC0 and bank <= 0xFF:
        farHead += r.n; farHeadN += 1

echo &"incomplete FAR heads (n<4): {farInc} B / {farIncN}"
echo &"FAR start free runs n>=4: {farHead} B / {farHeadN}"

# Free runs where walk would succeed if we only had more free bytes past claimed?
# Check: free run ends mid-op if we extend into next free after a claimed island? skip.

# Good AS on free runs with minLen 2-3
for minL in [2, 3, 4, 6]:
  var b = 0; var n = 0
  for r in freeRuns(claimed):
    if r.n < minL: continue
    let w = walkActionScript(g, r.o, r.o + r.n)
    if w.ended and w.length >= minL and w.length <= r.n and w.ops >= 1:
      # claim full cover?
      if consumeActionScriptRun(g, r.o, r.n) == r.n:
        b += r.n; n += 1
  echo &"full-cover AS minL={minL}: {b} B / {n}"

# Partial: walk ends with length < free run but good
var partB = 0; var partN = 0
for r in freeRuns(claimed):
  if r.n < 2: continue
  let w = walkActionScript(g, r.o, r.o + r.n)
  if isGoodActionScriptWalk(w) and w.length < r.n:
    partB += w.length; partN += 1
echo &"partial good AS heads: {partB} B / {partN}"

# Free runs that are complete single terminal ops (e.g. 0x00 halt alone = 1 byte)
var termSolo = 0
for r in freeRuns(claimed):
  if r.n == 1 and ActionScriptTerminal[int(g[r.o])] and ActionScriptOperandWidths[int(g[r.o])] == 0:
    termSolo += 1
echo &"single-byte AS terminal free: {termSolo}"

# High-path end 0x70+ single byte (AS treats as terminal)
var highSolo = 0
for r in freeRuns(claimed):
  if r.n == 1 and g[r.o] >= 0x70:
    highSolo += 1
echo &"single-byte highpath >=0x70 free: {highSolo}"

# Free that is pure FF or pure 00 already known
# Check incomplete FAR where free is mid-FAR: look for free runs where
# claimed[o-1] is 0x42 and free is remaining operand bytes
var midFar = 0; var midFarN = 0
for r in freeRuns(claimed):
  if r.o == 0: continue
  # check if within 3 bytes after a 0x42 that was claimed as AS or code
  for back in 1..3:
    let base = r.o - back
    if base < 0: continue
    if g[base] in [0x42u8, 0x4Cu8] and claimed[base]:
      # FAR is 4 bytes; free should cover remaining
      let need = 4 - back
      if need > 0 and r.n >= need:
        let bank = int(g[base + 3])
        if bank >= 0xC0 and bank <= 0xFF:
          midFar += need; midFarN += 1
          break
echo &"mid-FAR free continuations: {midFar} B / {midFarN}"

# Look at code sandwich top free - do they look like code stubs?
var kindAt = newSeq[string](g.len)
for c in allRomChunksMeta():
  let kn = case c.kind
    of ckImplementedCode: "code"
    of ckImplementedMeta: "meta"
    of ckUnclaimed: "free"
  for j in 0..<c.length:
    if c.offset+j < kindAt.len: kindAt[c.offset+j] = kn

# RTL/RTS/RTI endings in code sandwiches
var rtlEnds = 0; var rtlB = 0
for r in freeRuns(claimed):
  if r.o > 0 and kindAt[r.o-1] == "code" and r.o+r.n < g.len and kindAt[r.o+r.n] == "code":
    let last = g[r.o + r.n - 1]
    if last in [0x6Bu8, 0x60u8, 0x40u8]:  # RTL RTS RTI
      rtlEnds += 1; rtlB += r.n
echo &"code-sandwich ending RTL/RTS/RTI: {rtlB} B / {rtlEnds}"

# Count free runs that start with common 65816 prologues (08 PHP, 8B PHB, etc) between code
var prolog = 0; var prologB = 0
for r in freeRuns(claimed):
  if not (r.o > 0 and kindAt[r.o-1] == "code" and r.o+r.n < g.len and kindAt[r.o+r.n] == "code"):
    continue
  if g[r.o] in [0x08u8, 0x8Bu8, 0x4Bu8, 0xC2u8, 0xE2u8, 0xA9u8, 0xA2u8, 0xA0u8, 0x22u8, 0x20u8, 0xADu8, 0xAFu8]:
    prolog += 1; prologB += r.n
echo &"code-sandwich common prologue: {prologB} B / {prolog}"

# List some code sandwich examples
var shown = 0
for r in freeRuns(claimed):
  if not (r.o > 0 and kindAt[r.o-1] == "code" and r.o+r.n < g.len and kindAt[r.o+r.n] == "code"):
    continue
  if r.n < 8: continue
  var hx = ""
  for j in 0..<min(16, r.n): hx.add &"{g[r.o+j]:02X} "
  echo &"  code| 0x{r.o:06X}+{r.n} | {hx}"
  shown += 1
  if shown >= 20: break
