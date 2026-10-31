; Create an entity and attach an action script, file $009321..$00943B
; (283 bytes). JSL $C09321: native M16/X16, decimal clear, DBR=$7E.
; A=script selector, X/Y=initial coordinates. $0A4C/$0A4E are inclusive
; lower and exclusive upper entity IDs; both are doubled in place to byte
; offsets even on failure. Success: A=raw entity ID, carry clear. Failure:
; A=0, carry set, neither list consumed. Entity ID 0 is valid; test carry.
; Shared RTL at $C0943B is also the default far-callback body.
; Preserves D, DBR and stack depth. Evidence: docs/scripts.md.

    .a16
    .i16

createEntity:
    ; Saved across allocation; selector is restored after the active append.
    PHA
    PHY
    PHX

    ; Bounds start as entity IDs and stay doubled even if allocation fails.
    LDA $0A4C
    ASL A
    STA $0A4C              ; Inclusive lower bound, byte-offset units.
    LDA $0A4E
    ASL A
    STA $0A4E              ; Exclusive upper bound, byte-offset units.
    JSR $9C02              ; allocateEntity; also requires a free script state.
    BCC entityAllocated

    ; Carry remains set from allocateEntity. A=0 here is failure, not ID 0.
    PLA
    PLA
    PLA
    LDA #$0000
    RTL

entityAllocated:
    JSR $9D03              ; allocateScriptState; $0A54 already non-negative.
    TYA
    STA $0ADA,X            ; Attached script-state offset.
    LDA #$FFFF
    STA $125A,Y            ; Allocator left this next-link stale.

    LDA #$9FC8
    STA $121E,X            ; Default callback; pause bit 14 skips this.
    LDA #$A023
    STA $11A6,X            ; Default callback; still runs while paused.
    LDA #$A3A4
    STA $11E2,X            ; Default callback.

    ; TODO: Identify the eight template fields; retain their exact copy mapping.
    LDA $0A38
    STA $0E5E,X
    LDA $0A3A
    STA $0E9A,X
    LDA $0A3C
    STA $0ED6,X
    LDA $0A3E
    STA $0F12,X
    LDA $0A40
    STA $0F4E,X
    LDA $0A42
    STA $0F8A,X
    LDA $0A44
    STA $0FC6,X
    LDA $0A46
    STA $1002,X
    LDA $0A4A
    STA $103E,X            ; Rendering queue group.

    LDA #$8000
    STA $0C42,X
    STA $0C7E,X
    STA $0CBA,X            ; TODO: meaning of this $8000 initializer.

    PLA
    STA $0B8E,X            ; Initial world X coordinate.
    STA $0B16,X            ; Render X; $A023 later subtracts scroll $0031.
    PLA
    STA $0BCA,X            ; Initial world Y coordinate.
    STA $0B52,X            ; Render Y; $A023 later subtracts scroll $0033.
    LDA $0A48
    STA $0C06,X
    JSR $9C57              ; appendActiveEntity.
    PLA
    BRA attachScriptSelector

replaceAttachedScript:
    ; JSL $C093B9: A=selector, X=entity offset. JSL-only; RTL at $C0943B.
    ; Returns the old state chain (restocking free states), then allocates.
    PHA
    JSR $9C99              ; returnScriptStateChain.
    JSR $9D03              ; allocateScriptState.
    TYA
    STA $0ADA,X
    LDA #$FFFF
    STA $125A,Y
    PLA

attachScriptSelector:
    STA $0A62,X            ; Selector; bit 15 set would mean inactive.
    PHX
    ASL A
    ADC $0A62,X            ; selector*3; decimal clear, selector < $8000.
    TXY
    TAX
    LDA $C400D6,X          ; Three-byte table +2: bank (high byte masked later).
    TAY
    LDA $C400D4,X          ; Three-byte table +0: script pointer word.
    PLX
    STZ $10F2,X
    DEC $10F2,X            ; Frame $FFFF; graphics dispatcher rejects it.
    STZ $0DAA,X
    STZ $0CF6,X
    STZ $0DE6,X
    STZ $0D32,X
    STZ $0E22,X
    STZ $0D6E,X            ; Action/animation words; reset on selector attach.
    BRA installScriptPointer

replaceScriptById:
    ; JSL $C093F9: X=entity ID, A=script pointer, Y=bank word.
    PHA
    TXA
    ASL A
    TAX                    ; ID to byte offset.
    PLA
    JSL $C09403            ; replaceScriptByOffset.
    RTL

replaceScriptByOffset:
    ; JSL $C09403: X=already-doubled offset, A=pointer, Y=bank. JSL-only.
    ; Inactive $0A62 (bit 15) spins. Selector and frame/motion stay as-is.
    PHY
    PHA
    LDA $0A62,X
    BPL scriptEntityActive
inactiveEntityHalt:
    BRA inactiveEntityHalt
scriptEntityActive:
    JSR $9C99              ; returnScriptStateChain.
    JSR $9D03              ; allocateScriptState.
    TYA
    STA $0ADA,X
    LDA #$FFFF
    STA $125A,Y
    PLA
    PLY

installScriptPointer:
    PHY
    PHA
    JSR $9DA1              ; Far callback $107A=$943B, $10B6=$00C0.
    TXY
    LDX $0ADA,Y            ; X=state offset, Y=entity offset.
    PLA
    STA $13FE,X            ; Script PC word.
    PLA
    AND #$00FF
    STA $148A,X            ; Script bank, high byte forced 0.
    STZ $1372,X            ; Wait counter.
    STZ $12E6,X            ; TODO: script-state field at $12E6.
    TYA
    LSR A                  ; Entity byte offset back to raw ID.
    CLC                    ; Success; distinguishes ID 0 from failure.
    RTL                    ; Default far-callback body is this RTL at $C0943B.
