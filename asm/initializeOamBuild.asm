; Initialize the next OAM build buffer and clear all four sprite queue counts.
; File $0088B1..$008B18; native JSL entry with DBR=$7E.
; Selector word $002E == 1 chooses low/high buffers $0500/$0700;
; every other value chooses $0800/$0A00. The low table is 128 four-byte
; OAM entries. Only each Y byte is set to $E0 (outside the visible scanlines).
; Other entry bytes and the high table remain untouched until composition.
; Absolute $0003 is the low-table cursor; $0005 is its end and $0007 the
; packed high-table cursor. $000A starts the high-bit packing sentinel at $80.
; Calls come from the normal frame path at $C10067 and blank build at $C08B22.
; Preserves DBR, direct page, Y, stack depth, carry/decimal/overflow flags.
; Returns with 16-bit A/X, A low byte $E0 (high byte retained), X high-table base.
.a16
.i16
SEP #$20
REP #$10
.a8
.i16
LDX #$0000
STX $2504
STX $2606
STX $2708
STX $280A
LDX $002E
DEX
BEQ firstBuffer
JMP secondBuffer
firstBuffer:
LDX #$0500
STX $0003
LDX #$0700
STX $0005
LDX #$0700
STX $0007
LDA #$80
STA $000A
LDA #$E0
PHD
; Hide the 64 sprite entries on page $0500.
PEA $0500
PLD
STA $01
STA $05
STA $09
STA $0D
STA $11
STA $15
STA $19
STA $1D
STA $21
STA $25
STA $29
STA $2D
STA $31
STA $35
STA $39
STA $3D
STA $41
STA $45
STA $49
STA $4D
STA $51
STA $55
STA $59
STA $5D
STA $61
STA $65
STA $69
STA $6D
STA $71
STA $75
STA $79
STA $7D
STA $81
STA $85
STA $89
STA $8D
STA $91
STA $95
STA $99
STA $9D
STA $A1
STA $A5
STA $A9
STA $AD
STA $B1
STA $B5
STA $B9
STA $BD
STA $C1
STA $C5
STA $C9
STA $CD
STA $D1
STA $D5
STA $D9
STA $DD
STA $E1
STA $E5
STA $E9
STA $ED
STA $F1
STA $F5
STA $F9
STA $FD
; Hide the 64 sprite entries on page $0600.
PEA $0600
PLD
STA $01
STA $05
STA $09
STA $0D
STA $11
STA $15
STA $19
STA $1D
STA $21
STA $25
STA $29
STA $2D
STA $31
STA $35
STA $39
STA $3D
STA $41
STA $45
STA $49
STA $4D
STA $51
STA $55
STA $59
STA $5D
STA $61
STA $65
STA $69
STA $6D
STA $71
STA $75
STA $79
STA $7D
STA $81
STA $85
STA $89
STA $8D
STA $91
STA $95
STA $99
STA $9D
STA $A1
STA $A5
STA $A9
STA $AD
STA $B1
STA $B5
STA $B9
STA $BD
STA $C1
STA $C5
STA $C9
STA $CD
STA $D1
STA $D5
STA $D9
STA $DD
STA $E1
STA $E5
STA $E9
STA $ED
STA $F1
STA $F5
STA $F9
STA $FD
PLD
REP #$20
.a16
RTL
secondBuffer:
.a8
.i16
LDX #$0800
STX $0003
LDX #$0A00
STX $0005
LDX #$0A00
STX $0007
LDA #$80
STA $000A
LDA #$E0
PHD
; Hide the 64 sprite entries on page $0800.
PEA $0800
PLD
STA $01
STA $05
STA $09
STA $0D
STA $11
STA $15
STA $19
STA $1D
STA $21
STA $25
STA $29
STA $2D
STA $31
STA $35
STA $39
STA $3D
STA $41
STA $45
STA $49
STA $4D
STA $51
STA $55
STA $59
STA $5D
STA $61
STA $65
STA $69
STA $6D
STA $71
STA $75
STA $79
STA $7D
STA $81
STA $85
STA $89
STA $8D
STA $91
STA $95
STA $99
STA $9D
STA $A1
STA $A5
STA $A9
STA $AD
STA $B1
STA $B5
STA $B9
STA $BD
STA $C1
STA $C5
STA $C9
STA $CD
STA $D1
STA $D5
STA $D9
STA $DD
STA $E1
STA $E5
STA $E9
STA $ED
STA $F1
STA $F5
STA $F9
STA $FD
; Hide the 64 sprite entries on page $0900.
PEA $0900
PLD
STA $01
STA $05
STA $09
STA $0D
STA $11
STA $15
STA $19
STA $1D
STA $21
STA $25
STA $29
STA $2D
STA $31
STA $35
STA $39
STA $3D
STA $41
STA $45
STA $49
STA $4D
STA $51
STA $55
STA $59
STA $5D
STA $61
STA $65
STA $69
STA $6D
STA $71
STA $75
STA $79
STA $7D
STA $81
STA $85
STA $89
STA $8D
STA $91
STA $95
STA $99
STA $9D
STA $A1
STA $A5
STA $A9
STA $AD
STA $B1
STA $B5
STA $B9
STA $BD
STA $C1
STA $C5
STA $C9
STA $CD
STA $D1
STA $D5
STA $D9
STA $DD
STA $E1
STA $E5
STA $E9
STA $ED
STA $F1
STA $F5
STA $F9
STA $FD
PLD
REP #$20
.a16
RTL
