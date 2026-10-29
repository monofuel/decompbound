import
  std/[os, osproc, tempfiles]

const
  Probe = """
static:
  doAssert defined(danger) == defined(expectShipping)
  doAssert defined(release) == defined(expectShipping)
  doAssert compileOption("boundChecks") != defined(expectShipping)
  doAssert compileOption("rangeChecks") != defined(expectShipping)
  doAssert compileOption("overflowChecks") != defined(expectShipping)
  doAssert compileOption("assertions") != defined(expectShipping)
  doAssert compileOption("stackTrace") != defined(expectShipping)
  doAssert compileOption("opt", "speed") == defined(expectShipping)
"""

proc main() =
  ## Verify actual compiler options for default shipping and developer builds.
  let
    root = currentSourcePath().parentDir.parentDir
  for parent in [root, root / "tests", root / "src" / "libretro"]:
    let
      directory = createTempDir("build-profile-", "", parent)
      probe = directory / "profile.nim"
    defer:
      removeFile(probe)
      removeDir(directory)
    writeFile(probe, Probe)
    let defaultFlags = if parent == root / "tests": "" else: "-d:expectShipping"
    for flags in [defaultFlags, "-d:debug", "-d:danger -d:expectShipping"]:
      let verification = execCmdEx(
        "nim check --hints:off --warnings:off " & flags & " " & quoteShell(probe),
        workingDir = root)
      doAssert verification.exitCode == 0, verification.output

main()
