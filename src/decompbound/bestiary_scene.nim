import
  pixie,
  ./[bestiary, bestiary_browser, battle_bg]

type
  BestiaryScene* = ref object
    image*: Image
    background: BattleBg
    workspace: BackgroundWorkspace
    portrait: Image
    enemyId, groupId: int
    renderedFrame: int64

proc newBestiaryScene*(): BestiaryScene =
  ## Allocate a native scene whose decoded assets and frame buffers are reused.
  BestiaryScene(image: newImage(ScreenW, ScreenH), enemyId: -1,
    groupId: -1, renderedFrame: -1)

proc composePortrait*(image: Image, portrait: Image) =
  ## Center a binary-alpha battle portrait at its original pixel size over the background.
  if image == nil: raise newException(ValueError, "Missing scene image.")
  if portrait == nil: return
  if portrait.width > image.width or portrait.height > image.height:
    raise newException(ValueError, "Portrait does not fit the native scene.")
  let
    originX = (image.width - portrait.width) div 2
    originY = (image.height - portrait.height) div 2
  for y in 0 ..< portrait.height:
    for x in 0 ..< portrait.width:
      let pixel = portrait.data[y * portrait.width + x]
      if pixel.a != 0:
        image.data[(originY + y) * image.width + originX + x] = pixel

proc render*(scene: BestiaryScene, browser: BestiaryBrowser): Image =
  ## Update selected assets only when needed and produce a deterministic combined frame.
  let
    enemyId = if browser.hasSelection: browser.currentEnemy.id else: 0
    variants = browser.variants
    groupId = if variants.len > 0: variants[browser.variantIndex].groupIds[0] else: -1
  if scene.enemyId != enemyId or scene.groupId != groupId:
    scene.enemyId = enemyId
    scene.groupId = groupId
    scene.portrait = if enemyId > 0: browser.library.portrait(enemyId).image else: nil
    scene.background = if groupId >= 0: loadBattleBg(browser.library.catalog.rom, groupId) else: BattleBg()
    scene.renderedFrame = -1
  if scene.renderedFrame != browser.frame:
    renderInto(scene.background, browser.frame.int, scene.image, scene.workspace)
    scene.image.composePortrait(scene.portrait)
    scene.renderedFrame = browser.frame
  scene.image
