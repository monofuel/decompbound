# A self-initializing shared library with an isolated runtime symbol namespace.
import std/[os, sequtils, strutils]

let
  repositoryRoot = thisDir().parentDir.parentDir
  target = getEnv("DECOMPBOUND_TARGET")
  cc = getEnv("DECOMPBOUND_CC", "aarch64-unknown-linux-gnu-gcc")
  tune = getEnv("DECOMPBOUND_TUNE")
  pgo = getEnv("DECOMPBOUND_PGO")
  pgoDir = getEnv("DECOMPBOUND_PGO_DIR")

if tune notin ["", "cortex-a55"]:
  raise newException(ValueError, "Unknown DECOMPBOUND_TUNE: " & tune)
if pgo notin ["", "off", "generate", "use"]:
  raise newException(ValueError, "Unknown DECOMPBOUND_PGO: " & pgo)
if pgo in ["generate", "use"] and not pgoDir.isAbsolute:
  raise newException(ValueError, "DECOMPBOUND_PGO_DIR must be absolute for PGO")
if tune.len > 0 or pgo in ["generate", "use"]:
  if target != "arm64":
    raise newException(ValueError, "Tuning and PGO require DECOMPBOUND_TARGET=arm64")
  let compiler = gorgeEx(quoteShell(cc) & " -dM -E -x c /dev/null")
  if compiler.exitCode != 0 or "#define __GNUC__ " notin compiler.output or
      "#define __clang__ " in compiler.output or
      "#define __aarch64__ " notin compiler.output:
    raise newException(ValueError, "Tuning and PGO require an AArch64 GCC: " & cc)

if pgo == "use":
  # Set this before selecting GCC: Nim caches its always-on compiler options.
  # Nim's default -w also disables GCC's fatal profile diagnostics.
  var gccOptions = get("gcc.options.always").splitWhitespace
  gccOptions.keepItIf(it != "-w")
  put("gcc.options.always", gccOptions.join(" "))

switch("app", "lib")
switch("mm", "orc")
# Return the library's allocations to libc instead of retaining a private heap
# whose page pools cannot be reclaimed after dlclose.
switch("define", "useMalloc")
switch("nimMainPrefix", "decompboundLibretro")
switch("passL", "-Wl,--version-script=" & (thisDir() / "exports.map"))

if target.len == 0:
  switch("out", repositoryRoot / "bin/libretro/decompbound_libretro.so")
elif target == "arm64":
  switch("cpu", "arm64")
  switch("os", "linux")
  switch("cc", "gcc")
  switch("gcc.exe", cc)
  switch("gcc.linkerexe", cc)
  switch("out", repositoryRoot / "bin/libretro/decompbound_libretro-arm64.so")
else:
  raise newException(ValueError, "Unknown DECOMPBOUND_TARGET: " & target)

if tune == "cortex-a55":
  switch("passC", "-mcpu=cortex-a55")
  switch("passL", "-mcpu=cortex-a55")

if pgo in ["generate", "use"]:
  let profileFlag = quoteShell("-fprofile-" & pgo & "=" & pgoDir)
  switch("passC", profileFlag)
  switch("passL", profileFlag)
  if pgo == "use":
    switch("passC", "-Werror=missing-profile -Werror=coverage-mismatch")
