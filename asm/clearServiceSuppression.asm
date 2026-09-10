; Clear the persistent service-work suppression byte at DBR:$9622.
; File $03E4CA..$03E4D3, SNES $C3E4CA; JSL entry in native mode.
; DBR must select the intended WRAM bank (normally $7E).
; $C12DEA tests the low byte after advancing RNG and returns early if set.
; $C3E4E2 calls this before a service step, then calls the setter at $C3E4EA.
; No graphics data is loaded here. The neighboring byte is preserved.
; A, X, Y, DBR, and direct page are preserved for valid entry widths.
; Returns with 16-bit A/X/Y and carry clear; other status bits unchanged.
.a16
.i16
REP #$31 ; Clear accumulator/index width bits and carry.
SEP #$20 ; Write only the suppression byte.
.a8
STZ $9622
REP #$20
.a16
RTL
