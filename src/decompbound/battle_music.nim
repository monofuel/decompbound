## Battle music selection — enemy config record `+0x37` (u8) is the song id.
##
## Disasm evidence (battle bank $C2, DB=$7E; verified byte-exact by
## `src/probes/probe_battle_music.nim`):
##
##   $C24A4B  AD 8C 9F      LDA $9F8C      ; music-source enemy id (WRAM)
##   $C24A4E  A0 5E 00      LDY #$005E     ; enemy record stride
##   $C24A51  22 F7 8F C0   JSL $C08FF7    ; A = id * $5E (shared mul helper)
##   $C24A55  18            CLC
##   $C24A56  69 37 00      ADC #$0037     ; + music field offset
##   $C24A59  AA            TAX
##   $C24A5A  BF 89 95 D5   LDA $D59589,X  ; enemy config table (file 0x159589)
##   $C24A5E  29 FF 00      AND #$00FF     ; u8 field
##   $C24A61  22 BD FB C4   JSL $C4FBBD    ; song loader, A = song id
##
## The identical 26-byte chain repeats at $C24CD5..$C24CEE (second battle
## music-start site; reached only via `$C24B6C JMP $C24CD5`).
##
## `$9F8C` is the base of a u16 ENEMY-ID ARRAY (count in `$9F8A`, max 4); the
## absolute `LDA $9F8C` above reads element [0]. Builders (all walk the battle
## group's member list — group table $D0C60D + groupId*8, +0..+2 far ptr to
## `[u8 count, u16 enemyId]…$FF` — and append via `LDA $9F8A / ASL / TAX /
## LDA [$06],Y / STA $9F8C,X / INC $9F8A`):
##   $C0D256  overworld sprite-contact encounter (group id from $2C9A,X)
##   $C22F38  script "start battle group N" (sets $4DC2=$FFFF, the flag that
##            makes battle init $C24829 skip its default seeding)
##   $C1E3A5  battle-select/debug menu
##   $C24884  default init when $4DC2==0: count=1, element[0]=first list entry
##
## Semantics: field value 0 = "leave music alone" (only ally/scripted records
## carry it); real encounters decode to 1..191, in-range for the song table at
## file 0x04F70A (3 bytes/song, up to the pack table at 0x04F947 → 191 songs).

import battle_formation

const
  ## Battle music field inside the 0x5E-byte enemy config record —
  ## ADC #$0037 at $C24A56 / $C24CDF (see module doc for the full chain).
  EnemyMusicOff* = 0x37
  ## Song ids are 1-based into the song table; (packTable - songTable) / 3.
  SongCount* = (0x04F947 - 0x04F70A) div 3

proc musicId*(rom: openArray[uint8], enemyId: int): int =
  ## Battle song id for an enemy (0 = no music change; see module doc).
  if enemyId < 0 or enemyId > EnemyIdMax:
    raise newException(ValueError, "enemy id out of range: " & $enemyId)
  rom[EnemyTableFileBase + enemyId * EnemyRecordSize + EnemyMusicOff].int
