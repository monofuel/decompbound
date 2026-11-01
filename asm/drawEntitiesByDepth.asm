; Clip active entities, drawing raw queue one by descending unsigned world Y.
; File $00DB0F..$00DBE5 (215 bytes), nominal SNES $C0DB0F; JSR/RTS.
; Native, decimal clear, DBR=$7E; use PBR=$80 (or $00) for WRAM dispatch.
; REP establishes M16/X16 and clears C; D becomes caller D-$18 (mod 65536).
; Requires a valid acyclic active list ($0A50/$0A9E: doubled offsets, $FFFF
; end), disjoint local $02..$17 and nested $A0CA/$DA31 scratch frames.
; Restores D/DBR with cooperating callbacks; A/X/Y/flags are clobbered.
; $280C becomes a temporary raw-ID linked list for selector one only.
; Callbacks preserve D/DBR, M16/X16 and outer locals; arrays are trusted.
; Evidence: docs/graphics.md and docs/expanded-viewport.md.
    .a16
    .i16

drawEntitiesByDepth:
    REP #$31
    ; $FFE8 is -24 bytes of local scratch; REP above cleared ADC carry.
    PHD
    TDC
    ADC #$FFE8
    TCD
    ; Bit $2000 selects the slot scan. TODO: establish its scene meaning.
    ; Do not interpret this as a different entity activation policy.
    LDA $0067
    AND #$2000
    BEQ beginActiveList
    JSR $DA31              ; drawEntitiesBySlot; adds another DP frame.
    JMP returnDepth

beginActiveList:
    ; Build a reversed pending list from clipped selector-one entities.
    LDA #$FFFF
    STA $16
    LDY $0A50
    STY $14
    BRA checkActive

clipActiveY:
    ; Links are doubled offsets, not raw IDs. LSR/ASL clears bit zero.
    ; Unsigned tests admit Y $FFC0..$FFFF or $0000..$00FF (-64..255).
    TYA
    LSR A
    ASL A
    TAX
    LDA $0B52,X
    CMP #$0100
    BCC clipActiveX
    CMP #$FFC0
    BCC nextActive

clipActiveX:
    ; Unsigned tests admit X $FFC0..$FFFF or $0000..$013F (-64..319).
    TYA
    LSR A
    ASL A
    TAX
    LDA $0B16,X
    CMP #$0140
    BCC classifyActive
    CMP #$FFC0
    BCC nextActive

classifyActive:
    ; Convert the doubled link to a raw ID only at the dispatch boundary.
    ; Classify the full $103E word: indirect selectors are not resolved here.
    TYA
    LSR A
    STA $12
    ASL A
    TAX
    LDA $103E,X
    CMP #$0001
    BNE drawActiveNow
    ; Per-entity $280C links hold raw IDs; prepend to pending head $16.
    LDA $16
    STA $280C,X
    LDA $12
    STA $16
    BRA nextActive

drawActiveNow:
    ; Other selectors draw first, in active-list order, if not clipped.
    ; Disabled graphics bank/frame selectors are rejected later by $A0E3.
    LDA $12
    JSR $A0CA              ; drawEntityById; nested isolated DP.

nextActive:
    ; Reload the saved current link after callbacks, then read next live.
    LDY $14
    TYA
    LSR A
    ASL A
    TAX
    LDY $0A9E,X
    STY $14

checkActive:
    ; Only $FFFF ends traversal; an empty head invokes no callback.
    TYA
    INC A
    BNE clipActiveY
    BRA checkPending

beginDepthSelection:
    ; Seed maximum and chosen predecessor from the pending head.
    ; $0BCA is compared as an unsigned 16-bit world-Y word.
    LDA $16
    STA $10
    LDA $16
    ASL A
    TAX
    LDA $0BCA,X
    STA $0E
    LDA #$FFFF
    STA $04
    LDA $16
    STA $02
    LDY $280C,X
    BRA checkDepth

compareDepth:
    ; Replace on greater OR equal: pending order reverses active order,
    ; so equal depths draw in original active-list order.
    TYA
    ASL A
    TAX
    LDA $0BCA,X
    CMP $0E
    BCC nextDepth
    STA $0E
    STY $10
    LDA $02
    STA $04

nextDepth:
    STY $02
    TYA
    ASL A
    TAX
    LDY $280C,X

checkDepth:
    TYA
    INC A
    BNE compareDepth
    ; Draw the selected raw ID, then unlink it from the pending list.
    LDA $10
    JSR $A0CA              ; drawEntityById; nested isolated DP.
    LDA $04
    INC A
    BEQ removeHead
    ; A predecessor exists: splice around the selected entry.
    LDA $04
    ASL A
    PHA
    LDA $10
    ASL A
    TAX
    LDA $280C,X
    PLX
    STA $280C,X
    BRA checkPending

removeHead:
    ; Otherwise the chosen entry was the head; advance the pending head.
    LDA $10
    ASL A
    TAX
    LDA $280C,X
    STA $16

checkPending:
    LDA $16
    INC A
    BNE beginDepthSelection

returnDepth:
    PLD
    RTS
