## SNES USB controller test. Prints how each connected gamepad reports its
## buttons and d-pad, and which SNES button play.nim maps each to. Use it to
## diagnose clone-controller mappings (e.g. a swapped B/X): press a physical
## button and read which paddy `Gamepad*` it fires and the SNES button it maps
## to. No window needed — reads gamepads directly.
##
## Usage: nim r src/tools/gamepad_test.nim   (Ctrl+C to quit)

import
  std/[os, strformat, strutils, sets],
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

# The d-pad latch (same logic as play.nim): hold each direction `latchFrames`
# frames after it's last seen, to bridge a flickery clone d-pad. Tune with the
# LATCH env var, e.g. `LATCH=8 make gamepad-test`, then set the winning value in
# play.nim. SMOOTH shows the latched result you'd actually get in-game.
let latchFrames = (if getEnv("LATCH").len > 0: parseInt(getEnv("LATCH")) else: 10)
echo "d-pad latch = ", latchFrames, " frames  (set LATCH=N to tune; SMOOTH = in-game result)"
echo ""

const DirNames = ["Up", "Down", "Left", "Right"]
var
  prev: seq[HashSet[GamepadButton]]
  prevDir: seq[string]
  prevSmooth: seq[string]
  latch: seq[array[4, int]]

while true:
  let pads = pollGamepads()
  while prev.len < pads.len:
    prev.add initHashSet[GamepadButton]()
    prevDir.add ""
    prevSmooth.add ""
    latch.add [0, 0, 0, 0]
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
        echo &"[pad {i}] raw    -> {d}  (x={lx:.2f} y={ly:.2f})"
      prevDir[i] = d
    # Raw directions from axes OR d-pad buttons, then latch -> SMOOTH.
    let rawDir = [(ly < -0.4) or (GamepadUp in now),
                  (ly > 0.4) or (GamepadDown in now),
                  (lx < -0.4) or (GamepadLeft in now),
                  (lx > 0.4) or (GamepadRight in now)]
    var smooth = ""
    for k in 0 .. 3:
      if rawDir[k]: latch[i][k] = latchFrames
      elif latch[i][k] > 0: latch[i][k] -= 1
      if latch[i][k] > 0: smooth.add DirNames[k]
    if smooth != prevSmooth[i]:
      echo &"[pad {i}] SMOOTH -> {(if smooth.len > 0: smooth else: \"(none)\")}"
      prevSmooth[i] = smooth
  sleep(16)
