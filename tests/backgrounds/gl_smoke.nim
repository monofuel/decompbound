import
  pixie, windy, opengl,
  ../../src/tools/glblit

proc main() =
  ## Check two independent GL contexts and exact integer crop pixels using authored art.
  var
    controls = initGlBlit("Synthetic controls", 4, 4, scale = 3, vsync = false)
    preview = initGlBlit("Synthetic preview", 4, 4, scale = 3, vsync = false)
  defer: controls.close()
  defer: preview.close()
  let image = newImage(4, 4)
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      image[x, y] = ColorRGBA(r: uint8(x * 50), g: uint8(y * 50), b: 200, a: 255)
  for size in [ivec2(9, 7), ivec2(20, 5), ivec2(2, 2)]:
    preview.window.size = size
    pollEvents()
    controls.blit(newImage(4, 4))
    preview.upload(image)
    preview.draw(cover = true)
    let
      dimensions = preview.window.framebufferSize
      viewport = integerCover(dimensions.x.int, dimensions.y.int, 4, 4)
      scale = viewport.width div 4
    var pixels = newSeq[ColorRGBA](dimensions.x.int * dimensions.y.int)
    glReadPixels(0, 0, dimensions.x.GLsizei, dimensions.y.GLsizei, GL_RGBA,
      GL_UNSIGNED_BYTE, addr pixels[0])
    for y in 0 ..< dimensions.y.int:
      for x in 0 ..< dimensions.x.int:
        let
          sourceX = (x - viewport.x) div scale
          sourceY = (viewport.y + viewport.height - 1 - y) div scale
          expected = image[sourceX, sourceY]
        doAssert pixels[y * dimensions.x.int + x] == expected
    doAssert glGetError() == GL_NO_ERROR
  preview.close()
  pollEvents()
  preview = initGlBlit("Synthetic reopened preview", 4, 4, scale = 3, vsync = false)
  controls.blit(image)
  preview.blit(image, cover = true)
  doAssert glGetError() == GL_NO_ERROR

when isMainModule: main()
