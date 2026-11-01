import
  std/[strformat, strutils, unittest],
  ../src/decompbound/spc_asm

type
  EncodingFixture = object
    source: string
    expected: seq[uint8]

const
  # Independent synthetic encodings, not extracted game instructions. Reference:
  # Nintendo SNES Development Manual, Appendix C, tables C-4 through C-20:
  # https://floating.muncher.se/bot/manual/book1_text.pdf#page=229
  # Destination-first spellings are paired with literal wire-order bytes.
  # Every relative fixture starts at $0000 and targets $0025; displacements
  # therefore differ for two-byte and three-byte branch instructions.
  OpcodeFixtures = """
00|NOP
01|TCALL 0
02 57|SET1 $57.0
03 57 22|BBS $57.0,$0025
04 57|OR A,$57
05 56 34|OR A,!$3456
06|OR A,(X)
07 57|OR A,[$57+X]
08 C3|OR A,#$C3
09 A6 57|OR $57,$A6
0A 34 B2|OR1 C,$1234.5
0B 57|ASL $57
0C 56 34|ASL !$3456
0D|PUSH PSW
0E 56 34|TSET1 !$3456
0F|BRK
10 23|BPL $0025
11|TCALL 1
12 57|CLR1 $57.0
13 57 22|BBC $57.0,$0025
14 57|OR A,$57+X
15 56 34|OR A,!$3456+X
16 56 34|OR A,!$3456+Y
17 57|OR A,[$57]+Y
18 C3 57|OR $57,#$C3
19|OR (X),(Y)
1A 57|DECW $57
1B 57|ASL $57+X
1C|ASL A
1D|DEC X
1E 56 34|CMP X,!$3456
1F 56 34|JMP [!$3456+X]
20|CLRP
21|TCALL 2
22 57|SET1 $57.1
23 57 22|BBS $57.1,$0025
24 57|AND A,$57
25 56 34|AND A,!$3456
26|AND A,(X)
27 57|AND A,[$57+X]
28 C3|AND A,#$C3
29 A6 57|AND $57,$A6
2A 34 B2|OR1 C,/$1234.5
2B 57|ROL $57
2C 56 34|ROL !$3456
2D|PUSH A
2E 57 22|CBNE $57,$0025
2F 23|BRA $0025
30 23|BMI $0025
31|TCALL 3
32 57|CLR1 $57.1
33 57 22|BBC $57.1,$0025
34 57|AND A,$57+X
35 56 34|AND A,!$3456+X
36 56 34|AND A,!$3456+Y
37 57|AND A,[$57]+Y
38 C3 57|AND $57,#$C3
39|AND (X),(Y)
3A 57|INCW $57
3B 57|ROL $57+X
3C|ROL A
3D|INC X
3E 57|CMP X,$57
3F 56 34|CALL !$3456
40|SETP
41|TCALL 4
42 57|SET1 $57.2
43 57 22|BBS $57.2,$0025
44 57|EOR A,$57
45 56 34|EOR A,!$3456
46|EOR A,(X)
47 57|EOR A,[$57+X]
48 C3|EOR A,#$C3
49 A6 57|EOR $57,$A6
4A 34 B2|AND1 C,$1234.5
4B 57|LSR $57
4C 56 34|LSR !$3456
4D|PUSH X
4E 56 34|TCLR1 !$3456
4F A6|PCALL $A6
50 23|BVC $0025
51|TCALL 5
52 57|CLR1 $57.2
53 57 22|BBC $57.2,$0025
54 57|EOR A,$57+X
55 56 34|EOR A,!$3456+X
56 56 34|EOR A,!$3456+Y
57 57|EOR A,[$57]+Y
58 C3 57|EOR $57,#$C3
59|EOR (X),(Y)
5A 57|CMPW YA,$57
5B 57|LSR $57+X
5C|LSR A
5D|MOV X,A
5E 56 34|CMP Y,!$3456
5F 56 34|JMP !$3456
60|CLRC
61|TCALL 6
62 57|SET1 $57.3
63 57 22|BBS $57.3,$0025
64 57|CMP A,$57
65 56 34|CMP A,!$3456
66|CMP A,(X)
67 57|CMP A,[$57+X]
68 C3|CMP A,#$C3
69 A6 57|CMP $57,$A6
6A 34 B2|AND1 C,/$1234.5
6B 57|ROR $57
6C 56 34|ROR !$3456
6D|PUSH Y
6E 57 22|DBNZ $57,$0025
6F|RET
70 23|BVS $0025
71|TCALL 7
72 57|CLR1 $57.3
73 57 22|BBC $57.3,$0025
74 57|CMP A,$57+X
75 56 34|CMP A,!$3456+X
76 56 34|CMP A,!$3456+Y
77 57|CMP A,[$57]+Y
78 C3 57|CMP $57,#$C3
79|CMP (X),(Y)
7A 57|ADDW YA,$57
7B 57|ROR $57+X
7C|ROR A
7D|MOV A,X
7E 57|CMP Y,$57
7F|RETI
80|SETC
81|TCALL 8
82 57|SET1 $57.4
83 57 22|BBS $57.4,$0025
84 57|ADC A,$57
85 56 34|ADC A,!$3456
86|ADC A,(X)
87 57|ADC A,[$57+X]
88 C3|ADC A,#$C3
89 A6 57|ADC $57,$A6
8A 34 B2|EOR1 C,$1234.5
8B 57|DEC $57
8C 56 34|DEC !$3456
8D C3|MOV Y,#$C3
8E|POP PSW
8F C3 57|MOV $57,#$C3
90 23|BCC $0025
91|TCALL 9
92 57|CLR1 $57.4
93 57 22|BBC $57.4,$0025
94 57|ADC A,$57+X
95 56 34|ADC A,!$3456+X
96 56 34|ADC A,!$3456+Y
97 57|ADC A,[$57]+Y
98 C3 57|ADC $57,#$C3
99|ADC (X),(Y)
9A 57|SUBW YA,$57
9B 57|DEC $57+X
9C|DEC A
9D|MOV X,SP
9E|DIV YA,X
9F|XCN A
A0|EI
A1|TCALL 10
A2 57|SET1 $57.5
A3 57 22|BBS $57.5,$0025
A4 57|SBC A,$57
A5 56 34|SBC A,!$3456
A6|SBC A,(X)
A7 57|SBC A,[$57+X]
A8 C3|SBC A,#$C3
A9 A6 57|SBC $57,$A6
AA 34 B2|MOV1 C,$1234.5
AB 57|INC $57
AC 56 34|INC !$3456
AD C3|CMP Y,#$C3
AE|POP A
AF|MOV (X)+,A
B0 23|BCS $0025
B1|TCALL 11
B2 57|CLR1 $57.5
B3 57 22|BBC $57.5,$0025
B4 57|SBC A,$57+X
B5 56 34|SBC A,!$3456+X
B6 56 34|SBC A,!$3456+Y
B7 57|SBC A,[$57]+Y
B8 C3 57|SBC $57,#$C3
B9|SBC (X),(Y)
BA 57|MOVW YA,$57
BB 57|INC $57+X
BC|INC A
BD|MOV SP,X
BE|DAS A
BF|MOV A,(X)+
C0|DI
C1|TCALL 12
C2 57|SET1 $57.6
C3 57 22|BBS $57.6,$0025
C4 57|MOV $57,A
C5 56 34|MOV !$3456,A
C6|MOV (X),A
C7 57|MOV [$57+X],A
C8 C3|CMP X,#$C3
C9 56 34|MOV !$3456,X
CA 34 B2|MOV1 $1234.5,C
CB 57|MOV $57,Y
CC 56 34|MOV !$3456,Y
CD C3|MOV X,#$C3
CE|POP X
CF|MUL YA
D0 23|BNE $0025
D1|TCALL 13
D2 57|CLR1 $57.6
D3 57 22|BBC $57.6,$0025
D4 57|MOV $57+X,A
D5 56 34|MOV !$3456+X,A
D6 56 34|MOV !$3456+Y,A
D7 57|MOV [$57]+Y,A
D8 57|MOV $57,X
D9 57|MOV $57+Y,X
DA 57|MOVW $57,YA
DB 57|MOV $57+X,Y
DC|DEC Y
DD|MOV A,Y
DE 57 22|CBNE $57+X,$0025
DF|DAA A
E0|CLRV
E1|TCALL 14
E2 57|SET1 $57.7
E3 57 22|BBS $57.7,$0025
E4 57|MOV A,$57
E5 56 34|MOV A,!$3456
E6|MOV A,(X)
E7 57|MOV A,[$57+X]
E8 C3|MOV A,#$C3
E9 56 34|MOV X,!$3456
EA 34 B2|NOT1 $1234.5
EB 57|MOV Y,$57
EC 56 34|MOV Y,!$3456
ED|NOTC
EE|POP Y
EF|SLEEP
F0 23|BEQ $0025
F1|TCALL 15
F2 57|CLR1 $57.7
F3 57 22|BBC $57.7,$0025
F4 57|MOV A,$57+X
F5 56 34|MOV A,!$3456+X
F6 56 34|MOV A,!$3456+Y
F7 57|MOV A,[$57]+Y
F8 57|MOV X,$57
F9 57|MOV X,$57+Y
FA A6 57|MOV $57,$A6
FB 57|MOV Y,$57+X
FC|INC Y
FD|MOV Y,A
FE 23|DBNZ Y,$0025
FF|STOP
"""

proc parseBytes(value: string): seq[uint8] =
  ## Decode the independently authored hexadecimal fixture bytes.
  for token in value.splitWhitespace:
    result.add uint8(parseHexInt(token))

proc fixtures(): seq[EncodingFixture] =
  ## Read the literal fixture list without consulting assembler metadata.
  for line in OpcodeFixtures.strip.splitLines:
    let parts = line.split('|')
    doAssert parts.len == 2
    result.add EncodingFixture(source: parts[1], expected: parseBytes(parts[0]))

proc expectEncoding(source, expected: string, origin = 0'u16) =
  ## Compare a synthetic source with explicit expected machine bytes.
  checkpoint source
  check assembleSpcAsm(source, origin) == parseBytes(expected)

suite "SPC700 assembler independent full-ISA encodings":
  test "fixture inventory contains every raw opcode exactly once":
    var seen: array[256, int]
    let cases = fixtures()
    check cases.len == 256
    for fixture in cases:
      check fixture.expected.len in 1 .. 3
      inc seen[int(fixture.expected[0])]
    for count in seen:
      check count == 1

  for fixture in fixtures():
    test &"opcode {fixture.expected[0]:02X}: {fixture.source}":
      checkpoint fixture.source
      check assembleSpcAsm(fixture.source) == fixture.expected

suite "SPC700 assembler syntax and addressing distinctions":
  test "mnemonics and registers ignore case; comments do not become operands":
    expectEncoding("mOv a, #0xc3 ; MOV X,#$00\nMoV x,a\nret ; end", "E8 C3 5D 6F")

  test "empty source and comment-only lines emit nothing":
    expectEncoding("", "")
    expectEncoding("; comment\n \n; another comment", "")

  test "direct page and padded or explicitly absolute operands differ":
    expectEncoding("MOV A,$57\nMOV A,$0057\nMOV A,!$57", "E4 57 E5 57 00 E5 57 00")
    expectEncoding("MOV $57,A\nMOV $0057,A\nMOV !$57,A", "C4 57 C5 57 00 C5 57 00")
    expectEncoding("MOV A,$57+X\nMOV A,$0057+X", "F4 57 F5 57 00")
    expectEncoding("ASL $57\nASL !$57", "0B 57 0C 57 00")

  test "hexadecimal and decimal notation preserve addressing meaning":
    expectEncoding("MOV A,0x57\nMOV A,0x0057\nMOV A,87", "E4 57 E5 57 00 E4 57")
    expectEncoding("MOV A,#195\nMOV X,#0xA6", "E8 C3 CD A6")

  test "source bytes precede destination bytes in dual-direct-page encodings":
    expectEncoding("MOV $12,$E9\nADC $23,$B4\nCMP $56,$A7", "FA E9 12 89 B4 23 69 A7 56")
    expectEncoding("MOV $12,#$E9\nSBC $23,#$B4", "8F E9 12 B8 B4 23")

  test "direct page edges and forced absolute edges encode independently":
    expectEncoding("MOV A,$00\nMOV A,$FF\nMOV A,!$0000\nMOV A,!$FFFF", "E4 00 E4 FF E5 00 00 E5 FF FF")
    expectEncoding("MOV A,[$00+X]\nMOV [$FF]+Y,A", "E7 00 D7 FF")
    expectEncoding("MOV A,#0\nMOV X,#255\nPCALL $FF", "E8 00 CD FF 4F FF")

  test "metadata emits little-endian words without inventing alignment":
    expectEncoding(".byte $A5,0x5A,255,0\n.word $1234,0xABCD,65535,0", "A5 5A FF 00 34 12 CD AB FF FF 00 00")

  test "the eight address-bit positions occupy bits 13 through 15":
    expectEncoding("MOV1 C,$0000.0\nMOV1 $1FFF.7,C\nNOT1 $0123.6", "AA 00 00 CA FF FF EA 23 C1")
    expectEncoding("OR1 C,/$1FFF.0\nAND1 C,/$0000.7", "2A FF 1F 6A 00 E0")
    for bit in 0 .. 7:
      # This independent format formula exercises all bit slots at guard addresses.
      let
        packed = 0x15A3 or (bit shl 13)
        expected = @[0xAA'u8, uint8(packed and 0xFF), uint8(packed shr 8)]
      check assembleSpcAsm(&"MOV1 C,$15A3.{bit}") == expected

suite "SPC700 assembler labels, origins and relative displacement":
  test "forward and backward labels use the byte after the instruction":
    expectEncoding(".org $2400\nStart: NOP\nBRA Finish\n.byte $A5\nFinish: BRA Start", "00 2F 01 A5 2F FA")

  test "all multioperand branch forms count their entire instruction":
    expectEncoding(".org $2400\nStart: BBS $57.3,Finish\nBBC $A6.6,Start\nCBNE $34,Finish\nCBNE $89+X,Start\nDBNZ $CD,Finish\nDBNZ Y,Start\nFinish: RET",
      "63 57 0E D3 A6 FA 2E 34 08 DE 89 F4 6E CD 02 FE EF 6F")

  test "literal targets also use the caller-specified origin":
    expectEncoding("BRA $247F", "2F 7D", 0x2400)
    expectEncoding("CBNE $57,$2400", "2E 57 FD", 0x2400)

  test "signed relative limits are accepted including three-byte branches":
    expectEncoding("BRA $2481", "2F 7F", 0x2400)
    expectEncoding("BRA $2382", "2F 80", 0x2400)
    expectEncoding("BBS $57.2,$2482", "43 57 7F", 0x2400)
    expectEncoding("DBNZ $57,$2383", "6E 57 80", 0x2400)

  test "relative distances and label locations wrap across the APU address end":
    expectEncoding("BRA $0000", "2F 00", 0xFFFE)
    expectEncoding("BRA $FFFF", "2F FD", 0x0000)
    expectEncoding(".org $FFFF\nStart: NOP\nBRA Start\nCALL Start\n.word Start", "00 2F FD 3F FF FF FF FF")
    expectEncoding(".org $FFFE\nBRA After\nAfter: RET", "2F 00 6F")

  test "org changes label addresses without emitting fill":
    expectEncoding(".org $3456\nHere: NOP\nCALL Here\nJMP Here\n.word Here", "00 3F 56 34 5F 56 34 56 34")

  test "forward absolute labels and label arithmetic are resolved in pass two":
    expectEncoding(".org $2300\nCALL Target\nJMP Target+1\n.word Target,Target-1,Target+2\nTarget: RET\nNOP",
      "3F 0C 23 5F 0D 23 0C 23 0B 23 0E 23 6F 00")
    expectEncoding(".org $2400\nBRA Target-1\nNOP\nTarget: RET", "2F 00 00 6F")

  test "labels are case-sensitive even while instructions are not":
    expectEncoding(".org $2000\nCase: nop\ncase: ret\n.word Case,case\ncall Case\ncall case", "00 6F 00 20 01 20 3F 00 20 3F 01 20")

  test "a full address space emits once and a trailing label wraps":
    let source = ".org $1234\n.word End\n.byte " & repeat("0,", 65533) & "0\nEnd:"
    let image = assembleSpcAsm(source)
    var expected = newSeq[uint8](65536)
    expected[0] = 0x34
    expected[1] = 0x12
    check image.len == 65536
    check image == expected

suite "SPC700 assembler rejects unencodable or ambiguous source":
  for source in [
      "UnknownMnemonic A,$57", "MOV A", "MOV A,#$01,#$02", "NOP A",
      "MOV A,(Y)", "MOV (X),(Y)", "MOV A,[$57+Y]", "JMP [!$1234+Y]",
      "MOV !$3456,#$00", "OR A,/$1234.2", "OR1 C,$57", "MOV1 /$1234.2,C",
      "TCALL 16", "TCALL -1", "SET1 $57.8", "CLR1 $57.-1",
      "BBS $57.8,$0003", "BBC $0100.1,$0003", "MOV1 C,$2000.0",
      "MOV1 C,$1FFF.8", "NOT1 $FFFF.0", "MOV A,#256", "MOV A,#-1",
      "PCALL 256", "MOV A,[$0100+X]", "MOV A,[$0100]+Y", "MOVW YA,$0100",
      "MOV A,!65536", "CALL $10000", "JMP -1", "BRA $10000", "BRA -1",
      ".byte 256", ".byte -1",
      ".word 65536", ".word -1", ".org $10000", ".org -1",
      ".org $1000\n.org $1000\nNOP", "NOP\n.org $1000", ".byte 0\n.org $1000",
      "Same: NOP\nSame: RET", "BRA Missing", "CALL Missing", "JMP Missing",
      ".word Missing", "Target: NOP\nBRA target", "CALL Known+Missing\nKnown: RET",
      "BRA $0082", "BRA $FF81", "CBNE $57,$0083", "DBNZ $57,$FF82"]:
    test "reject " & source.replace('\n', ' '):
      expect ValueError:
        discard assembleSpcAsm(source)

  test "labels outside the signed branch window are rejected":
    expect ValueError:
      discard assembleSpcAsm("BRA Far\n.byte " & repeat("0,", 127) & "0\nFar: RET")
    expect ValueError:
      discard assembleSpcAsm("Back: NOP\n.byte " & repeat("0,", 125) & "0\nBRA Back")

  test "oversized numeric literals cannot wrap into valid operands":
    for literal in ["$10000000000000000", "0x10000000000000000",
        "$10000000000000001", "0x10000000000000001",
        "$FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", "18446744073709551616"]:
      for source in [".word " & literal, ".byte " & literal,
          ".org " & literal & "\nNOP", "MOV A,#" & literal,
          "MOV A," & literal, "CALL " & literal,
          "BRA " & literal, "TCALL " & literal]:
        expect ValueError:
          discard assembleSpcAsm(source)
    expectEncoding(".word 65536-1\n.word $10000-1", "FF FF FF FF")

  test "more than 65536 output bytes are rejected even when addresses wrap":
    expect ValueError:
      discard assembleSpcAsm(".byte " & repeat("0,", 65536) & "0")
