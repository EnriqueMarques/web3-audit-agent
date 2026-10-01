# Heuristic: Surgical blindness escalation — surgical authorization of ONE upstream function

When a hypothesis in a BLIND shadow audit is BLOCKED by an
unauthorized upstream dependency (vendored lib, external contract whose
semantics decide the downstream verdict), do NOT accept BLOCKED as the
final state. Instead, ask the user for **surgical authorization of
ONE specific function** (not the whole contract), with a short time-box,
citing the exact dependency and the bug being discriminated.

**Family:** process / methodology (shadow audit blindness)
**Reference example:** Panoptic Hypovault, Code4rena 2025-06 (H-01)
**Detection by Slither/Aderyn:** N/A (procedure, not a code pattern)
**Solodit tags:** methodology, shadow-audit, blindness, process

---

## Anti-habit it corrects

Accepting BLOCKED on gaps that depend on unauthorized upstream behavior
(zero escalations). Result: misses that a single targeted read would have resolved.

**Why it was suboptimal:** blindness exists to avoid reading the official
findings/reports, NOT to prevent reading the CODE of a
dependency whose semantics are needed to judge the in-scope target.
Reading one specific upstream function does not contaminate the audit's
blindness; reading the C4 report does. Confusing the two leaves HIGHs on the table.

---

## Canonical procedure

1. **Isolate the exact dependency.** Identify the specific upstream
   function (not the contract) whose semantics decide the verdict. E.g.:
   "I need to know which token goes in `rightSlot` vs `leftSlot` in
   `getAccumulatedFeesAndPositionsData`".
2. **Formulate the discriminator.** Before reading, state which result
   confirms BUG and which result confirms CONVENTION. This avoids
   rabbit-holing and keeps the read focused.
3. **Ask the user for surgical authorization:** ONE function + its
   direct packing helpers if it delegates, with a time-box (30 min typical).
   Do NOT ask to "read the whole PanopticPool".
4. **Read only what was authorized.** If the function delegates, follow ONLY the
   specific packing subroutine. Don't wander off into liquidation/solvency/
   minting.
5. **Resolve with a file:line citation** and an AP-check. CONFIRMED+PoC /
   REFUTED-convention (with the justifying citation) / BLOCKED-persistent
   (if the time-box is not enough).
6. **Record the contamination:** note exactly what was read upstream,
   so the blindness log is auditable.

---

## When to apply it vs when NOT to

**Apply:** the semantics of a dependency (sign of a slot, direction
of a conversion, convention of a packed type) decide whether an anomaly
in the IN-SCOPE code is a bug or a convention.

**Do NOT apply (still forbidden under blindness):** official findings/reports,
4naly3er-report.md, discord-export, contest PRs/issues, web searches
about the target. That is NOT "an upstream dependency" — it is the answer key.

**Signal that it is NOT a convention (raises the value of escalating):** an INTERNAL
inconsistency within the same in-scope file (e.g. premium uses `short−long` for
token0 but `long−short` for token1, while exercised uses `long−short` for
both). An internal asymmetry is a stronger bug signal than an isolated
asymmetry, and justifies spending the escalation.

---

## Example (Panoptic Hypovault, Code4rena 2025-06)

- A hypothesis was BLOCKED in the PoC phase: `poolExposure1` (Accountant:134-136)
  uses `longPremium − shortPremium`, the sign inverted with respect to token0. `LeftRight.sol`
  turned out to be symmetric → it didn't resolve it. The suspicion was NOT discarded as "probably
  a convention".
- **Surgical escalation:** authorization to read ONLY
  `getAccumulatedFeesAndPositionsData` + the packing helper in `PanopticPool.sol`
  (l.365-484). Cost: <30 min.
- **Resolution:** NatSpec `:370-371` confirms an identical slot↔token mapping for short
  and long → correct equity = `short − long` for both → BUG. PoC written,
  HIGH.
- **Validation against the official report:** full match with **H-01** (same lines
  134-136, same one-line fix, found by 14 wardens). Without the
  escalation it would have been a pure HIGH MISS.

**Contrast with the precision side:** the same discipline applied to
`convert0to1/convert1to0` resolved REFUTED-convention (2×2 truth
table + NatSpec citation `PanopticMath:497`). Escalating surgically does NOT
mean fabricating bugs: it confirms OR refutes with the same citation.

---

## Cross-refs

- [[severity-heuristic-high]] — calibration of the HIGH that this escalation produced.
- `prompts/refutation-anti-patterns.md` — the AP-checks that close the verdict.
- [[audit-block-and-consumers-after-finding]] — after a finding/refutation, sub-audit the
  adjacent block, the cross-flow functions and all of the function's consumers.
