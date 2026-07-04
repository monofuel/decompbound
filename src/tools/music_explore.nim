## Music explorer - Nim desktop app for browsing game music tracks.
## Proper focus: use the real driver + captured data + port commands.
## No force voices, no magic tails.

import
  std/[os, strformat, strutils],
  pixie,
  opengl,
  windy,
  ../decompbound/[apu, cpu, snesbus]

const
  Scale = 3
  W = 640
  H = 480

type
  TrackPreset = object
    name: string
    desc: string
    boot: int
    secs: int
    ports: array[4, uint8]

var presets = @[
  TrackPreset(name: "Giygas/Intro", desc: "Title static (good with 16M boot)", boot: 16000000, secs: 10, ports: [0u8, 0x81, 0, 0]),
  TrackPreset(name: "Early/Other", desc: "Default shorter boot capture", boot: 3000000, secs: 8, ports: [0u8, 0x02, 0, 0]),
  TrackPreset(name: "Driver only", desc: "No special play command", boot: 2000000, secs: 5, ports: [0u8, 0, 0, 0]),
]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  let s = if d.len mod 1024 == 512: 512 else: 0
  result = newSeq[uint8](d.len - s)
  for i in 0..<result.len: result[i] = d[s+i].uint8

proc doRender(rom: string, pr: TrackPreset, outp: string): tuple[info: string, nz: int] =
  let romd = readRom(rom)
  let bus = newSnesBus(romd)
  var cpu = bus.resetCpu()
  var ex = 0
  var ln = 0
  bus.initHdma()
  while ex < pr.boot and not cpu.stopped:
    for _ in 0..<30:
      if (bus.nmitimen and 0x80) != 0 and ln == 240: cpu.nmiPending = true
      cpu.step(bus.bus)
      ex += 1
      if ex >= pr.boot or cpu.stopped: break
    if ln < 224: bus.runHdma()
    ln += 1
    if ln >= 262: ln = 0; bus.initHdma()

  let ap = newApu()
  for i in 0..<0x10000: ap.spc.ram[i] = bus.apuImage[i]
  ap.spc.pc = if bus.apuEntry != 0: bus.apuEntry else: 0x0500'u16
  ap.spc.sp = 0xEF
  for i in 0..3: ap.portsIn[i] = pr.ports[i]

  let tot = pr.secs * 32000
  var sam: seq[int16]
  var pidx = 0
  let per = 32000 div 200
  var nzc = 0
  for si in 0..<tot:
    if pidx < bus.apuPostBoot.len and si mod per == 0:
      let (po, va) = bus.apuPostBoot[pidx]
      ap.portsIn[(po-0x2140).int] = va
      pidx += 1
    let (l,r) = ap.runSample()
    sam.add l; sam.add r
    if l != 0 or r != 0: nzc += 1

  # minimal WAV
  let ds = sam.len * 2
  let fs = 36 + ds
  var hdr = newSeq[uint8](44)
  proc p32(o, v: int) = (hdr[o]=v.uint8 and 0xff; hdr[o+1]=(v shr 8).uint8 and 0xff; hdr[o+2]=(v shr 16).uint8 and 0xff; hdr[o+3]=(v shr 24).uint8 and 0xff)
  proc p16(o, v: int) = (hdr[o]=v.uint8 and 0xff; hdr[o+1]=(v shr 8).uint8 and 0xff)
  hdr[0..3] = @[0x52u8,0x49,0x46,0x46]; p32(4,fs)
  hdr[8..11] = @[0x57u8,0x41,0x56,0x45]
  hdr[12..15] = @[0x66u8,0x6d,0x74,0x20]; p32(16,16); p16(20,1); p16(22,2); p32(24,32000); p32(28,128000); p16(32,4); p16(34,16)
  hdr[36..39] = @[0x64u8,0x61,0x74,0x61]; p32(40,ds)
  var o = newString(44+ds)
  for i,b in hdr: o[i]=b.char
  for i,s in sam: (o[44+i*2] = (s.uint16 and 0xff).char; o[45+i*2]=(s.uint16 shr 8).char)
  writeFile(outp, o)

  result = (&"boot={pr.boot} posts={bus.apuPostBoot.len} blks={bus.apuJumps.len} up={bus.apuUploadBytes}", nzc)

proc main() =
  var rom = "bin/Earthbound (U) [!].smc"
  if paramCount() > 0: rom = paramStr(1)

  var sel = 0
  var info = ""
  var nzs = 0
  var lastf = ""

  let win = newWindow("decompbound music explorer", ivec2(W*Scale, H*Scale))
  win.makeContextCurrent()
  loadExtensions()

  var img = newImage(W, H)

  proc menu() =
    img.fill(rgbx(22,22,30,255))
    # visual selection bars + simple labels via position
    for i in 0..<presets.len:
      let y = 70 + i * 45
      let c = if i == sel: rgbx(60,90,50,255) else: rgbx(38,38,48,255)
      for yy in y..<y+38:
        for xx in 25..<W-25:
          img.data[yy*W + xx] = c
      # crude label: fill a "number" area
      img.data[y*W + 30] = rgbx(255,255,255,255)
    # status bar area
    for yy in H-75..<H-10:
      for xx in 15..<W-15:
        img.data[yy*W + xx] = rgbx(30,30,38,255)

  # minimal GL
  proc csh(k: GLenum, s: string): GLuint =
    let sh = glCreateShader(k)
    let a = allocCStringArray([s])
    glShaderSource(sh,1,a,nil); glCompileShader(sh)
    var status: GLint
    glGetShaderiv(sh, GL_COMPILE_STATUS, addr status)
    if status.GLboolean == GL_FALSE:
      echo "shader fail"; quit(1)
    deallocCStringArray(a); sh

  let vs = csh(GL_VERTEX_SHADER, "#version 410\nin vec2 p;in vec2 u;out vec2 v;void main(){gl_Position=vec4(p,0,1);v=u;}")
  let fs = csh(GL_FRAGMENT_SHADER, "#version 410\nin vec2 v;uniform sampler2D t;out vec4 c;void main(){c=texture(t,v);}")
  let prg = glCreateProgram()
  glAttachShader(prg,vs); glAttachShader(prg,fs); glLinkProgram(prg)
  let ut = glGetUniformLocation(prg,"t")

  var vao,pb,ub:GLuint
  glGenVertexArrays(1,addr vao); glBindVertexArray(vao)
  var pd = @[vec2(-1f,-1),vec2(1,-1),vec2(1,1),vec2(1,1),vec2(-1,1),vec2(-1,-1)]
  var ud = @[vec2(0f,1),vec2(1,1),vec2(1,0),vec2(1,0),vec2(0,0),vec2(0,1)]
  glGenBuffers(1,addr pb); glBindBuffer(GL_ARRAY_BUFFER,pb)
  glBufferData(GL_ARRAY_BUFFER,pd.len*8,pd[0].addr,GL_STATIC_DRAW)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil); glEnableVertexAttribArray(0)
  glGenBuffers(1,addr ub); glBindBuffer(GL_ARRAY_BUFFER,ub)
  glBufferData(GL_ARRAY_BUFFER,ud.len*8,ud[0].addr,GL_STATIC_DRAW)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil); glEnableVertexAttribArray(1)

  var tx:GLuint
  glGenTextures(1,addr tx); glBindTexture(GL_TEXTURE_2D,tx)
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST)
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST)

  proc blit() =
    glBindTexture(GL_TEXTURE_2D,tx)
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8.GLint,img.width.GLsizei,img.height.GLsizei,0,GL_RGBA,GL_UNSIGNED_BYTE,cast[pointer](img.data[0].addr))
    glUseProgram(prg); glUniform1i(ut,0); glActiveTexture(GL_TEXTURE0)
    glBindVertexArray(vao)
    glViewport(0,0,win.size.x,win.size.y)
    glClearColor(0.08,0.08,0.1,1); glClear(GL_COLOR_BUFFER_BIT)
    glDrawArrays(GL_TRIANGLES,0,6)
    win.swapBuffers()

  proc up() = (menu(); blit())

  echo "music explorer ready"
  up()

  while not win.closeRequested:
    pollEvents()
    var d = false
    if win.buttonPressed[KeyUp]: sel = (sel-1+presets.len) mod presets.len; d=true
    if win.buttonPressed[KeyDown]: sel = (sel+1) mod presets.len; d=true
    if win.buttonPressed[KeyEnter]:
      let p = presets[sel]
      let f = "bin/track_" & p.name.toLowerAscii.replace(" ","_") & ".wav"
      echo "rendering ", p.name, " ..."
      let r = doRender(rom, p, f)
      info = r.info; nzs = r.nz; lastf = f
      echo "  wrote ", f, " nz=", nzs
      d = true
    if win.buttonPressed[KeyR] and lastf.len>0:
      let p = presets[sel]
      let r = doRender(rom, p, lastf)
      nzs = r.nz
      d = true
    if win.buttonPressed[KeyEscape]: win.closeRequested = true
    if d: up()

when isMainModule: main()