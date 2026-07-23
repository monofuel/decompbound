## Scratch: package a .state fixture as a drag-droppable ebSt PNG for make play.
## Renders the state's frame and embeds the save-state + ROM hash, exactly like
## an F12 state-screenshot. Output under bin/ (gitignored).
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, png_state, policy]

proc main() =
  ## probe_make_drop_png <state> <out.png>
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    if paramStr(i) != "--":
      args.add paramStr(i)
  let statePath = if args.len >= 1: args[0] else: "bin/states/llm/onett_start.state"
  let outPath = if args.len >= 2: args[1] else: "bin/pokey_start_drop.png"
  let rom = policy.readRomFile("bin/Earthbound (U) [!].smc")
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  let stateBytes = cast[seq[uint8]](readFile(statePath))
  deserializeState(cast[seq[byte]](stateBytes), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for i in 0 .. 60:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
  # Re-serialize AFTER settling so the embedded state matches the shown frame.
  let settled = serializeState(snes, c)
  let png = img.encodeImage(PngFormat)
  let bundled = embedState(cast[seq[uint8]](png), cast[seq[uint8]](settled), romHashOf(rom))
  writeFile(outPath, cast[string](bundled))
  echo &"wrote {outPath} ({bundled.len} bytes) — drag onto the make play window"

when isMainModule:
  main()
