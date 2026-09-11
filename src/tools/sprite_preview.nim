import
  std/[os, strutils],
  pixie,
  ../decompbound/[ppu, rom_pipeline, sprite_preview]

proc main() =
  ## Export an isolated baseline-palette sprite from the user's ROM.
  if paramCount() > 3:
    raise newException(ValueError, "Usage: nim r src/tools/sprite_preview.nim [resource [direction [phase]]]")
  let
    resource = if paramCount() >= 1: parseInt(paramStr(1)) else: 437
    direction = if paramCount() >= 2: parseInt(paramStr(2)) else: 0
    phase = if paramCount() >= 3: parseInt(paramStr(3)) else: 0
    snes = buildSpritePreview(readGoldBaserom(), resource, direction, phase)
    directory = "extracted/view/sprites"
    output = directory / ($resource & "-" & $direction & "-" & $phase & ".png")
  createDir(directory)
  snes.renderFrame().writeFile(output)
  echo output & " (baseline palette; scene overrides excluded)"

when isMainModule:
  main()
