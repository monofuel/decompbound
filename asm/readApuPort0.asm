; readApuPort0
; Ported from snes_src/wait_apu_idle.nim :: readApuPort0 (evidence-preserving re-port).
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
; --- readApuPort0 ---
; Read APU port 0 ($2140) and return its low byte zero-extended in A.
;
; Literally `SEP #$20 / LDA long $2140 / REP #$30 / AND #$00FF / RTL`.
; Sole in-ROM caller in the adopted audio spine is waitApuIdleClearSong
; (poll until A == 0). Named for the verified port read, not a higher-level
; driver state.
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
LDA $002140  ; ApuPort0 — APU communication port 0 (S-CPU side). Written 0 to request idle; polled
REP #$30  ; StatusMX
.a16
.i16
AND #$FF  ; ByteMask
RTL

