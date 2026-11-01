; Load/select a song, file $04FBBD..04FD17 / SNES $C4FBBD (347B).
; JSL/RTL: native mode, A=trusted song ID; DBR=$7E, decimal clear.
; REP establishes M16/X16. D must support the twenty-byte local frame and
; nested scratch, disjoint from the stack; incoming D is restored with PHD/PLD.
; Registers/status are clobbered by this routine and its original callees.
; Equal current-song ID skips all I/O. Otherwise compare three package slots,
; upload changed non-$FF entries, then publish the requested song on port zero.
; No ID/table bound check or upload rollback is added. Handshakes can wait.
; Slot one's alternate cache retains the initializer seed; see docs/audio.md
; for cache provenance, the nominal-row limit and original execution evidence.

    .a16
    .i16
loadSong:
    REP #$31
    .a16
    .i16
    PHD
    PHA
    TDC
    ADC #$FFEC  ; Twenty-byte local DP frame; initial REP cleared carry.
    TCD
    PLA
    TAX
    STX $12
    CPX $B53B  ; Current requested-song cache.
    BNE notSameSong
    JMP exit

notSameSong:
    ; Prepare the changed-song handshake.
    LDA $B4B6  ; Nonzero skips $57. TODO: explain the wider flag policy.
    BNE afterWarmPoke
    JSL $C0AC01  ; Publish port-three $57 before an ordinary warm change.

afterWarmPoke:
    ; Special IDs retain the current stop/idle state.
    LDX $12
    CPX #$A0  ; IDs $A0..A7 skip the stop handshake.
    BCC stopMusic
    CPX #$A7
    BCC afterStopMusic
    BEQ afterStopMusic

stopMusic:
    LDA #$01
    JSL $C0AC0C  ; Phase-toggle port one with command 1.
    JSL $C0ABC6  ; Wait for idle, then invalidate current-song cache.

afterStopMusic:
    ; Resolve first package slot at (song ID - 1) * 3.
    LDX $12
    STX $B53B  ; Record the request before uploading.
    TXY
    DEY
    STY $10
    TYA
    STA $04
    ASL A
    ADC $04
    TAX
    LDA $C4F70A,X
    AND #$FF
    STA $0E
    CMP $B53D
    BEQ pack0Done
    CMP #$FF  ; Unused slot leaves its old cache intact.
    BEQ pack0Done
    STA $B53D  ; Changed first-slot package cache.

    ; Resolve a three-byte [bank,address-low,address-high] package pointer.
    LDA #$F947
    STA $06
    LDA #$C4
    STA $08
    LDA $0E
    STA $04
    ASL A
    ADC $04
    STA $02
    LDX $06
    STX $0A
    LDX $08
    STX $0C
    CLC
    ADC $0A
    STA $0A
    LDA [$0A]
    AND #$FF
    JSR $FB42  ; Prepare bank and full $B547 address mask.
    TAX
    LDA $02
    INC A
    CLC
    ADC $06
    STA $06
    LDA [$06]
    AND $B547  ; Package address masked by the original helper result.
    JSL $C0AB06  ; Original uploader: A=package address, X=bank.

pack0Done:
    ; Resolve middle slot, including the retained-seed cache.
    LDY $10
    TYA
    STA $04
    ASL A
    ADC $04
    TAX
    INX
    LDA $C4F70A,X
    AND #$FF
    STA $0E
    CMP $B53F
    BEQ pack1Done
    CMP #$FF  ; Unused slot leaves its old cache intact.
    BEQ pack1Done
    CMP $B543  ; Retained initializer seed; match leaves $B53F unchanged.
    BEQ pack1Done
    STA $B53F  ; Changed middle-slot package cache.

    ; Resolve a three-byte [bank,address-low,address-high] package pointer.
    LDA #$F947
    STA $06
    LDA #$C4
    STA $08
    LDA $0E
    STA $04
    ASL A
    ADC $04
    STA $02
    LDX $06
    STX $0A
    LDX $08
    STX $0C
    CLC
    ADC $0A
    STA $0A
    LDA [$0A]
    AND #$FF
    JSR $FB42  ; Prepare bank and full $B547 address mask.
    TAX
    LDA $02
    INC A
    CLC
    ADC $06
    STA $06
    LDA [$06]
    AND $B547  ; Package address masked by the original helper result.
    JSL $C0AB06  ; Original uploader: A=package address, X=bank.

pack1Done:
    ; Resolve last slot; it has no alternate-cache comparison.
    LDY $10
    TYA
    STA $04
    ASL A
    ADC $04
    TAX
    INX
    INX
    LDA $C4F70A,X
    AND #$FF
    STA $0E
    CMP $B541
    BEQ pack2Done
    CMP #$FF  ; Unused slot leaves its old cache intact.
    BEQ pack2Done
    STA $B541  ; Changed last-slot package cache.

    ; Resolve a three-byte [bank,address-low,address-high] package pointer.
    LDA #$F947
    STA $06
    LDA #$C4
    STA $08
    LDA $0E
    STA $04
    ASL A
    ADC $04
    STA $02
    LDX $06
    STX $0A
    LDX $08
    STX $0C
    CLC
    ADC $0A
    STA $0A
    LDA [$0A]
    AND #$FF
    JSR $FB42  ; Prepare bank and full $B547 address mask.
    TAX
    LDA $02
    INC A
    CLC
    ADC $06
    STA $06
    LDA [$06]
    AND $B547  ; Package address masked by the original helper result.
    JSL $C0AB06  ; Original uploader: A=package address, X=bank.

pack2Done:
    ; Re-form the requested ID and publish it after all uploads.
    LDY $10
    TYA
    INC A
    JSL $C0ABBD  ; Publish song ID to port zero.

exit:
    PLD
    RTL
