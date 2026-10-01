# Heuristic: After a finding or refutation in a region, audit the entire BLOCK AND all the function's CONSUMERS

A finding (or a refutation) in a function/region does NOT close that region.
It signals the opposite: the region has structural defects and/or has not
been looked at completely. Before closing, do an explicit sub-pass over
(a) the adjacent lines of the same block, and (b) all consumers of the
function touched.

**Family:** process / methodology (coverage)
**Reference examples:** Panoptic Hypovault H-02 (Code4rena 2025-06); Yieldoor H-5 and #635
(Sherlock 2025-02). Three different variants of the same coverage failure.
**Detection by Slither/Aderyn:** N/A (procedure, not a code pattern)
**Solodit tags:** methodology, coverage, audit-process

---

## Anti-habit it corrects

"I found/refuted a bug in function F → F's region is covered →
I move elsewhere." In all three examples, an official H/M lived exactly in the
region already touched and considered closed.

---

## The 3 variants (each one a real miss)

### Flavor 1 — Adjacent block (Panoptic H-02)

A finding in the clamp at `Accountant:250`. The official H-02 was in the
SAME cluster (`:197-202 + :250 + :254-258`) — the asymmetry of the underlying
balance before/after the clamp. The adjacent region was marked "low risk" without
a sub-pass. **Miss.**
→ Sub-pass: the ~50 lines adjacent to a finding, with dedicated AP-checks.

### Flavor 2 — Cross-function invariant in the same flow (Yieldoor H-5)

A hypothesis was refuted by validating the unit consistency of `Leverager:464`
(leverage cap on open) **in isolation**. The official H-5 is a
CONTRADICTION between `:464` (opening allows up to `maxTimesLeverage`) and
`:411` (the liquidation check only tolerates ~2x → positions >2x become
un-liquidatable). The bug was not about units; it was about **two invariants of the
same flow that were never crossed**. **A false refutation = the most expensive miss.**
→ Sub-pass: when you refute a check/invariant, cross that function against
the OTHER functions that touch the same state (open vs liquidate vs
withdraw of the same object).

### Flavor 3 — The function's consumers (Yieldoor #635)

`Strategy.price()`/`twapPrice()` was verified by looking at ONE consumer
(`_calculateTokenValues` single-feed, which was fine — the decimals cancel out
because `price` is a raw ratio) and the FUNCTION was declared clean. #635 (MED) is a
bug in that same formula for its OTHER consumer
(`_setSecondaryPositionsTicks`, which needs a decimal-adjusted price).
**A function verified through only one of its consumers. Miss.**
→ Sub-pass: `grep` all call sites of the verified function; each
consumer may need different semantics for the value it produces.

---

## Canonical procedure (when closing a finding/refutation)

1. **Adjacent block:** Read ~50 lines around the line touched;
   AP-check every statement with an effect on the same state.
2. **Cross-function within the flow:** list the functions that mutate/read the
   SAME state object (position, epoch, index). Cross the refuted invariant
   against each of them (typical: open ↔ liquidate ↔ withdraw must be
   consistent in their thresholds).
3. **The function's consumers:** `grep` all call sites of the function
   you verified. For each consumer, ask whether it needs the SAME
   semantics for the value (scale, decimals, direction) as the consumer you
   looked at. "Correct for consumer A" ≠ "correct".
4. Only after 1-3, mark the region as covered.

---

## Empirical cost of NOT applying it

- Panoptic: near-miss on H-02 (recovered by applying the sub-pass).
- Yieldoor: H-5 HIGH (miss), #635 MED (miss) — both in territory that was touched
  and closed.

The presence of ONE bug/refutation in a region is the STRONGEST signal
that the region deserves MORE attention, not less.

---

## Cross-refs

- [[severity-heuristic-high]] — severity calibration for the findings this uncovers.
- [[surgical-blindness-escalation]] — surgical escalation when verification needs an upstream dependency.
- `prompts/operational-lessons.md` OL-12 (siblings of a fix) and OL-15 (permissioned trigger ≠ skip the math).
