# Post-mortem: <project> (<platform>)

<!--
Written when each hunt closes, with or without a finding, at <hunt-root>/post-mortem.md.
A hunt without a finding is not a failure: it is calibration. Whatever is not captured in the
first 48 h is lost.
-->

- **Close date:** YYYY-MM-DD
- **Platform:** Immunefi / Sherlock / Cantina / Code4rena / shadow audit
- **Audited commit:** <hash>
- **Time invested:** X h
- **Outcome:** finding submitted / no finding / by-design / duplicate / aborted

## Summary

2-3 sentences: what was audited, what was being looked for and what came out (or why nothing did).

## Hypotheses explored

| ID | Hypothesis | Result | Reason (include the AP-check if refuted) |
|----|------------|--------|------------------------------------------|
| H1 | ... | PoC / REFUTED / open | ... |

## Coverage map

What was reviewed and, explicitly, what was **not** reviewed (OL-4).

## What worked

- ...

## What didn't work

- ...

## Signals that could have been read earlier

What, in hindsight, should have triggered an earlier abort or a re-prioritization. This is the most
valuable part.

## Proposals for the knowledge base

Patterns, heuristics or protocol notes worth distilling. They are only written to `knowledge/`
with explicit user approval (see `prompts/orchestrator.md`).

- `knowledge/patterns/<name>.md`: ...
- `knowledge/target-notes/<family>.md`: ...
