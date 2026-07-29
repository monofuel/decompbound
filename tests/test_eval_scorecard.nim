## Synthetic scorecard writer tests — no ROM, no fixtures, pure schema.

import
  std/[json, os, strutils],
  ../src/tools/eval_scorecard

proc goodCard(): Scorecard =
  ## A valid screen-tier card used as the mutation base for failure cases.
  Scorecard(
    ideaId: "canary",
    candidateId: "abc1234",
    baselineId: "def5678",
    utc: "20260728T000000Z",
    tier: etScreen,
    primaryName: "max_knock",
    primaryValue: 80.0,
    higherIsBetter: true,
    hardConstraints: @[
      HardConstraint(name: "harness_canary", pass: true),
      HardConstraint(name: "referee_green", pass: true),
    ],
    n: 1,
    seedsOrSlate: "scripted-deterministic",
    decision: edKeep,
    reasonCodes: @["keep"],
    links: @["../decompbound_secret/some/log/path"],
    domainExtra: %*{
      "scaffold_tier": "T4",
      "pilot": "scripted",
      "tempo": "turbo",
      "frames": 200000,
      "gates": {"tg": 100, "pokey": 100, "knock": 80},
    },
  )

proc expectReject(card: Scorecard, label: string) =
  ## Assert validation raises for a deliberately bad card.
  var raised = false
  try:
    validate(card)
  except ValueError:
    raised = true
  doAssert raised, "expected rejection: " & label

proc main() =
  ## Exercise the writer round trip plus every rejection class.
  let tmp = getTempDir() / "decompbound_eval_test_runs"
  removeDir(tmp)

  # Round trip: write, re-read, check schema fields.
  let path = writeScorecard(goodCard(), tmp)
  doAssert fileExists(path)
  let parsed = parseJson(readFile(path))
  doAssert parsed["schema_version"].getInt() == 0
  doAssert parsed["tier"].getStr() == "screen"
  doAssert parsed["decision"].getStr() == "keep"
  doAssert parsed["primary_for_ranking"]["value"].getFloat() == 80.0
  doAssert parsed["domain_extra"]["gates"]["knock"].getInt() == 80
  doAssert parsed["hard_constraints"].len == 2
  doAssert path.contains("20260728T000000Z-canary")

  # Invariant 1: failed floor + keep must be rejected.
  var badFloor = goodCard()
  badFloor.hardConstraints[0].pass = false
  expectReject(badFloor, "failed floor with decision=keep")
  # Same card flipped to discard is fine.
  badFloor.decision = edDiscard
  badFloor.reasonCodes = @["fail_canary"]
  validate(badFloor)

  # Copyright allowlist: prose-shaped strings are rejected everywhere.
  var proseExtra = goodCard()
  proseExtra.domainExtra = %*{"pilot": "the bot said hello to mom"}
  expectReject(proseExtra, "whitespace prose in domain_extra value")

  var unknownKey = goodCard()
  unknownKey.domainExtra = %*{"dialogue": "x"}
  expectReject(unknownKey, "domain_extra key outside allowlist")

  var proseReason = goodCard()
  proseReason.reasonCodes = @["failed because the screen text was wrong"]
  expectReject(proseReason, "prose reason code")

  var proseIdea = goodCard()
  proseIdea.ideaId = "my cool idea"
  expectReject(proseIdea, "idea_id with whitespace")

  var proseLink = goodCard()
  proseLink.links = @["see the dialogue: WELCOME TO ONETT"]
  expectReject(proseLink, "prose link")

  # Nested string inside an allowlisted object is still checked.
  var nestedProse = goodCard()
  nestedProse.domainExtra = %*{"gates": {"note": "walked past the cop"}}
  expectReject(nestedProse, "nested prose inside gates")

  # Summary line shape.
  doAssert summaryLine(goodCard()) == "primary=80 floors=pass decision=keep"
  var inconclusive = goodCard()
  inconclusive.decision = edInconclusive
  inconclusive.reasonCodes = @["missing_fixture"]
  doAssert summaryLine(inconclusive).endsWith("decision=inconclusive")

  removeDir(tmp)
  echo "OK test_eval_scorecard"

when isMainModule:
  main()
