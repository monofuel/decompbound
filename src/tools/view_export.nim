## Phase-2 M7 view path: export modern formats under extracted/view/ (gitignored).
## Does **not** feed the vanilla rebuild. Graphics→PNG, audio→WAV (one-way),
## script→text, tables→CSV/JSON.

import
  std/[json, os, strformat, strutils],
  pixie,
  ../decompbound/[baserom_extract, common, gfx_lz, text_decode]

const
  ViewRoot* = "extracted/view"
  ## Known-good gfx_lz stream (also used by gfx_roundtrip).
  GfxSampleOff = 0x214EE0
  ## First dialogue scan window used by script tools.
  ScriptSampleOff = 0x63040
  ## Enemy/item-style residual table claim sample when present in inventory.
  TableSampleNamePrefix = "table_"

proc writeWavPcm8*(path: string, samples: openArray[uint8], sampleRate = 32000) =
  ## Write a minimal mono 8-bit PCM WAV (view-only; not bit-identical to BRR).
  let dataSize = samples.len
  var wav = newStringOfCap(44 + dataSize)
  template put32(v: int) =
    wav.add char(v and 0xFF)
    wav.add char((v shr 8) and 0xFF)
    wav.add char((v shr 16) and 0xFF)
    wav.add char((v shr 24) and 0xFF)
  template put16(v: int) =
    wav.add char(v and 0xFF)
    wav.add char((v shr 8) and 0xFF)
  wav.add "RIFF"
  put32(36 + dataSize)
  wav.add "WAVE"
  wav.add "fmt "
  put32(16)
  put16(1)           # PCM
  put16(1)           # mono
  put32(sampleRate)
  put32(sampleRate)  # byte rate 8-bit mono
  put16(1)           # block align
  put16(8)           # bits
  wav.add "data"
  put32(dataSize)
  for s in samples:
    wav.add char(s)
  writeFile(path, wav)

proc exportGraphicsPng(rom: openArray[uint8], destDir: string): string =
  ## Decode one gfx_lz stream into an indexed greyscale PNG.
  let window = rom[GfxSampleOff ..< min(GfxSampleOff + 0x10000, rom.len)]
  let decoded = decode(window)
  let w = 16
  let h = max(1, (decoded.len + w - 1) div w)
  let img = newImage(w, h)
  for i, b in decoded:
    let x = i mod w
    let y = i div w
    if y >= h: break
    let v = b.uint8
    img[x, y] = rgba(v, v, v, 255)
  let path = destDir / "graphics_sample.png"
  img.writeFile(path)
  result = path

proc exportAudioWav(rom: openArray[uint8], destDir: string): string =
  ## One-way listen export: slice a few KB of APU package region as PCM noise.
  ## Real BRR→WAV listening is better via jukebox; this proves the view path.
  var off = 0x04F000
  for s in allBaseromExtractSpans():
    if s.kind == ekApuPackage:
      off = s.offset
      break
  let n = min(4096, rom.len - off)
  var samples = newSeq[uint8](n)
  for i in 0 ..< n:
    samples[i] = rom[off + i]
  let path = destDir / "audio_sample.wav"
  writeWavPcm8(path, samples)
  result = path

proc exportScriptText(rom: openArray[uint8], destDir: string): string =
  ## Decode a dialogue window to UTF-8 text (gitignored).
  let text = decodeText(rom, ScriptSampleOff)
  let path = destDir / "script_sample.txt"
  writeFile(path, &"; offset 0x{ScriptSampleOff:06X}\n{text}\n")
  result = path

proc exportTableCsv(rom: openArray[uint8], destDir: string): string =
  ## Export one baserom table claim as CSV of hex bytes (layout only).
  var span: BaseromExtractSpan
  var found = false
  for s in allBaseromExtractSpans():
    if s.kind == ekTable and s.name.startsWith(TableSampleNamePrefix):
      span = s
      found = true
      break
  if not found:
    for s in allBaseromExtractSpans():
      if s.kind == ekTable:
        span = s
        found = true
        break
  let path = destDir / "table_sample.csv"
  if not found:
    writeFile(path, "name,offset,length\n(none found),0,0\n")
    return path
  var lines = @[&"# {span.name} @ 0x{span.offset:06X} len={span.length}", "index,hex"]
  let n = min(span.length, 64)
  for i in 0 ..< n:
    lines.add &"{i},0x{rom[span.offset + i]:02X}"
  writeFile(path, lines.join("\n") & "\n")
  let jpath = destDir / "table_sample.json"
  let j = %*{
    "name": span.name,
    "offset": span.offset,
    "length": span.length,
    "note": span.note,
    "previewBytes": n
  }
  writeFile(jpath, pretty(j) & "\n")
  result = path

proc main() =
  ## Run all four view exporters into extracted/view/.
  if not goldBaseromAvailable():
    echo "gold missing; view_export requires baserom"
    quit(1)
  let rom = readGoldBaseromBytes()
  createDir(ViewRoot)
  let g = exportGraphicsPng(rom, ViewRoot)
  let a = exportAudioWav(rom, ViewRoot)
  let s = exportScriptText(rom, ViewRoot)
  let t = exportTableCsv(rom, ViewRoot)
  echo &"view export ok under {ViewRoot}/"
  echo &"  graphics: {g}"
  echo &"  audio:    {a}"
  echo &"  script:   {s}"
  echo &"  table:    {t}"
  for p in [g, a, s, t]:
    doAssert fileExists(p) and getFileSize(p) > 0, p

main()
