## Hand-curated ROM regions assembled from committed ca65 `.asm` under `asm/`.
## Phase-2 M5: evidence-bearing source is assembly text, not the Nim snesAsm DSL.

import
  std/[os, strformat],
  ./[asm_parse, assembler, common, opcodes]

const
  AsmRoot* = "asm"

type
  AdoptedSpec = object
    name: string
    offset: int
    isData: bool

const
  AdoptedSpecs: seq[AdoptedSpec] = @[
    AdoptedSpec(name: "clearServiceSuppression", offset: 0x03E4CA),
    AdoptedSpec(name: "setServiceSuppression", offset: 0x03E4D4),
    AdoptedSpec(name: "sramMirrorPiracyCheck", offset: 0x00A11C),
    AdoptedSpec(name: "earthboundRandom", offset: 0x008E9A),
    AdoptedSpec(name: "uploadApuPackages", offset: 0x00AB06),
    AdoptedSpec(name: "requestCgramDma", offset: 0x00856B),
    AdoptedSpec(name: "writeApuPort0", offset: 0x00ABBD),
    AdoptedSpec(name: "writeApuPort3Cmd57", offset: 0x00AC01),
    AdoptedSpec(name: "writeApuPort1Toggled", offset: 0x00AC0C),
    AdoptedSpec(name: "loadSong", offset: 0x04FBBD),
    AdoptedSpec(name: "queueApuCommand", offset: 0x00ABE0),
    AdoptedSpec(name: "waitApuIdleClearSong", offset: 0x00ABC6),
    AdoptedSpec(name: "readApuPort0", offset: 0x00AC20),
    AdoptedSpec(name: "setBgMode", offset: 0x008D79),
    AdoptedSpec(name: "setObjBase", offset: 0x008D92),
    AdoptedSpec(name: "setBg1Bases", offset: 0x008D9E),
    AdoptedSpec(name: "setBg2Bases", offset: 0x008DDE),
    AdoptedSpec(name: "setBg3Bases", offset: 0x008E1C),
    AdoptedSpec(name: "setBg4Bases", offset: 0x008E5C),
    AdoptedSpec(name: "clearWramBlock280C", offset: 0x000000),
    AdoptedSpec(name: "applyColorMathPreset", offset: 0x00AFCD),
    AdoptedSpec(name: "setFixedColorRgb", offset: 0x00B01A),
    AdoptedSpec(name: "writeColorMathRegs", offset: 0x00B039),
    AdoptedSpec(name: "configurePpuWindows", offset: 0x00B047),
    AdoptedSpec(name: "resetWindowPositions", offset: 0x00B0AA),
    AdoptedSpec(name: "flushBg3Vofs", offset: 0x00AD9F),
    AdoptedSpec(name: "mode7MulBySine", offset: 0x00B400),
    AdoptedSpec(name: "clearHdmaEnableBit", offset: 0x00AE34),
    AdoptedSpec(name: "setupHdmaChannelWh0", offset: 0x00B0B8),
    AdoptedSpec(name: "hardwareMultiply", offset: 0x008FF7),
    AdoptedSpec(name: "hardwareMultiply16", offset: 0x009032),
    AdoptedSpec(name: "setupHdmaChannelBgScroll", offset: 0x00ADB2),
    AdoptedSpec(name: "pollJoypads", offset: 0x008496),
    AdoptedSpec(name: "actionScriptFetch", offset: 0x009506),
    AdoptedSpec(name: "actionScriptDispatchTable", offset: 0x009558, isData: true),
    AdoptedSpec(name: "jmpTable8C65", offset: 0x008C65, isData: true),
    AdoptedSpec(name: "jmpTableA1AE", offset: 0x00A1AE, isData: true),
    AdoptedSpec(name: "jmpTableA350", offset: 0x00A350, isData: true),
  ]

  ## Public offsets retained for tests/tools (was snes_src consts).
  RngAdvanceOffset* = 0x008E9A
  ActionScriptFetchOffset* = 0x009506
  SramPiracyCheckOffset* = 0x00A11C

proc asmPath*(name: string): string =
  ## Path to a committed adopted assembly file.
  AsmRoot / (name & ".asm")

proc assembleAdoptedFile*(name: string, offset: int): seq[uint8] =
  ## Parse and assemble one adopted `.asm` at its ROM file origin.
  let path = asmPath(name)
  if not fileExists(path):
    raise newException(IOError, &"missing adopted asm: {path}")
  result = assembleAsm(readFile(path), offset.uint32, NativeFlags16)

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
