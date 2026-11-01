; Startup continuation, APU $050C..0542 / file $26004E..260084 (55 bytes).
; Fall-through from $0500: DP zero, A=0, SP=$CF, cleared $00..DF; resident
; initialization/descriptor code must be loaded. Reads hardware DSP EDL once.
; Clears auxiliary RAM through $16A5, seeds feedback, initializes echo/master
; DSP state and timer zero; no host output-port write. Ends by branching $0546.
; A=1, X=0, Y=$5D, SP=$CF; C=1/H=1/V=0/N=0/Z=0/P=0, I/B preserved.
; Echo settle depends on old EDL readback; input ports are cleared by CONTROL.
; Native CALL frames use page one down to $01CC. See docs/audio.md.
    .org $050C
spcInitializeDriverHardware:
    CALL $16A5            ; Clear auxiliary arrays/pages; shared $2FC8 tail returns.
    MOV A, #$55
    MOV $18, A            ; Feedback word seed, not an echo coefficient.
    MOV $19, A

    MOV A, #$00
    INC A
    CALL $0B2C            ; Request EDL=1, settle/reset old hardware, ESA=$F7.
    SET1 $48.5            ; Buffered FLG: disable echo writes until F5 clears it.
    MOV A, #$70
    MOV Y, #$0C
    CALL $0749            ; Unconditional DSP MVOLL=$70.
    MOV Y, #$1C
    CALL $0749            ; MVOLR=$70; writer preserves A.
    MOV A, #$6C
    MOV Y, #$5D
    CALL $0749            ; Sample directory page $6C00.

    MOV A, #$F0
    MOV !$00F1, A         ; Disable timers, clear all CPU-input ports; map IPL.
    MOV A, #$10
    MOV !$00FA, A         ; Timer-zero target; timers one/two targets untouched.
    MOV $53, A            ; Initial tempo integer; fractional $52 remains zero.
    MOV A, #$01
    MOV !$00F1, A         ; Enable only timer zero and unmap IPL.
    BNE $0546             ; A=1 leaves Z clear: skip $0543's bypass jump.
