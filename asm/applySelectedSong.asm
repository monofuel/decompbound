; Apply selected song candidate, file $0069AF..0069EC / SNES $C069AF..C069EC (62B).
; JSL/RTL, native, decimal clear, DBR=$7E; valid nonaliasing DP/stack scratch.
; Local DP frame is14 bytes; loadSong's nested scratch extends to entry DP-36.
; Nonzero $5DD8 blocks all work. Otherwise copy selected pointer $5E38/$5E3A;
; equal candidate $5DD6/current $5DD4 returns without loading or port output.
; Changed candidate updates $5DD4 BEFORE calling loadSong, then sends selected
; record byte+3 through writeApuPort1Toggled. No rollback or pointer/ID checks.
; D/DBR restored, A/X16; registers/other flags follow callees, N/Z from saved D.
; Port helper toggles $1ACB; loadSong can wait/upload. No musical identity inferred.
    .a16
    .i16
applySelectedSong:
    REP #$31
    PHD
    TDC
    ADC #$FFF2
    TCD
    LDA $5DD8
    BNE done

    LDA $5E38
    STA $06
    LDA $5E3A
    STA $08
    LDA $5DD6
    CMP $5DD4
    BEQ done

    LDA $5DD6
    STA $5DD4              ; Selection is committed before the potentially waiting loader.
    LDA $5DD6
    JSL $C4FBBD            ; Real loadSong; its DP frame lies below this saved record pointer.
    SEP #$20
    LDY #$0003
    LDA [$06],Y            ; Full far-pointer addition; no record bounds check.
    REP #$20
    AND #$00FF
    JSL $C0AC0C            ; Publish full record byte OR phase, then toggle latch bit7.
done:
    PLD
    RTL
