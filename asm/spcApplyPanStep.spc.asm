; Apply transition step, APU $0CD3..$0CF6 / file $260815..$260838.
; CALL/RET: DP zero, X=even channel offset, YA=$0330 for pan or $0300 for
; channel volume. Current word is [YA+X], step at +$10,
; target integer at +$20. ORs caller mask $47 into dirty mask $5E.
; Nonzero OR adds step modulo 65536; zero OR writes target*256. The branch
; at $0CD3 uses OR's N/Z, not the caller's decrement flags: no normal final snap.
; Preserves X; clobbers A/Y/PSW and DP $14..$17. See docs/audio.md.
; Bases $0330/$0300 here and $0360 below keep low-byte pointer offsets in page.
; Offset addition does not propagate carry into the high pointer byte.
    .org $0CD3
spcApplyPanStep:
    OR $5E, $47            ; Both marks dirty channels and selects the path.

; Shared CALL entry $0CD6: YA=$0360 for pitch, X=channel, incoming Z selects
; target snap (Z=1) versus step addition (Z=0). The pitch caller's DEC $A0+X
; supplies this flag; this entry neither reads nor changes dirty mask $5E.
; Same scratch/register effects and RET as above. The final pitch tick snaps.
spcApplyTransitionStep:
    MOVW $14, YA
    MOVW $16, YA
    PUSH X
    POP Y                  ; Indexed indirect addressing now uses channel Y.
    CLRC                   ; Preserves Z from the dirty OR or pitch duration DEC.
    BNE addStep

    ; Z=1 selects the target integer and clears the fraction.
    ADC $16, #$1F          ; Target is at base+$20; Y advances once below.
    MOV A, #$00
    MOV [$14]+Y, A
    INC Y
    BRA addAndStoreByte
addStep:
    ADC $16, #$10          ; Step word follows current word by $10 bytes.
    CALL addCurrentByte    ; Low-byte carry feeds the following high-byte sum.
    INC Y

; Local CALL entry $0CF0: $14/$16 are current/source pointers, Y byte index.
; Adds source and incoming carry to current byte; preserves X/Y and pointers.
; RET returns A=result and arithmetic flags, also used by the high-byte tail.
addCurrentByte:
    MOV A, [$14]+Y
addAndStoreByte:
    ADC A, [$16]+Y
    MOV [$14]+Y, A
    RET
