; Read one original 8-by-8 tile word from a 32-by-32 map arrangement.
; File $00035B..$000390 inclusive; SNES $C0035B; length 54 bytes.
;
; Entry: native-mode CPU, A = arrangement ID, X = tile column 0..3,
; Y = tile row 0..3. The routine forces 16-bit A/X/Y and clears carry.
; D must leave sixteen writable direct-page bytes below its incoming value.
; The caller has loaded the selected drawing tileset's arrangements into
; $7F8000 using the resource pointer table at $EF10AB ($C00949).
;
; Return: A is the original SNES tile/attributes word at
; $7F8000 + arrangementID*32 + tileRow*8 + tileColumn*2.
; X, Y, D, DBR, and stack depth are preserved. Status is not preserved.
; The selected word retains palette, priority, and horizontal/vertical flip
; fields. Its tile number indexes the separately loaded $EF105B CHR resource.
;
; Independent evidence: tests/integration_world_map_assets.nim runs this
; original routine over all sixteen words of every arrangement in all twenty
; drawing tilesets, after the original decompressor fills $7F8000.

.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFF0 ; Allocate sixteen direct-page scratch bytes with carry cleared.
TCD
PLA
STA $0E ; Arrangement identity.
LDA #$8000 ; Arrangement buffer low address.
STA $06
LDA #$007F ; Arrangement buffer bank.
STA $08
LDA $0E
ASL A
ASL A
ASL A
ASL A
ASL A ; Sixteen two-byte tile words occupy thirty-two bytes.
CLC
ADC $06
STA $06
TXA
ASL A ; Tile-column byte offset.
STA $02
TYA
ASL A
ASL A
ASL A ; Four two-byte words per tile row.
CLC
ADC $02
CLC
ADC $06
STA $06
LDA [$06]
PLD
RTL
