; waitApuIdleClearSong
; Ported from snes_src/wait_apu_idle.nim :: waitApuIdleClearSong (evidence-preserving re-port).
;
; Wait for APU port 0 idle, then invalidate the current-song cache
; (file 0x00ABC6 / SNES $C0ABC6) plus its port-0 poll helper
; (file 0x00AC20 / SNES $C0AC20).
;
; Called by loadSong ($C4FBBD) after writeApuPort1Toggled when stopping the
; resident driver before a package re-upload (see song_loader.nim
; WaitApuIdleClearSong). ADOPTED mid-region after queueApuCommand /
; writeApuPort* siblings; gold-gated by tests/test_regions.nim.
;
;
; --- waitApuIdleClearSong ---
; Force APU port 0 to 0, spin until it reads idle, clear current-song cache.
;
; Entry (JSL): any M/X; manages widths itself. Writes #$00 to $2140 (8-bit),
; then loops `JSL readApuPort0` + `CMP #$0000` until the port low byte is 0.
; Finally stores #$FFFF at $B53B (CurrentSongId) and RTL.
;
; Evidence:
; - Disasm region 0x00ABC6-0x00ABDF (26 bytes) ends at RTL.
; - song_loader stop-music path: writeApuPort1Toggled then JSL $C0ABC6.
; - $B53B is the same WRAM word loadSong compares/stores as CurrentSongId;
; $FFFF makes the next loadSong treat "no current song" and re-upload.
; - Inner JSL $C0AC20 is readApuPort0 (port-0 poll helper adopted below).
;
; Named constants (values inlined below; names preserved as comments):
;   WaitApuIdleClearSongOffset = $ABC6
;   WaitApuIdleClearSongSnes = $C0ABC6
;   ReadApuPort0Offset = $AC20
;   ReadApuPort0Snes = $C0AC20
;   ApuPort0 = $2140
;     APU communication port 0 (S-CPU side). Written 0 to request idle; polled
;     until the low byte reads back 0 before the song cache is cleared.
;   CurrentSongId = $B53B
;     WRAM: last song ID loaded by loadSong. Forced to $FFFF so the next load
;     never early-outs on "same song" after a stop-music handshake.
;   SongCacheInvalid = $FFFF
;     Sentinel written to CurrentSongId after port 0 goes idle.
;   ByteMask = $FF
;   StatusM = $20
;   StatusMX = $30
;
.a16
.i16
SEP #$20  ; StatusM
.a8
.i16
LDA #$00
STA $002140  ; ApuPort0 — APU communication port 0 (S-CPU side). Written 0 to request idle; polled
REP #$30  ; StatusMX
.a16
.i16
waitIdle:
JSL $C0AC20  ; ReadApuPort0Snes
CMP #$00
BNE waitIdle
LDA #$FFFF  ; SongCacheInvalid — Sentinel written to CurrentSongId after port 0 goes idle.
STA $B53B  ; CurrentSongId — WRAM: last song ID loaded by loadSong. Forced to $FFFF so the next load
RTL
