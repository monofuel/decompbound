## Headless export through the same decoder and renderer as Pocket Backgrounds.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/battle_bg

proc main() =
  ## Export a battle group's frames into a local ignored output directory.
  var
    romPath = DefaultRomPath
    outputBase = "bin/battle_bg"
    group = 0
    frames = 60
    index = 1
  while index <= paramCount():
    let argument = paramStr(index)
    if argument in ["--help", "-h"]:
      echo "Usage: battle_bg_explore [ROM] --bg N --frames N --out bin/battle_bg"
      return
    if argument in ["--bg", "--frames", "--out", "--rom"]:
      inc index
      if index > paramCount(): raise newException(ValueError, "Missing value for " & argument)
      let value = paramStr(index)
      case argument
      of "--bg": group = parseInt(value)
      of "--frames": frames = parseInt(value)
      of "--out": outputBase = value
      of "--rom": romPath = value
      else: discard
    elif argument.startsWith("-"):
      raise newException(ValueError, "Unknown option: " & argument)
    else: romPath = argument
    inc index
  if frames <= 0: raise newException(ValueError, "Frame count must be positive.")
  let
    rom = loadBattleBgRom(romPath)
    background = loadBattleBg(rom, group)
    directory = outputBase / &"bg_{group:03d}"
    image = newImage(ScreenW, ScreenH)
  var workspace: BackgroundWorkspace
  createDir(directory)
  for frame in 0 ..< frames:
    renderInto(background, frame, image, workspace)
    image.writeFile(directory / &"frame_{frame:03d}.png")
  echo &"Group {group}: layers {background.layerA}+{background.layerB}; {frames} frames in {directory}"

when isMainModule: main()
