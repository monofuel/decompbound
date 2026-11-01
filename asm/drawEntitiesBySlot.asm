; Draw occupied slots, deferring raw queue selector one for depth ordering.
; File $00DA31..$00DB0E (222 bytes), nominal SNES $C0DA31; JSR/RTS.
; Native, decimal clear, DBR=$7E; use PBR=$80 (or $00) for WRAM dispatch.
; REP establishes M16/X16 and clears C; D becomes caller D-$16 (mod 65536).
; Requires nonaliasing scratch here ($02..$15) and in nested $A0CA frames.
; Restores D/DBR with cooperating callbacks; A/X/Y/flags are clobbered.
; Uses $280C as an ID+1 vector, zero tombstones and a $FFFF terminator.
; $0A50=$FFFF suppresses even the slot scan. Callbacks preserve D/DBR,
; M16/X16 and caller scratch; entity arrays and selectors are trusted.
; Evidence: docs/graphics.md and docs/expanded-viewport.md.
    .a16
    .i16

drawEntitiesBySlot:
    REP #$31
    ; $FFEA is -22 bytes of local scratch, not a scene-mode constant.
    PHD
    TDC
    ADC #$FFEA
    TCD
    ; The active-head sentinel gates the whole alternate path.
    LDA $0A50
    INC A
    BNE beginSlotScan
    JMP returnSlots

beginSlotScan:
    ; Scan raw IDs 0..29, independently of active-list reachability.
    LDA #$0000
    STA $02
    TAY
    STY $14
    BRA checkSlot

scanSlot:
    TYA
    ASL A
    TAX
    ; $0A62 is the previous-link/occupancy word: only $FFFF is empty.
    LDA $0A62,X
    INC A
    BEQ nextSlot
    ; Only the exact raw selector 1 is deferred. Indirect words draw now.
    ; TODO: identify the scene meaning of this alternate Y-only gate.
    ; ((screenY+8) mod 65536)&$FE00 == 0 admits -8..503; X is unchecked.
    LDA $103E,X
    DEC A
    BNE drawSlotNow
    LDA $0B52,X
    CLC
    ADC #$0008
    AND #$FE00
    BNE drawSlotNow
    ; Append raw ID+1, reserving zero for a consumed entry.
    LDA $02
    ASL A
    TAX
    TYA
    INC A
    STA $280C,X
    INC $02
    BRA nextSlot

drawSlotNow:
    ; Non-one selectors and selector-one slots outside the gate draw now.
    TYA
    JSR $A0CA              ; drawEntityById; nested isolated DP.

nextSlot:
    LDY $14
    INY
    STY $14

checkSlot:
    CPY #$001E
    BNE scanSlot
    ; Terminate the compact vector, then draw exactly the saved count.
    LDA $02
    ASL A
    TAX
    LDA #$FFFF
    STA $280C,X
    LDA $02
    STA $04
    BRA checkRemaining

beginSelection:
    ; Selection sort: first unconsumed vector entry seeds the maximum.
    LDX #$0000
    STX $14
    BRA findFirstLive

skipConsumed:
    LDX $14
    INX
    STX $14

findFirstLive:
    TXA
    ASL A
    TAX
    LDA $280C,X
    BEQ skipConsumed
    LDX $14
    STX $02
    STX $12
    DEC A
    ASL A
    TAX
    ; $0BCA is the raw 16-bit world-Y word, not projected screen Y.
    LDY $0BCA,X
    BRA nextCandidate

compareCandidate:
    ; Zero entries were already drawn. Compare unsigned world-Y words.
    ; Keep the earlier vector entry on equality: ties retain ascending slot ID.
    LDA $10
    BEQ nextCandidate
    DEC A
    ASL A
    TAX
    LDA $0BCA,X
    STA $0E
    STA $02
    TYA
    CMP $02
    BCS nextCandidate
    LDA $0E
    TAY
    LDX $14
    STX $02
    LDA $02
    STA $12

nextCandidate:
    LDX $14
    INX
    STX $14
    TXA
    ASL A
    TAX
    LDA $280C,X
    STA $10
    INC A
    BNE compareCandidate
    ; Draw the chosen ID, then mark its vector word consumed.
    LDA $12
    STA $02
    ASL A
    CLC
    ADC #$280C
    TAX
    STX $10
    LDA $0000,X
    DEC A
    JSR $A0CA              ; drawEntityById; nested isolated DP.
    LDA #$0000
    LDX $10
    STA $0000,X

checkRemaining:
    ; Post-decrement is intentional: zero count exits without selection.
    LDA $04
    STA $0E
    LDA $04
    DEC A
    STA $04
    LDA $0E
    BEQ returnSlots
    JMP beginSelection

returnSlots:
    PLD
    RTS
