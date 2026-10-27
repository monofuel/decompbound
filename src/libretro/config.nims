# A self-initializing shared library with an isolated runtime symbol namespace.
import std/os

let repositoryRoot = thisDir().parentDir.parentDir
switch("app", "lib")
switch("mm", "orc")
switch("define", "release")
# Return the library's allocations to libc instead of retaining a private heap
# whose page pools cannot be reclaimed after dlclose.
switch("define", "useMalloc")
switch("nimMainPrefix", "decompboundLibretro")
switch("passL", "-Wl,--version-script=" & (thisDir() / "exports.map"))
switch("out", repositoryRoot / "bin/libretro/decompbound_libretro.so")
