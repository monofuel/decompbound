## Shared GL + windy blit helper for the windowed emulator viewers (play.nim,
## llm_ai.nim): shader compile/link, a nearest-filtered texture quad, an
## integer-scale centred viewport, and per-frame upload/draw/swap.
##
## Targets OpenGL 2.1 (GLSL 1.20, no vertex array objects, unsized texture
## format) so the same code runs on a desktop compatibility context and on
## the Raspberry Pi 3's VC4 driver.

import
  pixie,
  opengl,
  windy

const
  VertSrc = """
#version 120
attribute vec2 vertexPos;
attribute vec2 vertexUv;
varying vec2 uv;
void main() {
  gl_Position = vec4(vertexPos, 0.0, 1.0);
  uv = vertexUv;
}
"""
  FragSrc = """
#version 120
varying vec2 uv;
uniform sampler2D tex;
void main() {
  gl_FragColor = texture2D(tex, uv);
}
"""

type
  GlBlit* = object
    ## Holds the GL resources and window for repeated frame blits.
    window*: Window
    program*: GLuint
    texLoc*: GLint
    textureId*: GLuint
    posBuffer*: GLuint
    uvBuffer*: GLuint
    nativeW*: int
    nativeH*: int

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

proc initGlBlit*(title: string, nativeW, nativeH: int, scale: int = 3,
                 fullscreen = false, vsync = true): GlBlit =
  ## Create the window, GL context, shader program, texture and quad buffers
  ## for a native frame of nativeW x nativeH. The window opens at scale times
  ## the native size, or undecorated and fullscreen when `fullscreen` is set.
  let windowSize = ivec2((nativeW * scale).int32, (nativeH * scale).int32)
  let style = if fullscreen: Undecorated else: DecoratedResizable
  let window = newWindow(title, windowSize, style = style, vsync = vsync)
  window.makeContextCurrent()
  loadExtensions()
  if fullscreen:
    window.fullscreen = true
    window.focus()

  # Fullscreen covering quad in NDC with UVs that map pixie top-left (0,0) to (0,1) uv.
  var posData = @[
    vec2(-1f, -1f), vec2(1f, -1f), vec2(1f, 1f),
    vec2(1f, 1f), vec2(-1f, 1f), vec2(-1f, -1f)
  ]
  var uvData = @[
    vec2(0f, 1f), vec2(1f, 1f), vec2(1f, 0f),
    vec2(1f, 0f), vec2(0f, 0f), vec2(0f, 1f)
  ]
  var posBuffer: GLuint
  glGenBuffers(1, addr posBuffer)
  glBindBuffer(GL_ARRAY_BUFFER, posBuffer)
  glBufferData(GL_ARRAY_BUFFER, posData.len * 4 * 2, posData[0].addr, GL_STATIC_DRAW)
  var uvBuffer: GLuint
  glGenBuffers(1, addr uvBuffer)
  glBindBuffer(GL_ARRAY_BUFFER, uvBuffer)
  glBufferData(GL_ARRAY_BUFFER, uvData.len * 4 * 2, uvData[0].addr, GL_STATIC_DRAW)

  let vertShader = compileShader(GL_VERTEX_SHADER, VertSrc)
  let fragShader = compileShader(GL_FRAGMENT_SHADER, FragSrc)
  let program = glCreateProgram()
  glAttachShader(program, vertShader)
  glAttachShader(program, fragShader)
  glBindAttribLocation(program, 0, "vertexPos")
  glBindAttribLocation(program, 1, "vertexUv")
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
  var initImage = newImage(nativeW, nativeH)
  initImage.fill(rgbx(0, 0, 0, 255))
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint,
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
    posBuffer: posBuffer,
    uvBuffer: uvBuffer,
    nativeW: nativeW,
    nativeH: nativeH
  )

proc upload*(blit: GlBlit, img: Image) =
  ## Copy the frame image into the texture (same size as the native frame).
  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glTexSubImage2D(
    GL_TEXTURE_2D, 0, 0, 0,
    img.width.GLsizei, img.height.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](img.data[0].addr)
  )

proc draw*(blit: GlBlit) =
  ## Clear the window and draw the texture at the largest integer multiple of
  ## the native size that fits, centred, with black around it. The caller
  ## swaps buffers.
  let winW = blit.window.size.x
  let winH = blit.window.size.y
  let k = max(1'i32, min(winW div blit.nativeW.int32, winH div blit.nativeH.int32))
  let vpW = blit.nativeW.int32 * k
  let vpH = blit.nativeH.int32 * k
  let vpX = (winW - vpW) div 2
  let vpY = (winH - vpH) div 2

  glClearColor(0.0, 0.0, 0.0, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)
  glViewport(vpX, vpY, vpW, vpH)

  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glBindBuffer(GL_ARRAY_BUFFER, blit.posBuffer)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(0)
  glBindBuffer(GL_ARRAY_BUFFER, blit.uvBuffer)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(1)
  glDrawArrays(GL_TRIANGLES, 0, 6)

proc blit*(blit: GlBlit, img: Image) =
  ## Upload, draw and present one frame.
  blit.upload(img)
  blit.draw()
  blit.window.swapBuffers()
