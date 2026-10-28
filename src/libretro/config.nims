# A self-initializing shared library with an isolated runtime symbol namespace.
import std/os

let
  repositoryRoot = thisDir().parentDir.parentDir
  target = getEnv("DECOMPBOUND_TARGET")
  cc = getEnv("DECOMPBOUND_CC", "aarch64-unknown-linux-gnu-gcc")

switch("app", "lib")
switch("mm", "orc")
switch("define", "release")
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
