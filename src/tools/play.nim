## Interactive real-time player for the emulator. Human can watch and
## control Earthbound for debugging. Boots ROM, runs at ~60 fps with
## NMI injection, maps keyboard + all paddy gamepads (as player 1) to joy1,
## renders via PPU each frame.
## Usage: nim r src/tools/play.nim [--verbose|-v] <rom>

import
  std/[os, strformat],
  pixie,
  opengl,
  windy,
  paddy,
  ../decompbound/[cpu, ppu, snesbus]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc compileShader(kind: GLenum, source: string): GLuint =
  ## Compile one shader and return its id, or quit on error.
  let shader = glCreateShader(kind)
  let sourceArr = allocCStringArray([source])
  glShaderSource(shader, 1, sourceArr, nil)
  glCompileShader(shader)
  var status: GLint
  glGetShaderiv(shader, GL_COMPILE_STATUS, addr status)
  if status.GLboolean == GL_FALSE:
    var logLen: GLint
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, addr logLen)
    var log = newString(logLen)
    glGetShaderInfoLog(shader, logLen, nil, log.cstring)
    echo "Shader compile error: ", log
    quit(1)
  deallocCStringArray(sourceArr)
  result = shader

proc checkLink(program: GLuint) =
  ## Check program link status, quit on error.
  var status: GLint
  glGetProgramiv(program, GL_LINK_STATUS, addr status)
  if status.GLboolean == GL_FALSE:
    var logLen: GLint
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, addr logLen)
    var log = newString(logLen)
    glGetProgramInfoLog(program, logLen, nil, log.cstring)
    echo "Program link error: ", log
    quit(1)

proc main() =
  ## Open a windowed player, run the emulator at ~60 fps, accept input,
  ## render frames, and support debug controls. Keyboard + all connected
  ## paddy gamepads (treated as player 1) feed joy1 (ORed).
  ## Pass --verbose to print input state changes to stdout.
  var verbose = false
  var romPath = ""
  for i in 1..paramCount():
    let arg = paramStr(i)
    if arg == "--verbose" or arg == "-v":
      verbose = true
    elif romPath.len == 0:
      romPath = arg
    else:
      echo "Unknown argument: ", arg
      quit(1)

  if romPath.len == 0:
    echo "Usage: nim r src/tools/play.nim [--verbose|-v] <rom>"
    quit(1)

  const
    Scale = 3
    InstructionsPerFrame = 8000
    BtnB = 0x8000'u16
    BtnY = 0x4000'u16
    BtnSel = 0x2000'u16
    BtnStart = 0x1000'u16
    BtnUp = 0x0800'u16
    BtnDown = 0x0400'u16
    BtnLeft = 0x0200'u16
    BtnRight = 0x0100'u16
    BtnA = 0x0080'u16
    BtnX = 0x0040'u16
    Controls = """
Controls:
  Arrows      D-pad (Up/Down/Left/Right)
  Z           B
  X           A
  A           Y
  S           X
  Enter       Start
  RightShift  Select
  Space       Toggle pause
  N           Advance one frame (when paused)
  -           Decrease speed
  =           Increase speed
  F12         Write bin/frame.png
  Esc         Quit

  Gamepad (via paddy):
    All connected gamepads act as player 1 (this is Earthbound-specific).
    D-pad (real buttons OR left-stick axes for cheap fake-dpad pads) + face buttons, Select, Start feed joy1 (OR with keyboard).

  --verbose / -v   Print input changes (joy1 + only active gamepads) for debugging
"""
  echo Controls

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  var frameCount = 0
  var paused = false
  var frameAdvance = false
  var framesPerTick = 1
  var lastJoy1: uint16 = 0

  let windowSize = ivec2(ScreenWidth * Scale, ScreenHeight * Scale)
  let window = newWindow("decompbound player - frame 0", windowSize)
  window.makeContextCurrent()
  loadExtensions()

  initGamepads()

  if verbose:
    let initialPads = pollGamepads()
    echo &"verbose: {initialPads.len} gamepad(s) detected by paddy"
    for i, p in initialPads:
      echo &"  [{i}] id={p.id} name=\"{p.name}\""

  # Fullscreen covering quad in NDC with UVs that map pixie top-left to screen top.
  var posData = @[
    vec2(-1f, -1f), vec2(1f, -1f), vec2(1f, 1f),
    vec2(1f, 1f), vec2(-1f, 1f), vec2(-1f, -1f)
  ]
  var uvData = @[
    vec2(0f, 1f), vec2(1f, 1f), vec2(1f, 0f),
    vec2(1f, 0f), vec2(0f, 0f), vec2(0f, 1f)
  ]

  var vao: GLuint
  glGenVertexArrays(1, addr vao)
  glBindVertexArray(vao)

  var posBuffer: GLuint
  glGenBuffers(1, addr posBuffer)
  glBindBuffer(GL_ARRAY_BUFFER, posBuffer)
  glBufferData(GL_ARRAY_BUFFER, posData.len * 4 * 2, posData[0].addr, GL_STATIC_DRAW)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(0)

  var uvBuffer: GLuint
  glGenBuffers(1, addr uvBuffer)
  glBindBuffer(GL_ARRAY_BUFFER, uvBuffer)
  glBufferData(GL_ARRAY_BUFFER, uvData.len * 4 * 2, uvData[0].addr, GL_STATIC_DRAW)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(1)

  const vertSrc = """
#version 410
in vec2 vertexPos;
in vec2 vertexUv;
out vec2 uv;
void main() {
  gl_Position = vec4(vertexPos, 0.0, 1.0);
  uv = vertexUv;
}
"""
  const fragSrc = """
#version 410
in vec2 uv;
uniform sampler2D tex;
out vec4 fragColor;
void main() {
  fragColor = texture(tex, uv);
}
"""
  let vertShader = compileShader(GL_VERTEX_SHADER, vertSrc)
  let fragShader = compileShader(GL_FRAGMENT_SHADER, fragSrc)
  let program = glCreateProgram()
  glAttachShader(program, vertShader)
  glAttachShader(program, fragShader)
  glLinkProgram(program)
  checkLink(program)

  let texLoc = glGetUniformLocation(program, "tex")

  var textureId: GLuint
  glGenTextures(1, addr textureId)
  glBindTexture(GL_TEXTURE_2D, textureId)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

  # Initial black texture of native size.
  var initImage = newImage(ScreenWidth, ScreenHeight)
  initImage.fill(rgbx(0, 0, 0, 255))
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
    initImage.width.GLsizei, initImage.height.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](initImage.data[0].addr)
  )

  glActiveTexture(GL_TEXTURE0)
  glUseProgram(program)
  glUniform1i(texLoc, 0)

  while not window.closeRequested:
    pollEvents()

    # Map current key state to joy1 every frame.
    # Paddy gamepad (player 1) as alternative/additive input for SNES controller.
    var joy1: uint16 = 0
    if window.buttonDown[KeyUp]: joy1 = joy1 or BtnUp
    if window.buttonDown[KeyDown]: joy1 = joy1 or BtnDown
    if window.buttonDown[KeyLeft]: joy1 = joy1 or BtnLeft
    if window.buttonDown[KeyRight]: joy1 = joy1 or BtnRight
    if window.buttonDown[KeyZ]: joy1 = joy1 or BtnB
    if window.buttonDown[KeyX]: joy1 = joy1 or BtnA
    if window.buttonDown[KeyA]: joy1 = joy1 or BtnY
    if window.buttonDown[KeyS]: joy1 = joy1 or BtnX
    if window.buttonDown[KeyEnter]: joy1 = joy1 or BtnStart
    if window.buttonDown[KeyRightShift]: joy1 = joy1 or BtnSel

    # Paddy: aggregate ALL gamepads as player 1.
    # This is an Earthbound-specific emulator (only player 1 matters), so every
    # connected gamepad (including multiple SNES clones + random USB controllers)
    # contributes to the same joy1 (ORed with keyboard).
    let pads = pollGamepads()
    for gp in pads:
      if gp.button(GamepadUp): joy1 = joy1 or BtnUp
      if gp.button(GamepadDown): joy1 = joy1 or BtnDown
      if gp.button(GamepadLeft): joy1 = joy1 or BtnLeft
      if gp.button(GamepadRight): joy1 = joy1 or BtnRight
      if gp.button(GamepadB): joy1 = joy1 or BtnB
      if gp.button(GamepadA): joy1 = joy1 or BtnA
      if gp.button(GamepadY): joy1 = joy1 or BtnY
      if gp.button(GamepadX): joy1 = joy1 or BtnX
      if gp.button(GamepadStart): joy1 = joy1 or BtnStart
      if gp.button(GamepadSelect): joy1 = joy1 or BtnSel

      # Support cheap SNES imitation pads that report d-pad as fake left-stick axes
      # (values like 1.0 / 0.0 / -1.0) instead of (or in addition to) real d-pad buttons.
      let lx = gp.axis(GamepadLStickX)
      let ly = gp.axis(GamepadLStickY)
      const AxisThreshold = 0.5'f
      if lx > AxisThreshold: joy1 = joy1 or BtnRight
      if lx < -AxisThreshold: joy1 = joy1 or BtnLeft
      if ly > AxisThreshold: joy1 = joy1 or BtnDown
      if ly < -AxisThreshold: joy1 = joy1 or BtnUp
    snes.joy1 = joy1

    if verbose:
      if joy1 != lastJoy1:
        echo &"joy1=0x{joy1:04x} (changed)"
        lastJoy1 = joy1

      # Only print gamepads that are currently sending input.
      # This keeps output quiet when you have multiple controllers (some idle).
      for i, gp in pads:
        let lx = gp.axis(GamepadLStickX)
        let ly = gp.axis(GamepadLStickY)
        let hasInput = gp.buttons != 0 or
                       abs(lx) > 0.01 or abs(ly) > 0.01

        if hasInput:
          echo &"paddy[{i}]: '{gp.name}' raw=0x{gp.buttons:016x}"
          if abs(lx) > 0.01 or abs(ly) > 0.01:
            echo &"  LStickX={lx:.2f} LStickY={ly:.2f}"
          let relevant = [GamepadUp, GamepadDown, GamepadLeft, GamepadRight,
                          GamepadA, GamepadB, GamepadX, GamepadY,
                          GamepadSelect, GamepadStart]
          for btn in relevant:
            if gp.button(btn):
              echo "  ", btn

    # One-shot controls.
    if window.buttonPressed[KeySpace]:
      paused = not paused
    if window.buttonPressed[KeyN] and paused:
      frameAdvance = true
    if window.buttonPressed[KeyMinus] and framesPerTick > 1:
      dec framesPerTick
    if window.buttonPressed[KeyEqual]:
      inc framesPerTick
    if window.buttonPressed[KeyF12]:
      let snap = snes.renderFrame()
      snap.writeFile("bin/frame.png")
      echo "wrote bin/frame.png"
    if window.buttonPressed[KeyEscape]:
      window.closeRequested = true

    # Emulation advance.
    if not paused or frameAdvance:
      let ticks = if frameAdvance: 1 else: framesPerTick
      for t in 0 ..< ticks:
        if (snes.nmitimen and 0x80) != 0:
          cpu.nmiPending = true
        for i in 0 ..< InstructionsPerFrame:
          cpu.step(snes.bus)
          if cpu.stopped:
            break
        frameCount += 1
        if frameAdvance:
          frameAdvance = false
          break

    # Render and display.
    let image = snes.renderFrame()
    glBindTexture(GL_TEXTURE_2D, textureId)
    glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
      image.width.GLsizei, image.height.GLsizei, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](image.data[0].addr)
    )

    glViewport(0, 0, window.size.x, window.size.y)
    glClearColor(0.0, 0.0, 0.0, 1.0)
    glClear(GL_COLOR_BUFFER_BIT)

    glBindVertexArray(vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)

    window.swapBuffers()

    let pausedStr = if paused: " (paused)" else: ""
    let newTitle = &"decompbound player - frame {frameCount}{pausedStr} x{framesPerTick}"
    if window.title != newTitle:
      window.title = newTitle

when isMainModule:
  main()
