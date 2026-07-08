## EarthBound battery-save (SRAM) inspector / report card.
##
## Reads an 8KB .srm and prints a human-readable report of mapped fields:
## save slots, money/ATM, party roster, full char stat blocks (level/EXP/HP/PP,
## combat stats, inventory, equipment), Escargo Express, and primary-vs-backup
## ($500) divergence. Use --find to locate unknown values before promoting them.
##
## Usage:
##   nim r src/tools/sram_info.nim [save.srm]
##   nim r src/tools/sram_info.nim [save.srm] --find 20
##   nim r src/tools/sram_info.nim [save.srm] --out /tmp/save-report.txt
##
## Default save path: "bin/Earthbound (U) [!].srm".

import
  std/[os, strformat, strutils, tables]

const
  DefaultSrm = "bin/Earthbound (U) [!].srm"
  Header = "HAL Laboratory, inc."
  SramSize = 0x2000
  SaveSlotSize = 0x500
  ## Data payload starts after the 20-byte HAL signature + checksum words.
  ## TODO: magic 0x20 / 0x4E0 until docs/sram-format.md is complete; matches
  ## Oh Mother / datacrystal layout (signature @0, csum @0x1C/0x1E, data @0x20).
  DataOffset = 0x20
  DataSize = 0x4E0
  Csum1Off = 0x1C
  Csum2Off = 0x1E
  StampOff = 0x1C
  ## Three user slots, each with an A/B mirror 0x500 apart.
  ## Verified on real .srm: HAL headers at 0x0000/0500/0A00/0F00/1400/1900.
  SlotPairBases = [0x0000, 0x0A00, 0x1400]
  MirrorDelta = 0x500

  # Slot-relative offsets (include header). Equiv. data-relative + DataOffset.
  # TODO: magic offsets — confirmed via --find / byte match on real saves +
  # community cross-ref (datacrystal character table, Oh Mother editor).
  MoneyOff = 0x5C
  AtmOff = 0x60
  EscargoOff = 0x76
  EscargoLen = 36
  PartyRosterOff = 0xB6
  PartyRosterLen = 7
  PetNameOff = 0x44
  FavFoodOff = 0x4A
  FavThingOff = 0x54
  PosXOff = 0xA2
  PosYOff = 0xA6
  CharTableBase = 0x1F9
  CharStride = 0x5F
  PlayableCharCount = 4
  InvLen = 14
  PsiLen = 14
  EquipLen = 4

  # Per-character entry (relative to entry base).
  CharNameOff = 0x00
  CharLevelOff = 0x05
  CharExpOff = 0x06
  CharHpMaxOff = 0x0A
  CharPpMaxOff = 0x0C
  CharOffOff = 0x15
  CharDefOff = 0x16
  CharSpdOff = 0x17
  CharGutOff = 0x18
  CharLucOff = 0x19
  CharVitOff = 0x1A
  CharIqOff = 0x1B
  CharBaseOffOff = 0x1C
  CharBaseDefOff = 0x1D
  CharBaseSpdOff = 0x1E
  CharBaseGutOff = 0x1F
  CharBaseLucOff = 0x20
  CharBaseVitOff = 0x21
  CharBaseIqOff = 0x22
  CharInvOff = 0x23
  CharEquipOff = 0x31
  CharPsiOff = 0x35
  CharHpRollOff = 0x45
  CharHpCurOff = 0x47
  CharPpRollOff = 0x4B
  CharPpCurOff = 0x4D
  CharBoostSpdOff = 0x57
  CharBoostGutOff = 0x58
  CharBoostVitOff = 0x59
  CharBoostIqOff = 0x5A
  CharBoostLucOff = 0x5B

  # Equipment bytes are 1-based inventory indices. Community labels say
  # Weapon/Body/Arms/Other at +0x31..+0x34, but on this midgame save the
  # second/fourth slots hold Other-class (charms) / Body-class (hats) items
  # respectively — so we label Weapon/Other/Arms/Body to match item types.
  # TODO: re-confirm slot names with an equip/unequip --find pass in-game.
  EquipSlotNames = ["Weapon", "Other", "Arms", "Body"]
  CharRoleNames = ["Ness", "Paula", "Jeff", "Poo"]

  # XP-to-reach level N (index = level). Source: rpgclassics.com EB chart via
  # community save tools — not ROM bytes. Used only for "EXP to next" display.
  NessXp = [
    0, 0, 4, 17, 44, 109, 236, 449,
    772, 1229, 1844, 2641, 3644, 4877, 6364, 8129,
    10703, 13241, 16214, 19673, 23669, 28253, 33476, 39389,
    46043, 53489, 61778, 70961, 81089, 92213, 104384, 117653,
    132071, 147689, 164558, 182729, 202270, 223249, 245734, 269793,
    295494, 322905, 352094, 383129, 416078, 451009, 487990, 527089,
    568374, 611913, 657774, 706025, 756734, 809969, 865798, 924289,
    985510, 1049529, 1116414, 1186233, 1259054, 1335030, 1414314, 1497059,
    1583418, 1673544, 1767590, 1865709, 1968054, 2074778, 2186034, 2301975,
    2422754, 2548524, 2679438, 2815649, 2957310, 3104574, 3257594, 3416523,
    3581514, 3752720, 3930294, 4114389, 4305158, 4502754, 4707330, 4919039,
    5138034, 5364468, 5598494, 5840265, 6089934, 6347654, 6613578, 6887859,
    7170650, 7462104, 7762374, 8071613
  ]
  PaulaXp = [
    0, 0, 8, 32, 80, 178, 352, 628,
    1032, 1590, 2328, 3272, 4448, 5882, 7600, 9628,
    12023, 14842, 18142, 21980, 26413, 31498, 37292, 43852,
    51235, 59498, 68698, 78892, 90137, 102490, 116008, 130748,
    146767, 164122, 182870, 203068, 224789, 248106, 273092, 299820,
    328363, 358794, 391186, 425612, 462145, 500858, 541824, 585116,
    630807, 678970, 729678, 783004, 839021, 897802, 959420, 1023948,
    1091459, 1162026, 1235722, 1312620, 1392793, 1476442, 1563768, 1654972,
    1750255, 1849818, 1953862, 2062588, 2176197, 2294890, 2418868, 2548332,
    2683483, 2824522, 2971650, 3125068, 3284977, 3451578, 3625072, 3805660,
    3993543, 4188922, 4391998, 4602972, 4822045, 5049418, 5285292, 5529868,
    5783347, 6045930, 6317818, 6599212, 6890313, 7191322, 7502440, 7823868,
    8155807, 8498458, 8852022, 9216700
  ]
  JeffXp = [
    0, 0, 4, 16, 40, 88, 172, 304,
    496, 760, 1108, 1552, 2104, 2776, 3580, 4528,
    5733, 7308, 9366, 12020, 15383, 19568, 24688, 30856,
    38185, 46788, 56778, 68268, 81371, 96200, 112868, 131488,
    152173, 175036, 200190, 227748, 257711, 290080, 324856, 362040,
    401633, 443636, 488050, 534876, 584115, 635768, 689836, 746320,
    805221, 866540, 930278, 996436, 1065015, 1136016, 1209440, 1285288,
    1363561, 1444260, 1527386, 1612940, 1700923, 1791605, 1885256, 1982146,
    2082545, 2186723, 2294950, 2407496, 2524631, 2646625, 2773748, 2906270,
    3044461, 3188591, 3338930, 3495748, 3659315, 3829901, 4007776, 4193210,
    4386473, 4587835, 4797566, 5015936, 5243215, 5479673, 5725580, 5981206,
    6246821, 6522695, 6809098, 7106300, 7414571, 7734181, 8065400, 8408498,
    8763745, 9131411, 9511766, 9905080
  ]
  PooXp = [
    0, 0, 8, 25, 52, 106, 204, 363,
    600, 932, 1376, 1949, 2668, 3550, 4612, 5871,
    7390, 9232, 11460, 14137, 17326, 21090, 25492, 30595,
    36462, 43156, 50740, 59277, 68830, 79462, 91236, 104215,
    118462, 134040, 151012, 169441, 189442, 211130, 234620, 260027,
    287466, 317052, 348900, 383125, 419842, 459166, 501212, 546095,
    593930, 644832, 698916, 756297, 817090, 881410, 949372, 1021091,
    1096682, 1176260, 1259940, 1347837, 1440066, 1536775, 1638112, 1744225,
    1855262, 1971371, 2092700, 2219397, 2351610, 2489487, 2633176, 2782825,
    2938582, 3100595, 3269012, 3443981, 3625650, 3814167, 4009680, 4212337,
    4422286, 4639675, 4864652, 5097365, 5337962, 5586591, 5843400, 6108537,
    6382150, 6664387, 6955396, 7255325, 7564322, 7882535, 8210112, 8547201,
    8893950, 9250507, 9617020, 9993637
  ]

type
  Field = object
    name: string
    offset: int
    size: int
    confidence: string
  ReportSink = object
    lines: seq[string]
    toStdout: bool

# Item names from community GameFAQs ID list (Oh Mother / FAQ), not ROM extract.
const ItemNames = {
  0x01.uint8: "Franklin Badge",
  0x02.uint8: "Teddy Bear",
  0x03.uint8: "Super Plush Bear",
  0x04.uint8: "Broken Machine",
  0x05.uint8: "Broken Gadget",
  0x06.uint8: "Broken Air Gun",
  0x07.uint8: "Broken Spray Can",
  0x08.uint8: "Broken Laser",
  0x09.uint8: "Broken Iron",
  0x0A.uint8: "Broken Pipe",
  0x0B.uint8: "Broken Cannon",
  0x0C.uint8: "Broken Tube",
  0x0D.uint8: "Broken Bazooka",
  0x0E.uint8: "Broken Trumpet",
  0x0F.uint8: "Broken Harmonica",
  0x10.uint8: "Broken Antenna",
  0x11.uint8: "Cracked Bat",
  0x12.uint8: "Tee Ball Bat",
  0x13.uint8: "Sand Lot Bat",
  0x14.uint8: "Minor League Bat",
  0x15.uint8: "Mr. Baseball Bat",
  0x16.uint8: "Big League Bat",
  0x17.uint8: "Hall of Fame Bat",
  0x18.uint8: "Magicant Bat",
  0x19.uint8: "Legendary Bat",
  0x1A.uint8: "Gutsy Bat",
  0x1B.uint8: "Casey Bat",
  0x1C.uint8: "Fry Pan",
  0x1D.uint8: "Thick Fry Pan",
  0x1E.uint8: "Deluxe Fry Pan",
  0x1F.uint8: "Chef's Fry Pan",
  0x20.uint8: "French Fry Pan",
  0x21.uint8: "Magic Fry Pan",
  0x22.uint8: "Holy Fry Pan",
  0x23.uint8: "Sword of Kings",
  0x24.uint8: "Pop Gun",
  0x25.uint8: "Stun Gun",
  0x26.uint8: "Toy Air Gun",
  0x27.uint8: "Magnum Air Gun",
  0x28.uint8: "Zip Gun",
  0x29.uint8: "Laser Gun",
  0x2A.uint8: "Hyper Beam",
  0x2B.uint8: "Crusher Beam",
  0x2C.uint8: "Spectrum Beam",
  0x2D.uint8: "Death Ray",
  0x2E.uint8: "Baddest Beam",
  0x2F.uint8: "Moon Beam Gun",
  0x30.uint8: "Gaia Beam",
  0x31.uint8: "Yo-Yo",
  0x32.uint8: "Slingshot",
  0x33.uint8: "Bionic Slingshot",
  0x34.uint8: "Trick Yo-Yo",
  0x35.uint8: "Combat Yo-Yo",
  0x36.uint8: "Travel Charm",
  0x37.uint8: "Great Charm",
  0x38.uint8: "Crystal Charm",
  0x39.uint8: "Rabbit's Foot",
  0x3A.uint8: "Flame Pendant",
  0x3B.uint8: "Rain Pendant",
  0x3C.uint8: "Night Pendant",
  0x3D.uint8: "Sea Pendant",
  0x3E.uint8: "Star Pendant",
  0x3F.uint8: "Cloak of Kings",
  0x40.uint8: "Cheap Bracelet",
  0x41.uint8: "Copper Bracelet",
  0x42.uint8: "Silver Bracelet",
  0x43.uint8: "Gold Bracelet",
  0x44.uint8: "Platinum Band",
  0x45.uint8: "Diamond Band",
  0x46.uint8: "Pixie's Bracelet",
  0x47.uint8: "Cherub's Band",
  0x48.uint8: "Goddess Band",
  0x49.uint8: "Bracer of Kings",
  0x4A.uint8: "Baseball Cap",
  0x4B.uint8: "Holmes Hat",
  0x4C.uint8: "Mr. Baseball Cap",
  0x4D.uint8: "Hard Hat",
  0x4E.uint8: "Ribbon",
  0x4F.uint8: "Red Ribbon",
  0x50.uint8: "Goddess Ribbon",
  0x51.uint8: "Coin of Slumber",
  0x52.uint8: "Coin of Defense",
  0x53.uint8: "Lucky Coin",
  0x54.uint8: "Talisman Coin",
  0x55.uint8: "Shiny Coin",
  0x56.uint8: "Souvenir Coin",
  0x57.uint8: "Diadem of Kings",
  0x58.uint8: "Cookie",
  0x59.uint8: "Bag of Fries",
  0x5A.uint8: "Hamburger",
  0x5B.uint8: "Boiled Egg",
  0x5C.uint8: "Fresh Egg",
  0x5D.uint8: "Picnic Lunch",
  0x5E.uint8: "Pasta di Summers",
  0x5F.uint8: "Pizza",
  0x60.uint8: "Chef's Special",
  0x61.uint8: "Large Pizza",
  0x62.uint8: "PSI Caramel",
  0x63.uint8: "Magic Truffle",
  0x64.uint8: "Brain Food Lunch",
  0x65.uint8: "Rock Candy",
  0x66.uint8: "Croissant",
  0x67.uint8: "Bread Roll",
  0x68.uint8: "Pak of Bubble Gum",
  0x69.uint8: "Jar of Fly Honey",
  0x6A.uint8: "Can of Fruit Juice",
  0x6B.uint8: "Royal Iced Tea",
  0x6C.uint8: "Protein Drink",
  0x6D.uint8: "Kraken Soup",
  0x6E.uint8: "Bottle of Water",
  0x6F.uint8: "Cold Remedy",
  0x70.uint8: "Vial of Serum",
  0x71.uint8: "IQ Capsule",
  0x72.uint8: "Guts Capsule",
  0x73.uint8: "Speed Capsule",
  0x74.uint8: "Vital Capsule",
  0x75.uint8: "Luck Capsule",
  0x76.uint8: "Ketchup Packet",
  0x77.uint8: "Sugar Packet",
  0x78.uint8: "Tin of Cocoa",
  0x79.uint8: "Carton of Cream",
  0x7A.uint8: "Sprig of Parsley",
  0x7B.uint8: "Jar of Hot Sauce",
  0x7C.uint8: "Salt Packet",
  0x7D.uint8: "Backstage Pass",
  0x7E.uint8: "Jar of Delisauce",
  0x7F.uint8: "Wet Towel",
  0x80.uint8: "Refreshing Herb",
  0x81.uint8: "Secret Herb",
  0x82.uint8: "Horn of Life",
  0x83.uint8: "Counter-PSI Unit",
  0x84.uint8: "Shield Killer",
  0x85.uint8: "Bazooka",
  0x86.uint8: "Heavy Bazooka",
  0x87.uint8: "HP-Sucker",
  0x88.uint8: "Hungry HP-Sucker",
  0x89.uint8: "Xterminator Spray",
  0x8A.uint8: "Slime Generator",
  0x8B.uint8: "Yogurt Dispenser",
  0x8C.uint8: "Ruler",
  0x8D.uint8: "Snake Bag",
  0x8E.uint8: "Mummy Wrap",
  0x8F.uint8: "Protractor",
  0x90.uint8: "Bottle Rocket",
  0x91.uint8: "Big Bottle Rocket",
  0x92.uint8: "Multi Bottle Rocket",
  0x93.uint8: "Bomb",
  0x94.uint8: "Super Bomb",
  0x95.uint8: "Insecticide Spray",
  0x96.uint8: "Rust Promoter",
  0x97.uint8: "Rust Promoter DX",
  0x98.uint8: "Pair of Dirty Socks",
  0x99.uint8: "Stag Beetle",
  0x9A.uint8: "Toothbrush",
  0x9B.uint8: "Handbag Strap",
  0x9C.uint8: "Pharaoh's Curse",
  0x9D.uint8: "Defense Shower",
  0x9E.uint8: "Letter from Mom",
  0x9F.uint8: "Sudden Guts Pills",
  0xA0.uint8: "Bag of Dragonite",
  0xA1.uint8: "Defense Spray",
  0xA2.uint8: "Piggy Nose",
  0xA3.uint8: "For Sale Sign",
  0xA4.uint8: "Shyness Book",
  0xA5.uint8: "Picture Postcard",
  0xA6.uint8: "King Banana",
  0xA7.uint8: "Letter from Tony",
  0xA8.uint8: "Chick",
  0xA9.uint8: "Chicken",
  0xAA.uint8: "Key to the Shack",
  0xAB.uint8: "Key to the Cabin",
  0xAC.uint8: "Bad Key Machine",
  0xAD.uint8: "Temporary Goods",
  0xAE.uint8: "Zombie Paper",
  0xAF.uint8: "Hawk Eye",
  0xB0.uint8: "Bicycle",
  0xB1.uint8: "ATM Card",
  0xB2.uint8: "Shock Ticket",
  0xB3.uint8: "Letter from Kids",
  0xB4.uint8: "Wad of Bills",
  0xB5.uint8: "Receiver Phone",
  0xB6.uint8: "Diamond",
  0xB7.uint8: "Signed Banana",
  0xB8.uint8: "Pencil Eraser",
  0xB9.uint8: "Hieroglyph Copy",
  0xBA.uint8: "Meteotite",
  0xBB.uint8: "Contact Lens",
  0xBC.uint8: "Hand-Aid",
  0xBD.uint8: "Trout Yogurt",
  0xBE.uint8: "Banana",
  0xBF.uint8: "Calorie Stick",
  0xC0.uint8: "Key to the Tower",
  0xC1.uint8: "Meteorite Piece",
  0xC2.uint8: "Earth Pendant",
  0xC3.uint8: "Neutralizer",
  0xC4.uint8: "Sound Stone",
  0xC5.uint8: "Exit Mouse",
  0xC6.uint8: "Gelato de Resort",
  0xC7.uint8: "Snake",
  0xC8.uint8: "Viper",
  0xC9.uint8: "Brain Stone",
  0xCA.uint8: "Town Map",
  0xCB.uint8: "Video Relaxant",
  0xCC.uint8: "Suporma",
  0xCD.uint8: "Key to the Locker",
  0xCE.uint8: "Insignificant Item",
  0xCF.uint8: "Magic Tart",
  0xD0.uint8: "Tiny Ruby",
  0xD1.uint8: "Monkey's Love",
  0xD2.uint8: "Eraser Eraser",
  0xD3.uint8: "Tendakraut",
  0xD4.uint8: "T-Rex's Bat",
  0xD5.uint8: "Big League Bat (dup)",
  0xD6.uint8: "Ultimate Bat",
  0xD7.uint8: "Double Beam",
  0xD8.uint8: "Platinum Band (dup)",
  0xD9.uint8: "Diamond Band (dup)",
  0xDA.uint8: "Defense Ribbon",
  0xDB.uint8: "Talisman Ribbon",
  0xDC.uint8: "Saturn Ribbon",
  0xDD.uint8: "Coin of Silence",
  0xDE.uint8: "Charm Coin",
  0xDF.uint8: "Cup of Noodles",
  0xE0.uint8: "Skip Sandwich",
  0xE1.uint8: "Skip Sandwich DX",
  0xE2.uint8: "Lucky Sandwich (60HP)",
  0xE3.uint8: "Lucky Sandwich (250HP)",
  0xE4.uint8: "Lucky Sandwich (full)",
  0xE5.uint8: "Lucky Sandwich (5PP)",
  0xE6.uint8: "Lucky Sandwich (20PP)",
  0xE7.uint8: "Lucky Sandwich (full+)",
  0xE8.uint8: "Cup of Coffee",
  0xE9.uint8: "Double Burger",
  0xEA.uint8: "Peanut Cheese Bar",
  0xEB.uint8: "Piggy Jelly",
  0xEC.uint8: "Bowl of Rice Gruel",
  0xED.uint8: "Bean Croquette",
  0xEE.uint8: "Molokheiya Soup",
  0xEF.uint8: "Plain Roll",
  0xF0.uint8: "Kabob",
  0xF1.uint8: "Plain Yogurt",
  0xF2.uint8: "Beef Jerky",
  0xF3.uint8: "Mammoth Burger",
  0xF4.uint8: "Spicy Jerky",
  0xF5.uint8: "Luxury Jerky",
  0xF6.uint8: "Bottle of DX Water",
  0xF7.uint8: "Magic Pudding",
  0xF8.uint8: "Non-Stick Frypan",
  0xF9.uint8: "Mr. Saturn Coin",
  0xFA.uint8: "Meteornium",
  0xFB.uint8: "Popsicle",
  0xFC.uint8: "Cup of Lifenoodles",
  0xFD.uint8: "Carrot Key",
  0xFE.uint8: "(crash - do NOT use)",
  0xFF.uint8: "(crash - do NOT use)"
}.toTable

# Known top-level fields (slot-relative when active base applied in dump).
const KnownFields = [
  Field(name: "Money on hand", offset: MoneyOff, size: 4,
    confidence: "confirmed ($20/$71/$924 across saves)"),
  Field(name: "ATM balance", offset: AtmOff, size: 4,
    confidence: "confirmed ($0/$64/$109/$6617 across saves)"),
]

proc emit(sink: var ReportSink, s: string) =
  ## Append a report line and optionally echo it.
  sink.lines.add s
  if sink.toStdout:
    echo s

proc readLE(data: string, offset, size: int): uint32 =
  ## Little-endian unsigned read of `size` bytes at `offset`.
  for i in 0 ..< size:
    if offset + i < data.len:
      result = result or (data[offset + i].uint32 shl (8 * i))

proc readU8(data: string, offset: int): uint8 =
  ## Read one byte at `offset`, or 0 if out of range.
  if offset >= 0 and offset < data.len:
    result = data[offset].uint8

proc decodeSaveName(data: string, off: int, maxLen = 5): string =
  ## Decode a null-terminated EB-encoded name at `off` (byte = ASCII + 0x30).
  var s = ""
  for i in 0 ..< maxLen:
    if off + i >= data.len: break
    let b = data[off + i].uint8
    if b == 0: break
    let c = char(b - 0x30)
    if c in ' '..'~':
      s.add c
    else:
      s.add &"[{b:02X}]"
  if s.len == 0: s = "(empty)"
  return s

proc itemStr(id: uint8): string =
  ## Format an inventory item ID with community name when known.
  if id == 0:
    return "(empty)"
  if id in ItemNames:
    return &"{ItemNames[id]}(0x{id:02X})"
  return &"0x{id:02X}"

proc xpThreshold(charIdx, level: int): int =
  ## Total EXP required to be at `level` for playable char index 0..3.
  if level < 1 or level > 99:
    return 0
  case charIdx
  of 0: result = NessXp[level]
  of 1: result = PaulaXp[level]
  of 2: result = JeffXp[level]
  of 3: result = PooXp[level]
  else: result = 0

proc slotHasHeader(data: string, base: int): bool =
  ## True if `base` starts with the HAL Laboratory signature.
  if base + Header.len > data.len: return false
  return data[base ..< base + Header.len] == Header

proc slotNonzero(data: string, base: int): int =
  ## Count non-zero payload bytes in a slot (skips pure signature-only empties).
  let endp = min(base + SaveSlotSize, data.len)
  for i in base + DataOffset ..< endp:
    if data[i] != '\0': inc result

proc detectActiveBase(data: string): int =
  ## Pick the occupied slot copy with the highest stamp among all A/B mirrors.
  var
    best = 0
    bestNz = 0
    bestStamp = 0'u32
  for pair in SlotPairBases:
    for base in [pair, pair + MirrorDelta]:
      if not slotHasHeader(data, base): continue
      let nz = slotNonzero(data, base)
      if nz == 0: continue
      let stamp = readLE(data, base + StampOff, 4)
      if nz > bestNz or (nz == bestNz and stamp > bestStamp):
        best = base
        bestNz = nz
        bestStamp = stamp
  return best

proc pairMate(base: int): int =
  ## Return the A/B mirror partner for a slot base.
  let mod500 = base mod (MirrorDelta * 2)
  if mod500 < MirrorDelta:
    return base + MirrorDelta
  return base - MirrorDelta

proc dumpChar(sink: var ReportSink, data: string, slotBase, charIdx: int, tag = "") =
  ## Dump one playable character's full mapped stat block.
  let eb = slotBase + CharTableBase + charIdx * CharStride
  let name = decodeSaveName(data, eb + CharNameOff)
  let level = readU8(data, eb + CharLevelOff).int
  let exp = readLE(data, eb + CharExpOff, 4).int
  let hpMax = readLE(data, eb + CharHpMaxOff, 2).int
  let ppMax = readLE(data, eb + CharPpMaxOff, 2).int
  let hpCur = readLE(data, eb + CharHpCurOff, 2).int
  let ppCur = readLE(data, eb + CharPpCurOff, 2).int
  let hpRoll = readLE(data, eb + CharHpRollOff, 2).int
  let ppRoll = readLE(data, eb + CharPpRollOff, 2).int
  let offn = readU8(data, eb + CharOffOff)
  let defn = readU8(data, eb + CharDefOff)
  let spdn = readU8(data, eb + CharSpdOff)
  let gutn = readU8(data, eb + CharGutOff)
  let lucn = readU8(data, eb + CharLucOff)
  let vitn = readU8(data, eb + CharVitOff)
  let iqn = readU8(data, eb + CharIqOff)
  let boff = readU8(data, eb + CharBaseOffOff)
  let bdef = readU8(data, eb + CharBaseDefOff)
  let bspd = readU8(data, eb + CharBaseSpdOff)
  let bgut = readU8(data, eb + CharBaseGutOff)
  let bluc = readU8(data, eb + CharBaseLucOff)
  let bvit = readU8(data, eb + CharBaseVitOff)
  let biq = readU8(data, eb + CharBaseIqOff)
  let boostSpd = readU8(data, eb + CharBoostSpdOff)
  let boostGut = readU8(data, eb + CharBoostGutOff)
  let boostVit = readU8(data, eb + CharBoostVitOff)
  let boostIq = readU8(data, eb + CharBoostIqOff)
  let boostLuc = readU8(data, eb + CharBoostLucOff)

  var inv: array[InvLen, uint8]
  for j in 0 ..< InvLen:
    inv[j] = readU8(data, eb + CharInvOff + j)

  var equipParts: seq[string] = @[]
  for j in 0 ..< EquipLen:
    let idx = readU8(data, eb + CharEquipOff + j).int
    let slotName = EquipSlotNames[j]
    if idx == 0:
      equipParts.add &"{slotName}=(none)"
    elif idx >= 1 and idx <= InvLen:
      equipParts.add &"{slotName}={itemStr(inv[idx - 1])} [inv#{idx}]"
    else:
      equipParts.add &"{slotName}=raw{idx}"

  var psiHex = ""
  for j in 0 ..< PsiLen:
    if j > 0: psiHex.add " "
    psiHex.add &"{readU8(data, eb + CharPsiOff + j):02X}"

  let tagStr = if tag.len > 0: " " & tag else: ""
  let role = if charIdx < CharRoleNames.len: CharRoleNames[charIdx] else: &"char{charIdx}"
  emit(sink, &"  {name} ({role}, lv{level}){tagStr}:")
  emit(sink, &"    EXP {exp}")
  if level >= 1 and level < 99:
    let nextNeed = xpThreshold(charIdx, level + 1)
    let curFloor = xpThreshold(charIdx, level)
    let toNext = nextNeed - exp
    let nextLv = level + 1
    emit(sink, &"    EXP band lv{level}..{nextLv}: {curFloor}..{nextNeed}  ({toNext} to next) [community XP table]")
  elif level >= 99:
    emit(sink, "    EXP band: max level")
  emit(sink, &"    HP {hpCur}/{hpMax}  PP {ppCur}/{ppMax}")
  if hpRoll != hpCur or ppRoll != ppCur:
    emit(sink, &"    rolling HP/PP {hpRoll}/{ppRoll} (display animation)")
  emit(sink, &"    stats (w/ equip): OFF {offn}  DEF {defn}  SPD {spdn}  GUT {gutn}  LUC {lucn}  VIT {vitn}  IQ {iqn}")
  emit(sink, &"    stats (base):     OFF {boff}  DEF {bdef}  SPD {bspd}  GUT {bgut}  LUC {bluc}  VIT {bvit}  IQ {biq}")
  emit(sink, "      [combat stats: community char-table offsets 0x15-0x22; values sane for midgame]")
  if boostSpd.int + boostGut.int + boostVit.int + boostIq.int + boostLuc.int > 0:
    emit(sink, &"    capsule boosts: SPD+{boostSpd} GUT+{boostGut} VIT+{boostVit} IQ+{boostIq} LUC+{boostLuc}")
  let equipLine = equipParts.join(", ")
  emit(sink, &"    equipment: {equipLine}")
  emit(sink, "    inventory:")
  var anyInv = false
  for j in 0 ..< InvLen:
    if inv[j] != 0:
      anyInv = true
      emit(sink, &"      [{j+1:2}] {itemStr(inv[j])}")
  if not anyInv:
    emit(sink, "      (all empty)")
  emit(sink, &"    PSI-learned (raw 14B @+0x35): {psiHex}")

proc dumpMirrorDiff(sink: var ReportSink, data: string, primary, backup: int) =
  ## Compare primary vs backup ($500 mirror) and summarize divergence.
  emit(sink, "")
  emit(sink, &"primary vs backup (0x{primary:04X} vs 0x{backup:04X}):")
  if not slotHasHeader(data, backup):
    emit(sink, "  backup: missing HAL header")
    return
  var diffs: seq[int] = @[]
  let n = min(SaveSlotSize, data.len - max(primary, backup))
  for i in 0 ..< n:
    if data[primary + i] != data[backup + i]:
      diffs.add i
  if diffs.len == 0:
    emit(sink, "  identical (no divergence)")
  else:
    emit(sink, &"  {diffs.len} differing byte(s) — corruption canary / stamp churn")
    let show = min(diffs.len, 16)
    for k in 0 ..< show:
      let i = diffs[k]
      emit(sink, &"    +0x{i:03X}: primary=0x{readU8(data, primary + i):02X} backup=0x{readU8(data, backup + i):02X}")
    if diffs.len > show:
      emit(sink, &"    ... and {diffs.len - show} more")
    # Highlight money/ATM specifically.
    let pm = readLE(data, primary + MoneyOff, 4)
    let bm = readLE(data, backup + MoneyOff, 4)
    let pa = readLE(data, primary + AtmOff, 4)
    let ba = readLE(data, backup + AtmOff, 4)
    if pm != bm or pa != ba:
      emit(sink, &"  money/ATM diverge: primary ${pm}/${pa} vs backup ${bm}/${ba}")
    else:
      emit(sink, &"  money/ATM agree: ${pm} hand / ${pa} ATM")

proc dumpPartyAndStorage(sink: var ReportSink, data: string, slotBase: int) =
  ## Print party roster, full char blocks, and Escargo Express storage.
  emit(sink, "")
  emit(sink, &"party + storage (active slot base 0x{slotBase:04X}):")
  var roster: seq[int] = @[]
  for j in 0 ..< PartyRosterLen:
    let id = readU8(data, slotBase + PartyRosterOff + j).int
    if id >= 1 and id <= PlayableCharCount:
      roster.add(id - 1)
  emit(sink, "  In party (order):")
  if roster.len == 0:
    emit(sink, "    (none)")
  else:
    for ci in roster:
      dumpChar(sink, data, slotBase, ci)
  var inPartySet: set[range[0..3]] = {}
  for ci in roster:
    inPartySet.incl(ci)
  emit(sink, "  Roster (not yet joined / reserved):")
  var anyNotJoined = false
  for i in 0 ..< PlayableCharCount:
    if i notin inPartySet:
      anyNotJoined = true
      dumpChar(sink, data, slotBase, i, "(not in party)")
  if not anyNotJoined:
    emit(sink, "    (none)")
  let escBase = slotBase + EscargoOff
  var anyEsc = false
  emit(sink, "  Escargo Express (36 slots):")
  for j in 0 ..< EscargoLen:
    let id = readU8(data, escBase + j)
    if id != 0:
      anyEsc = true
      emit(sink, &"    [{j+1:2}] {itemStr(id)}")
  if not anyEsc:
    emit(sink, "    (all empty)")

proc dumpSlotSummary(sink: var ReportSink, data: string) =
  ## List all three save slots and which A/B copy looks active.
  emit(sink, "save slots (3 x primary+backup @ +$500):")
  for si, pair in SlotPairBases:
    let a = pair
    let b = pair + MirrorDelta
    let aOk = slotHasHeader(data, a)
    let bOk = slotHasHeader(data, b)
    let aNz = if aOk: slotNonzero(data, a) else: 0
    let bNz = if bOk: slotNonzero(data, b) else: 0
    let aSt = if aOk: readLE(data, a + StampOff, 4) else: 0'u32
    let bSt = if bOk: readLE(data, b + StampOff, 4) else: 0'u32
    let aMoney = if aOk and aNz > 0: readLE(data, a + MoneyOff, 4).int else: -1
    let bMoney = if bOk and bNz > 0: readLE(data, b + MoneyOff, 4).int else: -1
    let status =
      if aNz == 0 and bNz == 0: "empty"
      elif aNz > 0 or bNz > 0: "occupied"
      else: "header-only"
    emit(sink, &"  slot {si+1}: {status}  A@0x{a:04X} nz={aNz} stamp={aSt} money={aMoney}  B@0x{b:04X} nz={bNz} stamp={bSt} money={bMoney}")

proc dumpKnown(sink: var ReportSink, data: string) =
  ## Full save report card for the active slot.
  let sig = if data.len >= Header.len: data[0 ..< Header.len] else: ""
  emit(sink, &"save file: {data.len} bytes")
  if sig == Header:
    emit(sink, "header:    OK  (\"" & Header & "\") — valid EarthBound save")
  else:
    emit(sink, "header:    MISSING/INVALID — not a valid EB save (or empty)")
  var nonzero = 0
  for c in data:
    if c != '\0': inc nonzero
  emit(sink, &"non-zero:  {nonzero} / {data.len} bytes of real data")
  emit(sink, &"layout:    0x{SramSize:X} SRAM, data@+0x{DataOffset:X} len 0x{DataSize:X}, csum@+0x{Csum1Off:X}/+0x{Csum2Off:X}")
  emit(sink, "playtime:  (not mapped in SRAM tools yet — use --find if you know a value)")
  emit(sink, "")
  dumpSlotSummary(sink, data)

  let slotBase = detectActiveBase(data)
  emit(sink, "")
  emit(sink, &"active report slot: 0x{slotBase:04X}")
  let pet = decodeSaveName(data, slotBase + PetNameOff, 6)
  let food = decodeSaveName(data, slotBase + FavFoodOff, 6)
  let thing = decodeSaveName(data, slotBase + FavThingOff, 6)
  emit(sink, &"  pet:    {pet}  [EB text @+0x44; decoded King/Steak/Rockin on sample]")
  emit(sink, &"  food:   {food}")
  emit(sink, &"  thing:  {thing}")
  let px = readLE(data, slotBase + PosXOff, 2)
  let py = readLE(data, slotBase + PosYOff, 2)
  emit(sink, &"  position: X={px} Y={py}  [community OFF_X/Y; confidence: cross-ref only]")

  emit(sink, "")
  emit(sink, "mapped fields (active-slot-relative  value  field  [confidence]):")
  for f in KnownFields:
    let v = readLE(data, slotBase + f.offset, f.size)
    emit(sink, &"  0x{f.offset:03X}  {v:>7}   {f.name:<14} [{f.confidence}]")
  let money = readLE(data, slotBase + MoneyOff, 4)
  let atm = readLE(data, slotBase + AtmOff, 4)
  emit(sink, &"  wallet:  ${money} on hand / ${atm} in ATM")

  emit(sink, "")
  emit(sink, "The format is only partially mapped. Use --find <value> to locate a")
  emit(sink, "stat you know in-game, then we can add it with a confidence label.")
  emit(sink, "Combat stats / equip / XP tables: community cross-ref + local sanity,")
  emit(sink, "not every field has been --find re-confirmed on this save.")

  dumpPartyAndStorage(sink, data, slotBase)
  dumpMirrorDiff(sink, data, slotBase, pairMate(slotBase))

proc findValue(data: string, n: uint32) =
  ## Report every offset where n appears as a u8, u16-LE, or u32-LE.
  echo &"searching for {n} (0x{n:X}) as u8 / u16-LE / u32-LE:"
  var hits = 0
  for size in [1, 2, 4]:
    if n >= (1'u64 shl (8 * size)).uint32 and size < 4: continue
    for off in 0 .. data.len - size:
      if readLE(data, off, size) == n:
        echo &"  0x{off:03X}  as u{size*8}-LE"
        inc hits
  if hits == 0:
    echo "  (not found — try a nearby value; some stats are BCD or offset)"
  echo &"({hits} hit(s))"

when isMainModule:
  var
    path = DefaultSrm
    findN = -1
    outPath = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--find" and i < paramCount():
      findN = parseInt(paramStr(i + 1)); inc i
    elif (a == "--out" or a == "--report") and i < paramCount():
      outPath = paramStr(i + 1); inc i
    elif not a.startsWith("--"):
      path = a
    inc i

  if not fileExists(path):
    echo "no save file at: ", path
    echo "(save in-game at a phone first, or pass a .srm path)"
    quit(1)
  let data = readFile(path)
  echo "== ", path, " =="
  if findN >= 0:
    findValue(data, findN.uint32)
  else:
    var sink = ReportSink(lines: @[], toStdout: true)
    dumpKnown(sink, data)
    if outPath.len > 0:
      writeFile(outPath, sink.lines.join("\n") & "\n")
      echo ""
      echo "wrote report: ", outPath
