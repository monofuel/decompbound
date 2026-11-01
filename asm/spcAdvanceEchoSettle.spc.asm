; Advance echo settle state, APU $05C6..05CC / file $260108..26010E (7 bytes).
; Service-pass fall-through entry: direct page zero, state $4C and request $4D.
; Increment $4C modulo 256 iff unequal; preserve $4D. Preserves A/X/Y/SP and
; PSW H/V/P/I/B. C compares old $4C >= $4D; N/Z reflect equality comparison
; when equal, otherwise the incremented byte, including $FF wrapping to zero.
; Falls into phase producer $05CD, which expects the existing pushed timer byte.
; Earlier service calls $0596..05C5 remain outside this source; no absolute
; update cadence is established here. See docs/audio.md for the flush gate.
    .org $05C6
spcAdvanceEchoSettle:
    CMP $4C, $4D
    BEQ $05CD
    INC $4C                ; No clamping or special treatment of the high bit.
    ; Fall through $05CD: spcAdvancePhase.
