; loadSong
; Ported from snes_src/song_loader.nim :: loadSong (evidence-preserving re-port).
;
; Song loader / selector — song ID → pack indices → APU package upload
; (file 0x04FBBD / SNES $C4FBBD).
;
; docs/audio.md Findings: called with a song ID; walks the song table
; (file 0x04F70A, 3 bytes/song, index (id-1)*3) and pack table
; (file 0x04F947, 3 bytes/pack = [bank, addrL, addrH]), then JSL $C0AB06
; (uploadApuPackages) for each pack that changed. Tail pokes the play
; command via writeApuPort0 ($C0ABBD). ADOPTED mid-region after the small
; RTS helper at $C4FB42 (still generated); gold-gated by tests/test_regions.nim.
;
;
; --- loadSong ---
; Load a song by ID: resolve packs, upload changed packages, start playback.
;
; Entry (JSL): native mode; A = song ID. Builds a 20-byte DP frame, stores
; the ID in DP $12 / $B53B. If the ID matches the current song, returns
; immediately. Otherwise optionally pokes APU port 3 with $57 (warm path),
; and for non-special IDs stops the resident driver (port1 toggle + wait
; idle) before re-uploading.
;
; For each of the three song-table pack indices (bytes 0, 1, 2 at
; $C4F70A + (id-1)*3): if the index is not $FF and differs from the
; cached slot, index the pack table at $C4F947 (stride 3 → [bank, addr]),
; JSR the $C4FB42 mask helper, then JSL uploadApuPackages ($C0AB06) with
; A = address and X = bank.
;
; Tail: A = (id-1)+1 = song ID, JSL writeApuPort0 ($C0ABBD) to poke the
; play command on $2140, PLD, RTL.
;
; Evidence: docs/audio.md song table / pack table / $C0AB06 path; call sites
; pass song IDs then JSL $C4FBBD; three LDA $C4F70A,X at +0/+1/+2 with
; (id-1)*3; three JSL $C0AB06 after pack-table far-pointer walks.
;
; Named constants (values inlined below; names preserved as comments):
;   LoadSongOffset = $04FBBD
;   LoadSongSnes = $C4FBBD
;   SongTableBase = $C4F70A
;     Song table: 3 pack indices per song, indexed (songId - 1) * 3.
;   PackTableAddr = $F947
;     Pack table far pointer built in DP $06/$08: bank $C4, addr $F947.
;   PackTableBank = $C4
;   PrepPackBankHelper = $FB42
;     Same-bank RTS helper at $C4FB42: sets $B547 = $FFFF (APU addr mask) and
;     returns A (pack bank). Callers TAX the bank then JSL uploadApuPackages.
;   UploadApuPackages = $C0AB06
;   WriteApuPort3Cmd57 = $C0AC01
;   WriteApuPort1Toggled = $C0AC0C
;   WaitApuIdleClearSong = $C0ABC6
;     Wait until APU port 0 is idle, then force current-song cache $B53B = $FFFF.
;     TODO: name this routine when it is adopted; only the wait+clear is known.
;   WriteApuPort0 = $C0ABBD
;   CurrentSongId = $B53B
;     WRAM: last song ID loaded (skip re-load when equal).
;   MusicWarmFlag = $B4B6
;     WRAM: non-zero skips the warm-path port-3 $57 poke before a music change.
;     TODO: identify what $B4B6 gates beyond "already warm".
;   CachedPack0 = $B53D
;     WRAM: cached pack indices for the three song-table slots (skip re-upload).
;   CachedPack1 = $B53F
;   CachedPack2 = $B541
;   CachedPack1Alt = $B543
;     WRAM: alternate pack-1 cache; pack slot 1 also skips when equal to this.
;     TODO: who writes $B543 and why it shadows CachedPack1.
;   ApuPackAddrMask = $B547
;     WRAM: mask AND'd onto the pack address word before JSL $C0AB06.
;     Prep helper forces $FFFF (full address); keep the name honest to the AND.
;   LocalFrameAdj = $FFEC
;     Local DP frame size: TDC + #$FFEC (-20) before the body runs.
;   SpecialSongIdLo = $A0
;     Song IDs $A0..$A7 skip the stop-music handshake (port1 toggle + wait idle).
;     TODO: confirm these IDs are ambient/SFX-layer tracks that keep the driver.
;   SpecialSongIdHi = $A7
;   PackNone = $FF
;     Pack index $FF means "no pack" for that slot — skip upload.
;   One = $01
;   StatusMXC = $31
;     REP #$31: clear M, X, and C (16-bit A/X, carry clear for frame ADC).
;   ByteMask = $FF
;
.a16
.i16
REP #$31  ; StatusMXC — REP #$31: clear M, X, and C (16-bit A/X, carry clear for frame ADC).
.a16
.i16
PHD
PHA
TDC
ADC #$FFEC  ; LocalFrameAdj — Local DP frame size: TDC + #$FFEC (-20) before the body runs.
TCD
PLA
TAX
STX $12
CPX $B53B  ; CurrentSongId — WRAM: last song ID loaded (skip re-load when equal).
BNE notSameSong
JMP exit
notSameSong:
LDA $B4B6  ; MusicWarmFlag — WRAM: non-zero skips the warm-path port-3 $57 poke before a music change.
BNE afterWarmPoke
JSL $C0AC01  ; WriteApuPort3Cmd57
afterWarmPoke:
LDX $12
CPX #$A0  ; SpecialSongIdLo — Song IDs $A0..$A7 skip the stop-music handshake (port1 toggle + wait idle).
BCC stopMusic
CPX #$A7  ; SpecialSongIdHi
BCC afterStopMusic
BEQ afterStopMusic
stopMusic:
LDA #$01  ; One
JSL $C0AC0C  ; WriteApuPort1Toggled
JSL $C0ABC6  ; WaitApuIdleClearSong — Wait until APU port 0 is idle, then force current-song cache $B53B = $FFFF.
afterStopMusic:
LDX $12
STX $B53B  ; CurrentSongId — WRAM: last song ID loaded (skip re-load when equal).
TXY
DEY
STY $10
TYA
STA $04
ASL A
ADC $04
TAX
LDA $C4F70A,X  ; SongTableBase — Song table: 3 pack indices per song, indexed (songId - 1) * 3.
AND #$FF  ; ByteMask
STA $0E
CMP $B53D  ; CachedPack0 — WRAM: cached pack indices for the three song-table slots (skip re-upload).
BEQ pack0Done
CMP #$FF  ; PackNone — Pack index $FF means "no pack" for that slot — skip upload.
BEQ pack0Done
STA $B53D  ; CachedPack0 — WRAM: cached pack indices for the three song-table slots (skip re-upload).
LDA #$F947  ; PackTableAddr — Pack table far pointer built in DP $06/$08: bank $C4, addr $F947.
STA $06
LDA #$C4  ; PackTableBank
STA $08
LDA $0E
STA $04
ASL A
ADC $04
STA $02
LDX $06
STX $0A
LDX $08
STX $0C
CLC
ADC $0A
STA $0A
LDA [$0A]
AND #$FF  ; ByteMask
JSR $FB42  ; PrepPackBankHelper — Same-bank RTS helper at $C4FB42: sets $B547 = $FFFF (APU addr mask) and
TAX
LDA $02
INC A
CLC
ADC $06
STA $06
LDA [$06]
AND $B547  ; ApuPackAddrMask — WRAM: mask AND'd onto the pack address word before JSL $C0AB06.
JSL $C0AB06  ; UploadApuPackages
pack0Done:
LDY $10
TYA
STA $04
ASL A
ADC $04
TAX
INX
LDA $C4F70A,X  ; SongTableBase — Song table: 3 pack indices per song, indexed (songId - 1) * 3.
AND #$FF  ; ByteMask
STA $0E
CMP $B53F  ; CachedPack1
BEQ pack1Done
CMP #$FF  ; PackNone — Pack index $FF means "no pack" for that slot — skip upload.
BEQ pack1Done
CMP $B543  ; CachedPack1Alt — WRAM: alternate pack-1 cache; pack slot 1 also skips when equal to this.
BEQ pack1Done
STA $B53F  ; CachedPack1
LDA #$F947  ; PackTableAddr — Pack table far pointer built in DP $06/$08: bank $C4, addr $F947.
STA $06
LDA #$C4  ; PackTableBank
STA $08
LDA $0E
STA $04
ASL A
ADC $04
STA $02
LDX $06
STX $0A
LDX $08
STX $0C
CLC
ADC $0A
STA $0A
LDA [$0A]
AND #$FF  ; ByteMask
JSR $FB42  ; PrepPackBankHelper — Same-bank RTS helper at $C4FB42: sets $B547 = $FFFF (APU addr mask) and
TAX
LDA $02
INC A
CLC
ADC $06
STA $06
LDA [$06]
AND $B547  ; ApuPackAddrMask — WRAM: mask AND'd onto the pack address word before JSL $C0AB06.
JSL $C0AB06  ; UploadApuPackages
pack1Done:
LDY $10
TYA
STA $04
ASL A
ADC $04
TAX
INX
INX
LDA $C4F70A,X  ; SongTableBase — Song table: 3 pack indices per song, indexed (songId - 1) * 3.
AND #$FF  ; ByteMask
STA $0E
CMP $B541  ; CachedPack2
BEQ pack2Done
CMP #$FF  ; PackNone — Pack index $FF means "no pack" for that slot — skip upload.
BEQ pack2Done
STA $B541  ; CachedPack2
LDA #$F947  ; PackTableAddr — Pack table far pointer built in DP $06/$08: bank $C4, addr $F947.
STA $06
LDA #$C4  ; PackTableBank
STA $08
LDA $0E
STA $04
ASL A
ADC $04
STA $02
LDX $06
STX $0A
LDX $08
STX $0C
CLC
ADC $0A
STA $0A
LDA [$0A]
AND #$FF  ; ByteMask
JSR $FB42  ; PrepPackBankHelper — Same-bank RTS helper at $C4FB42: sets $B547 = $FFFF (APU addr mask) and
TAX
LDA $02
INC A
CLC
ADC $06
STA $06
LDA [$06]
AND $B547  ; ApuPackAddrMask — WRAM: mask AND'd onto the pack address word before JSL $C0AB06.
JSL $C0AB06  ; UploadApuPackages
pack2Done:
LDY $10
TYA
INC A
JSL $C0ABBD  ; WriteApuPort0
exit:
PLD
RTL
