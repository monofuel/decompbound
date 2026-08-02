; writeApuPort1Toggled
; Ported from snes_src/apu_port_io.nim :: writeApuPort1Toggled (evidence-preserving re-port).
;
; Small APU port I/O helpers next to the upload streamer
; (file 0x00ABBD+ / SNES $C0ABBD+).
;
; docs/audio.md: "SFX are fire-and-forget port pokes to the resident driver."
; These three are RTL-bounded, byte-short, and named only for the port action
; each byte stream verifiably performs. ADOPTED mid-region after uploadApuPackages
; (adopted.nim); gold-gated by tests/test_regions.nim.
;
;
; --- writeApuPort1Toggled ---
; Write `(A | $1ACB)` to APU port 1 ($2141), then toggle bit 7 of $1ACB.
;
; Entry: A holds the low command bits; $1ACB supplies the alternating phase
; bit used by dual-phase APU handshakes. Song loader uses this (e.g. JSL at
; $C4FBEC with A = 1) before stopping/re-uploading music. Named for the
; verified port + toggle, not a higher-level SFX id.
;
; Named constants (values inlined below; names preserved as comments):
;   WriteApuPort0Offset = $ABBD
;   WriteApuPort0Snes = $C0ABBD
;   WriteApuPort3Cmd57Offset = $AC01
;   WriteApuPort3Cmd57Snes = $C0AC01
;   WriteApuPort1ToggleOffset = $AC0C
;   WriteApuPort1ToggleSnes = $C0AC0C
;   ApuPort0 = $2140
;   ApuPort1 = $2141
;   ApuPort3 = $2143
;   ApuPort1PhaseLatch = $1ACB
;     Phase / handshake latch OR'd into the byte written to $2141; bit 7 is
;     toggled after each poke so successive commands alternate the high bit.
;   PhaseToggleBit = $80
;   ApuPort3Command57 = $57
;     Opaque command byte written to $2143 by the song-loader warm path.
;     TODO: identify what the resident driver does with $57 on port 3.
;   StatusM = $20
;   StatusMX = $30
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
ORA $1ACB  ; ApuPort1PhaseLatch — Phase / handshake latch OR'd into the byte written to $2141; bit 7 is
STA $002141  ; ApuPort1
LDA #$80  ; PhaseToggleBit
EOR $1ACB  ; ApuPort1PhaseLatch — Phase / handshake latch OR'd into the byte written to $2141; bit 7 is
STA $1ACB  ; ApuPort1PhaseLatch — Phase / handshake latch OR'd into the byte written to $2141; bit 7 is
REP #$30  ; StatusMX
.a16
.i16
RTL
