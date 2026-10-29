; Read a row-major 256-by-128-pixel sector attribute word.
; File $000AA1..$000AC4, SNES $C00AA1; native-mode long entry.
; A=world X in pixels, X=world Y in pixels; DBR=$7E for scratch and result.
; Decimal mode is clear, as in the original binary-coordinate callers.
; Word index=(worldY&$FF80)/4+(worldX>>8), doubled for D7B200.
; In atlas bounds this is ((worldY/128)*32+worldX/256)*2.
; Returns attributes in A and stores WRAM $438E. X is clobbered.
; Y, DBR, original D and stack are preserved.
; REP #$31 forces A/X/Y16 and clears carry before allocating 14 scratch bytes.
.a16
.i16
REP #$31
PHD
PHA
TDC
ADC #$FFF2
TCD
PLA
XBA
AND #$00FF
STA $02
TXA
AND #$FF80
LSR A
LSR A
CLC
ADC $02
ASL A
TAX
LDA $D7B200,X
STA $438E
PLD
RTL
