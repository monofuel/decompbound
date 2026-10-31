; Enqueue bank-C4 effect definitions for the current entity.
; File $00AC43..$00AD55 (275 bytes), SNES $C0AC43. JSL; RTL.
; Native M16/X16, decimal clear, DBR=$7E. X and DP+$88 are the entity
; byte offset. Word $2400 is the inherited queue index 0..3.
; Stores $00C4 at DP+$04 and $000B. Clobbers A/X/Y/P and DP+$00..$09.
; Preserves D, DBR and stack depth. Callers restore $000B after RTL.
; Evidence: docs/graphics.md (default callback overlay helper).
    .a16
    .i16

enqueueEntityEffects:
    ; Sequence long-pointer bank and enqueue definition bank are C4.
    LDA #$00C4
    STA $04
    STA $000B

    ; $2BAA bit 0 selects a 0- or 5-byte definition-record addend.
    LDY #$0000
    LDA $2BAA,X
    AND #$0001
    BEQ storeRecordAddend
    LDY #$0005
storeRecordAddend:
    STY $00

    ; Bits 2/3 choose the chunk-size overlay, skip it, or jump to signed.
    LDA $2BAA,X
    AND #$000C
    BEQ restoreEntityAfterSize
    CMP #$0004
    BEQ enqueueSignedEffect

    ; Bit 3 set ($8 or $C): $2A7E is bytes per graphics chunk.
    LDA $2A7E,X
    CMP #$0040
    BNE enqueueOtherSizeEffect

    LDA $301E,X             ; sequence pointer
    STA $02
    LDA $305A,X             ; remaining duration
    BNE haveSize64Duration
    LDA #$3096              ; output definition field
    JSR $AD56               ; advanceEntityEffectSequence
    LDX $88
    STA $301E,X
    TYA
    STA $305A,X
haveSize64Duration:
    DEC $305A,X             ; duration 0 from the sequence wraps to $FFFF
    LDA $0B16,X             ; origin X
    STA $06
    LDY $0B52,X             ; origin Y
    LDA $3096,X
    CLC
    ADC $00
    LDX $06
    JSR $8C58               ; enqueueOamDefinition near entry
    BRA restoreEntityAfterSize

enqueueOtherSizeEffect:
    LDA $30D2,X
    STA $02
    LDA $310E,X
    BNE haveOtherSizeDuration
    LDA #$314A
    JSR $AD56
    LDX $88
    STA $30D2,X
    TYA
    STA $310E,X
haveOtherSizeDuration:
    DEC $310E,X
    LDA $0B16,X
    STA $06
    LDA $0B52,X
    CLC
    ADC #$0008              ; origin Y is eight pixels down
    TAY
    LDA $314A,X
    CLC
    ADC $00
    ADC $00                 ; Addend twice; retain the first ADC's carry.
    LDX $06
    JSR $8C58

restoreEntityAfterSize:
    LDX $88
    LDA $2E7A,X             ; overlay control; 0 ends the helper
    BNE overlayControlLive
    RTL
overlayControlLive:
    BPL enqueueBit14Effect  ; bit 15 clear: skip the signed family

enqueueSignedEffect:
    ; Bits 2/3 == $4 land here without testing $2E7A. Offsets below
    ; $002E skip this family and the bit-14 family.
    CPX #$002E
    BCC returnEffects
    LDA $2F6A,X
    STA $02
    LDA $2FA6,X
    BNE haveSignedDuration
    LDA #$2FE2
    JSR $AD56
    LDX $88
    STA $2F6A,X
    TYA
    STA $2FA6,X
haveSignedDuration:
    DEC $2FA6,X
    LDA $0B16,X
    STA $06
    LDY $0B52,X
    LDA $2FE2,X
    BEQ enqueueBit14Effect  ; zero output skips this enqueue only
    CLC
    ADC $00
    LDX $06
    JSR $8C58
    LDX $88

enqueueBit14Effect:
    LDA $2E7A,X
    AND #$4000
    BEQ returnEffects
    CPX #$002E
    BCC returnEffects
    LDA $2EB6,X
    STA $02
    LDA $2EF2,X
    BNE haveBit14Duration
    LDA #$2F2E
    JSR $AD56
    LDX $88
    STA $2EB6,X
    TYA
    STA $2EF2,X
haveBit14Duration:
    DEC $2EF2,X
    LDA $0B16,X
    STA $06
    LDY $0B52,X
    LDA $2F2E,X
    CLC
    ADC $00
    LDX $06
    JSR $8C58
returnEffects:
    RTL
