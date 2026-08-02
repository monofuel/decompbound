; writeApuPort0
; Ported from snes_src/apu_port_io.nim :: writeApuPort0 (evidence-preserving re-port).
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
; --- writeApuPort0 ---
; Write A (8-bit) to APU port 0 ($2140) and return.
;
; Literally `SEP #$20 / STA long $2140 / REP #$30 / RTL`. Call site in the
; song loader at $C4FD12 (after package upload). Fire-and-forget port poke.
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
STA $002140  ; ApuPort0
REP #$30  ; StatusMX
.a16
.i16
RTL

