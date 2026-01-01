## SNES assembly macro, converts Nim code into 65816 assembly

import macros, strutils, tables

var labelCounter {.compiletime.}: int = 0

proc err(msg: string, n: NimNode) {.noreturn.} =
  error("[SNES ASM] " & msg, n)

proc nextLabel(): string =
  ## Generate a unique label for control flow.
  inc labelCounter
  result = "label_" & $labelCounter

type
  SnesType = enum
    stUint8
    stInt8
    stUint16
    stInt16
    stBool
    stAddress

proc typeToSnes(t: string): SnesType =
  ## Map Nim types to 65816 types.
  case t:
  of "uint8": stUint8
  of "int8": stInt8
  of "uint16": stUint16
  of "int16": stInt16
  of "bool": stBool
  of "int": stInt16
  of "uint": stUint16
  else:
    err "Unsupported type: " & t, nil

proc getTypeSize(t: SnesType): int =
  ## Get the size in bytes for a type.
  case t:
  of stUint8, stInt8, stBool: 1
  of stUint16, stInt16, stAddress: 2

proc is8Bit(t: SnesType): bool =
  ## Check if type is 8-bit.
  result = t in {stUint8, stInt8, stBool}

proc is16Bit(t: SnesType): bool =
  ## Check if type is 16-bit.
  result = t in {stUint16, stInt16, stAddress}

type
  Register = enum
    regA
    regX
    regY
    regS
    regD
    regP

  AddressingMode = enum
    amImmediate
    amAbsolute
    amDirectPage
    amAbsoluteX
    amAbsoluteY
    amDirectPageX
    amDirectPageY
    amIndirect
    amIndirectX
    amIndirectY

type
  CodeGen = object
    code: string
    variables: Table[string, SnesType]
    labelCounter: int

proc newCodeGen(): CodeGen =
  result.code = ""
  result.variables = initTable[string, SnesType]()
  result.labelCounter = 0

proc addLine(cg: var CodeGen, line: string) =
  ## Add a line of assembly code.
  cg.code.add line
  cg.code.add "\n"

proc addComment(cg: var CodeGen, comment: string) =
  ## Add a comment line.
  cg.addLine "; " & comment

proc toAsm(n: NimNode, cg: var CodeGen): string

proc toAsmStmts(n: NimNode, cg: var CodeGen)

proc selectAddressingMode(value: string, varType: SnesType): string =
  ## Select appropriate addressing mode based on value format and type.
  if value.startsWith("#"):
    result = value  # Immediate mode already
  elif value.len <= 4 and value.allCharsInSet({'0'..'9', 'A'..'F', 'a'..'f', '$'}):
    if value.startsWith("$"):
      if is8Bit(varType):
        result = value  # Direct page or absolute
      else:
        result = value  # Absolute 16-bit
    else:
      result = "$" & value  # Assume hex address
  else:
    result = value  # Variable name, will be resolved to absolute or direct page

proc toAsm(n: NimNode, cg: var CodeGen): string =
  ## Convert Nim AST node to assembly expression.
  ## Returns the register or memory location containing the result.
  
  case n.kind:
  
  of nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit:
    let val = n.intVal
    if val < 0:
      err "Negative literals not yet supported", n
    if val <= 255:
      result = "#$" & val.toHex(2).toUpperAscii()
    else:
      result = "#$" & val.toHex(4).toUpperAscii()
  
  of nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit:
    let val = n.intVal
    if val <= 255:
      result = "#$" & val.toHex(2).toUpperAscii()
    else:
      result = "#$" & val.toHex(4).toUpperAscii()
  
  of nnkIdent, nnkSym:
    let name = n.strVal
    if name in cg.variables:
      let varType = cg.variables[name]
      result = selectAddressingMode(name, varType)
    else:
      err "Unknown variable: " & name, n
  
  of nnkInfix:
    let op = n[0].strVal
    case op:
    of "+":
      let left = toAsm(n[1], cg)
      let right = toAsm(n[2], cg)
      cg.addLine "  LDA " & left
      cg.addLine "  CLC"
      cg.addLine "  ADC " & right
      result = "A"
    of "-":
      let left = toAsm(n[1], cg)
      let right = toAsm(n[2], cg)
      cg.addLine "  LDA " & left
      cg.addLine "  SEC"
      cg.addLine "  SBC " & right
      result = "A"
    of "==":
      let left = toAsm(n[1], cg)
      let right = toAsm(n[2], cg)
      cg.addLine "  LDA " & left
      cg.addLine "  CMP " & right
      result = "P"  # Result in processor flags
    of "!=":
      let left = toAsm(n[1], cg)
      let right = toAsm(n[2], cg)
      cg.addLine "  LDA " & left
      cg.addLine "  CMP " & right
      result = "P"  # Result in processor flags (inverted)
    else:
      err "Unsupported operator: " & op, n
  
  of nnkAsgn:
    let varName = n[0].strVal
    let value = toAsm(n[1], cg)
    if value == "A":
      cg.addLine "  STA " & varName
    else:
      cg.addLine "  LDA " & value
      cg.addLine "  STA " & varName
    result = varName
  
  else:
    err "Unsupported node kind: " & $n.kind, n

proc toAsmStmts(n: NimNode, cg: var CodeGen) =
  ## Convert Nim AST node to assembly statements.
  
  case n.kind:
  
  of nnkStmtList:
    for child in n:
      toAsmStmts(child, cg)
  
  of nnkAsgn:
    discard toAsm(n, cg)
  
  of nnkIfStmt:
    let endLabel = nextLabel()
    var hasElse = false
    
    for i, branch in n:
      if i == 0:
        let condition = toAsm(branch[0], cg)
        let elseLabel = nextLabel()
        cg.addLine "  LDA " & condition
        cg.addLine "  BEQ " & elseLabel
        toAsmStmts(branch[1], cg)
        cg.addLine "  BRA " & endLabel
        cg.addLine elseLabel & ":"
      elif branch.kind == nnkElse:
        hasElse = true
        toAsmStmts(branch[0], cg)
      elif branch.kind == nnkElifBranch:
        let elifLabel = nextLabel()
        let condition = toAsm(branch[0], cg)
        cg.addLine "  LDA " & condition
        cg.addLine "  BEQ " & elifLabel
        toAsmStmts(branch[1], cg)
        cg.addLine "  BRA " & endLabel
        cg.addLine elifLabel & ":"
    
    if not hasElse:
      cg.addLine endLabel & ":"
    else:
      cg.addLine endLabel & ":"
  
  of nnkVarSection, nnkLetSection:
    for def in n:
      if def.kind == nnkIdentDefs:
        let varName = def[0].strVal
        var varType = stUint8
        if def[1].kind != nnkEmpty:
          try:
            varType = typeToSnes(def[1].getTypeInst().repr)
          except:
            varType = stUint8
        cg.variables[varName] = varType
        if def[^1].kind != nnkEmpty:
          discard toAsm(def[^1], cg)
  
  of nnkEmpty, nnkDiscardStmt:
    discard
  
  else:
    err "Unsupported statement: " & $n.kind, n

proc toSnesAsmInner(s: NimNode): string =
  ## Inner function to convert proc to assembly.
  
  var cg = newCodeGen()
  let impl = getImpl(s)
  
  cg.addComment "Generated SNES assembly from Nim"
  cg.addLine ""
  
  for child in impl:
    if child.kind == nnkStmtList:
      toAsmStmts(child, cg)
  
  result = cg.code

macro toSnesAsm*(
  s: typed,
): string =
  ## Convert Nim code to SNES ASM.
  newLit(toSnesAsmInner(s))
