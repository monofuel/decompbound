## The `snesAsm` macro — readable labeled 65816 assembly as Nim (docs/goal-1.5.md).
##
## Sugar only: it lowers a block of terse instruction statements to the exact
## same `AsmNode` list + `assemble()` machinery Goal 1 verified, so it adds ZERO
## new verification surface. Each adopted region still round-trips byte-exact
## against gold (`tests/test_regions.nim`), which is what makes adoption
## un-fakeable. See `src/decompbound/sram_piracy.nim` for a worked region.
##
## Grammar (incremental — extend the marker/immediate tables as regions need
## more modes; every addition is gold-gated):
##   pla                      -> implied
##   inc a                    -> accumulator
##   lda SramProbePattern     -> immediate (width from the mnemonic: M / X / 8)
##   sta long SramProbeA      -> absolute-long   (markers: long/longx/abs/absx/
##                                                 absy/dp/dpx/dpy)
##   beq "labelName"          -> relative branch to a label (string operand)
##   label "labelName"        -> label definition (passthrough to assembler)
##   flagHint true, false     -> explicit m8/x8 flag state (passthrough)
##
## Operand expressions (`SramProbeA`, `0x30`, `Foo or Bar`) are passed straight
## through to `instr()`, so any compile-time Nim const/expression works and the
## macro never needs to know the value.

import
  std/[macros, strutils, tables],
  ./[assembler, opcodes]

export assembler, opcodes

const
  NativeFlags16* = FlagState(m8: false, x8: false, emulation: false)
    ## Native mode, 16-bit A/X/Y (M and X clear) — the common routine entry.
  # Immediate width is chosen by mnemonic (the operand carries no width marker).
  # TODO: this is the SNES immediate-mode split; keep in sync with opcodes.nim.
  Imm8Mnemonics = ["SEP", "REP", "BRK", "COP", "WDM"]
  ImmXMnemonics = ["LDX", "LDY", "CPX", "CPY"]
  # 65816 mnemonics that collide with Nim keywords need a DSL alias. AND is the
  # only real 65816/Nim clash; alias it `andOp`. TODO: extend if more surface.
  MnemonicAliases = {"andop": "AND"}.toTable
  # Addressing-mode markers -> AddressingMode enum symbol emitted into instr().
  ModeMarkers = {
    "long":   "amAbsoluteLong",
    "longx":  "amAbsoluteLongX",
    "abs":    "amAbsolute",
    "absx":   "amAbsoluteX",
    "absy":   "amAbsoluteY",
    "dp":     "amDirectPage",
    "dpx":    "amDirectPageX",
    "dpy":    "amDirectPageY",
    "dpil":   "amDpIndirectLong",     # [$dp]
    "dpily":  "amDpIndirectLongY",    # [$dp],Y
    "dpind":  "amDpIndirect",         # ($dp)
    "dpindx": "amDpIndirectX",        # ($dp,X)
    "dpindy": "amDpIndirectY",        # ($dp),Y
    "sr":     "amStackRelative",      # $sr,S
    "sry":    "amStackRelativeY",     # ($sr,S),Y
    "absind": "amAbsIndirect",        # ($abs)
  }.toTable

proc immMode(mnemonic: string): string =
  ## AddressingMode symbol for a bare (immediate) operand, per mnemonic width.
  if mnemonic in Imm8Mnemonics: "amImmediate8"
  elif mnemonic in ImmXMnemonics: "amImmediateX"
  else: "amImmediateM"

proc lowerStatement(stmt: NimNode): NimNode =
  ## Lower one DSL statement to an `AsmNode`-building expression.
  # Bare mnemonic (`pla`) -> implied.
  if stmt.kind == nnkIdent:
    let mne = ($stmt).toUpperAscii
    return newCall(bindSym"instr", newLit(mne), ident"amImplied")

  if stmt.kind notin {nnkCommand, nnkCall}:
    error("snesAsm: unexpected statement " & stmt.repr, stmt)

  let head = stmt[0]
  if head.kind != nnkIdent:
    error("snesAsm: expected a mnemonic/directive identifier", stmt)
  let word = ($head).toLowerAscii

  # Directives pass straight through to the assembler procs.
  if word == "label":
    return newCall(bindSym"label", stmt[1])
  if word == "flaghint":
    return newCall(bindSym"flagHint", stmt[1], stmt[2])

  # Otherwise it is an instruction: mnemonic + exactly one operand form.
  let mne = if word in MnemonicAliases: MnemonicAliases[word]
            else: ($head).toUpperAscii
  if stmt.len != 2:
    error("snesAsm: `" & word & "` takes one operand form", stmt)
  let operand = stmt[1]

  # Accumulator: `inc a`.
  if operand.kind == nnkIdent and ($operand).toLowerAscii == "a":
    return newCall(bindSym"instr", newLit(mne), ident"amAccumulator")

  # Label target: relative branches by default; JSR/JMP resolve absolute
  # (low 16 bits), JSL/JML absolute-long, BRL/PER relative-16. Needed by
  # routines that JSR to a local helper (e.g. APU IPL reboot at $C0ABA8).
  if operand.kind == nnkStrLit:
    let mode =
      case mne
      of "JSR", "JMP": "amAbsolute"
      of "JSL", "JML": "amAbsoluteLong"
      of "BRL", "PER": "amRelative16"
      else: "amRelative8"
    return newCall(bindSym"instrTo", newLit(mne), ident(mode), operand)

  # Marked mode: `sta long SramProbeA`.
  if operand.kind in {nnkCommand, nnkCall} and operand[0].kind == nnkIdent:
    let marker = ($operand[0]).toLowerAscii
    if marker in ModeMarkers:
      return newCall(bindSym"instr", newLit(mne),
                     ident(ModeMarkers[marker]), operand[1])

  # Bare operand: immediate (width from the mnemonic).
  return newCall(bindSym"instr", newLit(mne), ident(immMode(mne)), operand)

macro snesAsm*(origin, entry, body: untyped): untyped =
  ## Assemble a labeled-assembly block to `seq[uint8]` via the verified
  ## `assemble()` path. `origin` is the first byte's address (labels/branches);
  ## `entry` is the entry `FlagState`. Returns the assembled bytes.
  body.expectKind(nnkStmtList)
  let nodes = genSym(nskVar, "snesAsmNodes")
  result = newStmtList()
  result.add newVarStmt(nodes, newCall(newTree(nnkBracketExpr,
    bindSym"newSeq", bindSym"AsmNode")))
  for stmt in body:
    result.add newCall(newDotExpr(nodes, ident"add"), lowerStatement(stmt))
  result.add newCall(bindSym"assemble", nodes, origin, entry)
  result = newTree(nnkBlockStmt, newEmptyNode(), result)
