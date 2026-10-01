# Pattern: V4 hook permission / address-bits mismatch (silent mis-wiring)

**Family:** permission / configuration (Uniswap V4 hooks)
**References:** structural — derived from the validation asymmetry in V4's own core (read line by line); no known public incident. Detection-oriented.
**Severity when present:** **config-dependent / by-custody** — a mismatch is silent mis-wiring; severity = whatever the missing/forged callback would have governed. Often LOW (mis-config) but Critical if a missing flag means a security callback is never invoked, or an extra flag lets an unimplemented callback be assumed safe.
**Detection by Slither/Aderyn:** NO
**Solodit tags:** uniswap-v4, hooks, permissions, create2, hook-miner, address-bits, misconfiguration

---

## Core mechanism

A V4 hook's permissions are encoded in the **low 14 bits of its deployed address** — immutable, no storage, no setter. They're mined via CREATE2 (`HookMiner`). Verified @ pin 59d3ecf:

```
Hooks.sol:27       ALL_HOOK_MASK = (1 << 14) - 1
Hooks.sol:29-47    14 flags: BEFORE_INITIALIZE(1<<13) ... AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA(1<<0)
Hooks.sol:337      hasPermission(self, flag) = uint160(addr) & flag != 0
```

There are **two** validators, and they are NOT equally strict:

- `validateHookPermissions` (`Hooks.sol:83-101`, reverts `HookAddressNotValid`): asserts **every one of the 14** declared `Permissions` booleans equals the matching address bit. This is the STRONG check — but it's a *self-check the hook opts into*, used by `BaseHook` constructor (`BaseHook.sol:31-33`).
- `isValidHookAddress` (`Hooks.sol:109-126`): the only check the **PoolManager itself enforces** at `initialize`. It only verifies (a) each `*_RETURNS_DELTA` flag has its base action flag (`:111-120`), and (b) `uint160(addr) & ALL_HOOK_MASK > 0 || fee.isDynamicFee()` (`:126`). It does **NOT** check that the bits match what the hook actually implements.

**The gap:** the manager will happily run a pool whose hook address bits don't match its implementation. A hand-rolled hook (not extending `BaseHook`, or overriding `validateHookAddress`) can be deployed at a flag-mismatched address and the manager never complains.

## Two failure directions (severity by what's mis-wired)

| Mismatch | Effect | Severity driver |
|---|---|---|
| **Address has a flag bit set, but the hook doesn't implement (or empties) that callback** | the manager calls a reverting/empty function → swaps/liq ops may revert (DoS), or a "fee/guard" the protocol believed active silently does nothing | DoS → MED; *missing security guard* → up to High/Critical |
| **Hook implements a callback but the address bit is NOT set** | the manager **never calls** that callback → a hook the integration relied on for a check/fee/limit is dead code | **Critical if the un-called callback was the security control** (e.g. a `beforeSwap` risk check that never runs) |

The severity is never "the mismatch itself" — it's **what the mis-wired callback was supposed to enforce, and what funds depend on it** ([[severity-gate-funds-at-risk]]).

## Where it bites in practice (forks/integrations)

- A fork copies a hook but changes which callbacks it implements **without re-mining the salt** → address bits stale.
- Test scaffolding uses `vm.etch` onto a flag-correct address (legit for tests) but the production deploy mis-mines.
- A hook overrides `validateHookAddress` to a no-op "for testing" and ships it (the comment at `BaseHook.sol:28-30` explicitly enables this override) → loses the only strong self-check.
- Dynamic-fee pools: a hook with **zero** flag bits is valid *only* if `fee.isDynamicFee()` (`:126`) — a fee-manager-only hook; if someone clears the dynamic-fee flag, the hook becomes an invalid address for that pool.

## Detection heuristic

For each hook in scope, reconstruct three sets and diff them:
1. **Address bits:** `uint160(hookAddress) & 0x3FFF` → which of the 14 flags are on.
2. **Declared:** the `getHookPermissions()` struct (if it extends `BaseHook`).
3. **Implemented:** which callbacks actually have non-reverting bodies.

Any disagreement among {1,2,3} is a finding. Specifically:
- bit ON but callback reverts/empty → DoS or silent no-op guard.
- callback implemented but bit OFF → dead callback (the dangerous one — a guard that never runs).
- Hook does **not** call `Hooks.validateHookPermissions` anywhere → it relies solely on the weaker `isValidHookAddress`; flag it.

grep: `getHookPermissions`, `validateHookAddress`, `HookMiner.find`, `ALL_HOOK_MASK`, the flag constants.

## Cross-reference

- [[hook-callback-missing-onlypoolmanager]] — the *other* hook access-control failure (caller identity); this one is callback *wiring*.
- [[hook-custom-accounting-delta-skim]] — depends on the returns-delta bits being set; a mis-set bit there changes whether the skim is even reachable.
- [[fork-behavior-divergence-checklist]] — forks that copy a hook but change callbacks without re-mining are this pattern's main breeding ground.
- [[severity-gate-funds-at-risk]] — severity = what the mis-wired callback governed × funds at risk.
- Target notes: `knowledge/target-notes/uniswap-v4-hooks.md` §3 (bitmap + the isValidHookAddress vs validateHookPermissions gap).
