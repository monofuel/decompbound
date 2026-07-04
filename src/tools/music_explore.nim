## Music explorer desktop app.
## A menu-based UI to browse and render music tracks from the game using
## the captured APU driver + standalone SPC700+DSP.
## Run with: nim r src/tools/music_explore.nim [rom]
##
## Goal: proper exploration without force-hacks or arbitrary tails.
## Select a track preset, adjust port commands if needed, render to WAV.
## The driver itself should produce the audio when the right data + command is present.

import
  std/[os, strformat, strutils, osproc],
  pixie,
  opengl,
  windy,
  ../decompbound/[apu, cpu, snesbus]

const
  Scale = 3
  ScreenW = 640
  ScreenH = 480

type
  TrackPreset = object
    name*: string
    description*: string
    bootInstructions*: int
    durationSeconds*: int
    initialPorts*: array[4, uint8]   # values to poke on portsIn after load

var presets: seq[TrackPreset] = @[
  TrackPreset(name: "Giygas Static / Intro",
    description: "War Against Giygas title card music (use ~16M boot)",
    bootInstructions: 16_000_000,
    durationSeconds: 10,
    initialPorts: [0x00'u8, 0x81'u8, 0x00'u8, 0x00'u8]),
  TrackPreset(name: "Default / Early Capture",
    description: "Whatever music is active with default shorter boot",
    bootInstructions: 3_000_000,
    durationSeconds: 8,
    initialPorts: [0x00'u8, 0x02'u8, 0x00'u8, 0x00'u8]),
  TrackPreset(name: "Silence / Init",
    description: "Just the driver, no specific song command",
    bootInstructions: 2_000_000,
    durationSeconds: 5,
    initialPorts: [0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8]),
]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc captureAndRender(romPath: string, preset: TrackPreset, outPath: string): tuple[success: bool, info: string, nonzero: int] =
  ## Run a capture using similar logic to render_song but driven from the explorer.
  ## Returns info for the UI.
  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  const InstrPerLine = 30
  var executed = 0
  var line = 0
  snes.initHdma()
  while executed < preset.bootInstructions and not cpu.stopped:
    for i in 0..<InstrPerLine:
      if (snes.nmitimen and 0x80) != 0 and line == 240 and i == 0:
        cpu.nmiPending = true
      cpu.step(snes.bus)
      executed += 1
      if executed >= preset.bootInstructions or cpu.stopped:
        break
    if line < 224:
      snes.runHdma()
    line += 1
    if line >= 262:
      line = 0
      snes.initHdma()

  let apuUnit = newApu()
  for i in 0..<0x10000:
    apuUnit.spc.ram[i] = snes.apuImage[i]
  apuUnit.spc.pc = if snes.apuEntry != 0: snes.apuEntry else: 0x0500'u16
  apuUnit.spc.sp = 0xEF

  # Apply the preset's initial port command (this is how the game "selects" the track)
  for i in 0..3:
    apuUnit.portsIn[i] = preset.initialPorts[i]

  let total = preset.durationSeconds * 32000
  var samples = newSeq[int16]()
  var portIdx = 0
  let post = snes.apuPostBoot
  let writesPerSec = 200
  let perWrite = 32000 div writesPerSec

  var nz = 0
  for si in 0..<total:
    if portIdx < post.len and si mod perWrite == 0:
      let (p, v) = post[portIdx]
      apuUnit.portsIn[(p - 0x2140).int] = v
      portIdx += 1
    let (l, r) = apuUnit.runSample()
    samples.add l
    samples.add r
    if l != 0 or r != 0: nz += 1

  # Write WAV (simple, no tail hack)
  # (reuse writeWav logic or inline minimal)
  let dataSize = samples.len * 2
  let fileSize = 36 + dataSize
  var header = newSeq[uint8](44)
  proc put32(off: int, val: int) =
    header[off] = (val and 0xff).uint8
    header[off+1] = ((val shr 8) and 0xff).uint8
    header[off+2] = ((val shr 16) and 0xff).uint8
    header[off+3] = ((val shr 24) and 0xff).uint8
  proc put16(off: int, val: int) =
    header[off] = (val and 0xff).uint8
    header[off+1] = ((val shr 8) and 0xff).uint8
  header[0..3] = @[0x52'u8, 0x49, 0x46, 0x46]
  put32(4, fileSize)
  header[8..11] = @[0x57'u8, 0x41, 0x56, 0x45]
  header[12..15] = @[0x66'u8, 0x6d, 0x74, 0x20]
  put32(16, 16); put16(20, 1); put16(22, 2); put32(24, 32000); put32(28, 32000*4); put16(32, 4); put16(34, 16)
  header[36..39] = @[0x64'u8, 0x61, 0x74, 0x61]
  put32(40, dataSize)
  var outstr = newString(44 + dataSize)
  for i, b in header: outstr[i] = b.char
  for i, s in samples:
    outstr[44 + i*2] = (s.uint16 and 0xff).char
    outstr[45 + i*2] = ((s.uint16 shr 8) and 0xff).char
  writeFile(outPath, outstr)

  let info = &"boot={preset.bootInstructions} posts={post.len} blocks={snes.apuJumps.len} upload={snes.apuUploadBytes} bytes"
  return (true, info, nz)

proc compileShader(kind: GLenum, source: string): GLuint =
  let sh = glCreateShader(kind)
  let arr = allocCStringArray([source])
  glShaderSource(sh, 1, arr, nil)
  glCompileShader(sh)
  var st: GLint
  glGetShaderiv(sh, GL_COMPILE_STATUS, addr st)
  if st.GLboolean == GL_FALSE:
    var ln: GLint
    glGetShaderiv(sh, GL_INFO_LOG_LENGTH, addr ln)
    var log = newString(ln)
    glGetShaderInfoLog(sh, ln, nil, log.cstring)
    echo "shader err: ", log
    quit(1)
  deallocCStringArray(arr)
  result = sh

proc main() =
  var romPath = "bin/Earthbound (U) [!].smc"
  if paramCount() >= 1:
    romPath = paramStr(1)

  var selected = 0
  var lastInfo = ""
  var lastNz = 0
  var lastOut = ""

  let window = newWindow("decompbound music explorer", ivec2(ScreenW * Scale, ScreenH * Scale))
  window.makeContextCurrent()
  loadExtensions()

  var image = newImage(ScreenW, ScreenH)

  # GL setup (minimal working textured quad)
  let vsrc = """
#version 410
in vec2 p; in vec2 u; out vec2 uv; void main(){gl_Position=vec4(p,0,1); uv=u;}
"""
  let fsrc = """
#version 410
in vec2 uv; uniform sampler2D t; out vec4 c; void main(){c=texture(t,uv);}
"""
  let vs = compileShader(GL_VERTEX_SHADER, vsrc)
  let fs = compileShader(GL_FRAGMENT_SHADER, fsrc)
  let pr = glCreateProgram()
  glAttachShader(pr, vs); glAttachShader(pr, fs); glLinkProgram(pr)
  let ut = glGetUniformLocation(pr, "t")

  var vao, pb, ub: GLuint
  glGenVertexArrays(1, addr vao); glBindVertexArray(vao)
  var pd = @[vec2(-1f,-1), vec2(1,-1), vec2(1,1), vec2(1,1), vec2(-1,1), vec2(-1,-1)]
  var ud = @[vec2(0f,1), vec2(1,1), vec2(1,0), vec2(1,0), vec2(0,0), vec2(0,1)]
  glGenBuffers(1, addr pb); glBindBuffer(GL_ARRAY_BUFFER, pb)
  glBufferData(GL_ARRAY_BUFFER, pd.len*8, pd[0].addr, GL_STATIC_DRAW)
  glVertexAttribPointer(0,2,cGL_FLOAT,GL_FALSE,8,nil); glEnableVertexAttribArray(0)
  glGenBuffers(1, addr ub); glBindBuffer(GL_ARRAY_BUFFER, ub)
  glBufferData(GL_ARRAY_BUFFER, ud.len*8, ud[0].addr, GL_STATIC_DRAW)
  glVertexAttribPointer(1,2,cGL_FLOAT,GL_FALSE,8,nil); glEnableVertexAttribArray(1)

  var tex: GLuint
  glGenTextures(1, addr tex); glBindTexture(GL_TEXTURE_2D, tex)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)

  proc draw() =
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, image.width.GLsizei, image.height.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](image.data[0].addr))
    glUseProgram(pr); glUniform1i(ut, 0); glActiveTexture(GL_TEXTURE0)
    glBindVertexArray(vao)
    glViewport(0, 0, window.size.x, window.size.y)
    glClearColor(0.07, 0.07, 0.1, 1)
    glClear(GL_COLOR_BUFFER_BIT)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    window.swapBuffers()

  proc refresh() =
    drawMenu()
    draw()

  echo "decompbound music explorer"
  echo "Select with arrows, Enter to render (this runs a boot + SPC render)"

  refresh()

  while not window.closeRequested:
    pollEvents()
    var dirty = false

    if window.buttonPressed[KeyUp]:
      selected = (selected - 1 + presets.len) mod presets.len; dirty = true
    if window.buttonPressed[KeyDown]:
      selected = (selected + 1) mod presets.len; dirty = true

    if window.buttonPressed[KeyEnter] or window.buttonPressed[KeyReturn]:
      let prs = presets[selected]
      let outp = "bin/track_" & prs.name.toLowerAscii.replace(" ","_").replace("/","_") & ".wav"
      echo &"→ rendering {prs.name} (boot {prs.bootInstructions} instr, {prs.durationSeconds}s) ..."
      let r = captureAndRender(romPath, prs, outp)
      lastInfo = r.info; lastNz = r.nonzero; lastOut = outp
      echo &"   wrote {outp}  nonzero={lastNz}"
      dirty = true

    if window.buttonPressed[KeyR] and lastOut.len > 0:
      let prs = presets[selected]
      echo "re-rendering..."
      let r = captureAndRender(romPath, prs, lastOut)
      lastNz = r.nonzero
      dirty = true

    if window.buttonPressed[KeyEscape]:
      window.closeRequested = true

    if dirty:
      refresh()
      echo &"selected: {presets[selected].name}"

when isMainModule:
  main()
