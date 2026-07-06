## Tiny shared GL + windy blit helper for windowed emulator viewers.
## Provides shader compile/link, a simple nearest-filter texture quad,
## and aspect-ratio letterbox viewport + per-frame upload/draw/swap.
## Used by llm_ai.nim (and potentially others later). Logic mirrors play.nim's
## display path but factored for reuse without touching play.nim.
## The window is created at 3x scale by default and is user-resizable (letterbox adjusts).

import
  pixie,
  opengl,
  windy

proc compileShader*(kind: GLenum, source: string): GLuint =
  ## Compile one shader and return its id, or quit on error (tooling context).
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

proc checkLink*(program: GLuint) =
  ## Check program link status, quit on error (tooling context).
  var status: GLint
  glGetProgramiv(program, GL_LINK_STATUS, addr status)
  if status.GLboolean == GL_FALSE:
    var logLen: GLint
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, addr logLen)
    var log = newString(logLen)
    glGetProgramInfoLog(program, logLen, nil, log.cstring)
    echo "Program link error: ", log
    quit(1)

type
  GlBlit* = object
    ## Holds the GL resources and window for repeated frame blits.
    window*: Window
    program*: GLuint
    texLoc*: GLint
    textureId*: GLuint
    vao*: GLuint
    nativeW*: int
    nativeH*: int

proc initGlBlit*(title: string, nativeW, nativeH: int, scale: int = 3): GlBlit =
  ## Create a window (title), GL context, shader program, texture, and quad VAO
  ## sized for the given native frame (e.g. 256x224). Initial window is scale*size.
  ## Call makeContextCurrent + loadExtensions is done here.
  let windowSize = ivec2((nativeW * scale).int32, (nativeH * scale).int32)
  let window = newWindow(title, windowSize)
  window.makeContextCurrent()
  loadExtensions()

  # Fullscreen covering quad in NDC with UVs that map pixie top-left (0,0) to (0,1) uv.
  # (pixie y-down, GL texture y-up handled by uv flip in data.)
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

  # Initial black texture.
  var initImage = newImage(nativeW, nativeH)
  initImage.fill(rgbx(0, 0, 0, 255))
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
    initImage.width.GLsizei, initImage.height.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](initImage.data[0].addr)
  )

  glActiveTexture(GL_TEXTURE0)
  glUseProgram(program)
  glUniform1i(texLoc, 0)

  result = GlBlit(
    window: window,
    program: program,
    texLoc: texLoc,
    textureId: textureId,
    vao: vao,
    nativeW: nativeW,
    nativeH: nativeH
  )

proc blit*(blit: GlBlit, img: Image) =
  ## Upload the (current) frame Image to the texture and draw it with
  ## aspect-preserving letterbox (black bars) into the current window size.
  ## Caller must have called pollEvents() as needed before.
  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
    img.width.GLsizei, img.height.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](img.data[0].addr)
  )

  # Aspect-preserving viewport with black borders.
  let TargetAspect = blit.nativeW.float / blit.nativeH.float
  let winW = blit.window.size.x
  let winH = blit.window.size.y
  var vpW, vpH: int32
  if winW.float / winH.float > TargetAspect:
    vpH = winH                                  # window wider: pillarbox
    vpW = (winH.float * TargetAspect).int32
  else:
    vpW = winW                                  # window taller: letterbox
    vpH = (winW.float / TargetAspect).int32
  let vpX = (winW - vpW) div 2
  let vpY = (winH - vpH) div 2

  glClearColor(0.0, 0.0, 0.0, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)
  glViewport(vpX, vpY, vpW, vpH)

  glBindVertexArray(blit.vao)
  glDrawArrays(GL_TRIANGLES, 0, 6)

  blit.window.swapBuffers()
