## Two-pass Sony-syntax SPC700 assembler with explicit addressing widths.

import
  std/[sequtils, strutils, tables]

const
  # Operand letters describe encoded fields; uppercase tokens are registers.
  OpcodeRows = [
    "NOP|TCALL t0|SET1 q0|BBS q0,r|OR A,d|OR A,w|OR A,(X)|OR A,[d+X]|OR A,#i|OR d,d|OR1 C,b|ASL d|ASL w|PUSH PSW|TSET1 w|BRK",
    "BPL r|TCALL t1|CLR1 q0|BBC q0,r|OR A,d+X|OR A,w+X|OR A,w+Y|OR A,[d]+Y|OR d,#i|OR (X),(Y)|DECW d|ASL d+X|ASL A|DEC X|CMP X,w|JMP [w+X]",
    "CLRP|TCALL t2|SET1 q1|BBS q1,r|AND A,d|AND A,w|AND A,(X)|AND A,[d+X]|AND A,#i|AND d,d|OR1 C,/b|ROL d|ROL w|PUSH A|CBNE d,r|BRA r",
    "BMI r|TCALL t3|CLR1 q1|BBC q1,r|AND A,d+X|AND A,w+X|AND A,w+Y|AND A,[d]+Y|AND d,#i|AND (X),(Y)|INCW d|ROL d+X|ROL A|INC X|CMP X,d|CALL w",
    "SETP|TCALL t4|SET1 q2|BBS q2,r|EOR A,d|EOR A,w|EOR A,(X)|EOR A,[d+X]|EOR A,#i|EOR d,d|AND1 C,b|LSR d|LSR w|PUSH X|TCLR1 w|PCALL i",
    "BVC r|TCALL t5|CLR1 q2|BBC q2,r|EOR A,d+X|EOR A,w+X|EOR A,w+Y|EOR A,[d]+Y|EOR d,#i|EOR (X),(Y)|CMPW YA,d|LSR d+X|LSR A|MOV X,A|CMP Y,w|JMP w",
    "CLRC|TCALL t6|SET1 q3|BBS q3,r|CMP A,d|CMP A,w|CMP A,(X)|CMP A,[d+X]|CMP A,#i|CMP d,d|AND1 C,/b|ROR d|ROR w|PUSH Y|DBNZ d,r|RET",
    "BVS r|TCALL t7|CLR1 q3|BBC q3,r|CMP A,d+X|CMP A,w+X|CMP A,w+Y|CMP A,[d]+Y|CMP d,#i|CMP (X),(Y)|ADDW YA,d|ROR d+X|ROR A|MOV A,X|CMP Y,d|RETI",
    "SETC|TCALL t8|SET1 q4|BBS q4,r|ADC A,d|ADC A,w|ADC A,(X)|ADC A,[d+X]|ADC A,#i|ADC d,d|EOR1 C,b|DEC d|DEC w|MOV Y,#i|POP PSW|MOV d,#i",
    "BCC r|TCALL t9|CLR1 q4|BBC q4,r|ADC A,d+X|ADC A,w+X|ADC A,w+Y|ADC A,[d]+Y|ADC d,#i|ADC (X),(Y)|SUBW YA,d|DEC d+X|DEC A|MOV X,SP|DIV YA,X|XCN A",
    "EI|TCALL t10|SET1 q5|BBS q5,r|SBC A,d|SBC A,w|SBC A,(X)|SBC A,[d+X]|SBC A,#i|SBC d,d|MOV1 C,b|INC d|INC w|CMP Y,#i|POP A|MOV (X)+,A",
    "BCS r|TCALL t11|CLR1 q5|BBC q5,r|SBC A,d+X|SBC A,w+X|SBC A,w+Y|SBC A,[d]+Y|SBC d,#i|SBC (X),(Y)|MOVW YA,d|INC d+X|INC A|MOV SP,X|DAS A|MOV A,(X)+",
    "DI|TCALL t12|SET1 q6|BBS q6,r|MOV d,A|MOV w,A|MOV (X),A|MOV [d+X],A|CMP X,#i|MOV w,X|MOV1 b,C|MOV d,Y|MOV w,Y|MOV X,#i|POP X|MUL YA",
    "BNE r|TCALL t13|CLR1 q6|BBC q6,r|MOV d+X,A|MOV w+X,A|MOV w+Y,A|MOV [d]+Y,A|MOV d,X|MOV d+Y,X|MOVW d,YA|MOV d+X,Y|DEC Y|MOV A,Y|CBNE d+X,r|DAA A",
    "CLRV|TCALL t14|SET1 q7|BBS q7,r|MOV A,d|MOV A,w|MOV A,(X)|MOV A,[d+X]|MOV A,#i|MOV X,w|NOT1 b|MOV Y,d|MOV Y,w|NOTC|POP Y|SLEEP",
    "BEQ r|TCALL t15|CLR1 q7|BBC q7,r|MOV A,d+X|MOV A,w+X|MOV A,w+Y|MOV A,[d]+Y|MOV X,d|MOV X,d+Y|MOV d,d|MOV Y,d+X|INC Y|MOV Y,A|DBNZ Y,r|STOP"
  ]

type
  Form = object
    opcode: int
    mnemonic: string
    patterns: seq[string]
  Field = object
    kind: char
    expression: string
    selector: int
  Statement = object
    line: int
    address: int
    directive: string
    values: seq[string]
    form: Form
    fields: seq[Field]

proc fail(line: int, message: string) =
  ## Raise an assembly error with its source line.
  raise newException(ValueError, "SPC assembly line " & $line & ": " & message)

proc compact(value: string): string =
  ## Remove operand whitespace without changing symbol case.
  for ch in value:
    if not ch.isSpaceAscii:
      result.add ch

proc identifier(value: string): bool =
  ## Recognize a local symbol name.
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_'):
    return false
  for ch in value:
    if not (ch.isAlphaNumeric or ch == '_'):
      return false
  result = true

proc expressionShape(value: string): bool =
  ## Reject operand punctuation before selecting a numeric addressing form.
  if value.len == 0:
    return false
  var
    cursor = 0
    first = true
  while cursor < value.len:
    if value[cursor] in {'+', '-'}: inc cursor
    let start = cursor
    while cursor < value.len and value[cursor] notin {'+', '-'}: inc cursor
    if start == cursor: return false
    let term = value[start ..< cursor]
    if term.toUpperAscii in ["A", "X", "Y", "YA", "SP", "PSW", "C"]:
      return false
    if term.startsWith("$") or term.toLowerAscii.startsWith("0x"):
      let digits = if term[0] == '$': term[1 .. ^1] else: term[2 .. ^1]
      if digits.len == 0: return false
      for ch in digits:
        if ch notin HexDigits: return false
    elif term[0].isDigit:
      for ch in term:
        if not ch.isDigit: return false
    elif not first or not identifier(term):
      return false
    first = false
  result = true

proc literalMagnitude(term: string, line: int): int =
  ## Parse a nonnegative literal without overflowing or truncating native int.
  let
    hexadecimal = term.startsWith("$") or term.toLowerAscii.startsWith("0x")
    start = if term.startsWith("$"): 1 elif hexadecimal: 2 else: 0
    radix = if hexadecimal: 16 else: 10
  if term.len == start: fail(line, "empty numeric literal: " & term)
  for index in start ..< term.len:
    let
      ch = term[index].toUpperAscii
      digit = if ch in {'0' .. '9'}: ord(ch) - ord('0')
        elif ch in {'A' .. 'F'}: ord(ch) - ord('A') + 10 else: -1
    if digit < 0 or digit >= radix:
      fail(line, "invalid numeric literal: " & term)
    if result > (high(int) - digit) div radix:
      fail(line, "literal exceeds signed integer range: " & term)
    result = result * radix + digit

proc decimalByte(value: string): bool =
  ## Compare a decimal magnitude with 255 without parsing a native integer.
  if value.len == 0 or not value[0].isDigit: return false
  var start = 0
  while start < value.high and value[start] == '0': inc start
  let digits = value[start .. ^1]
  result = digits.len < 3 or (digits.len == 3 and digits <= "255")

proc evaluate(expression: string, symbols: Table[string, int], line: int): int =
  ## Evaluate a literal or local symbol with numeric additions/subtractions.
  let value = compact(expression)
  var
    cursor = 0
    first = true
  while cursor < value.len:
    var sign = 1
    if value[cursor] in {'+', '-'}:
      if value[cursor] == '-': sign = -1
      inc cursor
    elif not first:
      fail(line, "expected + or - in expression " & expression)
    let start = cursor
    while cursor < value.len and value[cursor] notin {'+', '-'}:
      inc cursor
    if cursor == start:
      fail(line, "missing expression term in " & expression)
    let term = value[start ..< cursor]
    var number: int
    if term.startsWith("$") or term.toLowerAscii.startsWith("0x") or
        term[0].isDigit:
      number = literalMagnitude(term, line)
    elif identifier(term) and first:
      if not symbols.hasKey(term): fail(line, "unresolved label " & term)
      number = symbols[term]
    else:
      fail(line, "expected numeric constant or initial symbol: " & term)
    let addend = sign * number
    if (addend > 0 and result > high(int) - addend) or
        (addend < 0 and result < low(int) - addend):
      fail(line, "expression overflow: " & expression)
    result += addend
    first = false
  if first: fail(line, "empty expression")

proc checked(value, maximum, line: int, role: string): int =
  ## Enforce the representable range before emitting any field.
  if value < 0 or value > maximum:
    fail(line, role & " out of range: " & $value)
  result = value

proc forms(): seq[Form] =
  ## Build the complete opcode table in its architectural byte order.
  for row, contents in OpcodeRows:
    for column, text in contents.split('|').toSeq:
      let pieces = text.splitWhitespace(maxsplit = 1)
      result.add Form(opcode: row * 16 + column, mnemonic: pieces[0],
        patterns: if pieces.len == 1: @[] else: pieces[1].split(','))

proc matchOperand(pattern, operand: string, field: var Field,
    score: var int): bool =
  ## Match an addressing form while preserving the expression for pass two.
  var position = -1
  for i, ch in pattern:
    if ch in {'d', 'w', 'i', 'r', 'b', 'q', 't'}:
      position = i
      break
  if position < 0:
    return pattern == operand.toUpperAscii
  let
    kind = pattern[position]
    dynamicBit = kind in {'q', 't'}
    prefix = pattern[0 ..< position]
    suffix = if dynamicBit: "" else: pattern[position + 1 .. ^1]
    upper = operand.toUpperAscii
  if not upper.startsWith(prefix) or not upper.endsWith(suffix) or
      operand.len <= prefix.len + suffix.len:
    return false
  var expression = operand[prefix.len ..< operand.len - suffix.len]
  if expression.toUpperAscii in ["A", "X", "Y", "YA", "SP", "PSW", "C"]:
    return false
  field = Field(kind: kind, selector: -1)
  if dynamicBit:
    field.selector = parseInt(pattern[position + 1 .. ^1])
  if kind in {'q', 'b'}:
    let dot = expression.rfind('.')
    if dot < 1 or dot == expression.high: return false
    if not expressionShape(expression[0 ..< dot]) or
        not expressionShape(expression[dot + 1 .. ^1]): return false
  elif not expressionShape(expression.strip(chars = {'!'})):
    return false
  if kind in {'d', 'w'}:
    let forced = expression.startsWith("!")
    if forced: expression = expression[1 .. ^1]
    if forced and kind == 'd': return false
    let
      firstTerm = expression.split({'+', '-'})[0]
      wide = forced or (firstTerm.startsWith("$") and firstTerm.len > 3) or
        (firstTerm.toLowerAscii.startsWith("0x") and firstTerm.len > 4)
      symbolic = identifier(firstTerm)
      narrow = not wide and not symbolic and
        (firstTerm.startsWith("$") or firstTerm.toLowerAscii.startsWith("0x") or
          decimalByte(firstTerm))
    if wide and kind == 'd': return false
    score += (if (kind == 'd') == narrow: 4 else: 1)
  elif expression.startsWith("!"):
    return false
  field.expression = expression
  result = true

proc fieldSize(field: Field): int =
  ## Return the number of encoded bytes occupied by an operand field.
  case field.kind
  of 't': 0
  of 'w', 'b': 2
  else: 1

proc instructionSize(statement: Statement): int =
  ## Calculate an instruction length before resolving forward references.
  result = 1
  for field in statement.fields:
    result += field.fieldSize

proc selectForm(mnemonic: string, operands: seq[string], allForms: seq[Form],
    line: int): Statement =
  ## Select exactly one syntax/width form without relaxing labels in pass two.
  var
    bestScore = -1
    ambiguous = false
  for form in allForms:
    if form.mnemonic != mnemonic or form.patterns.len != operands.len: continue
    var
      fields: seq[Field]
      score = 0
      matches = true
    for i, pattern in form.patterns:
      var field: Field
      if not matchOperand(pattern, operands[i], field, score):
        matches = false
        break
      if field.kind != '\0': fields.add field
    if matches:
      # Bit selectors are encoded in the opcode and must be literal constants.
      for field in fields:
        if field.kind == 't':
          if evaluate(field.expression, initTable[string, int](), line) != field.selector:
            matches = false
        elif field.kind == 'q':
          let dot = field.expression.rfind('.')
          if evaluate(field.expression[dot + 1 .. ^1], initTable[string, int](), line) != field.selector:
            matches = false
    if matches and score >= bestScore:
      if score == bestScore:
        ambiguous = true
      else:
        result = Statement(form: form, fields: fields)
        bestScore = score
        ambiguous = false
  if bestScore < 0: fail(line, "unsupported or invalid operands for " & mnemonic)
  if ambiguous: fail(line, "ambiguous operands for " & mnemonic)

proc emitWord(output: var seq[uint8], value: int) =
  ## Emit an already checked little-endian word.
  output.add (value and 255).uint8
  output.add ((value shr 8) and 255).uint8

proc assembleSpcAsm*(source: string, origin: uint16 = 0): seq[uint8] =
  ## Assemble all SPC700 forms with local labels, .org, .byte and .word.
  ## Labels are case-sensitive; instructions/registers/directives are not.
  ## Address widths remain fixed between passes. Use ! to force absolute.
  let allForms = forms()
  var
    symbols = initTable[string, int]()
    statements: seq[Statement]
    base = origin.int
    length = 0
    sawOrg = false
  for index, raw in source.splitLines.toSeq:
    let line = index + 1
    var text = raw.split(';', maxsplit = 1)[0].strip
    if text.len == 0: continue
    let colon = text.find(':')
    if colon >= 0:
      let name = text[0 ..< colon].strip
      if not identifier(name): fail(line, "invalid label " & name)
      if symbols.hasKey(name): fail(line, "duplicate label " & name)
      symbols[name] = (base + length) and 65535
      text = text[colon + 1 .. ^1].strip
      if text.len == 0: continue
    let
      parts = text.splitWhitespace(maxsplit = 1)
      mnemonic = parts[0].toUpperAscii
      tail = if parts.len > 1: parts[1] else: ""
    if mnemonic == ".ORG":
      if sawOrg or length != 0: fail(line, ".org must occur once before emitted bytes")
      base = checked(evaluate(tail, symbols, line), 65535, line, "origin")
      sawOrg = true
      continue
    let startAddress = (base + length) and 65535
    var statement: Statement
    if mnemonic in [".BYTE", ".WORD"]:
      statement.directive = mnemonic
      statement.values = tail.split(',')
      for value in statement.values:
        if value.strip.len == 0: fail(line, "empty data operand")
      length += statement.values.len * (if mnemonic == ".WORD": 2 else: 1)
    else:
      let operands = if tail.strip.len == 0: @[] else: tail.split(',')
      var normalized: seq[string]
      for operand in operands: normalized.add compact(operand)
      statement = selectForm(mnemonic, normalized, allForms, line)
      length += statement.instructionSize
    statement.line = line
    statement.address = startAddress
    statements.add statement
    if length > 65536: fail(line, "output exceeds 65536 bytes")
  for statement in statements:
    let line = statement.line
    if statement.directive.len > 0:
      for expression in statement.values:
        let value = checked(evaluate(expression, symbols, line),
          (if statement.directive == ".WORD": 65535 else: 255), line, "data")
        if statement.directive == ".WORD": result.emitWord(value)
        else: result.add value.uint8
      continue
    result.add statement.form.opcode.uint8
    var encoded: seq[seq[uint8]]
    for field in statement.fields:
      var bytes: seq[uint8]
      if field.kind == 't': continue
      if field.kind in {'b', 'q'}:
        let
          dot = field.expression.rfind('.')
          address = checked(evaluate(field.expression[0 ..< dot], symbols, line),
            (if field.kind == 'b': 8191 else: 255), line, "bit address")
          bit = checked(evaluate(field.expression[dot + 1 .. ^1], symbols, line), 7, line, "bit")
        if field.kind == 'b': bytes.emitWord(address or (bit shl 13))
        else: bytes.add address.uint8
      else:
        let value = evaluate(field.expression, symbols, line)
        case field.kind
        of 'r':
          discard checked(value, 65535, line, "branch target")
          let displacement = (value - statement.address - statement.instructionSize) and 65535
          if displacement > 127 and displacement < 65408:
            fail(line, "relative branch out of signed-byte range")
          bytes.add (displacement and 255).uint8
        of 'w': bytes.emitWord(checked(value, 65535, line, "word"))
        else: bytes.add checked(value, 255, line, "byte").uint8
      encoded.add bytes
    let opcode = statement.form.opcode
    # Memory-to-memory and memory/immediate forms encode source before destination.
    if opcode == 0xFA or opcode == 0x8F or
        (opcode < 0xC0 and (opcode and 0x1F) in [0x09, 0x18]):
      for i in countdown(encoded.high, 0): result.add encoded[i]
    else:
      for bytes in encoded: result.add bytes
