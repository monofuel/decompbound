import std/[os, strutils]

# Applications ship by default; tests stay checked unless explicitly built fast.
let
  testBuild = relativePath(projectPath(), thisDir()).startsWith("tests" & DirSep)
  debugBuild = defined(debug) or (testBuild and not defined(danger) and not defined(fast))

if debugBuild:
  switch("define", "debug")
  switch("undef", "release")
  switch("undef", "danger")
  for option in ["boundChecks", "rangeChecks", "overflowChecks", "objChecks",
      "fieldChecks", "assertions", "stackTrace", "lineTrace"]:
    switch(option, "on")
else:
  # Define release explicitly for dependencies when selecting danger in NimScript.
  switch("define", "release")
  switch("define", "danger")
