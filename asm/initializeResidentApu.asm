; Resident package initialization, file $04FB58..04FBBC / SNES $C4FB58..C4FBBC (101B).
; JSL/RTL: native, decimal clear; writable/nonaliasing D-frame scratch through
; entry D-20..D-1, native stack valid. DBR=$7E supplies intended WRAM caches
; and the uploader's initial low-WRAM pointer stores; D/DBR are preserved.
; Unconditionally upload the first song's third package byte; no FF/bounds test.
; Invalidate slot0/2 caches, seed mutable slot1 and alternate cache BEFORE upload;
; set $B549=1 only AFTER its return. Current-song cache $B53B is untouched.
; Returns A=1,A/X16,N/Z from restored D; X/Y/C/V follow the uploader, whose
; completion enables NMI. Cold/warm handshake belongs to original $C0AB06.
    .a16
    .i16
initializeResidentApu:
    REP #$31
    PHD
    TDC
    ADC #$FFEE
    TCD
    LDA #$FFFF
    STA $B541
    STA $B53D
    LDA $C4F70C           ; First song row, package slot two; mask away following byte.
    AND #$00FF
    STA $10
    STA $B543
    STA $B53F

    LDA #$F947
    STA $06
    LDA #$00C4
    STA $08
    LDA $10
    STA $04
    ASL A
    ADC $04              ; Byte package index: no shift carry, so exact index*3.
    TAY
    STY $0E
    TYA
    LDX $06
    STX $0A
    LDX $08
    STX $0C
    CLC
    ADC $0A
    STA $0A
    LDA [$0A]            ; Far-table record is bank, address-low, address-high.
    AND #$00FF
    JSR $FB42            ; prepareApuPackageBank; preserves bank word, sets maskFFFF.
    TAX
    LDY $0E
    TYA
    INC A
    CLC
    ADC $06
    STA $06
    LDA [$06]
    AND $B547
    JSL $C0AB06          ; Original uploader; may request resident reset or use IPL readiness.
    LDA #$0001
    STA $B549            ; Enable position-change song selection after the seed upload.
    PLD
    RTL
