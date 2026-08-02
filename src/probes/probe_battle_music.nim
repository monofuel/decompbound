## Battle-music RE dig: WHERE does the battle song id come from?
##
## ANSWER (disasm-proven, byte-exact-verified below): the **enemy config
## record, offset +0x37 (u8)** — not the battle-group/formation record.
## Chain (battle bank $C2, DB=$7E):
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
## The identical 26-byte chain repeats at $C24CD5..$C24CEE (second music-start
## site; only entered via `$C24B6C JMP $C24CD5`). `$9F8C` is the base of a u16
## enemy-id ARRAY ($9F8A = count, max 4) filled from the battle group's member
## list (group table $D0C60D + groupId*8, +0..+2 far ptr to the
## `[u8 count, u16 enemyId]…$FF` list); the absolute LDA reads element [0].
## Builders: $C0D256 (overworld encounter), $C22F38 (script battle; sets
## $4DC2=$FFFF which skips the default init), $C1E3A5 (battle-select menu),
## and the $4DC2==0 default at $C24884 (`LDY #$0001 / LDA [$06],Y /
## STA $9F8C` — the first member's enemy id).
##
## The probe re-verifies every claimed opcode sequence byte-exact against the
## user's ROM (the machine referee), then decodes +0x37 for all enemies and
## cross-checks the values against the 191-entry song table, plus decodes the
## battle-group table (Track D seed: member lists, bg-pair candidates).
##
## Usage: nim r src/probes/probe_battle_music.nim [rom] [--all] [--trace]

import
  std/[os, sets, strformat, strutils],
  ../decompbound/[battle_formation, battle_music, item_table]

const
  ## Song table (docs/audio.md): 3 bytes/song, (id-1)*3, up to the pack table.
  SongTableFile = 0x04F70A
  PackTableFile = 0x04F947

  ## Battle-group (formation) table — SNES $D0C60D, 8 bytes/group:
  ##   +0..+2 far ptr to member list, +3 pad,
  ##   +4 u16 event-flag number (0 = unconditional) and +6 u8 wanted flag
  ##      value — group-enable predicate (sole reader $C0C524: LDA [$0A] at
  ##      $C0C55D → JSL $C21628 flag test → CMP with +6),
  ##   +7 u8 letterbox selector (AND #$0003 in $C2D121 picks the battle
  ##      window's top/bottom scanline pair via $ADB2/$ADB4).
  ## The two u16s at $CBD89A + groupId*4 are the battle-background layer ids
  ## passed in A/X to JSL $C2D121 (which walks the bg anim table $CAD7A1).
  ## Evidence: $C24878 LDA $D0C615 (= group 1 +0) / $C248D7 LDA $D0C60D,X with
  ## X = groupId*8+7 / $C248A7.. walks $CBD89A + groupId*4. No music field
  ## exists in the group record — music is enemy-record data only.
  GroupTableFile = 0x10C60D
  GroupRecSize = 8
  GroupBgPairFile = 0x0BD89A
  ## Member list entry: [u8 count, u16 enemyId], list terminated by $FF.
  ## count 0 observed (17 groups) — optional/randomized member slot.
  MemberTerm = 0xFF

  ## --- Byte-exact disasm evidence (the referee) ---
  ## LDA $9F8C; LDY #$005E; JSL $C08FF7; CLC; ADC #$0037; TAX;
  ## LDA $D59589,X; AND #$00FF; JSL $C4FBBD
  MusicChain = [
    0xAD'u8, 0x8C, 0x9F, 0xA0, 0x5E, 0x00, 0x22, 0xF7, 0x8F, 0xC0,
    0x18, 0x69, 0x37, 0x00, 0xAA, 0xBF, 0x89, 0x95, 0xD5,
    0x29, 0xFF, 0x00, 0x22, 0xBD, 0xFB, 0xC4]
  MusicChainSite1 = 0x024A4B  # $C24A4B
  MusicChainSite2 = 0x024CD5  # $C24CD5
  ## LDY #$0001; LDA [$06],Y; STA $9F8C  (first-member enemy id → $9F8C)
  SeedChain = [0xA0'u8, 0x01, 0x00, 0xB7, 0x06, 0x8D, 0x8C, 0x9F]
  SeedChainSite = 0x024884    # $C24884
  ## LDA $D0C615; STA $06; LDA $D0C617; STA $08  (group-table far ptr load)
  GroupPtrChain = [0xAF'u8, 0x15, 0xC6, 0xD0, 0x85, 0x06,
                   0xAF, 0x17, 0xC6, 0xD0, 0x85, 0x08]
  GroupPtrSite = 0x024878     # $C24878
  ## Normal-path append idiom filling the $9F8C enemy-id array from a group
  ## member-list entry: LDA $9F8A; ASL; TAX; LDY #$0001; LDA [$06],Y;
  ## STA $9F8C,X; INC $9F8A
  AppendChain = [0xAD'u8, 0x8A, 0x9F, 0x0A, 0xAA, 0xA0, 0x01, 0x00,
                 0xB7, 0x06, 0x9D, 0x8C, 0x9F, 0xEE, 0x8A, 0x9F]
  AppendSiteScript = 0x022F6C  # $C22F6C (script battle builder $C22F38)
  AppendSiteMenu = 0x01E3CF    # $C1E3CF (battle-select menu builder $C1E3A5)

  ## Structural cross-checks (ids only; all values decoded from the ROM).
  StarmanSuperId = 68
  StarmanSuperMirrorId = 185
  AtomicPowerRobotId = 13
  MinDistinctSongs = 10

type
  GroupMember = tuple[count: int, enemyId: int]
  Group = object
    id: int
    listFile: int
    members: seq[GroupMember]
    f4: int
    f6: int
    f7: int
    bgA: int
    bgB: int

proc expect(cond: bool, msg: string) =
  if not cond:
    raise newException(AssertionDefect, msg)

proc rdU16(rom: openArray[uint8], off: int): int =
  rom[off].int or (rom[off + 1].int shl 8)

proc rdU24(rom: openArray[uint8], off: int): int =
  rdU16(rom, off) or (rom[off + 2].int shl 16)

proc snesToFile(a: int): int =
  ## HiROM $C0.. → file offset.
  a - 0xC00000

proc checkChain(rom: openArray[uint8], site: int, chain: openArray[uint8],
                what: string) =
  ## Byte-exact verify a claimed instruction sequence at a file offset.
  for i in 0 ..< chain.len:
    expect(rom[site + i] == chain[i],
      &"{what}: byte {i} at file 0x{site + i:06X} is " &
      &"0x{rom[site + i]:02X}, want 0x{chain[i]:02X}")

proc parseGroup(rom: openArray[uint8], g: int): Group =
  ## Decode one battle-group record + its member list.
  let rec = GroupTableFile + g * GroupRecSize
  result.id = g
  result.listFile = snesToFile(rdU24(rom, rec))
  result.f4 = rdU16(rom, rec + 4)
  result.f6 = rom[rec + 6].int
  result.f7 = rom[rec + 7].int
  result.bgA = rdU16(rom, GroupBgPairFile + g * 4)
  result.bgB = rdU16(rom, GroupBgPairFile + g * 4 + 2)
  var p = result.listFile
  for _ in 0 ..< 16:
    if rom[p].int == MemberTerm:
      return
    result.members.add (count: rom[p].int, enemyId: rdU16(rom, p + 1))
    p += 3
  raise newException(AssertionDefect,
    &"group {g}: member list at 0x{result.listFile:06X} missing $FF terminator")

proc printTrace() =
  ## The address-by-address evidence chain (also asserted byte-exact in main).
  echo """
=== Disasm evidence chain (battle music) ===
Battle init, bank $C2 (DB=$7E). Default-init path ($4DC2 == 0):
  $C24829  AD C2 4D      LDA $4DC2        ; skip init if battle vars pre-set
  $C2486F  A9 01 00      LDA #$0001
  $C24872  8D 8A 9F      STA $9F8A
  $C24875  8D 8C 4A      STA $4A8C        ; battle group id (default 1)
  $C24878  AF 15 C6 D0   LDA $D0C615      ; group-table $D0C60D + 1*8 (+0 ptr)
  $C2487C  85 06         STA $06
  $C2487E  AF 17 C6 D0   LDA $D0C617
  $C24882  85 08         STA $08          ; DP $06 = far ptr to member list
  $C24884  A0 01 00      LDY #$0001
  $C24887  B7 06         LDA [$06],Y      ; u16 at list+1 = FIRST member's id
  $C24889  8D 8C 9F      STA $9F8C        ; music/bg source enemy id

Normal encounter paths fill the same vars BEFORE battle init, walking the
group member list and appending ids to the $9F8C array ($9F8A = count):
  $C0D256  overworld sprite-contact encounter ($4A8C from $2C9A,X & $7FFF;
           STZ $9F8A at $C0D323; appends at $C0D4D6 / $C0D728)
  $C22F38  script "start battle group N" (STA $4A8C at $C22F44; append idiom
           at $C22F6C; then $C22FA3 LDA #$FFFF / STA $4DC2 -> skips default)
  $C1E3A5  battle-select menu (append idiom at $C1E3CF)
Append idiom (byte-verified): AD 8A 9F 0A AA A0 01 00 B7 06 9D 8C 9F EE 8A 9F
  = LDA $9F8A; ASL; TAX; LDY #$0001; LDA [$06],Y; STA $9F8C,X; INC $9F8A

Music start (site 1) — enemy record +0x37 -> song loader:
  $C24A4B  AD 8C 9F      LDA $9F8C        ; enemy id
  $C24A4E  A0 5E 00      LDY #$005E       ; record stride
  $C24A51  22 F7 8F C0   JSL $C08FF7      ; A = id * $5E
  $C24A55  18            CLC
  $C24A56  69 37 00      ADC #$0037       ; music field offset
  $C24A59  AA            TAX
  $C24A5A  BF 89 95 D5   LDA $D59589,X    ; enemy config table (file 0x159589)
  $C24A5E  29 FF 00      AND #$00FF       ; u8
  $C24A61  22 BD FB C4   JSL $C4FBBD      ; song loader, A = song id
Site 2: identical 26-byte chain at $C24CD5..$C24CEE (entered only via
  $C24B64 LDA $006D / AND #$1000 / BEQ+3 / $C24B6C JMP $C24CD5).

Battle-group side (NO music field in the group record — bg + predicate only):
  $C248A7  AD 8C 4A / ASL/ASL             ; groupId*4
  $C248BB  A7 0A         LDA [$0A]        ; u16 @ $CBD89A + groupId*4    -> $2D
  $C248C8  A7 06         LDA [$06]        ; u16 @ $CBD89A + groupId*4 +2 -> $2B
  $C248D7  BF 0D C6 D0   LDA $D0C60D,X    ; X = groupId*8+7 (byte +7)   -> $29
  $C2491E  22 21 D1 C2   JSL $C2D121      ; A/X = bg layer ids, Y&3 picks the
                                          ; letterbox extent ($ADB2/$ADB4)
Group fields +4 (u16 event-flag no., 0 = always) and +6 (wanted flag value)
are a group-enable predicate — sole reader $C0C524 ($C0C55D LDA [$0A] ->
JSL $C21628 flag test -> $C0C57E CMP with +6).
"""

proc main() =
  var romPath = DefaultRomPath
  var showAll = false
  var trace = false
  for i in 1 .. paramCount():
    case paramStr(i)
    of "--all": showAll = true
    of "--trace": trace = true
    else: romPath = paramStr(i)
  if not fileExists(romPath):
    raise newException(IOError, "ROM not found: " & romPath)
  let rom = loadRomBytes(romPath)

  if trace:
    printTrace()

  # --- 1. Referee: the claimed disasm chains exist byte-exact in this ROM ---
  checkChain(rom, MusicChainSite1, MusicChain, "music chain @$C24A4B")
  checkChain(rom, MusicChainSite2, MusicChain, "music chain @$C24CD5")
  checkChain(rom, SeedChainSite, SeedChain, "$9F8C seed @$C24884")
  checkChain(rom, GroupPtrSite, GroupPtrChain, "group ptr load @$C24878")
  checkChain(rom, AppendSiteScript, AppendChain, "$9F8C append @$C22F6C")
  checkChain(rom, AppendSiteMenu, AppendChain, "$9F8C append @$C1E3CF")
  echo "OK evidence: record[+0x37] -> $C4FBBD chain byte-exact at " &
    "$C24A4B and $C24CD5; $9F8C seed @$C24884 + append idiom @$C22F6C/$C1E3CF"

  # --- 2. Decode +0x37 for every enemy; range-check vs the song table ---
  let songCount = (PackTableFile - SongTableFile) div 3
  expect(songCount == SongCount, "song table size drifted")
  var distinct0: HashSet[int]
  var zeroIds: seq[int]
  echo &"\nsong table: {songCount} songs; enemy music = record[+0x{EnemyMusicOff:02X}]"
  for id in 0 .. EnemyIdMax:
    let m = musicId(rom, id)
    expect(m == 0 or m in 1 .. songCount,
      &"enemy {id} music {m} out of song-table range")
    if m == 0:
      zeroIds.add id
    else:
      distinct0.incl m
    if showAll:
      echo &"  id={id:3} music={m:3} [{decodeEnemyName(rom, id)}]"
  echo &"all {EnemyIdMax + 1} enemy records: music in range " &
    &"(distinct nonzero: {distinct0.len}, zero: {zeroIds.len})"
  expect(distinct0.len >= MinDistinctSongs,
    "suspiciously few distinct song ids — field misread?")
  expect(musicId(rom, 0) == 0, "null enemy 0 should carry music 0")
  # Formation-alt mirror row must agree with its primary (same fight context).
  expect(musicId(rom, StarmanSuperId) == musicId(rom, StarmanSuperMirrorId) and
         musicId(rom, StarmanSuperId) != 0,
    "Starman Super mirror rows disagree on music")
  echo &"cross-check: id {StarmanSuperId} and mirror {StarmanSuperMirrorId} " &
    &"share song {musicId(rom, StarmanSuperId)}"

  # --- 3. Battle-group table decode (Track D seed) ---
  let g0List = snesToFile(rdU24(rom, GroupTableFile))
  let groupCount = (g0List - GroupTableFile) div GroupRecSize
  echo &"\nbattle groups: table file 0x{GroupTableFile:06X}, " &
    &"{groupCount} records of {GroupRecSize} bytes (count derived from g0 ptr)"
  var slot200Group = -1
  var listLo = int.high
  var listHi = 0
  for g in 0 ..< groupCount:
    let gr = parseGroup(rom, g)
    listLo = min(listLo, gr.listFile)
    for m in gr.members:
      expect(m.count in 0 .. 9, &"group {g} member count {m.count} implausible")
      expect(m.enemyId in 0 .. EnemyIdMax,
        &"group {g} enemy id {m.enemyId} out of range")
      # A group's music comes from its FIRST member's record (seed chain).
      listHi = max(listHi, gr.listFile + gr.members.len * 3 + 1)
    if gr.members.len == 2 and
        gr.members[0] == (count: 1, enemyId: StarmanSuperId) and
        gr.members[1] == (count: 1, enemyId: AtomicPowerRobotId):
      slot200Group = g
  echo &"member lists parse clean for all {groupCount} groups " &
    &"(list area file 0x{listLo:06X}..0x{listHi:06X}; " &
    "note: old docs offset 0x10D74C is inside this blob, not a table base)"
  expect(slot200Group >= 0,
    "no group matches the known slot200 fight [1x Starman Super, 1x APR]")
  let sg = parseGroup(rom, slot200Group)
  echo &"cross-check: group {slot200Group} = live slot200 fight " &
    &"{{1x{StarmanSuperId}, 1x{AtomicPowerRobotId}}}; first member id " &
    &"{sg.members[0].enemyId} -> music {musicId(rom, sg.members[0].enemyId)}"
  echo &"  group fields: eventFlag+4=0x{sg.f4:04X} wantValue+6={sg.f6} " &
    &"letterbox+7={sg.f7}  bgLayers@$CBD89A+g*4 = ({sg.bgA}, {sg.bgB})"

  # Sample rows for eyeballing (names decoded at runtime, never committed).
  echo "\nsamples (enemy -> music):"
  for id in [1, 5, 36, 50, StarmanSuperId, 159, StarmanSuperMirrorId, 229, 230]:
    echo &"  id={id:3} music={musicId(rom, id):3} [{decodeEnemyName(rom, id)}]"

  echo "\nOK probe_battle_music — music field = enemy record +0x37 (u8), " &
    "selected via $9F8C[0] (first battle-group member); no group music field"

when isMainModule:
  main()
