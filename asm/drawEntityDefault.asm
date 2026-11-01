; Default entity graphics callback: patch two priority groups and enqueue.
; File $00A3A4..$00A442 (159 bytes), SNES $C0A3A4. JMP from dispatch at
; $11E2,X = $A3A4; tail JMP $8C58, appender RTS to the dispatch caller.
; Native M16/X16, decimal clear, DBR=$7E. X and DP $88 are the entity
; byte offset; DP $8C/$8E hold the definition pointer from dispatch.
; A is unused. Preserves D, DBR, and stack depth. Clobbers A/X/Y/flags,
; DP $00..$09/$8C, $000B/$000C, and $103E,X on a one-shot selector.
; Evidence: docs/graphics.md (Default callback: two priority groups).
    .a16
    .i16

drawEntityDefault:
    ; Bit 0 of the retained graphics entry selects the second variant.
    ; The add is 16-bit into $8C only; bank $8E is unchanged.
    LDA $341A,X
    AND #$0001
    BEQ patchPriorities
    LDA $2916,X
    CLC
    ADC $8C
    STA $8C

patchPriorities:
    ; Both loops and the $2BE6/$2BE7 counts are 8-bit. SEP is on every
    ; path; the assembler tracks that in source order, matching runtime.
    SEP #$30
    .a8
    .i8
    LDA #$30               ; OAM priority bits 4-5 = 3 when the flag is clear.
    LDY #$20               ; Priority bits 4-5 = 2 when the flag is set.
    STA $00                ; First-group patch; isolate DP from global OAM state.
    STA $02                ; Second-group patch value.
    LDA $2BAA,X
    LSR A                  ; Bit 0 controls the second group.
    BCC firstGroupFlag
    STY $02
firstGroupFlag:
    LSR A                  ; Bit 1 controls the first group.
    BCC loadFirstCount
    STY $00

loadFirstCount:
    ; X becomes the remaining count; reload the entity offset from $88
    ; after each loop. Counts $00 and $01..$80 iterate that many times;
    ; $81..$FF make DEX set N and skip the body.
    LDA $2BE7,X
    TAX
    LDY #$FD               ; Five INYs land on record byte 2 (attribute).
    BRA checkFirstCount

patchFirstRecord:
    INY
    INY
    INY
    INY
    INY
    LDA [$8C],Y            ; Attribute byte; Y is an 8-bit window index.
    AND #$CF               ; Keep palette, tile-high, and flip bits.
    ORA $00
    STA [$8C],Y
checkFirstCount:
    DEX
    BPL patchFirstRecord

    ; Second group continues the same Y cursor. Empty first count leaves
    ; Y at $FD, so the first second-group record is still byte 2.
    LDX $88
    LDA $2BE6,X
    TAX
    BRA checkSecondCount

patchSecondRecord:
    INY
    INY
    INY
    INY
    INY
    LDA [$8C],Y
    AND #$CF
    ORA $02
    STA [$8C],Y
checkSecondCount:
    DEX
    BPL patchSecondRecord

    ; Index 16-bit for entity arrays; A stays 8-bit so $000C is preserved.
    REP #$10
    .i16
    LDX $88
    LDA $8E                ; Definition bank from dispatch.
    STA $000B              ; AC43 overwrites this with $00C4.
    REP #$20
    .a16

    ; $2400 is the enqueue queue index 0..3; values outside that range
    ; are not masked here and the jump table at $8C65 is unchecked.
    LDA $103E,X
    STA $2400
    TAY
    AND #$8000             ; Bit 15: one-hop lookup, not a nested walk.
    BEQ callOverlayHelper
    TYA
    AND #$003F             ; Low 6 bits are a raw entity ID; 30..63 are unguarded.
    ASL A                  ; Double exactly once to a byte offset.
    TAX
    LDA $103E,X            ; Referred word is stored as-is, including flags.
    LDX $88
    STA $2400
    TYA
    AND #$4000             ; Bit 14 set: keep the indirect selector word.
    BNE callOverlayHelper
    LDA #$0000
    STA $103E,X            ; Bit 14 clear: one-shot; zeros the whole word.

callOverlayHelper:
    ; Overlay helper. Inactive when ($2BAA & $0C) = 0 and $2E7A = 0.
    ; Even that path clobbers DP $00/$04 and $000B. Returns M16/X16.
    JSL $C0AC43

    LDX $88
    LDA $8E                ; 16-bit: $8F rides into $000C for the queue word.
    STA $000B
    LDY $0B52,X            ; Screen Y origin.
    LDA $0B16,X            ; Screen X origin.
    TAX
    LDA $8C                ; Possibly variant-adjusted definition pointer.
    JMP $8C58              ; Near enqueue; zero counts still append this pointer.
