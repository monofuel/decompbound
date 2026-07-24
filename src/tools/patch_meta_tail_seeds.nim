## Patch Decompbound.smc with meta-tail seed regions.
import
  std/[os, strformat],
  ../decompbound/[assembler, baserom_extract, common, opcodes],
  ../decompbound/generated/code_bank00

proc main() =
  ## Patch seed-related assembled bytes into Decompbound.smc and score.
  let path = "bin/Decompbound.smc"
  let raw = readFile(path)
  var rom = newSeq[uint8](raw.len)
  for i, c in raw: rom[i] = c.uint8
  if rom.len == EarthboundRomSize + 512:
    rom = rom[512 .. ^1]
  doAssert rom.len == EarthboundRomSize

  let gold = readGoldBaseromBytes()
  let f16 = FlagState(m8: false, x8: false, emulation: false)

  let r922F = generateCode00922F()
  for i, b in r922F: rom[0x00922F + i] = b
  echo &"patched 0x00922F+{r922F.len}"

  let h170 = assemble(@[
    instr("PLD", amImplied), instr("RTS", amImplied),
  ], 0xC16170'u32, f16)
  for i, b in h170: rom[0x016170 + i] = b
  echo &"patched 0x016170+{h170.len}"

  let hEBA = assemble(@[
    instr("LDA", amImmediateM, 0x0),
    instr("PLD", amImplied),
    instr("RTS", amImplied),
  ], 0xC16EBA'u32, f16)
  for i, b in hEBA: rom[0x016EBA + i] = b
  echo &"patched 0x016EBA+{hEBA.len}"

  writeFile(path, rom)

  for (off, n) in [(0x00922F, 27), (0x016170, 2), (0x016EBA, 5)]:
    var m = 0
    for i in 0 ..< n:
      if rom[off + i] != gold[off + i]: m += 1
    echo &"site 0x{off:06X}+{n}: exact={m == 0}"
    if m != 0: quit 1

  var exact = 0
  for i in 0 ..< gold.len:
    if rom[i] == gold[i]: exact += 1
  let pct = 100.0 * exact.float / gold.len.float
  echo &"full image exact (partial patch): {exact}/{gold.len} ({pct:.4f}%)"

when isMainModule:
  main()
