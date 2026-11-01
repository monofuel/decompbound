import std/[os, osproc, strutils, unittest]

const SettingNames = ["DECOMPBOUND_TARGET", "DECOMPBOUND_TUNE", "DECOMPBOUND_PGO",
  "DECOMPBOUND_PGO_DIR", "DECOMPBOUND_CC"]

proc checkSettings(settings: openArray[(string, string)], expectedError: string) =
  ## Run the actual core configuration and restore the caller's build settings afterward.
  var
    previous: array[SettingNames.len, string]
    existed: array[SettingNames.len, bool]
  for index, name in SettingNames:
    existed[index] = existsEnv(name)
    previous[index] = getEnv(name)
    delEnv(name)
  defer:
    for index, name in SettingNames:
      if existed[index]: putEnv(name, previous[index])
      else: delEnv(name)
  for (name, value) in settings: putEnv(name, value)
  let checked = execCmdEx("nim dump --hints:off --warnings:off src/libretro/core.nim")
  if expectedError.len == 0:
    doAssert checked.exitCode == 0, checked.output
  else:
    doAssert checked.exitCode != 0 and expectedError in checked.output, checked.output

suite "Libretro compiler profile configuration":
  test "portable defaults and explicit PGO-off need no cross compiler":
    checkSettings([], "")
    checkSettings([("DECOMPBOUND_PGO", "off"), ("DECOMPBOUND_CC", "false")], "")

  test "unknown settings and incomplete PGO configuration fail explicitly":
    checkSettings([("DECOMPBOUND_TUNE", "unsupported")], "Unknown DECOMPBOUND_TUNE")
    checkSettings([("DECOMPBOUND_PGO", "unsupported")], "Unknown DECOMPBOUND_PGO")
    checkSettings([("DECOMPBOUND_PGO", "generate")], "DECOMPBOUND_PGO_DIR must be absolute")
    checkSettings([("DECOMPBOUND_PGO", "use"), ("DECOMPBOUND_PGO_DIR", "relative")],
      "DECOMPBOUND_PGO_DIR must be absolute")

  test "target-specific builds reject an incompatible target or compiler":
    checkSettings([("DECOMPBOUND_TUNE", "cortex-a55")],
      "Tuning and PGO require DECOMPBOUND_TARGET=arm64")
    checkSettings([("DECOMPBOUND_TARGET", "arm64"), ("DECOMPBOUND_TUNE", "cortex-a55"),
      ("DECOMPBOUND_CC", "false")], "Tuning and PGO require an AArch64 GCC")
