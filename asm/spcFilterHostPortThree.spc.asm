; Filter port-three change, APU $2E1D..2E47 / file $26295F..262989 (43B).
; CALL/shared tail: DP zero, A=input; store p=A&$7F in scratch $20.
; Clear copied change $04B3 iff (p<8 and $04B7>=8) or (p==7 and $04B7==7).
; Otherwise preserve $04B3, including any distinction from direct-entry A.
; Preserves X/Y/H/V/P/I/B and native frame. p!=7 returns A=p,C=(p>=8),Z=0,
; N=(p<7). p==7 returns A=$04B7 and its CMP7 flags, except matching 7 returns A=0.
; TODO: identify $04B7's full policy role. No local ports. See docs/audio.md.
    .org $2E1D
spcFilterHostPortThree:
    AND A, #$7F
    MOV $20, A
    CMP A, #$08
    BCC checkPreviousInput
compareSelection:
    MOV A, $20
    CMP A, #$07
    BNE returnFilteredInput
    MOV A, !$04B7
    CMP A, #$07
    BNE returnFilteredInput
    MOV A, #$00
    MOV !$04B3, A
returnFilteredInput:
    RET

checkPreviousInput:
    MOV A, !$04B7
    CMP A, #$00
    BEQ compareSelection
    CMP A, #$08
    BCC compareSelection
    MOV A, #$00
    MOV !$04B3, A
    ; Fall through existing $2E48 BEQ $2E25, taken because MOV A,#0 set Z.
    ; Its two bytes also form sequence-pointer table entry zero: keep them data-owned.
