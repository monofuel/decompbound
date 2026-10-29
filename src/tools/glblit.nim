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
  BlitViewport* = object
    ## A physical framebuffer viewport, including centered cropping offsets.
    x*, y*, width*, height*: int
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
  glDeleteShader(vertShader)
  glDeleteShader(fragShader)
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

proc ensureFullscreen*(blit: GlBlit) =
  ## Ask for fullscreen again. A request sent before the compositor has mapped
  ## the surface can land in _NET_WM_STATE without ever being applied (labwc
  ## over Xwayland on gammapi left the window at 320x204 under the panel), so
  ## the player repeats it a few frames after the first swap.
  blit.window.fullscreen = true

proc resize*(blit: var GlBlit, width, height: int) =
  ## Reallocate the texture when a responsive viewer changes its canvas dimensions.
  if width <= 0 or height <= 0:
    raise newException(ValueError, "Blit dimensions must be positive.")
  if width == blit.nativeW and height == blit.nativeH: return
  blit.window.makeContextCurrent()
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA.GLint, width.GLsizei, height.GLsizei,
    0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  blit.nativeW = width
  blit.nativeH = height

proc upload*(blit: GlBlit, img: Image) =
  ## Copy the frame image into the texture (same size as the native frame).
  blit.window.makeContextCurrent()
  glUseProgram(blit.program)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glTexSubImage2D(
    GL_TEXTURE_2D, 0, 0, 0,
    img.width.GLsizei, img.height.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, cast[pointer](img.data[0].addr)
  )

proc integerCover*(width, height, nativeW, nativeH: int): BlitViewport =
  ## Cover a framebuffer at the smallest whole-pixel scale and crop the overflow.
  if nativeW <= 0 or nativeH <= 0:
    raise newException(ValueError, "Native image dimensions must be positive.")
  if width <= 0 or height <= 0: return
  let
    scale = max(1, max((width + nativeW - 1) div nativeW,
      (height + nativeH - 1) div nativeH))
    fittedW = nativeW * scale
    fittedH = nativeH * scale
  BlitViewport(x: (width - fittedW) div 2, y: (height - fittedH) div 2,
    width: fittedW, height: fittedH)

proc draw*(blit: GlBlit, cover = false) =
  ## Draw in this window's own context, optionally using integer crop-to-fill.
  blit.window.makeContextCurrent()
  glUseProgram(blit.program)
  glActiveTexture(GL_TEXTURE0)
  let size = if cover: blit.window.framebufferSize else: blit.window.size
  let winW = size.x
  let winH = size.y
  let scale = min(winW.float / blit.nativeW.float, winH.float / blit.nativeH.float)
  let fittedScale = if scale >= 1: scale.int.float else: scale
  let vpW = max(1'i32, (blit.nativeW.float * fittedScale).int32)
  let vpH = max(1'i32, (blit.nativeH.float * fittedScale).int32)
  let vpX = (winW - vpW) div 2
  let vpY = (winH - vpH) div 2

  glClearColor(0.0, 0.0, 0.0, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)
  if cover:
    let viewport = integerCover(winW.int, winH.int, blit.nativeW, blit.nativeH)
    glViewport(viewport.x.GLint, viewport.y.GLint, viewport.width.GLsizei,
      viewport.height.GLsizei)
  else:
    glViewport(vpX, vpY, vpW, vpH)

  glBindTexture(GL_TEXTURE_2D, blit.textureId)
  glBindBuffer(GL_ARRAY_BUFFER, blit.posBuffer)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(0)
  glBindBuffer(GL_ARRAY_BUFFER, blit.uvBuffer)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 2 * 4, nil)
  glEnableVertexAttribArray(1)
  glDrawArrays(GL_TRIANGLES, 0, 6)

proc blit*(blit: GlBlit, img: Image, cover = false) =
  ## Upload, draw and present one frame.
  blit.upload(img)
  blit.draw(cover)
  blit.window.swapBuffers()

proc close*(blit: GlBlit) =
  ## Delete resources in their owning context before closing the window.
  if blit.window == nil or blit.window.closed: return
  blit.window.makeContextCurrent()
  glDeleteBuffers(1, unsafeAddr blit.posBuffer)
  glDeleteBuffers(1, unsafeAddr blit.uvBuffer)
  glDeleteTextures(1, unsafeAddr blit.textureId)
  glDeleteProgram(blit.program)
  blit.window.close()
