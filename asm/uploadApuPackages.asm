; uploadApuPackages
; Ported from snes_src/apu_upload.nim :: uploadApuPackages (evidence-preserving re-port).
;
; APU package upload — SPC700 IPL handshake + block streamer
; (file 0x00AB06 / SNES $C0AB06).
;
; Documented in docs/audio.md Findings and matched by the HLE capture path in
; snesbus.nim ($2140-$2143). ADOPTED into the region registry (adopted.nim):
; convert_all carves these 183 bytes out of the enclosing traced region
; (0x00AB06-0x00AC2B), so this curated source produces $C0AB06..$C0ABBC.
; Gold-gated by tests/test_regions.nim.
;
;
; --- uploadApuPackages ---
; Stream music/driver packages into APU RAM via the SPC700 IPL protocol.
;
; Entry (JSL): native mode, 16-bit A/X. A = package stream address, X = bank
; (stored as a 24-bit far pointer at $C6/$C8). Sets DBR and D to 0 so
; `LDA [$C6],Y` walks the caller's stream.
;
; Handshake: wait for IPL ready ($BBAA on $2140), or JSR the local reboot
; helper that writes $FF until $BBAA reappears. Disables NMI for the transfer
; (clears bit 7 of $001E / $4200), then for each block reads
; a length word, then address/payload only when nonzero. Zero length alone
; selects entry $0500. Writes addr to $2142, a flag from (len >= 1) to $2141,
; and streams payload bytes as 16-bit counter+data stores to $2140.
;
; Wait loop at $C0AB90 polls $2140 until 0 after the final block, forces
; NMI enabled, PLD/PLB, RTL. The IPL reboot helper at $C0ABA8 is only reached
; via the internal JSR (no external callers).
;
; Call sites: song loader $C4FBBD path (JSL $C0AB06 at $C4FBB1 and siblings).
;
; Named constants (values inlined below; names preserved as comments):
;   ApuUploadOffset = $AB06
;   ApuUploadSnes = $C0AB06
;   PackagePtrLo = $C6
;     24-bit far pointer to the package stream: lo word at $00C6, bank byte at
;     $00C8. Caller passes A = address, X = bank (REP #$30 on entry).
;   PackagePtrBank = $C8
;   ApuPort0 = $2140
;     APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
;     command/flag → $2141, counter+data pairs → $2140 (16-bit STA writes both
;     $2140 counter and $2141 payload when M is clear).
;   ApuPort1 = $2141
;   ApuPort2 = $2142
;   NmiEnableShadow = $1E
;     NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
;     set after, and mirrored to the hardware register.
;   NmiEnableMask = $80
;   NmiTimenAddr = $4200
;   IplReadySignature = $BBAA
;     SPC700 IPL ready signature read from $2140/$2141 as a 16-bit word.
;   IplBeginTransfer = $CC
;     First transfer kick-off counter written to $2140 (IPL start-transfer).
;     TODO: full IPL command set; 0xCC is the documented begin-transfer byte.
;   IplRebootCommand = $FF
;     $FF written to $2140 forces a running driver back to the IPL (reboot
;     between tracks). Same magic the snesbus HLE treats as ahsRunning → ahsIdle.
;     TODO: confirm all IPL reboot paths; this matches the observed warm reboot.
;   DefaultApuEntry = $0500
;     Default entry address when a package ends with len == 0 (kick SPC at $0500).
;   ZeroBankOrDp = $00
;     Zero data-bank / direct-page for long-pointer reads of the package stream.
;   StatusM = $20
;   StatusMX = $30
;
.a16
.i16
REP #$30  ; StatusMX
.a16
.i16
STA $00C6  ; PackagePtrLo — 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
STX $00C8  ; PackagePtrBank
PHB
PEA $0000  ; ZeroBankOrDp — Zero data-bank / direct-page for long-pointer reads of the package stream.
PLB
PLB
PHD
PEA $0000  ; ZeroBankOrDp — Zero data-bank / direct-page for long-pointer reads of the package stream.
PLD
LDY #$00
LDA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
CMP #$BBAA  ; IplReadySignature — SPC700 IPL ready signature read from $2140/$2141 as a 16-bit word.
BEQ iplReady
JSR rebootToIpl
iplReady:
SEP #$20  ; StatusM
.a8
.i16
LDA $001E  ; NmiEnableShadow — NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
AND #$7F
STA $001E  ; NmiEnableShadow — NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
STA $004200  ; NmiTimenAddr
LDA #$CC  ; IplBeginTransfer — First transfer kick-off counter written to $2140 (IPL start-transfer).
BRA beginBlock
readPayloadByte:
LDA [$C6],Y  ; PackagePtrLo — 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
INY
XBA
LDA #$00
BRA sendWord
nextPayloadByte:
XBA
LDA [$C6],Y  ; PackagePtrLo — 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
INY
XBA
waitPort0Match:
CMP $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
BNE waitPort0Match
INC A
sendWord:
REP #$20  ; StatusM
.a16
.i16
STA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
SEP #$20  ; StatusM
.a8
.i16
DEX
BNE nextPayloadByte
waitPort0AfterBlock:
CMP $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
BNE waitPort0AfterBlock
avoidZeroCounter:
ADC #$03
BEQ avoidZeroCounter
beginBlock:
PHA
REP #$20  ; StatusM
.a16
.i16
LDA [$C6],Y  ; PackagePtrLo — 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
BNE nonEmptyBlock
TAX
LDA #$0500  ; DefaultApuEntry — Default entry address when a package ends with len == 0 (kick SPC at $0500).
BRA writeBlockAddr
nonEmptyBlock:
TAX
INY
INY
LDA [$C6],Y  ; PackagePtrLo — 24-bit far pointer to the package stream: lo word at $00C6, bank byte at
INY
INY
writeBlockAddr:
STA $2142  ; ApuPort2
SEP #$20  ; StatusM
.a8
.i16
CPX #$01
LDA #$00
ROL A
STA $2141  ; ApuPort1
ADC #$7F
PLA
STA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
waitHeaderAck:
CMP $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
BNE waitHeaderAck
BVS readPayloadByte
REP #$20  ; StatusM
.a16
.i16
waitTransferIdle:
LDA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
BNE waitTransferIdle
SEP #$20  ; StatusM
.a8
.i16
LDA $001E  ; NmiEnableShadow — NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
ORA #$80  ; NmiEnableMask
STA $001E  ; NmiEnableShadow — NMITIMEN shadow in WRAM; bit 7 = NMI enable. Cleared for the transfer,
STA $004200  ; NmiTimenAddr
REP #$20  ; StatusM
.a16
.i16
PLD
PLB
RTL
rebootToIpl:
STZ $2142  ; ApuPort2
STZ $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
waitIplReady:
LDA #$FF  ; IplRebootCommand — $FF written to $2140 forces a running driver back to the IPL (reboot
STA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
LDA $2140  ; ApuPort0 — APU communication ports (S-CPU side). Protocol: target addr → $2142/$2143,
CMP #$BBAA  ; IplReadySignature — SPC700 IPL ready signature read from $2140/$2141 as a 16-bit word.
BNE waitIplReady
RTS
