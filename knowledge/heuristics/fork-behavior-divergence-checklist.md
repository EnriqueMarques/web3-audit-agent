# Heuristic: Fork behavior divergence — signatures match, behavior diverges

Verifying the signatures (selectors, types, returns) of a fork vs the canonical
protocol is NOT enough. Forks also diverge in BEHAVIOR — fee accounting,
reward distribution, governance flow, hook ordering — while keeping
compatible selectors. The compiler does not detect this divergence.

**Family:** cross-protocol composability / fork integration
**Reference example:** AXION, Sherlock contest #552 (official H-3 — LP fees stuck in V3AMO because SolidlyV3 moved fees to a RewardsDistributor). Other candidates: address-based governance in Ramses V3, epoch divergence in Aerodrome.
**Severity when present:** HIGH when the divergent path touches asset
flow or lifecycle; MEDIUM when it only touches metrics
**Detection by Slither/Aderyn:** NOT flagged (requires reading the fork's docs /
diff, not a code pattern)
**Solodit tags:** fork-integration, composability, signature-vs-behavior

---

## Core mechanism

A fork preserves the canonical API to keep upstream integrations
working, but alters the implementation. Examples of silent
divergence:

- Same signature, different return value semantics (returns 0 where
  canonical returned the accumulated amount).
- Same signature, side effects moved to another contract (fees in the pool ->
  fees in an external RewardsDistributor).
- Same signature, different parameter semantics (tokenId vs address).

Protocols that integrate the fork without re-reading its current docs assume
canonical behavior. The bug only shows up at runtime, post-deploy.

---

## AXION H-3 mechanics

`V3AMO` calls `pool.burnAndCollect(...)` expecting it to return LP fees
(UniV3 / Solidly V2 model). SolidlyV3 moved fees to an external
`RewardsDistributor` with a merkle claim:

- `burnAndCollect` exists with the same signature.
- `burnAndCollect` NO LONGER returns accumulated fees — it only returns the
  removed principal.
- To claim fees, the caller must interact with the `RewardsDistributor`
  with a merkle proof.

Result: the AMO's LP fees stay stuck in the distributor forever
(the AMO is not whitelisted as a claimer and does not build merkle proofs).
Severity HIGH due to silent loss of core yield for the protocol.

---

## Checklist per fork target declared in the README

For each integrated fork, run:

### 1. Fee accounting

- Do fees accumulate in-pool or in an external RewardsDistributor?
- Who claims? Permissioned or permissionless?
- Is the AMO/strategy whitelisted in the claimer?
- Does the interface the protocol uses return fees or only principal?

### 2. Reward distribution

- Do bribes and emissions follow the canonical path (`getReward(tokenId)`) or
  is there middleware?
- Is there a merkle distributor for closed epochs?
- Are claim windows and epoch boundaries the same?
- On which chain are the rewards (the same fork may move rewards to an L2
  via a bridge)?

### 3. Governance

- Is `vote()` tokenId-based or address-based? (Ramses V3 changed to
  address-based, which breaks the canonical tokenId assumption.)
- `poke()` parameter semantics?
- Is voting power reset per epoch or does it accumulate?

### 4. Hook ordering

- Are pre/post swap hooks in the same order as canonical?
- Are there new hooks (e.g., dynamic fees) that canonical does not execute?
- Does the reentrancy guard cover the same scope?

### 5. Initialization sequence

- Which params are mandatory? Setters that canonical does not have?
- Divergent order of steps in `initialize()`?
- Is there a `setOperator` / `setRewardsDistributor` that must be executed
  post-init?

---

## Application heuristic

For each fork target, read:

1. The fork's official docs (especially "what's new vs canonical").
2. 1 recent PR/commit that touches the integrated subsystem.
3. The diff of the fork contract vs canonical in the integrated subsystem.

Time: 1-2h per fork. Apply in Phase 2 (Static sweep) and before
Phase 3 (Hypothesis). If there is no fork repo, see OL-11 (diff against the ancestor).

---

## Anti-pattern

A compatibility check on signatures (selector + types) that confirms "fork
compatible" without reviewing behavior. False negative: the signatures match, but
the fees get stuck. In AXION, reading only `IPool.sol` and not the SolidlyV3
docs lets H-3 slip through.

---

## Cross-refs

- [[erc2771-multicall-sender-confusion]] — cross-protocol integration
  family.
- [[single-sided-lp-v3-liquidity-inflation]] — another V3-specific vector
  where behavior diverges from V2.
- [[severity-heuristic-high]] — severity heuristic if
  the divergent path touches a core invariant.
