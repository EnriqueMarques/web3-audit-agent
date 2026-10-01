# Pattern: V4 JIT-donation capture (donate accrues to CURRENT in-range liquidity)

**Family:** callback ordering / JIT-MEV (concentrated liquidity, Uniswap V4)
**References:** Spearbit's audit of the Uniswap V4 core, §5.1.1 (official Medium).
**Severity when present:** **MEDIUM** — MEV value-redistribution among LPs. Diverts an *external donation/reward*, does NOT touch custodied LP principal. Not HIGH however elegant the mechanism.
**Detection by Slither/Aderyn:** NO
**Solodit tags:** uniswap-v4, donate, JIT, MEV, concentrated-liquidity, sandwich, severity-MEV

---

## Core mechanism

`Pool.donate` splits the donated amount into `feeGrowthGlobal` **per unit of the liquidity that is in-range *right now*** — it has no memory of who was there before. Verified @ pin 59d3ecf:

```
Pool.sol:466   function donate(State storage state, uint256 amount0, uint256 amount1)
Pool.sol:467-468  uint128 liquidity = state.liquidity; if (liquidity == 0) NoLiquidityToReceiveFees
Pool.sol:474   state.feeGrowthGlobal0X128 += UnsafeMath.simpleMulDiv(amount0, FixedPoint128.Q128, liquidity);
Pool.sol:477   state.feeGrowthGlobal1X128 += UnsafeMath.simpleMulDiv(amount1, FixedPoint128.Q128, liquidity);
```

So anyone who is in-range at donate time captures a pro-rata share `myLiquidity / totalInRangeLiquidity`. An attacker adds huge JIT liquidity to the active range immediately before the donation and removes it immediately after, capturing the lion's share of a reward meant for the pre-existing LPs.

## The capital-free / risk-free insight (key generalizable finding)

Done in **one `unlock`**, the attack needs **zero capital and bears zero price risk**: the JIT `modifyLiquidity(+L)` records a transient debt and `modifyLiquidity(-L)` in the same frame returns it — **the principal cancels in the transient delta accounting**, so only the captured fees net out. The attacker takes the fees without ever moving the principal. No `beforeDonate`/`afterDonate` hook is required; a plain LP on a **hookless** pool does it (verified with a Foundry PoC against the real v4-core).

PoC result: donation 1e15, JIT 99e18 vs honest 1e18 → attacker captures **989999999999998 (~99%) with capital=0**; honest LP's donation share drops from the full 1e15 to ~1e13 (conserved exactly: honest's loss == attacker's gain).

## Severity drill

| | Value | Why |
|---|---|---|
| (a) naive | HIGH/Critical | "atomic, permissionless, **capital-free, risk-free** theft of 99% of a reward" |
| (b) gate | **MEDIUM** | the attack diverts an **external donation** (a reward inflow honest LPs hadn't received yet) — it does NOT touch custodied LP principal. MEV value-redistribution among LP participants, bounded by donation size × sandwichability. |
| (c) official | **MEDIUM** | Spearbit §5.1.1. |

**Δ naive→gate ≈ 1-2 levels.** Lesson: "capital-free + risk-free + atomic + 99%" describes the *exploit's elegance*, not the *severity of funds-at-risk*. The gate asks WHAT is captured: a reward, not principal → Medium. The strongest mechanical adjectives are a known over-sell trigger.

## When it changes severity

- **Donation funded by the protocol/users as a core mechanism** (e.g. a hook that periodically donates accrued fees to LPs): the diverted value is recurring and systematic — still MEV-class, but the magnitude × frequency can push the *aggregate* loss to a firm Medium / borderline High in a contest framing. Judge by realistic recurring loss, not per-event.
- If the "donation" is actually **redeposited user principal** misrouted through `donate`, it's no longer redistribution — re-class as a delta-accounting / custody bug.

## Detection heuristic

- grep the protocol/hook for `manager.donate(` or `pool.donate(` — any flow that donates to LPs.
- Ask: can an unprivileged actor add liquidity to the active range in the same block (front-run) and remove after (back-run)? On V4, can they do it **atomically in one unlock** (then it's risk-free)?
- Is the donation triggered by a **permissionless** function (keeper/`distribute()`)? Permissionless trigger inside an attacker's unlock = guaranteed sandwich.
- Mitigation to look for: donations gated to a snapshot of *prior* liquidity, time-locked reward streaming, or `donate` to a position the attacker can't join.

## Cross-reference

- [[severity-heuristic-high]] — the *donation severity heuristic*; THIS card is the concrete V4 code mechanism (donate→current-in-range) behind it.
- [[severity-gate-funds-at-risk]] — "reward redistribution ≠ principal drain" is the gate distinction that caps it at Medium.
- [[hook-custom-accounting-delta-skim]] — sibling MEV/value-extraction class on the swap path.
- Target notes: `knowledge/target-notes/uniswap-v4-hooks.md` §1.4 (donate ordering) + §7 (#2).
