## Interactive real-time player for the emulator. Human can watch and
## control Earthbound for debugging. Boots ROM, runs at ~60 fps with
## NMI injection, maps keyboard + all paddy gamepads (as player 1) to joy1,
## renders via PPU each frame.
## Usage: nim r src/tools/play.nim [--verbose|-v] <rom>

import
  std/[os, strformat, strutils, monotimes, times, algorithm, osproc, options],
  pixie,
  opengl,
  windy,
  paddy,
  slappy,
  ../decompbound/[apu, build_info, cpu, ppu, policy, replay, save_state, snesbus, png_state]

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
    const MaxBackups = 2000  # 8KB each -> ~16MB max; keep deep save history, basically never prune.
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

proc saveScreenshot(frameImage: Image, dir: string, state: seq[byte], romHash: uint32): string =
  ## Save the raw game frame (256x224) as a timestamped PNG under the given dir,
  ## embedding the current state via ebSt chunk (for drag-drop restore).
  ## Creates a name of the form earthbound_yyyyMMdd-HHmmss.png. Echoes and
  ## returns the full path (so callers can mirror the file elsewhere).
  let ts = now().format("yyyyMMdd-HHmmss")
  let path = dir / &"earthbound_{ts}.png"
  let pngStr = frameImage.encodeImage(PngFormat)
  var pngBytes = newSeq[uint8](pngStr.len)
  if pngBytes.len > 0:
    copyMem(addr pngBytes[0], unsafeAddr pngStr[0], pngBytes.len)
  let embedded = embedState(pngBytes, state, romHash)
  writeFile(path, cast[string](embedded))
  echo "screenshot: ", path
  path

proc main() =
  ## Open a windowed player, run the emulator at ~60 fps, accept input,
  ## render frames, and support debug controls. Keyboard + all connected
  ## paddy gamepads (treated as player 1) feed joy1 (ORed).
  ## Pass --verbose to print input state changes to stdout.
  var verbose = false
  var romPath = ""
  var startStatePath = ""
  for i in 1..paramCount():
    let arg = paramStr(i)
    if arg == "--verbose" or arg == "-v":
      verbose = true
    elif arg == "--load-state-path" and i < paramCount():
      discard  # value consumed next iteration via startStatePath check below
    elif arg.startsWith("--load-state-path="):
      startStatePath = arg[18..^1]
    elif startStatePath.len == 0 and i > 1 and paramStr(i - 1) == "--load-state-path":
      startStatePath = arg
    elif romPath.len == 0:
      romPath = arg
    else:
      echo "Unknown argument: ", arg
      quit(1)

  if romPath.len == 0:
    echo "Usage: nim r src/tools/play.nim [--verbose|-v] [--load-state-path PATH(.state|.png)] <rom>"
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
    MouseIdleHideFrames = 180
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
  F9          Capture a FULL diagnostic bundle: frame + PPU regs + scanline trace + CGRAM
              (bin/autoshots/, preserved as f9_NNN_*). The emulator ALSO auto-captures a
              bundle whenever an HDMA screen-split starts (a battle/iris) — no keypress needed.
  F10         Dump per-scanline TM/TS band profile only (bin/autoshots/scanline_trace.txt)
  F11         Toggle auto-screenshots (bin/autoshots/ every 5s; ON by default — press to turn OFF if the ~5s stutter bugs you)
  F12         SCREENSTATE (screenshot + embedded save-state, drag-drop restorable)
              -> bin/sessions/<session>/f12/ (canonical) + ~/Pictures/Screenshots
              mirror; archived flat into ../decompbound_secret/screenstates/ on exit
  F7          Toggle INPUT RECORDING (TAS). ALWAYS ON by default: every boot and
              every state load starts a fresh <ts>.tas + <ts>_start.state segment in
              bin/sessions/<session>/ (sparse joy1 deltas — replayable + great bug
              reports). F7 turns it off/on. On clean exit the session's replay pairs
              + F12s auto-archive to ../decompbound_secret/sessions/ (if present).
  1-4         Load state from slot 1-4 (bin/states/slotN.state)
  Ctrl+1-4    Save state to slot 1-4
  (close the window or Ctrl+C to quit — no Esc-to-quit, too easy to fat-finger)

  Gamepad (via paddy):
    All connected gamepads act as player 1 (this is Earthbound-specific).
    D-pad (real buttons OR left-stick axes for cheap fake-dpad pads) + face buttons, Select, Start feed joy1 (OR with keyboard).

  --verbose / -v   Print input changes (joy1 + only active gamepads) for debugging
  Mouse cursor hides after 3s (180 frames) idle; reappears on movement.
  Events (input changes, saves/loads, F9-F12, pause/speed) are logged to bin/play_log.txt
"""
  echo Controls

  let rom = readRomFile(romPath)
  var snes = newSnesBus(rom)
  let sramPath = sramPathFor(romPath)
  snes.loadSram(sramPath)   # battery save: load if a .srm exists
  var cpu = snes.resetCpu()

  var frameCount = 0
  var paused = false
  var frameAdvance = false
  var framesPerTick = 1
  # In-game text -> console for easy copy-paste: while a text/menu window is
  # open (slot headers $8650/$8654 != 0xFF), decode the on-screen text from
  # VRAM (policy.getScreenText — same decoder the LLM reads) and echo it when
  # it changes. Reset on window close so re-opened identical text reprints.
  var lastScreenText = ""
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
  # (gitignored) so scenes can be reviewed/diagnosed after the fact. ON by
  # default. Tradeoff: the synchronous per-5s PNG write blocks one frame = a
  # ~5s-periodic stutter. Press F11 to toggle it OFF for a stutter-free session.
  var autoShot = true
  var lastShotTime = getMonoTime()
  var shotCount = 0
  createDir("bin/autoshots")
  createDir("bin/states")
  let screenshotsDir = getHomeDir() / "Pictures" / "Screenshots"
  createDir(screenshotsDir)
  # Per-session capture home: the durable artifacts of ONE play session live
  # together — replay segments (.tas + _start.state) + F12 bookmarks (f12/).
  # Autoshots stay in bin/autoshots (disposable diagnostics; replay_seek can
  # regenerate any moment from the session's replays anyway). On clean exit
  # the durable bits auto-archive to ../decompbound_secret/sessions/.
  let sessionStamp = now().format("yyyyMMdd-HHmmss")
  let sessionDir = "bin/sessions" / sessionStamp
  createDir(sessionDir / "f12")
  # Session provenance manifest: the build that produced everything in this
  # session dir (screenstates, replays). Answers "what version was this?".
  block:
    let binPath = try: getAppFilename() except CatchableError: "?"
    let manifest = "build " & buildLabel() & "\n" &
      "build_date " & BuildDate & "\n" &
      "rom_hash 0x" & &"{romHashOf(rom):08X}" & "\n" &
      "binary " & binPath & "\n" &
      "session_start " & now().format("yyyy-MM-dd'T'HH:mm:ss") & "\n"
    writeFile(sessionDir / "session.txt", manifest)
  echo "BUILD: ", buildLabel(), " (", BuildDate, ")  session=", sessionDir

  var logOpened = false
  var logFile: File
  logOpened = open(logFile, "bin/play_log.txt", fmAppend)
  if logOpened:
    let ts0 = now().format("yyyy-MM-dd HH:mm:ss")
    # Build provenance from the BINARY itself (compile-time), not a runtime git
    # query — the running binary may be older than the current tree.
    logFile.writeLine(&"{ts0}  PLAY SESSION START build {buildLabel()} ({BuildDate})  ROM={romPath}")
    logFile.flushFile()

  proc writeLog(msg: string) =
    ## Append a timestamped event line to bin/play_log.txt (flushed immediately so useful after crash).
    if logOpened:
      let ts = now().format("yyyy-MM-dd HH:mm:ss")
      logFile.writeLine(&"{ts}  {msg}")
      logFile.flushFile()

  # F10: one-shot per-scanline TM/TS profile -> bin/autoshots/scanline_trace.txt,
  # for diagnosing HDMA screen-splits (e.g. the battle's bottom status band).
  var traceScanlines = false
  var traceArmed = 0    # frames since F10 armed; wait for an HDMA-active frame.
  var traceTM: array[262, uint8]
  var traceTS: array[262, uint8]
  var traceCG: array[262, uint8]   # CGADSUB (color math) per scanline
  var traceCW: array[262, uint8]   # CGWSEL per scanline
  # F9 / auto-anomaly full bundle: frame + PPU regs + CGRAM alongside the trace.
  var captureBundle = false
  # True when the bundle was triggered by F9 (a deliberate manual capture) rather
  # than an auto-anomaly. Manual captures get numbered f9_NNN_* copies so a later
  # HDMA auto-capture can't clobber the frame you actually wanted (e.g. HP/PP menu).
  var captureManual = false
  var f9Count = 0
  # Prev-frame HDMAEN, to auto-capture on a 0 -> non-zero HDMA edge (a screen
  # split starting: battle swirl/bands, scene iris) with no human keypress.
  var prevHdmaen: uint8 = 0
  var lastJoy1: uint16 = 0
  var currentInputDisplay = "none"

  # Minimal input recording (F7 toggle). Only taps at joy1 chokepoint; never
  # touches render, scroll, PPU, APU or emu step logic. Start state + deltas.
  var recording = false
  var replayLog: File
  var replayLogOpen = false
  var recordFrame = 0
  var lastRecordJoy: uint16 = 0
  var replayLogPath = ""

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

  # Prepare a fully-transparent 1x1 pixie image once for cursor hiding.
  # Windy 0.4.4 exposes Cursor/CustomCursor but no hidden CursorKind.
  # CustomCursor with alpha=0 works on linux x11 via Xcursor; sets invisible.
  let hiddenCursor = block:
    let img = newImage(1, 1)
    img.data[0] = rgbx(0'u8, 0, 0, 0)
    Cursor(kind: CustomCursor, image: img, hotspot: ivec2(0, 0))
  var prevMousePos = window.mousePos
  var mouseIdleFrames = 0

  # Replay recording is ALWAYS ON by default (sparse joy1 deltas + one start
  # state per segment — pennies of disk, and every session/bug becomes
  # replayable). A fresh segment starts at boot and after every state load so
  # each .tas is self-contained against its own _start.state. F7 toggles off.
  proc stopRecording() =
    ## Close the current replay segment (if any).
    if replayLogOpen:
      replayLog.close()
      replayLogOpen = false
    recording = false
    recordFrame = 0

  proc startRecording(tag: string) =
    ## Begin a fresh replay segment (per-segment start state + .tas log) in
    ## this session's directory.
    stopRecording()
    createDir(sessionDir)
    let ts = now().format("yyyyMMdd-HHmmss")
    let startP = sessionDir / &"{ts}_start.state"
    writeFile(startP, cast[string](serializeState(snes, cpu)))
    replayLogPath = sessionDir / &"{ts}.tas"
    replayLogOpen = open(replayLog, replayLogPath, fmWrite)
    if replayLogOpen:
      replay.writeReplayHeader(replayLog, romHashOf(rom), startP, buildLabel())
      recording = true
      recordFrame = 0
      lastRecordJoy = 0xFFFF'u16  # impossible joy1 → force a delta on frame 0
      echo &"RECORDING ({tag}) -> {replayLogPath} (+ {startP})"
      writeLog(&"RECORD ON {tag} {replayLogPath}")
    else:
      echo "ERROR: failed to open record log ", replayLogPath

  # Windy file drop: set the callback (fires via pollEvents). Only F12 screenshots
  # embed state; plain PNGs or wrong-ROM shots are rejected with a message (no crash).
  # Live drag-drop restore requires the actual window running (headless can't deliver drops).
  window.onFileDrop = proc(fileName: string, fileData: string) =
    if not (fileName.endsWith(".png") or fileName.endsWith(".PNG")):
      echo "drop ignored (not .png): ", fileName
      return
    var png = newSeq[uint8](fileData.len)
    if png.len > 0:
      copyMem(addr png[0], unsafeAddr fileData[0], png.len)
    let extractedOpt = extractState(png)
    if extractedOpt.isNone:
      echo "drop rejected (no ebSt / bad magic / version): ", fileName
      return
    # Extract romHash from ebSt (extractState validated magic+ver+len; we read the hash field).
    # Inline minimal walker (png_state internals private; only edit play.nim per task).
    var embeddedHash: uint32 = 0
    var hashFound = false
    block findHash:
      const PngSigLen = 8
      if png.len < PngSigLen + 12: break findHash
      var pos = PngSigLen
      while pos + 12 <= png.len:
        let clen = (png[pos+0].uint32 shl 24) or (png[pos+1].uint32 shl 16) or
                   (png[pos+2].uint32 shl 8) or png[pos+3].uint32
        if png[pos+4] == 'e'.uint8 and png[pos+5] == 'b'.uint8 and
           png[pos+6] == 'S'.uint8 and png[pos+7] == 't'.uint8:
          let ds = pos + 8
          if ds + 10 <= png.len:
            embeddedHash = png[ds+6].uint32 or (png[ds+7].uint32 shl 8) or
                           (png[ds+8].uint32 shl 16) or (png[ds+9].uint32 shl 24)
            hashFound = true
          break findHash
        pos += 8 + clen.int + 4
    if not hashFound:
      echo "drop rejected (no romHash in ebSt): ", fileName
      return
    let currentHash = romHashOf(rom)
    if embeddedHash != currentHash:
      echo &"drop rejected (romHash mismatch: 0x{embeddedHash:08X} != current 0x{currentHash:08X}): ", fileName
      return
    let stateData = extractedOpt.get
    try:
      deserializeState(stateData, snes, cpu)
      echo "restored state from ", fileName
      writeLog(&"restored state from drop: {fileName}")
      startRecording("drop")
    except CatchableError as e:
      echo "drop restore failed (deserialize): ", e.msg
      # never crash the live game

  # Optional start state from the CLI (make play-pokey etc): .state blob or
  # ebSt .png both work. Applied once before the loop; recording then starts
  # its first segment from exactly this state.
  if startStatePath.len > 0:
    try:
      if startStatePath.endsWith(".png") or startStatePath.endsWith(".PNG"):
        let pngBytes = cast[seq[uint8]](readFile(startStatePath))
        let ex = extractState(pngBytes)
        if ex.isNone:
          echo "start-state png has no ebSt chunk: ", startStatePath
          quit(1)
        deserializeState(ex.get, snes, cpu)
      else:
        deserializeState(cast[seq[byte]](readFile(startStatePath)), snes, cpu)
      echo "start state loaded: ", startStatePath
      writeLog(&"start state loaded: {startStatePath}")
    except CatchableError as e:
      echo "start-state load failed: ", e.msg
      quit(1)
  startRecording("boot")

  while not window.closeRequested:
    pollEvents()
    ss.pump()  # reclaim finished buffers every iteration (paused or not)

    # Track window.mousePos frame-to-frame for auto-hide: hide after
    # MouseIdleHideFrames (~3s) of no movement by setting a transparent
    # CustomCursor; restore ArrowCursor immediately on any movement.
    let currMousePos = window.mousePos
    if currMousePos != prevMousePos:
      mouseIdleFrames = 0
      prevMousePos = currMousePos
      if window.cursor.kind != ArrowCursor:
        window.cursor = Cursor(kind: ArrowCursor)
    else:
      inc mouseIdleFrames
      if mouseIdleFrames >= MouseIdleHideFrames and window.cursor.kind != CustomCursor:
        window.cursor = hiddenCursor

    # Map current key state to joy1 every frame. Keyboard and gamepad sources
    # are tracked separately so input logging can note the origin.
    # Paddy gamepad (player 1) as alternative/additive input for SNES controller.
    var kbdJoy: uint16 = 0
    if window.buttonDown[KeyUp]: kbdJoy = kbdJoy or BtnUp
    if window.buttonDown[KeyDown]: kbdJoy = kbdJoy or BtnDown
    if window.buttonDown[KeyLeft]: kbdJoy = kbdJoy or BtnLeft
    if window.buttonDown[KeyRight]: kbdJoy = kbdJoy or BtnRight
    if window.buttonDown[KeyZ]: kbdJoy = kbdJoy or BtnB
    if window.buttonDown[KeyX]: kbdJoy = kbdJoy or BtnA
    if window.buttonDown[KeyA]: kbdJoy = kbdJoy or BtnY
    if window.buttonDown[KeyS]: kbdJoy = kbdJoy or BtnX
    if window.buttonDown[KeyQ]: kbdJoy = kbdJoy or BtnL
    if window.buttonDown[KeyE]: kbdJoy = kbdJoy or BtnR
    if window.buttonDown[KeyEnter]: kbdJoy = kbdJoy or BtnStart
    if window.buttonDown[KeyRightShift]: kbdJoy = kbdJoy or BtnSel

    var padJoy: uint16 = 0
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
        if gp.button(GamepadUp): padJoy = padJoy or BtnUp
        if gp.button(GamepadDown): padJoy = padJoy or BtnDown
        if gp.button(GamepadLeft): padJoy = padJoy or BtnLeft
        if gp.button(GamepadRight): padJoy = padJoy or BtnRight
        # Map by PHYSICAL position, not label (paddy is positional/SDL-style):
        # paddy A=bottom, B=right, X=top, Y=left; SNES has B=bottom, A=right,
        # X=top, Y=left. So paddy A/B map to SNES B/A (the classic Nintendo A/B
        # swap); X/Y already line up by position.
        if gp.button(GamepadA): padJoy = padJoy or BtnB
        if gp.button(GamepadB): padJoy = padJoy or BtnA
        if gp.button(GamepadY): padJoy = padJoy or BtnY
        if gp.button(GamepadX): padJoy = padJoy or BtnX
        if gp.button(GamepadL1): padJoy = padJoy or BtnL
        if gp.button(GamepadR1): padJoy = padJoy or BtnR
        if gp.button(GamepadStart): padJoy = padJoy or BtnStart
        if gp.button(GamepadSelect): padJoy = padJoy or BtnSel

        # Support cheap SNES imitation pads that report d-pad as fake left-stick axes
        # (values like 1.0 / 0.0 / -1.0) instead of (or in addition to) real d-pad buttons.
        # A low threshold so diagonals engage easily — with 0.5 a not-quite-45-degree
        # push only crossed one axis, so diagonals "snapped" to orthogonal.
        let lx = gp.axis(GamepadLStickX)
        let ly = gp.axis(GamepadLStickY)
        const AxisThreshold = 0.35'f
        if lx > AxisThreshold: padJoy = padJoy or BtnRight
        if lx < -AxisThreshold: padJoy = padJoy or BtnLeft
        if ly > AxisThreshold: padJoy = padJoy or BtnDown
        if ly < -AxisThreshold: padJoy = padJoy or BtnUp
    except CatchableError, Defect:
      pads = @[]
    let joy1 = kbdJoy or padJoy
    # No input latch: faithful d-pad, no held-frame band-aid. A good controller
    # handles its own diagonals; we don't hack around bad hardware.
    snes.joy1 = joy1

    # MINIMAL record tap (ONLY at the joy1 chokepoint; play.nim render/emu untouched).
    # Deltas written only on joy1 change (plus first after toggle).
    if recording and replayLogOpen:
      if recordFrame == 0 or joy1 != lastRecordJoy:
        replay.appendReplayDelta(replayLog, recordFrame, joy1)
        lastRecordJoy = joy1
      inc recordFrame

    # Live input logging: decode bitmask to names, append to title, and print on
    # change (with kbd/pad source note). Always active (verbose adds raw dumps).
    const BtnNamePairs = [
      (BtnUp, "Up"), (BtnDown, "Down"), (BtnLeft, "Left"), (BtnRight, "Right"),
      (BtnA, "A"), (BtnB, "B"), (BtnX, "X"), (BtnY, "Y"),
      (BtnL, "L"), (BtnR, "R"), (BtnStart, "Start"), (BtnSel, "Select")
    ]
    var inputParts: seq[string] = @[]
    for (bit, name) in BtnNamePairs:
      if (joy1 and bit) != 0:
        inputParts.add(name)
    let inputDisplay = if inputParts.len > 0: inputParts.join("+") else: "none"
    var sources: seq[string] = @[]
    if kbdJoy != 0: sources.add("kbd")
    if padJoy != 0: sources.add("pad")
    let sourceNote = if sources.len > 0: sources.join("+") else: ""
    if joy1 != lastJoy1:
      let src = if sourceNote.len > 0: " (" & sourceNote & ")" else: ""
      echo &"input: {inputDisplay}{src}  joy1=0x{joy1:04x}"
      writeLog(&"input: {inputDisplay}{src}  joy1=0x{joy1:04x}")
      currentInputDisplay = inputDisplay
      lastJoy1 = joy1

    if verbose:
      # Raw details stay under verbose; decoded input: lines are always emitted on change.

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
      writeLog(&"pause: {(if paused: \"ON\" else: \"OFF\")}")
    if window.buttonPressed[KeyN] and paused:
      frameAdvance = true
      writeLog("frame advance")
    if window.buttonPressed[KeyMinus] and framesPerTick > 1:
      dec framesPerTick
      writeLog(&"speed: x{framesPerTick}")
    if window.buttonPressed[KeyEqual]:
      inc framesPerTick
      writeLog(&"speed: x{framesPerTick}")
    if window.buttonPressed[KeyF9]:
      # One-press full diagnostic bundle: arm the scanline trace and capture the
      # frame + PPU regs + CGRAM together (written when the trace fires). Plus an
      # immediate terminal readout. (F9, not F12 — Steam hijacks F12 for its own
      # screenshot, so F12 is our screenshot and F9 is the debug bundle.)
      captureBundle = true
      captureManual = true
      traceScanlines = true
      traceArmed = 0
      echo "F9: capturing diagnostic bundle -> bin/autoshots/ (frame + regs + scanline trace + CGRAM)"
      writeLog("F9: diagnostic bundle capture armed")
    if window.buttonPressed[KeyF10]:
      traceScanlines = true
      traceArmed = 0
      echo "scanline trace armed (captures the next HDMA-split frame, e.g. a battle)"
      writeLog("F10: scanline trace armed")
    if window.buttonPressed[KeyF11]:
      autoShot = not autoShot
      echo "auto-screenshots: ", (if autoShot: "ON (bin/autoshots/ every 5s)" else: "OFF")
      writeLog(&"F11: auto-screenshots {(if autoShot: \"ON\" else: \"OFF\")}")
    if window.buttonPressed[KeyF12]:
      # F12 = screenshot, matching Steam's screenshot-key convention (Steam
      # intercepts F12, so aligning ours avoids the surprise). Primary copy
      # lives in the session dir (archived with the replays); a mirror goes
      # to ~/Pictures/Screenshots for desktop browsing muscle memory.
      let stateBytes = serializeState(snes, cpu)
      let rhash = romHashOf(rom)
      createDir(sessionDir / "f12")
      let shotPath = saveScreenshot(frameImage, sessionDir / "f12", stateBytes, rhash)
      try:
        copyFile(shotPath, screenshotsDir / shotPath.extractFilename)
      except CatchableError:
        discard  # Pictures mirror is best-effort; the session copy is canonical.
      echo "  build=", buildLabel(), " (session.txt in ", sessionDir, ")"
      writeLog("screenshot (F12) build=" & buildLabel())
      echo &"  BGMODE={snes.ppuRegs[0x05] and 7} bg3prio={(snes.ppuRegs[0x05] and 8) != 0} " &
        &"TM(main)={snes.ppuRegs[0x2C]:02X} TS(sub)={snes.ppuRegs[0x2D]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"
      echo &"  CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X} HDMAEN={snes.hdmaen:02X}"
      echo &"  windows: W12SEL={snes.ppuRegs[0x23]:02X} W34SEL={snes.ppuRegs[0x24]:02X} " &
        &"WOBJSEL={snes.ppuRegs[0x25]:02X} WH0-3={snes.ppuRegs[0x26]:02X}/{snes.ppuRegs[0x27]:02X}/" &
        &"{snes.ppuRegs[0x28]:02X}/{snes.ppuRegs[0x29]:02X} TMW={snes.ppuRegs[0x2E]:02X} TSW={snes.ppuRegs[0x2F]:02X}"
    if window.buttonPressed[KeyF7]:
      if not recording:
        startRecording("F7")
      else:
        stopRecording()
        echo "RECORDING OFF"
        writeLog("RECORD OFF")
    # State save/load (Ctrl+1..4 = save slot N, 1..4 = load slot N; documented in
    # Controls above). Uses public fields only.
    for slot in 1..4:
      let keyNum = case slot
        of 1: Key1
        of 2: Key2
        of 3: Key3
        of 4: Key4
        else: Key1
      if window.buttonPressed[keyNum]:
        let isCtrl = window.buttonDown[KeyLeftControl] or window.buttonDown[KeyRightControl]
        let p = statePathForSlot(slot)
        if isCtrl:
          saveState(snes, cpu, slot)
          echo &"saved slot {slot} -> {p}"
          writeLog(&"saved slot {slot}")
        else:
          if fileExists(p):
            loadState(snes, cpu, slot)
            echo &"loaded slot {slot} <- {p}"
            writeLog(&"loaded slot {slot}")
            startRecording("slot" & $slot)
          else:
            echo &"no state for slot {slot}"
            writeLog(&"load failed for slot {slot} (no file)")
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
          # Clamp the backlog: after a long stall (alt-tab away, window drag, a
          # debugger pause) the accumulator would otherwise hold seconds of real
          # time and drain as sustained "super speed". Cap it at a few frames so
          # we catch up ONCE and resume normal speed, never a prolonged burst.
          if frameAcc > dueNs * 4:
            frameAcc = dueNs * 4
          var n = 0
          while frameAcc >= dueNs and n < 4:
            frameAcc -= dueNs
            inc n
          n
      for t in 0 ..< ticks:
        # Instructions per scanline = the CPU's per-frame budget (× 262 lines). The
        # SNES gives the CPU a fixed CYCLE budget/frame; we approximate with an
        # instruction count (goal.md: no cycle accuracy). This budget must cover the
        # game's HEAVIEST frames — area loads + intro-card transitions that decompress
        # graphics. At 40 (~10.5k/frame) those heavy frames were STARVED: the scene
        # logic spilled across many emulated frames while the APU (ticked per scanline,
        # decoupled from CPU *work*) kept perfect real-time tempo — so audio ran AHEAD
        # of the lagging visuals (Scaraba music over the Twoson scene; long inter-card
        # + hotel-exit/area-load delays). ~150 (~39k/frame) meets/exceeds hardware
        # throughput so heavy frames finish in hardware-like frame counts and the scene
        # keeps pace with the music. Light frames self-limit (the game spin-waits its
        # once-per-frame NMI, so it can't run logic faster), and the APU tick rate is
        # unchanged — so gameplay pacing + audio tempo are preserved. Tune if needed.
        const InstrPerLine = 150
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
            writeLog("F9/auto: wrote diagnostic bundle (scanline_trace + frame + regs)")
            if captureManual:
              # F9 (manual) captures get numbered copies the HDMA auto-capture
              # can't overwrite — so a deliberate F9 (e.g. on the battle HP/PP
              # menu) survives even if a later HDMA edge fires an auto-capture.
              copyFile("bin/autoshots/bundle_frame.png",
                &"bin/autoshots/f9_{f9Count:03}_frame.png")
              copyFile("bin/autoshots/bundle_regs.txt",
                &"bin/autoshots/f9_{f9Count:03}_regs.txt")
              copyFile("bin/autoshots/scanline_trace.txt",
                &"bin/autoshots/f9_{f9Count:03}_trace.txt")
              echo &"  F9 bundle preserved -> bin/autoshots/f9_{f9Count:03}_*"
              writeLog(&"F9: bundle preserved as f9_{f9Count:03}_*")
              inc f9Count
              captureManual = false
          else:
            echo "wrote bin/autoshots/scanline_trace.txt"
            writeLog("wrote scanline_trace.txt")
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
          writeLog(&"auto-capture: HDMA split started (HDMAEN={snes.hdmaen:02X})")
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
    let inputTitlePart = if currentInputDisplay != "none": " [" & currentInputDisplay & "]" else: ""
    let newTitle = &"decompbound player - {fpsShown:.0f} fps - frame {frameCount}{pausedStr} x{framesPerTick}{inputTitlePart}"
    if window.title != newTitle:
      window.title = newTitle

    # In-game text echo (dialogue / menus / signs) — every 20 frames while a
    # window is open. Uses getDialogueText — decodes the real EB dialogue
    # script stream (cursor $96C5 + dictionary tokens), NOT the old VRAM tile
    # scan (unsound for EB's variable-width font). Prints clean copy-pasteable
    # text once per change; empty when no message window is open.
    if frameCount mod 20 == 0:
      let txt = getDialogueText(snes)
      if txt.len > 0:
        if txt != lastScreenText:
          echo "── text ──────────────────────────"
          echo txt
          echo "──────────────────────────────────"
          lastScreenText = txt
      elif lastScreenText.len > 0:
        lastScreenText = ""

    # Auto-capture: every ~5s dump the frame + a PPU-register line to the
    # gitignored bin/autoshots/ so scenes can be reviewed/diagnosed later.
    if autoShot and (getMonoTime() - lastShotTime).inSeconds >= 5:
      frameImage.writeFile(&"bin/autoshots/shot_{shotCount:04}.png")
      # Timeline pointer: with always-on recording every autoshot maps to an
      # exact replayable moment — reconstruct it via
      #   nim r src/tools/replay_seek.nim <seg>.tas --frame <segframe>
      let segTag = if recording: &" seg={replayLogPath.extractFilename} segframe={recordFrame}"
        else: " seg=off"
      let regLine = &"shot_{shotCount:04}  frame={frameCount}{segTag} fps={fpsShown:.0f}  " &
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
  if recording and replayLogOpen:
    replayLog.close()
    replayLogOpen = false
  # Auto-archive this session's durable captures to the private secret repo,
  # if present. Replay pairs -> sessions/<ts>/ (session context); screenstates
  # (F12 screenshot+savestate PNGs) -> the FLAT screenstates/ collection so
  # they browse in one place across all sessions (successor of states/).
  # Best-effort: never block or fail the exit path. Autoshots are deliberately
  # NOT archived (regenerable via replay_seek).
  try:
    const SecretRoot = "../decompbound_secret"
    if dirExists(SecretRoot) and dirExists(sessionDir):
      var archived = 0
      let dest = SecretRoot / "sessions" / sessionStamp
      for kind, path in walkDir(sessionDir):
        if kind == pcFile and (path.endsWith(".tas") or path.endsWith(".state")):
          createDir(dest)
          copyFile(path, dest / path.extractFilename)
          inc archived
      if dirExists(sessionDir / "f12"):
        for kind, path in walkDir(sessionDir / "f12"):
          if kind == pcFile and path.endsWith(".png"):
            createDir(SecretRoot / "screenstates")
            copyFile(path, SecretRoot / "screenstates" / path.extractFilename)
            inc archived
      if archived > 0:
        echo &"session archived: {archived} file(s) -> {dest} (+ screenstates/)"
        writeLog(&"session archived: {archived} file(s) -> {dest}")
  except CatchableError as e:
    echo "session archive skipped: ", e.msg
  ss.close()
  slappyClose()
  if logOpened:
    writeLog("PLAY SESSION END")
    logFile.close()

when isMainModule:
  main()
