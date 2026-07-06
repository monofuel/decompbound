## Interactive real-time player for the emulator. Human can watch and
## control Earthbound for debugging. Boots ROM, runs at ~60 fps with
## NMI injection, maps keyboard + all paddy gamepads (as player 1) to joy1,
## renders via PPU each frame.
## Usage: nim r src/tools/play.nim [--verbose|-v] <rom>

import
  std/[os, strformat, strutils, monotimes, times, algorithm],
  pixie,
  opengl,
  windy,
  paddy,
  slappy,
  ../decompbound/[apu, cpu, ppu, snesbus]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc sramPathFor(romPath: string): string =
  ## The battery-save file sits next to the ROM with a .srm extension, e.g.
  ## "bin/Earthbound (U) [!].srm". Gitignored.
  romPath.changeFileExt("srm")

proc loadSram(snes: SnesBus, path: string) =
  ## Load a battery save into SRAM if the .srm file exists (else start fresh).
  if fileExists(path):
    let data = readFile(path)
    for i in 0 ..< min(data.len, snes.sram.len):
      snes.sram[i] = data[i].uint8
    echo "loaded save: ", path, " (", data.len, " bytes)"

proc sramBytes(snes: SnesBus): string =
  ## Serialize the 8KB SRAM to a byte string.
  result = newString(snes.sram.len)
  for i in 0 ..< snes.sram.len:
    result[i] = snes.sram[i].char

proc sramValid(snes: SnesBus): bool =
  ## True if the SRAM carries EB's "HAL Laboratory, inc." save signature — a
  ## real save, not an empty/garbage state — so we never back up junk.
  const Sig = "HAL Laboratory, inc."
  for i in 0 ..< Sig.len:
    if snes.sram[i].char != Sig[i]: return false
  true

proc saveSram(snes: SnesBus, path: string) =
  ## Write the 8KB battery SRAM to the .srm, plus a rotating, timestamped backup
  ## (of valid saves only) in bin/sram_backups/, keeping the newest 40 — so a
  ## corrupted write or a glitchy moment can't wipe out your progress.
  let bytes = snes.sramBytes()
  writeFile(path, bytes)
  snes.sramDirty = false
  echo "saved: ", path
  if snes.sramValid():
    const MaxBackups = 40
    let dir = "bin/sram_backups"
    createDir(dir)
    let base = path.splitFile.name
    let backup = dir / (base & "_" & now().format("yyyyMMdd-HHmmss") & ".srm")
    if not fileExists(backup):
      writeFile(backup, bytes)
      echo "  backup: ", backup
    # Prune to the newest MaxBackups (timestamped names sort chronologically).
    var files: seq[string]
    for f in walkFiles(dir / (base & "_*.srm")):
      files.add f
    files.sort()
    for i in 0 ..< max(0, files.len - MaxBackups):
      removeFile(files[i])

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
    BtnL = 0x0020'u16
    BtnR = 0x0010'u16
    Controls = """
Controls:
  Arrows      D-pad (Up/Down/Left/Right)
  Z           B
  X           A
  A           Y
  S           X
  Q           L
  E           R
  Enter       Start
  RightShift  Select
  Space       Toggle pause
  N           Advance one frame (when paused)
  -           Decrease speed
  =           Increase speed
  F10         Dump per-scanline TM/TS band profile only (bin/autoshots/scanline_trace.txt)
  F11         Toggle auto-screenshots (bin/autoshots/ every 5s; OFF by default)
  F12         Capture a FULL diagnostic bundle: frame + PPU regs + scanline trace + CGRAM
              (bin/autoshots/). The emulator ALSO auto-captures a bundle whenever an
              HDMA screen-split starts (a battle/iris) — no keypress needed.
  (close the window or Ctrl+C to quit — no Esc-to-quit, too easy to fat-finger)

  Gamepad (via paddy):
    All connected gamepads act as player 1 (this is Earthbound-specific).
    D-pad (real buttons OR left-stick axes for cheap fake-dpad pads) + face buttons, Select, Start feed joy1 (OR with keyboard).

  --verbose / -v   Print input changes (joy1 + only active gamepads) for debugging
"""
  echo Controls

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  let sramPath = sramPathFor(romPath)
  snes.loadSram(sramPath)   # battery save: load if a .srm exists
  var cpu = snes.resetCpu()

  var frameCount = 0
  var paused = false
  var frameAdvance = false
  var framesPerTick = 1
  # Live FPS measurement for the title bar (diagnoses perceived slowness).
  var fpsAccum = 0
  var fpsClock = getMonoTime()
  var fpsShown = 0.0
  # Real-time 60 Hz pacing: run emulated frames off a wall-clock accumulator so
  # the emulator holds ~60 fps (times the speed multiplier) regardless of vsync /
  # monitor refresh. This stops the 32kHz audio stream from under/overrunning
  # (the hitching) and keeps game speed steady run-to-run.
  const TargetFrameNs = 1_000_000_000 div 60
  var frameAcc: int64 = 0
  var lastFrameTime = getMonoTime()
  # Auto-capture: every 5s dump the frame + PPU state to bin/autoshots/
  # (gitignored) so scenes can be reviewed/diagnosed after the fact. OFF by
  # default (the periodic PNG write costs one frame ~every 5s = a small
  # stutter); press F11 to enable it when you want to capture a bug.
  var autoShot = false
  var lastShotTime = getMonoTime()
  var shotCount = 0
  createDir("bin/autoshots")
  # F10: one-shot per-scanline TM/TS profile -> bin/autoshots/scanline_trace.txt,
  # for diagnosing HDMA screen-splits (e.g. the battle's bottom status band).
  var traceScanlines = false
  var traceArmed = 0    # frames since F10 armed; wait for an HDMA-active frame.
  var traceTM: array[262, uint8]
  var traceTS: array[262, uint8]
  var traceCG: array[262, uint8]   # CGADSUB (color math) per scanline
  var traceCW: array[262, uint8]   # CGWSEL per scanline
  # F12 / auto-anomaly full bundle: frame + PPU regs + CGRAM alongside the trace.
  var captureBundle = false
  # Prev-frame HDMAEN, to auto-capture on a 0 -> non-zero HDMA edge (a screen
  # split starting: battle swirl/bands, scene iris) with no human keypress.
  var prevHdmaen: uint8 = 0
  var lastJoy1: uint16 = 0

  # Audio is driven by the live APU in the bus (snes.tickApu) — no per-frame
  # snapshot/replay state is needed here anymore.

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

  # Persistent frame buffer, built one scanline at a time each frame.
  var frameImage = newImage(ScreenWidth, ScreenHeight)
  frameImage.fill(rgbx(0, 0, 0, 255))

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

  # Audio streaming setup (real-time APU playback via slappy).
  # slappyInit once at startup; ss lives for the session.
  slappyInit()
  let ss = newStreamingSource(frequency = 32000, channels = 2, bits = 16)

  while not window.closeRequested:
    pollEvents()
    ss.pump()  # reclaim finished buffers every iteration (paused or not)

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
    if window.buttonDown[KeyQ]: joy1 = joy1 or BtnL
    if window.buttonDown[KeyE]: joy1 = joy1 or BtnR
    if window.buttonDown[KeyEnter]: joy1 = joy1 or BtnStart
    if window.buttonDown[KeyRightShift]: joy1 = joy1 or BtnSel

    # Paddy: aggregate ALL gamepads as player 1.
    # This is an Earthbound-specific emulator (only player 1 matters), so every
    # connected gamepad (including multiple SNES clones + random USB controllers)
    # contributes to the same joy1 (ORed with keyboard).
    # Polling can throw if a controller is unplugged/hotplugged mid-read — catch
    # it so yanking a gamepad never crashes the game (just drops its input).
    var pads: seq[Gamepad] = @[]
    # Poll + read gamepads inside ONE guard. A controller yanked mid-read can
    # throw a CatchableError OR a Defect (nil/index inside paddy's evdev read),
    # and reads on a just-vanished pad can throw too — either must only DROP that
    # frame's pad input, never crash the game. (A C-level segfault in paddy's
    # evdev layer is uncatchable here and would need an upstream paddy fix.)
    try:
      pads = pollGamepads()
      for gp in pads:
        if gp.button(GamepadUp): joy1 = joy1 or BtnUp
        if gp.button(GamepadDown): joy1 = joy1 or BtnDown
        if gp.button(GamepadLeft): joy1 = joy1 or BtnLeft
        if gp.button(GamepadRight): joy1 = joy1 or BtnRight
        # Map by PHYSICAL position, not label (paddy is positional/SDL-style):
        # paddy A=bottom, B=right, X=top, Y=left; SNES has B=bottom, A=right,
        # X=top, Y=left. So paddy A/B map to SNES B/A (the classic Nintendo A/B
        # swap); X/Y already line up by position.
        if gp.button(GamepadA): joy1 = joy1 or BtnB
        if gp.button(GamepadB): joy1 = joy1 or BtnA
        if gp.button(GamepadY): joy1 = joy1 or BtnY
        if gp.button(GamepadX): joy1 = joy1 or BtnX
        if gp.button(GamepadL1): joy1 = joy1 or BtnL
        if gp.button(GamepadR1): joy1 = joy1 or BtnR
        if gp.button(GamepadStart): joy1 = joy1 or BtnStart
        if gp.button(GamepadSelect): joy1 = joy1 or BtnSel

        # Support cheap SNES imitation pads that report d-pad as fake left-stick axes
        # (values like 1.0 / 0.0 / -1.0) instead of (or in addition to) real d-pad buttons.
        # A low threshold so diagonals engage easily — with 0.5 a not-quite-45-degree
        # push only crossed one axis, so diagonals "snapped" to orthogonal.
        let lx = gp.axis(GamepadLStickX)
        let ly = gp.axis(GamepadLStickY)
        const AxisThreshold = 0.35'f
        if lx > AxisThreshold: joy1 = joy1 or BtnRight
        if lx < -AxisThreshold: joy1 = joy1 or BtnLeft
        if ly > AxisThreshold: joy1 = joy1 or BtnDown
        if ly < -AxisThreshold: joy1 = joy1 or BtnUp
    except CatchableError, Defect:
      pads = @[]
    # No input latch: faithful d-pad, no held-frame band-aid. A good controller
    # handles its own diagonals; we don't hack around bad hardware.
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
    if window.buttonPressed[KeyF10]:
      traceScanlines = true
      traceArmed = 0
      echo "scanline trace armed (captures the next HDMA-split frame, e.g. a battle)"
    if window.buttonPressed[KeyF11]:
      autoShot = not autoShot
      echo "auto-screenshots: ", (if autoShot: "ON (bin/autoshots/ every 5s)" else: "OFF")
    if window.buttonPressed[KeyF12]:
      # One-press full diagnostic bundle: arm the scanline trace and capture the
      # frame + PPU regs + CGRAM together (written when the trace fires). Plus an
      # immediate terminal readout for quick eyeballing.
      captureBundle = true
      traceScanlines = true
      traceArmed = 0
      echo "F12: capturing diagnostic bundle -> bin/autoshots/ (frame + regs + scanline trace + CGRAM)"
      echo &"  BGMODE={snes.ppuRegs[0x05] and 7} bg3prio={(snes.ppuRegs[0x05] and 8) != 0} " &
        &"TM(main)={snes.ppuRegs[0x2C]:02X} TS(sub)={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
      echo &"  CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} HDMAEN={snes.hdmaen:02X}"
      echo &"  windows: W12SEL={snes.ppuRegs[0x23]:02X} W34SEL={snes.ppuRegs[0x24]:02X} " &
        &"WOBJSEL={snes.ppuRegs[0x25]:02X} WH0-3={snes.ppuRegs[0x26]:02X}/{snes.ppuRegs[0x27]:02X}/" &
        &"{snes.ppuRegs[0x28]:02X}/{snes.ppuRegs[0x29]:02X} TMW={snes.ppuRegs[0x2E]:02X} TSW={snes.ppuRegs[0x2F]:02X}"
    # (No Esc-to-quit: it was too easy to hit mid-game and lose your run. Close
    # the window or Ctrl+C the terminal to exit.)

    # Emulation advance. Render each visible scanline right after its HDMA
    # updates so per-line color-math effects (the Giygas red static) appear.
    if not paused or frameAdvance:
      let ticks =
        if frameAdvance: 1
        else:
          let nowT = getMonoTime()
          frameAcc += (nowT - lastFrameTime).inNanoseconds
          lastFrameTime = nowT
          # One emulated frame per TargetFrameNs of real time (divided by the
          # speed multiplier for fast-forward). Cap catch-up so a stall can't
          # trigger a runaway burst.
          let dueNs = max(1'i64, TargetFrameNs div framesPerTick)
          var n = 0
          while frameAcc >= dueNs and n < 4:
            frameAcc -= dueNs
            inc n
          n
      for t in 0 ..< ticks:
        # Instructions per scanline. The SNES gives the CPU a fixed CYCLE budget
        # (~227 CPU cycles/scanline on FastROM); we approximate with a fixed
        # instruction count (goal.md: no cycle accuracy). 30 starved EB's main
        # loop, so its animation lagged behind the (independently-ticked) audio;
        # ~40 matches hardware throughput so graphics keep pace. Tune if scenes
        # run fast/slow.
        const InstrPerLine = 40
        let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
        if not forceBlank:
          let backdrop = ppu.bgr555ToColor(snes.cgram[0])
          frameImage.fill(backdrop)
        # Audio: pull one frame of samples from the LIVE APU, ticked per scanline
        # so the boot handshake + music driver stay in step with the main CPU.
        # The note sequence and the BRR instrument samples both live in the real
        # SPC700 RAM, so they can never drift out of coherence (the old
        # snapshot-replay played the right melody with the wrong instruments).
        # Only queue at normal speed; during fast-forward we still tick the APU
        # (so the driver keeps running) but don't queue pitch-garbled audio.
        const SamplesPerFrame = 32000 div 60
        let genAudio = framesPerTick == 1 and not frameAdvance
        var pcm = newSeq[uint8](SamplesPerFrame * 4)
        var smp = 0
        var l = 0
        while l < 262:
          # NMI fires at vblank start (line 224), AFTER the visible scanlines are
          # drawn — so the game's vblank handler updates scroll/CGRAM/HDMA for the
          # NEXT frame, not mid-render (which flickered the top lines + the iris).
          if l == 224 and (snes.nmitimen and 0x80) != 0:
            cpu.nmiPending = true
          for i in 0 ..< InstrPerLine:
            cpu.step(snes.bus)
            if cpu.stopped:
              break
          if l < 224:
            snes.runHdma()
            if traceScanlines:
              traceTM[l] = snes.ppuRegs[0x2C]
              traceTS[l] = snes.ppuRegs[0x2D]
              traceCG[l] = snes.ppuRegs[0x31]
              traceCW[l] = snes.ppuRegs[0x30]
            if (snes.ppuRegs[0x00] and 0x80) == 0:
              ppu.renderScanline(snes, frameImage, l)
          for k in 0 ..< 2:
            let (lft, rgt) = snes.tickApu()
            if genAudio and smp < SamplesPerFrame:
              let off = smp * 4
              pcm[off + 0] = (lft and 0xFF).uint8
              pcm[off + 1] = ((lft shr 8) and 0xFF).uint8
              pcm[off + 2] = (rgt and 0xFF).uint8
              pcm[off + 3] = ((rgt shr 8) and 0xFF).uint8
              smp += 1
          l += 1
          if l >= 262:
            snes.initHdma()
            break
        # Top up to a full frame (262*2 = 524 < 533) so slappy never underruns.
        while genAudio and smp < SamplesPerFrame:
          let (lft, rgt) = snes.tickApu()
          let off = smp * 4
          pcm[off + 0] = (lft and 0xFF).uint8
          pcm[off + 1] = ((lft shr 8) and 0xFF).uint8
          pcm[off + 2] = (rgt and 0xFF).uint8
          pcm[off + 3] = ((rgt shr 8) and 0xFF).uint8
          smp += 1
        ppu.renderSprites(snes, frameImage)
        # High-priority BG (foreground tiles, dialogue/HUD, battle UI) interleaves
        # in front of the sprites the priority ladder places behind it.
        ppu.overlayForegroundBg(snes, frameImage)
        # Once armed, wait for a frame where HDMA is actually active (the battle
        # screen split) so the capture is useful; fall back after ~180 frames so
        # non-HDMA scenes (e.g. the top-line flicker) still get a trace.
        if traceScanlines:
          inc traceArmed
        if traceScanlines and (snes.hdmaen != 0 or traceArmed >= 180):
          let tf = open("bin/autoshots/scanline_trace.txt", fmWrite)
          tf.writeLine(&"per-scanline profile (frame {frameCount}): " &
            &"BGMODE={snes.ppuRegs[0x05] and 7} bg3prio={(snes.ppuRegs[0x05] and 8) != 0} " &
            &"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} HDMAEN={snes.hdmaen:02X}")
          var bstart = 0
          for l2 in 1 .. 224:
            if l2 == 224 or traceTM[l2] != traceTM[bstart] or traceTS[l2] != traceTS[bstart] or
               traceCG[l2] != traceCG[bstart] or traceCW[l2] != traceCW[bstart]:
              tf.writeLine(&"  lines {bstart:>3}..{l2-1:>3}  TM={traceTM[bstart]:02X} TS={traceTS[bstart]:02X} " &
                &"CGADSUB={traceCG[bstart]:02X} CGWSEL={traceCW[bstart]:02X}")
              bstart = l2
          tf.close()
          traceScanlines = false
          # Full bundle (from F12 or an auto-anomaly): frame + PPU regs + CGRAM
          # written alongside the trace, so one capture has everything a render
          # bug needs (e.g. the swirl's palette for the red-vs-green colour).
          if captureBundle:
            frameImage.writeFile("bin/autoshots/bundle_frame.png")
            let rf = open("bin/autoshots/bundle_regs.txt", fmWrite)
            rf.writeLine(&"frame {frameCount}  BGMODE={snes.ppuRegs[0x05] and 7} " &
              &"bg3prio={(snes.ppuRegs[0x05] and 8) != 0} TM={snes.ppuRegs[0x2C]:02X} " &
              &"TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X} " &
              &"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} HDMAEN={snes.hdmaen:02X}")
            rf.writeLine("CGRAM (BGR555, 16 palettes x 16 colours):")
            for pal in 0 ..< 16:
              var row = &"  pal{pal:02}:"
              for c in 0 ..< 16:
                row.add(&" {snes.cgram[pal * 16 + c]:04X}")
              rf.writeLine(row)
            # Active HDMA channels: which $21xx register each targets per scanline
            # (e.g. a channel writing $2131=CGADSUB or $212C/D=TM/TS is how a band
            # gets color math / layers). Reveals the battle HP/PP-band mechanism.
            rf.writeLine("HDMA channels (active per HDMAEN — target = $21xx reg):")
            for ch in 0 ..< 8:
              if (snes.hdmaen and (1'u8 shl ch)) != 0:
                let b = ch * 0x10
                rf.writeLine(&"  ch{ch}: DMAP={snes.dmaRegs[b]:02X} " &
                  &"target=$21{snes.dmaRegs[b + 1]:02X} " &
                  &"A1={snes.dmaRegs[b + 4]:02X}:{snes.dmaRegs[b + 3]:02X}{snes.dmaRegs[b + 2]:02X} " &
                  &"indirect={(snes.dmaRegs[b] and 0x40) != 0}")
            # OAM sprites in the lower screen (y >= 160): shows whether the HP/PP
            # band is drawn by OBJ (sprites) or is a color-math'd subscreen band.
            rf.writeLine("OAM sprites with y >= 160 (bottom region):")
            for s in 0 ..< 128:
              let sy = snes.oam[s * 4 + 1]
              if sy >= 160'u8 and sy < 240'u8:
                rf.writeLine(&"  spr{s:>3}: x={snes.oam[s * 4]:02X} y={sy:02X} " &
                  &"tile={snes.oam[s * 4 + 2]:02X} attr={snes.oam[s * 4 + 3]:02X}")
            rf.close()
            captureBundle = false
            echo "wrote diagnostic bundle -> bin/autoshots/ " &
              "(scanline_trace.txt + bundle_frame.png + bundle_regs.txt)"
          else:
            echo "wrote bin/autoshots/scanline_trace.txt"
        frameCount += 1
        # Automated anomaly capture: when HDMA turns on (0 -> non-zero) a screen
        # split just began (battle swirl/bands, scene iris) — auto-arm a full
        # bundle so the human never has to catch the exact frame. Once per edge.
        if prevHdmaen == 0'u8 and snes.hdmaen != 0'u8 and
           not (traceScanlines or captureBundle):
          captureBundle = true
          traceScanlines = true
          traceArmed = 0
          echo &"auto-capture: HDMA split started (HDMAEN={snes.hdmaen:02X}) — grabbing a bundle"
        prevHdmaen = snes.hdmaen
        if genAudio:
          ss.queueData(pcm)

        if frameAdvance:
          frameAdvance = false
          break
    else:
      # Paused: keep the pacing clock current so unpausing doesn't burst-catch-up.
      lastFrameTime = getMonoTime()
      frameAcc = 0

    # Display the frame built during emulation.
    let image = frameImage
    glBindTexture(GL_TEXTURE_2D, textureId)
    glTexImage2D(
      GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
      image.width.GLsizei, image.height.GLsizei, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](image.data[0].addr)
    )

    # Aspect-preserving viewport with black borders: fit the largest rect of the
    # framebuffer's aspect (ScreenWidth:ScreenHeight) inside the window, centered,
    # so resizing letter/pillar-boxes instead of stretching. glClear paints the
    # whole window black first, so the uncovered margins become the bars.
    const TargetAspect = ScreenWidth.float / ScreenHeight.float
    let winW = window.size.x
    let winH = window.size.y
    var vpW, vpH: int32
    if winW.float / winH.float > TargetAspect:
      vpH = winH                                  # window wider than frame: pillarbox
      vpW = (winH.float * TargetAspect).int32
    else:
      vpW = winW                                  # window taller than frame: letterbox
      vpH = (winW.float / TargetAspect).int32
    let vpX = (winW - vpW) div 2
    let vpY = (winH - vpH) div 2

    glClearColor(0.0, 0.0, 0.0, 1.0)
    glClear(GL_COLOR_BUFFER_BIT)
    glViewport(vpX, vpY, vpW, vpH)

    glBindVertexArray(vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)

    window.swapBuffers()

    inc fpsAccum
    let fpsElapsed = (getMonoTime() - fpsClock).inMilliseconds
    if fpsElapsed >= 500:
      fpsShown = fpsAccum.float * 1000.0 / fpsElapsed.float
      fpsAccum = 0
      fpsClock = getMonoTime()
    let pausedStr = if paused: " (paused)" else: ""
    let newTitle = &"decompbound player - {fpsShown:.0f} fps - frame {frameCount}{pausedStr} x{framesPerTick}"
    if window.title != newTitle:
      window.title = newTitle

    # Auto-capture: every ~5s dump the frame + a PPU-register line to the
    # gitignored bin/autoshots/ so scenes can be reviewed/diagnosed later.
    if autoShot and (getMonoTime() - lastShotTime).inSeconds >= 5:
      frameImage.writeFile(&"bin/autoshots/shot_{shotCount:04}.png")
      let regLine = &"shot_{shotCount:04}  frame={frameCount} fps={fpsShown:.0f}  " &
        &"BGMODE={snes.ppuRegs[0x05] and 7} bg3prio={(snes.ppuRegs[0x05] and 8) != 0} " &
        &"TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X} " &
        &"CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} " &
        &"fixedRGB={snes.fixedColorR},{snes.fixedColorG},{snes.fixedColorB} HDMAEN={snes.hdmaen:02X} " &
        &"W12={snes.ppuRegs[0x23]:02X} TMW={snes.ppuRegs[0x2E]:02X} TSW={snes.ppuRegs[0x2F]:02X}"
      let lf = open("bin/autoshots/registers.log", fmAppend)
      lf.writeLine(regLine)
      lf.close()
      inc shotCount
      lastShotTime = getMonoTime()

    # Autosave the battery SRAM shortly after the game writes it (throttled so a
    # multi-byte in-game save coalesces into one .srm flush).
    if snes.sramDirty and frameCount mod 60 == 0:
      snes.saveSram(sramPath)

  # Flush any pending battery save, then shut audio down cleanly, on exit.
  if snes.sramDirty:
    snes.saveSram(sramPath)
  ss.close()
  slappyClose()

when isMainModule:
  main()
