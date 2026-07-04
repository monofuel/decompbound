## Central registry of implemented ROM regions.
## The ROM builder and the compare harness both derive from this list, so
## coverage claims and generated output can never drift apart.
##
## Region boundaries follow the control-flow tracer's natural code regions
## (src/tools/full_disasm.nim), not arbitrary cuts. Adding a new region is:
## generate a module with tools/gen_source.nim, then add one entry here.

import
  ./[boot, common, early, header, init, subroutine_a156, vectors],
  ./[code_000000, code_00023F, code_000A30, code_000EA5, code_000EDA,
     code_000EE6, code_000FCB]

type
  RomRegion* = object
    name*: string
    offset*: int
    data*: seq[uint8]

proc allRegions*(): seq[RomRegion] =
  ## Build every implemented region: code assembled from disassembled
  ## mnemonics, plus the header and vector data declarations.
  @[
    RomRegion(name: "header", offset: HiRomHeaderOffset,
              data: generateEarthboundHeader()),
    RomRegion(name: "resetVectors", offset: ResetVectorOffset,
              data: generateResetVectors()),
    RomRegion(name: "code000000", offset: 0x000000,
              data: generateCode000000()),
    RomRegion(name: "code00023F", offset: 0x00023F,
              data: generateCode00023F()),
    RomRegion(name: "earlyCode", offset: 0x000391,
              data: generateEarlyCode()),
    RomRegion(name: "code000A30", offset: 0x000A30,
              data: generateCode000A30()),
    RomRegion(name: "code000EA5", offset: 0x000EA5,
              data: generateCode000EA5()),
    RomRegion(name: "code000EDA", offset: 0x000EDA,
              data: generateCode000EDA()),
    RomRegion(name: "code000EE6", offset: 0x000EE6,
              data: generateCode000EE6()),
    RomRegion(name: "code000FCB", offset: 0x000FCB,
              data: generateCode000FCB()),
    RomRegion(name: "bootCode", offset: 0x008000,
              data: generateBootCode()),
    RomRegion(name: "subroutineA156", offset: 0x00A156,
              data: generateSubroutineA156()),
    RomRegion(name: "initCode", offset: 0x010000,
              data: generateInitCode())
  ]
