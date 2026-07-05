## SNES USB controller test. Prints how each connected gamepad reports its
## buttons and d-pad, and which SNES button play.nim maps each to. Use it to
## diagnose clone-controller mappings (e.g. a swapped B/X): press a physical
## button and read which paddy `Gamepad*` it fires and the SNES button it maps
## to. No window needed — reads gamepads directly.
##
## Usage: nim r src/tools/gamepad_test.nim   (Ctrl+C to quit)

import
  std/[os, strformat, sets],
  paddy

proc snesName(b: GamepadButton): string =
  ## The SNES button play.nim maps this paddy button to (positional mapping:
  ## paddy A=bottom->SNES B, B=right->SNES A, X=top->SNES X, Y=left->SNES Y).
  case b
  of GamepadA: "B"
  of GamepadB: "A"
  of GamepadX: "X"
  of GamepadY: "Y"
  of GamepadL1: "L"
  of GamepadR1: "R"
  of GamepadUp: "Up"
  of GamepadDown: "Down"
  of GamepadLeft: "Left"
  of GamepadRight: "Right"
  of GamepadStart: "Start"
  of GamepadSelect: "Select"
  else: "(unmapped)"

const Checked = [
  GamepadA, GamepadB, GamepadX, GamepadY, GamepadL1, GamepadR1,
  GamepadL2, GamepadR2, GamepadSelect, GamepadStart,
  GamepadUp, GamepadDown, GamepadLeft, GamepadRight]

proc dirOf(lx, ly: float32): string =
  ## Compact d-pad direction from left-stick axes (for analog-d-pad clones).
  if ly < -0.4: result.add "Up"
  if ly > 0.4: result.add "Down"
  if lx < -0.4: result.add "Left"
  if lx > 0.4: result.add "Right"

initGamepads()

block:
  let pads = pollGamepads()
  echo &"Detected {pads.len} gamepad(s):"
  for i, p in pads:
    echo &"  [{i}] id={p.id} name=\"{p.name}\""
echo ""
echo "Press each face button (B, A, X, Y), the shoulders (L, R), Start/Select,"
echo "and hold a diagonal on the d-pad. Each line shows: paddy button -> SNES."
echo "If a physical button maps to the wrong SNES button, that's the fix I need."
echo "Ctrl+C to quit."
echo ""

var
  prev: seq[HashSet[GamepadButton]]
  prevDir: seq[string]

while true:
  let pads = pollGamepads()
  while prev.len < pads.len:
    prev.add initHashSet[GamepadButton]()
    prevDir.add ""
  for i, gp in pads:
    var now = initHashSet[GamepadButton]()
    for b in Checked:
      if gp.button(b): now.incl b
    for b in now - prev[i]:
      echo &"[pad {i}] DOWN {b}  ->  SNES {snesName(b)}"
    for b in prev[i] - now:
      echo &"[pad {i}] up   {b}"
    prev[i] = now
    let lx = gp.axis(GamepadLStickX)
    let ly = gp.axis(GamepadLStickY)
    let d = dirOf(lx, ly)
    if d != prevDir[i]:
      if d.len > 0:
        echo &"[pad {i}] stick -> {d}  (x={lx:.2f} y={ly:.2f})"
      prevDir[i] = d
  sleep(16)
