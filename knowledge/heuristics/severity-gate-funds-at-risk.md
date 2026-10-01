# Heuristic: Severity gate — funds at risk in NORMAL operation

Before labeling a drain/theft/impersonation/freeze bug HIGH or Critical, pass this MANDATORY gate:
**which user funds are actually at risk in the protocol's NORMAL operation — not in the PoC's
artificial precondition?** If the affected contract does not custody user funds in its normal flow
(it is stateless, only holds residue/dust, or the funds live in another context), the severity
ceiling is **LOW/MED**, however clean the mechanical exploit is.

**Family:** severity calibration (corrects the overselling bias)
**Detection by Slither/Aderyn:** N/A (severity heuristic)
**Solodit tags:** severity-calibration, funds-at-risk, drain, impersonation, severity-by-custody, severity-by-recoverability
**Related:** OL-7 (funds by ownership) in `prompts/operational-lessons.md`

---

## The mistake it corrects

"The exploit drains X permissionlessly and atomically → HIGH." FALSE if X is not user funds in
normal operation. The judge calibrates by **realistic economic damage**, not by the mechanical
elegance of the drain. Public examples:

- **Sequence/Trails (Code4rena 2025-11, Findings 09+10 → Low):** arbitrary-call-as-Router over a
  **stateless** ERC2470 singleton. The PoC drained the singleton's approvals/balances, but in normal
  operation the Router runs via delegatecall in the context of the *wallet*; the singleton only
  accumulates stray/dust. Realistic funds at risk = residue → **Low**.
- **Yieldoor (Sherlock 2025-02):** a configuration-dependent withdraw freeze (token1 denomination +
  a specific decimals pair) ended up **Low**: damage bounded to one class of pools.
- **Panoptic Hypovault (Code4rena 2025-06):** a brick that only the manager can trigger, with
  off-chain recovery under the program's trust model → **Low/QA**.

## The gate (hard checklist, not judgment)

Before setting HIGH/Critical for a drain/theft/freeze, answer WITH A CITATION:

1. **What does the affected contract custody in NORMAL operation?** User TVL, collateral, deposits
   → high severity possible. Stateless / dust only / funds in another context (wallet, external
   vault) → LOW/MED ceiling.
2. **Does the PoC drain funds that exist in the normal flow, or funds the PoC had to seed as a
   precondition?** If the victim only has funds at risk because the PoC's setup put them there
   (approval to the wrong contract, planted balance), check whether that state occurs without the
   attacker.
3. **Is the drainable approval/balance created on the user's normal path, or does it require the
   user to misuse an API?** (Sequence: the approval to the singleton only occurs in the direct-call
   pattern; the normal path approves the wallet.)
4. **Realistic damage magnitude** = (funds at risk in normal operation) × (frequency of the
   vulnerable state). Dust × rare = LOW even if the mechanism is perfect.

If 1-3 point to "no user funds at risk in normal operation" → **LOW/MED, not HIGH**, however clean
the PoC is.

## Interaction with the HIGH rule

The HIGH rule in `severity-heuristic-high.md` (permissionless + atomic profit + core invariant) is
NECESSARY but NOT SUFFICIENT. This gate is the additional condition: the "atomic profit" must be
over **real user funds in normal operation**. A permissionless atomic drain of a singleton's dust
meets the shape of the HIGH rule but fails the gate → LOW.

Likewise, **a violated documented invariant ≠ automatic HIGH**: in Sequence the README said
"must revert via onlyDelegatecall" and it was still capped at Low, because the violation did not
put TVL at risk.

## The gate is symmetric

The gate is a funds-at-risk **discriminator**, not a "downgrade everything". It goes up and down:

- **Custom-accounting skim in V4 hooks** (naive HIGH → LOW/MED): opt-in and bounded by the
  router's min-output on the normal path; "drains every swap" is not funds at risk.
- **JIT-donation in V4** (naive HIGH → MED, official Medium in Spearbit's core audit):
  MEV redistribution of an *external reward*; it does not touch custodied principal.
- **Hook without `onlyPoolManager` — Cork Protocol** (Critical → Critical): the hook **custodies
  the TVL** and the forged callback drains it in normal operation → the gate CONFIRMS Critical.
  Over-correcting the overselling bias produces the opposite failure: undervaluing a real Critical.

Strong adjectives ("atomic", "permissionless", "no capital", "risk-free") describe the exploit, not
the severity.

## Two axes of the discriminator

1. **CUSTODY axis — what kind of contract takes the damage** (sets the ceiling):
   - LayerZero composer without validating `_from`: **custodial** (routes funds according to the
     message) = Critical vs **stateless** (bookkeeping only) = LOW/MED. Same missing check.
   - OFT precision: **OFTAdapter** (lock/unlock of third-party TVL) = Critical drain vs **plain OFT**
     (mint/burn) = supply inflation, High class. Same over-credit bug.
2. **MAGNITUDE × RECOVERABILITY axis — how much, and whether it can be reversed** (places it under
   the ceiling):
   - Magnitude: full truncation vs dust per transaction (a real PING finding) → the same
     mechanism drops to **Medium** because of magnitude.
   - Recoverability: a "permanently bricked channel" in LayerZero ordered delivery is overselling
     bait — the channel **never** gets bricked and (privileged) recovery **exists** → recoverable
     DoS = MED; it only goes up to High if recovery is unreachable or what gets stuck is
     funds/governance.

Composite rule: **ceiling by custody, position by magnitude × recoverability.**

## Cross-refs

- [[flashloan-arbitrary-call]] — severity depends on WHAT the impersonated contract custodies
  (Truster over the pool's TVL = Critical; stateless router = LOW).
- [[severity-heuristic-high]] — HIGH rule; this gate is the funds-at-risk condition it lacks.
- `prompts/refutation-anti-patterns.md` AP-3 — the severity floor on the low side; this gate is
  the ceiling on the high side.
- [[hook-callback-missing-onlypoolmanager]] — CONFIRMS Critical (the hook custodies TVL).
- [[hook-custom-accounting-delta-skim]] — caps at LOW/MED (router-bounded + opt-in).
- [[hook-jit-donation-capture]] — caps at MED (reward redistribution, not principal).
- [[lzcompose-origin-not-validated]] — custody axis.
- [[oft-shared-decimals-precision]] — custody + magnitude axes.
- [[ordered-delivery-nonce-jam]] — recoverability axis.
- [[erc4626-totalassets-balanceof]] — donation discriminator: *is the donated token FOREIGN to or
  IDENTICAL to the asset backing the principal at risk?* Foreign → Critical; identical → the
  donation re-collateralizes the principal → Low.
