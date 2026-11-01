; Package-bank preservation helper, file $04FB42..04FB57 / SNES $C4FB42..C4FB57 (22B).
; JSR/RTS in bank C4; native mode, decimal clear, A is the caller's full bank word.
; Force A/X16, preserve A/X/Y/D/DBR, set DBR:$B547=$FFFF (address mask).
; Scratch word at (entry D-2)&$FFFF must be writable and not alias the live
; hardware stack. Intended cache context uses DBR=$7E; this helper does not set it.
; C/V follow D-16 arithmetic; N/Z follow restored D. Caller frame balances;
; incoming M/X/C and other arithmetic flags are not restored.
    .a16
    .i16
prepareApuPackageBank:
    REP #$31
    PHD
    PHA
    TDC
    ADC #$FFF0
    TCD
    PLA
    STA $0E               ; Temporary word immediately below the caller's D frame.
    LDA #$FFFF
    STA $B547
    LDA $0E
    PLD
    RTS
