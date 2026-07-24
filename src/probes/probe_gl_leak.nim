## Headless GL texture-upload leak isolator. Creates a SURFACELESS EGL context
## (a real GL driver, NO window, NO display server) and runs the exact texture
## pattern play.nim uses each frame, measuring RssAnon (/proc) growth.
##
## play.nim uploads the 256x224 RGBA framebuffer every frame with glTexImage2D,
## which *reallocates* the texture storage each call. On a software/Mesa driver
## that realloc churn can accumulate in RssAnon — invisible to any Nim-heap probe.
## This reproduces it with zero windows so we can pin (and A/B a fix) automatically.
##
## Usage: nim r src/probes/probe_gl_leak.nim [sub] [frames=N]
##   default   glTexImage2D every frame (current play.nim behavior — the suspect).
##   sub       glTexImage2D ONCE to allocate, then glTexSubImage2D each frame
##             (the proposed fix — reuse storage). Compare RssAnon between the two.

import std/[os, strformat, strutils]

# --- Minimal EGL FFI (libEGL via libglvnd) -----------------------------------
type
  EGLDisplay = pointer
  EGLConfig = pointer
  EGLContext = pointer
  EGLSurface = pointer
  EGLint = int32
  EGLenum = uint32

const
  EGL_PLATFORM_SURFACELESS_MESA = 0x31DD'u32
  EGL_NO_CONTEXT = cast[EGLContext](0)
  EGL_NO_SURFACE = cast[EGLSurface](0)
  EGL_NO_DISPLAY = cast[EGLDisplay](0)
  EGL_OPENGL_API = 0x30A2'u32
  EGL_OPENGL_BIT = 0x0008'i32
  EGL_RENDERABLE_TYPE = 0x3040'i32
  EGL_SURFACE_TYPE = 0x3033'i32
  EGL_PBUFFER_BIT = 0x0001'i32
  EGL_NONE = 0x3038'i32

{.push dynlib: "libEGL.so.1", importc.}
proc eglGetPlatformDisplay(platform: EGLenum, native: pointer, attrib: ptr EGLint): EGLDisplay
proc eglInitialize(dpy: EGLDisplay, major, minor: ptr EGLint): uint32
proc eglChooseConfig(dpy: EGLDisplay, attribs: ptr EGLint, configs: ptr EGLConfig,
                     configSize: EGLint, numConfig: ptr EGLint): uint32
proc eglBindAPI(api: EGLenum): uint32
proc eglCreateContext(dpy: EGLDisplay, cfg: EGLConfig, share: EGLContext,
                      attribs: ptr EGLint): EGLContext
proc eglMakeCurrent(dpy: EGLDisplay, draw, read: EGLSurface, ctx: EGLContext): uint32
proc eglGetError(): EGLint
{.pop.}

# --- Minimal GL FFI (only what the upload path touches) ----------------------
const
  GL_TEXTURE_2D = 0x0DE1'u32
  GL_RGBA8 = 0x8058'i32
  GL_RGBA = 0x1908'u32
  GL_UNSIGNED_BYTE = 0x1401'u32
  GL_NO_ERROR = 0'u32

{.push dynlib: "libGL.so.1", importc.}
proc glGenTextures(n: int32, tex: ptr uint32)
proc glBindTexture(target: uint32, tex: uint32)
proc glTexImage2D(target: uint32, level, internalFormat, w, h, border: int32,
                  format, typ: uint32, data: pointer)
proc glTexSubImage2D(target: uint32, level, xoff, yoff, w, h: int32,
                     format, typ: uint32, data: pointer)
proc glGetError(): uint32
proc glFinish()
{.pop.}

const
  TexW = 256
  TexH = 224

proc readRssAnonKb(): int =
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith("RssAnon:"):
        for tok in line.splitWhitespace():
          if tok.len > 0 and tok[0].isDigit:
            return parseInt(tok)
  except CatchableError:
    discard
  -1

proc main() =
  let useSub = "sub" in commandLineParams()
  var frames = 3600
  for p in commandLineParams():
    if p.startsWith("frames="):
      frames = parseInt(p["frames=".len .. ^1])

  # Surfaceless display — no window system involved at all.
  let dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, nil, nil)
  if dpy == EGL_NO_DISPLAY:
    echo "eglGetPlatformDisplay(SURFACELESS) failed — no headless GL driver here; skipping."
    quit(0)
  var major, minor: EGLint
  if eglInitialize(dpy, addr major, addr minor) == 0:
    echo "eglInitialize failed (err ", eglGetError(), ") — skipping."
    quit(0)
  discard eglBindAPI(EGL_OPENGL_API)

  var cfgAttribs = [
    EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
    EGL_NONE]
  var config: EGLConfig
  var numConfig: EGLint
  if eglChooseConfig(dpy, addr cfgAttribs[0], addr config, 1, addr numConfig) == 0 or numConfig < 1:
    echo "eglChooseConfig failed (err ", eglGetError(), ") — skipping."
    quit(0)
  let ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, nil)
  if ctx == EGL_NO_CONTEXT:
    echo "eglCreateContext failed (err ", eglGetError(), ") — skipping."
    quit(0)
  # Surfaceless make-current (EGL_KHR_surfaceless_context, Mesa supports it).
  if eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx) == 0:
    echo "eglMakeCurrent(surfaceless) failed (err ", eglGetError(), ") — skipping."
    quit(0)

  echo &"surfaceless EGL {major}.{minor} context OK; mode={(if useSub: \"glTexSubImage2D reuse (FIX)\" else: \"glTexImage2D realloc (SUSPECT)\")} frames={frames}"

  var texId: uint32
  glGenTextures(1, addr texId)
  glBindTexture(GL_TEXTURE_2D, texId)

  # The per-frame framebuffer, exactly like play.nim's frameImage.data.
  var pixels = newSeq[uint8](TexW * TexH * 4)
  for i in 0 ..< pixels.len: pixels[i] = (i and 0xFF).uint8

  if useSub:
    # Allocate storage once; then only sub-update it each frame.
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TexW, TexH, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)

  proc uploadFrame() =
    if useSub:
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, TexW, TexH, GL_RGBA, GL_UNSIGNED_BYTE, addr pixels[0])
    else:
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TexW, TexH, 0, GL_RGBA, GL_UNSIGNED_BYTE, addr pixels[0])
    glFinish()  # force the driver to actually process the upload this frame

  for i in 0 ..< 120:  # warmup — let the driver reach steady state
    uploadFrame()
  let err = glGetError()
  if err != GL_NO_ERROR:
    echo "warning: glGetError=0x", err.toHex(4), " after warmup"

  let heapBefore = getOccupiedMem()
  let rssBefore = readRssAnonKb()
  for i in 0 ..< frames:
    uploadFrame()
    if (i + 1) mod 600 == 0:
      echo &"  frame {i+1}: heap={getOccupiedMem() div 1024} KB rssAnon={readRssAnonKb()} KB"
  let heapAfter = getOccupiedMem()
  let rssAfter = readRssAnonKb()

  echo ""
  echo &"NIM-HEAP: {(heapAfter - heapBefore) div 1024} KB over {frames} frames = {(heapAfter - heapBefore) div frames} B/frame"
  if rssBefore >= 0 and rssAfter >= 0:
    echo &"RSS-ANON: {rssAfter - rssBefore} KB over {frames} frames = {(rssAfter - rssBefore) * 1024 div frames} B/frame"
    echo "  ^ per-frame glTexImage2D vs glTexSubImage2D: if 'realloc' leaks and 'reuse' is flat, that's the live leak + its fix."

main()
