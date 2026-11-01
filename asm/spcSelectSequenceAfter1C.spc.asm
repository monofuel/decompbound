; Conditional selection, APU $2E11..2E1C / file $262953..26295E (12B).
; Bounded direct CALL/RET entry: DP zero. If $04==$1C, call $0772 with A=2;
; otherwise return A=$04, C/N/Z from CMP $1C, preserving X/Y/H/V/P/I/B.
; Selection follows $0772's cursor/reset/pending-KOFF contract, without DSP I/O.
; Both native returns balance. TODO: identify an original caller; no caller or
; broader transition policy is established by this direct-entry contract.
; See docs/audio.md for the selected-sequence lifecycle.
    .org $2E11
spcSelectSequenceAfter1C:
    MOV A, $04
    CMP A, #$1C
    BNE returnSelection
    MOV A, #$02
    CALL $0772             ; Select sequence 2; original generic selection helper.
returnSelection:
    RET
