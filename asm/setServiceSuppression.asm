; Set the persistent service-work suppression byte at DBR:$9622 to one.
; File $03E4D4..$03E4DF, SNES $C3E4D4; JSL entry in native mode.
; DBR must select the intended WRAM bank (normally $7E).
; $C12DEA tests this byte after advancing RNG; suppression does not stop RNG.
; $C3E4EA calls this after one temporarily unsuppressed service call.
; The neighboring byte, X/Y, DBR, and direct page are preserved.
; Returns with 16-bit A/X/Y, carry/negative/zero clear. A's high byte is
; preserved and its low byte becomes one; the full accumulator is not set to one.
.a16
.i16
REP #$31 ; Clear accumulator/index width bits and carry.
SEP #$20 ; Store the enabled suppression flag as one byte.
.a8
LDA #$01
STA $9622
REP #$20
.a16
RTL
