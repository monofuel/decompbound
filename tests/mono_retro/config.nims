import std/os

let frontendRoot = getEnv("MONO_RETRO_ROOT")
if frontendRoot.len == 0:
  raise newException(ValueError, "Set MONO_RETRO_ROOT to the mono-retro checkout.")
switch("path", frontendRoot / "src")
