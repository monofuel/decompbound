## Hand-curated ROM regions assembled from committed 65816/SPC700 source under `asm/`.
## Phase-2 M5: evidence-bearing source is assembly text, not the Nim snesAsm DSL.

import
  std/[os, strformat, strutils],
  ./[asm_parse, assembler, common, opcodes, spc_asm]

const
  AsmRoot* = "asm"

type
  AdoptedSpec = object
    name: string
    offset: int
    isData: bool
    isSpc: bool

const
  AdoptedSpecs: seq[AdoptedSpec] = @[
    AdoptedSpec(name: "clearWramBlock280C", offset: 0x000000),
    AdoptedSpec(name: "readWorldMapArrangementTile", offset: 0x00035B),
    AdoptedSpec(name: "readWorldMapRegionAttributes", offset: 0x000AA1),
    AdoptedSpec(name: "initializeSpriteDefinitionPool", offset: 0x001A86),
    AdoptedSpec(name: "findSpriteDefinitionSpace", offset: 0x001A9D),
    AdoptedSpec(name: "releaseSpriteDefinitions", offset: 0x001B15),
    AdoptedSpec(name: "allocateSpriteSlots", offset: 0x001B96),
    AdoptedSpec(name: "replaceSpriteSlotTags", offset: 0x001C11),
    AdoptedSpec(name: "allocateAndClearSpriteTiles", offset: 0x001C52),
    AdoptedSpec(name: "buildSpriteDefinitions", offset: 0x001D38),
    AdoptedSpec(name: "readSpriteResourceHeader", offset: 0x001DED),
    AdoptedSpec(name: "spawnSpriteEntity", offset: 0x001E49),
    AdoptedSpec(name: "releaseCurrentSpriteGraphics", offset: 0x0020F1),
    AdoptedSpec(name: "removeSpriteEntity", offset: 0x002140),
    AdoptedSpec(name: "pollJoypads", offset: 0x008496),
    AdoptedSpec(name: "requestCgramDma", offset: 0x00856B),
    AdoptedSpec(name: "requestVramDma", offset: 0x008643),
    AdoptedSpec(name: "initializeOamBuild", offset: 0x0088B1),
    AdoptedSpec(name: "publishOamBuild", offset: 0x008B26),
    AdoptedSpec(name: "drainOamQueues", offset: 0x008B8E),
    AdoptedSpec(name: "enqueueOamDefinition", offset: 0x008C54),
    AdoptedSpec(name: "jmpTable8C65", offset: 0x008C65, isData: true),
    AdoptedSpec(name: "appendOamQueues", offset: 0x008C6D),
    AdoptedSpec(name: "emitSpriteElements", offset: 0x008CD5),
    AdoptedSpec(name: "setBgMode", offset: 0x008D79),
    AdoptedSpec(name: "setObjBase", offset: 0x008D92),
    AdoptedSpec(name: "setBg1Bases", offset: 0x008D9E),
    AdoptedSpec(name: "setBg2Bases", offset: 0x008DDE),
    AdoptedSpec(name: "setBg3Bases", offset: 0x008E1C),
    AdoptedSpec(name: "setBg4Bases", offset: 0x008E5C),
    AdoptedSpec(name: "earthboundRandom", offset: 0x008E9A),
    AdoptedSpec(name: "hardwareMultiply", offset: 0x008FF7),
    AdoptedSpec(name: "hardwareMultiply16", offset: 0x009032),
    AdoptedSpec(name: "initializeEntitySystem", offset: 0x009282),
    AdoptedSpec(name: "createEntityDefaults", offset: 0x0092F5),
    AdoptedSpec(name: "createEntity", offset: 0x009321),
    AdoptedSpec(name: "pauseEntityScripts", offset: 0x00943C),
    AdoptedSpec(name: "resumeEntityScripts", offset: 0x009451),
    AdoptedSpec(name: "scheduleEntities", offset: 0x009466),
    AdoptedSpec(name: "actionScriptFetch", offset: 0x009506),
    AdoptedSpec(name: "actionScriptDispatchTable", offset: 0x009558, isData: true),
    AdoptedSpec(name: "actionScriptRemoveEntity", offset: 0x0095F2),
    AdoptedSpec(name: "actionScriptCountedLoop", offset: 0x009603),
    AdoptedSpec(name: "actionScriptControlFlow", offset: 0x009649),
    AdoptedSpec(name: "actionScriptFarCall", offset: 0x009685),
    AdoptedSpec(name: "actionScriptWait", offset: 0x0096C3),
    AdoptedSpec(name: "actionScriptSetFrame", offset: 0x0096CF),
    AdoptedSpec(name: "actionScriptSetXStep", offset: 0x009713),
    AdoptedSpec(name: "actionScriptSetYStep", offset: 0x009731),
    AdoptedSpec(name: "actionScriptSetElevationStep", offset: 0x00974F),
    AdoptedSpec(name: "actionScriptAddXStep", offset: 0x00976D),
    AdoptedSpec(name: "actionScriptAddYStep", offset: 0x009792),
    AdoptedSpec(name: "actionScriptAddElevationStep", offset: 0x0097B7),
    AdoptedSpec(name: "actionScriptNativeCall", offset: 0x00993D),
    AdoptedSpec(name: "actionScriptBranchIfZero", offset: 0x00995D),
    AdoptedSpec(name: "actionScriptBranchIfNonzero", offset: 0x00996B),
    AdoptedSpec(name: "actionScriptSwitch", offset: 0x009979),
    AdoptedSpec(name: "actionScriptDetachState", offset: 0x0099C3),
    AdoptedSpec(name: "actionScriptByteOperation", offset: 0x009A5C),
    AdoptedSpec(name: "actionScriptWordOperation", offset: 0x009A87),
    AdoptedSpec(name: "actionScriptOperationTable", offset: 0x009ABD, isData: true),
    AdoptedSpec(name: "actionScriptOperations", offset: 0x009AC5),
    AdoptedSpec(name: "actionScriptSetFieldValue", offset: 0x009AE2),
    AdoptedSpec(name: "actionScriptFieldTable", offset: 0x009AF9, isData: true),
    AdoptedSpec(name: "actionScriptSetGraphics", offset: 0x009B4D),
    AdoptedSpec(name: "actionScriptSetRenderCallback", offset: 0x009BE4),
    AdoptedSpec(name: "allocateEntity", offset: 0x009C02),
    AdoptedSpec(name: "entityListLifecycle", offset: 0x009C35),
    AdoptedSpec(name: "allocateScriptState", offset: 0x009D03),
    AdoptedSpec(name: "detachScriptState", offset: 0x009D12),
    AdoptedSpec(name: "callEntityNativeTarget", offset: 0x009D9E),
    AdoptedSpec(name: "advanceEntityXY", offset: 0x009FC8),
    AdoptedSpec(name: "advanceEntityXYZ", offset: 0x00A00C),
    AdoptedSpec(name: "projectEntityPosition", offset: 0x00A023),
    AdoptedSpec(name: "projectElevatedEntityPosition", offset: 0x00A03A),
    AdoptedSpec(name: "projectEntityAlternatePosition", offset: 0x00A055),
    AdoptedSpec(name: "rebaseEntityPosition", offset: 0x00A06C),
    AdoptedSpec(name: "restoreEntityPositionOrigin", offset: 0x00A089),
    AdoptedSpec(name: "projectAlternateElevatedEntityPosition", offset: 0x00A0A0),
    AdoptedSpec(name: "copyEntityPositionToRender", offset: 0x00A0BB),
    AdoptedSpec(name: "drawEntityById", offset: 0x00A0CA),
    AdoptedSpec(name: "dispatchEntityGraphics", offset: 0x00A0E3),
    AdoptedSpec(name: "enqueueEntityFrame", offset: 0x00A0FA),
    AdoptedSpec(name: "sramMirrorPiracyCheck", offset: 0x00A11C),
    AdoptedSpec(name: "readWorldMapTile", offset: 0x00A152),
    AdoptedSpec(name: "jmpTableA1AE", offset: 0x00A1AE, isData: true),
    AdoptedSpec(name: "readWorldMapTileTail", offset: 0x00A1CE),
    AdoptedSpec(name: "jmpTableA350", offset: 0x00A350, isData: true),
    AdoptedSpec(name: "drawEntityDefault", offset: 0x00A3A4),
    AdoptedSpec(name: "uploadSpriteFrame", offset: 0x00A4C4),
    AdoptedSpec(name: "readSpriteGraphicsEntry", offset: 0x00A53F),
    AdoptedSpec(name: "transferSpriteChunk", offset: 0x00A56E),
    AdoptedSpec(name: "uploadApuPackages", offset: 0x00AB06),
    AdoptedSpec(name: "writeApuPort0", offset: 0x00ABBD),
    AdoptedSpec(name: "waitApuIdleClearSong", offset: 0x00ABC6),
    AdoptedSpec(name: "queueApuCommand", offset: 0x00ABE0),
    AdoptedSpec(name: "writeApuPort3Cmd57", offset: 0x00AC01),
    AdoptedSpec(name: "writeApuPort1Toggled", offset: 0x00AC0C),
    AdoptedSpec(name: "readApuPort0", offset: 0x00AC20),
    AdoptedSpec(name: "enqueueEntityEffects", offset: 0x00AC43),
    AdoptedSpec(name: "advanceEntityEffectSequence", offset: 0x00AD56),
    AdoptedSpec(name: "flushBg3Vofs", offset: 0x00AD9F),
    AdoptedSpec(name: "setupHdmaChannelBgScroll", offset: 0x00ADB2),
    AdoptedSpec(name: "clearHdmaEnableBit", offset: 0x00AE34),
    AdoptedSpec(name: "applyColorMathPreset", offset: 0x00AFCD),
    AdoptedSpec(name: "setFixedColorRgb", offset: 0x00B01A),
    AdoptedSpec(name: "writeColorMathRegs", offset: 0x00B039),
    AdoptedSpec(name: "configurePpuWindows", offset: 0x00B047),
    AdoptedSpec(name: "resetWindowPositions", offset: 0x00B0AA),
    AdoptedSpec(name: "setupHdmaChannelWh0", offset: 0x00B0B8),
    AdoptedSpec(name: "mode7MulBySine", offset: 0x00B400),
    AdoptedSpec(name: "drawEntitiesBySlot", offset: 0x00DA31),
    AdoptedSpec(name: "drawEntitiesByDepth", offset: 0x00DB0F),
    AdoptedSpec(name: "clearServiceSuppression", offset: 0x03E4CA),
    AdoptedSpec(name: "setServiceSuppression", offset: 0x03E4D4),
    AdoptedSpec(name: "loadSong", offset: 0x04FBBD),
    AdoptedSpec(name: "spcInitializeDriverRam", offset: 0x260042, isSpc: true),
    AdoptedSpec(name: "spcAdvancePhase", offset: 0x26010F, isSpc: true),
    AdoptedSpec(name: "spcPitchScale", offset: 0x260250, isSpc: true),
    AdoptedSpec(name: "spcWritePitch", offset: 0x260275, isSpc: true),
    AdoptedSpec(name: "spcWriteDsp", offset: 0x260283, isSpc: true),
    AdoptedSpec(name: "spcTickTempoTransition", offset: 0x260438, isSpc: true),
    AdoptedSpec(name: "spcTickMasterVolumeTransition", offset: 0x260460, isSpc: true),
    AdoptedSpec(name: "spcDispatchCommand", offset: 0x260485, isSpc: true),
    AdoptedSpec(name: "spcSequenceFetch", offset: 0x260497, isSpc: true),
    AdoptedSpec(name: "spcSelectInstrument", offset: 0x2604A1, isSpc: true),
    AdoptedSpec(name: "spcSetPan", offset: 0x2604FA, isSpc: true),
    AdoptedSpec(name: "spcSetPanTransition", offset: 0x260518, isSpc: true),
    AdoptedSpec(name: "spcSetMasterVolume", offset: 0x260566, isSpc: true),
    AdoptedSpec(name: "spcSetMasterVolumeTransition", offset: 0x26056B, isSpc: true),
    AdoptedSpec(name: "spcSetTempo", offset: 0x26057D, isSpc: true),
    AdoptedSpec(name: "spcSetTempoTransition", offset: 0x260582, isSpc: true),
    AdoptedSpec(name: "spcSetChannelVolume", offset: 0x2605C8, isSpc: true),
    AdoptedSpec(name: "spcSetVolumeTransition", offset: 0x2605D1, isSpc: true),
    AdoptedSpec(name: "spcDivideStep", offset: 0x260709, isSpc: true),
    AdoptedSpec(name: "spcTickChannelVolume", offset: 0x260782, isSpc: true),
    AdoptedSpec(name: "spcTickPanTransition", offset: 0x2607BB, isSpc: true),
    AdoptedSpec(name: "spcWriteStereo", offset: 0x2607CE, isSpc: true),
    AdoptedSpec(name: "spcApplyPanStep", offset: 0x260815, isSpc: true),
    AdoptedSpec(name: "spcPreviewPan", offset: 0x260921, isSpc: true),
    AdoptedSpec(name: "spcScaleSignedStep", offset: 0x26096D, isSpc: true),
    AdoptedSpec(name: "spcModulateChannelGain", offset: 0x260998, isSpc: true),
    AdoptedSpec(name: "spcComputeChannelGain", offset: 0x2609A3, isSpc: true),
  ]

  ## Public offsets retained for tests/tools (was snes_src consts).
  RngAdvanceOffset* = 0x008E9A
  ActionScriptFetchOffset* = 0x009506
  SramPiracyCheckOffset* = 0x00A11C

proc asmPath*(name: string): string =
  ## Path to a committed adopted assembly file.
  var suffix = ".asm"
  for spec in AdoptedSpecs:
    if spec.name == name and spec.isSpc:
      suffix = ".spc.asm"
      break
  result = AsmRoot / (name & suffix)

proc assembleAdoptedFile*(name: string, offset: int): seq[uint8] =
  ## Assemble a region using its architecture's CPU origin convention.
  let path = asmPath(name)
  if not fileExists(path):
    raise newException(IOError, &"missing adopted asm: {path}")
  result = if path.endsWith(".spc.asm"): assembleSpcAsm(readFile(path))
    else: assembleAsm(readFile(path), offset.uint32, NativeFlags16)

proc allAdoptedRegions*(): seq[tuple[name: string, offset: int, data: seq[uint8]]] =
  ## Every hand-curated region, assembled from `asm/*.asm`.
  for s in AdoptedSpecs:
    result.add (name: s.name, offset: s.offset,
                data: assembleAdoptedFile(s.name, s.offset))

proc adoptedRanges*(): seq[tuple[start: int, last: int]] =
  ## Inclusive file-offset spans owned by curated modules.
  for r in allAdoptedRegions():
    result.add (start: r.offset, last: r.offset + r.data.len - 1)

proc isAdoptedOffset*(offset: int): bool =
  ## True when a file offset is owned by a curated module.
  for r in adoptedRanges():
    if offset >= r.start and offset <= r.last:
      return true
  result = false

proc earthboundRandom*(): seq[uint8] =
  ## Assembled RNG advance routine (compat for tests).
  assembleAdoptedFile("earthboundRandom", RngAdvanceOffset)

proc actionScriptFetch*(): seq[uint8] =
  ## Assembled action-script fetch loop (compat for tests).
  assembleAdoptedFile("actionScriptFetch", ActionScriptFetchOffset)
