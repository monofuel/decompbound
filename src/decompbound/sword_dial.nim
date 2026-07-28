## Machine-executed RNG dial for drop-manipulation recipes.
##
## The emulator performs the frame-precise part of a recipe natively: a
## recipe file (written by src/tools/sword_recipe.nim on a validated hit)
## describes the exact input sequence — B-open, dwell N frames, B-close,
## walk — and `buildDialQueue` expands it into one joypad word per frame.
## play.nim replays the queue verbatim (replacing user input) when the
## player presses the dial key; the SAME builder drives the tool's
## headless simulation, so validation and live execution cannot drift.
##
## The human contract: restore the recipe's F12, press the dial key, hands
## off for a couple of seconds, then play the battle normally.

import
  std/[os, strutils]

const
  ## Frames the B button is held for the open/close presses (must match the
  ## sword_recipe simulation exactly — single source of truth lives here).
  BPressFrames* = 2
  ## Default cap on injected walk frames (the swirl interrupts long before).
  DialWalkFramesMax* = 900
  ## Recipe hand-off file, written by sword_recipe next to the states.
  RecipeCurrentPath* = "../decompbound_secret/recipe_current.txt"

  BtnB* = 0x8000'u16
  BtnUp* = 0x0800'u16
  BtnDown* = 0x0400'u16
  BtnLeft* = 0x0200'u16
  BtnRight* = 0x0100'u16

type
  DialRecipe* = object
    ## Parsed recipe_current.txt.
    capture*: string     ## F12/state filename the recipe was computed from.
    dwell*: int          ## Spinner dwell frames (the frame-precise part).
    dir*: string         ## Walk direction name (left/right/up/down/diagonals).
    seedAtClose*: uint32 ## Expected seed right after the closing B press.
    item*: string        ## Item the validated run rolled (display only).

proc dirToBtn*(dir: string): uint16 =
  ## Joypad word for a walk direction name; 0 for unknown/wait.
  case dir.toLowerAscii
  of "left": BtnLeft
  of "right": BtnRight
  of "up": BtnUp
  of "down": BtnDown
  of "up-left": BtnUp or BtnLeft
  of "up-right": BtnUp or BtnRight
  of "down-left": BtnDown or BtnLeft
  of "down-right": BtnDown or BtnRight
  else: 0'u16

proc buildDialQueue*(dwell: int, walkBtn: uint16,
                     walkFrames = DialWalkFramesMax): seq[uint16] =
  ## Expand a recipe into one joypad word per frame, byte-identical to the
  ## sword_recipe simulation's phase machine. Note the `+ 1`s: that machine
  ## checks its phase counter BEFORE emitting, so the transition frame still
  ## carries the outgoing phase's input (B held BPressFrames+1 frames, dwell
  ## spanning dwell+1 idle frames). Reproducing the off-by-one exactly is
  ## what makes a validated recipe replay identically live — an earlier
  ## "clean" queue drifted the seed and failed tests/test_sword_dial.
  result = @[]
  for _ in 0 .. BPressFrames: result.add BtnB      # open
  for _ in 0 .. dwell: result.add 0'u16            # dwell
  for _ in 0 .. BPressFrames: result.add BtnB      # close
  for _ in 0 ..< walkFrames: result.add walkBtn

proc dialCloseIndex*(dwell: int): int =
  ## Queue index of the frame on which the simulation samples the
  ## menu-close seed (start of the last closing-B frame).
  2 * BPressFrames + dwell + 2

proc parseRecipeFile*(path = RecipeCurrentPath): DialRecipe =
  ## Read a key=value recipe file. Raises IOError if absent; ValueError on
  ## malformed numeric fields (caller reports, never crashes the game loop).
  for line in readFile(path).splitLines:
    let l = line.strip
    if l.len == 0 or l.startsWith("#"):
      continue
    let eq = l.find('=')
    if eq <= 0:
      continue
    let key = l[0 ..< eq].strip
    let val = l[eq + 1 .. ^1].strip
    case key
    of "capture": result.capture = val
    of "dwell": result.dwell = parseInt(val)
    of "dir": result.dir = val
    of "seed_at_close": result.seedAtClose = fromHex[uint32](val)
    of "item": result.item = val
    else: discard

proc writeRecipeFile*(path: string, r: DialRecipe) =
  ## Write the hand-off file sword_recipe produces on a validated hit.
  var s = "# Sword recipe — executed in play with the dial key (F6).\n"
  s.add "# Restore the capture below FIRST, then press F6, hands off.\n"
  s.add "capture=" & r.capture & "\n"
  s.add "dwell=" & $r.dwell & "\n"
  s.add "dir=" & r.dir & "\n"
  s.add "seed_at_close=" & r.seedAtClose.toHex(8) & "\n"
  s.add "item=" & r.item & "\n"
  writeFile(path, s)
