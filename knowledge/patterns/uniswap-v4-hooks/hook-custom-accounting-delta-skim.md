# Pattern: V4 custom-accounting delta skim (severity is ROUTER-bounded)

**Family:** custom-accounting delta / hook fee (Uniswap V4 hooks)
**References:** official Uniswap documentation (`Known_Effects_of_Hook_Permissions.pdf`). The *router-bounded severity* is an example of [[severity-gate-funds-at-risk]].
**Severity when present:** **CONTEXT-DEPENDENT / router-bounded.** The PoolManager does NOT cap the skim; the swapper's loss is bounded only by the router's min-output/max-input check. Realistic funds-at-risk in normal op = the swapper's slippage tolerance, NOT an unconditional drain. Typically LOW/MED; HIGH only if the integration's router has no slippage guard AND users are routed through it.
**Detection by Slither/Aderyn:** NO
**Solodit tags:** uniswap-v4, hooks, custom-accounting, beforeSwap-delta, slippage, severity-by-router

---

## Core mechanism

A hook with the returns-delta flags can return a `BeforeSwapDelta`/`afterSwap` int128 that the PoolManager **subtracts from the swapper's delta and credits to the hook**. The hook realizes it with a physical `take`, nets itself to zero, and the swapper bears the cost. Verified loci @ pin 59d3ecf:

```
Hooks.sol:275   amountToSwap += hookDeltaSpecified           // beforeSwap eats part/all of the specified amount
Hooks.sol:307   hookDelta = (params.amountSpecified < 0 == params.zeroForOne) ? ... : ...   // specified/unspecified -> currency0/1
Hooks.sol:312   swapDelta = swapDelta - hookDelta             // swapper pays the hook's delta
PoolManager.sol:224  _accountPoolBalanceDelta(key, hookDelta, address(key.hooks))  // credited to the hook
PoolManager.sol:226  _accountPoolBalanceDelta(key, swapDelta, msg.sender)          // swapper settles the remainder
```

The official doc enumerates exactly this: a hook "can take all specified token without crediting the user" / "can take full unspecified amount" — each annotated **"should be checked in a router."** That annotation is the whole severity story.

## What the PoC proved

A Foundry PoC against the real v4-core (`DeltaReturningHook`) showed:
- **Naive router** (`PoolSwapTest`, no slippage guard): exact-input swap, hook skims 30% off the output (`baseline 999899994019494 → swapper 699929995813646 + hook 299969998205848`, conserved exactly). Also: hook eats 40% of the *input* via the specified delta. The PoolManager happily settles it.
- **Checking router** (a 20-line `CheckingRouter` enforcing `out >= minOut`): the **identical skim REVERTS**. → the bound is the router, not the core. Every production V4 router (`V4SwapRouter` / `PositionManager`) has this guard.

## Severity drill (the calibration centerpiece)

| | Value | Why |
|---|---|---|
| (a) naive | HIGH/Critical | "permissionless hook skims every swap, nets to zero → drain" |
| (b) gate | **LOW/MED** | (1) the hook is **opt-in** — chosen per-pool; against an honest hook funds-at-risk = 0. (2) the loss is **bounded by the router min-output** in the normal path (PoC: CheckingRouter reverts). Funds-at-risk = slippage tolerance, not a drain. |
| (c) official | context-dependent | `Known_Effects` doc: "should be checked in a router". |

**Δ naive→gate ≈ 3 levels.** Lesson: a mechanically perfect permissionless atomic skim is *not* HIGH when (i) the victim opts into the surface and (ii) a check in the normal path (router min-output) bounds the loss. "Drains every swap" ≠ funds-at-risk when the PoC dropped the router guard that exists in production.

## When it DOES escalate

The router-bound is the protection. It fails when:
- the integration ships its **own router with no/loose slippage check** (then funds-at-risk = full skim → HIGH), or
- the hook **blindly credits without checking pool liquidity** on a low-liquidity pool (Known_Effects p.2 example: user takes the full creditable amount paying ~nothing) — there the *hook itself* is drained, flip to [[hook-callback-missing-onlypoolmanager]]'s custody analysis on the hook's reserves.

## Detection heuristic

1. Does the hook address carry `BEFORE_SWAP_RETURNS_DELTA` (1<<3) or `AFTER_SWAP_RETURNS_DELTA` (1<<2)? (see [[hook-permission-address-bits-mismatch]])
2. Does a callback return a **positive** specified/unspecified delta the swapper must cover? grep `toBeforeSwapDelta`, `BeforeSwapDelta`, `return (.*selector, .*, )`.
3. **Then ask the router question** (do NOT call HIGH before this): does the user's actual swap path enforce `amountOutMinimum` / `amountInMaximum`? If yes → LOW/MED (slippage-bounded). If the integration's router doesn't → HIGH.

## Cross-reference

- [[severity-gate-funds-at-risk]] — this is the canonical worked example: "bounded by an external check in the normal path" + "opt-in surface".
- [[hook-permission-address-bits-mismatch]] — the returns-delta flag must be set for any of this to be reachable.
- [[hook-callback-missing-onlypoolmanager]] — sibling hook bug class; the low-liquidity blind-credit variant flips to draining the hook's own reserves.
- Target notes: `knowledge/target-notes/uniswap-v4-hooks.md` §4 (beforeSwap/afterSwap delta mechanics) + §7 (#6).
