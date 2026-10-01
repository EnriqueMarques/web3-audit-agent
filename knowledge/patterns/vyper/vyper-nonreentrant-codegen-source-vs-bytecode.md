# Pattern: Source-level correctness ≠ bytecode-level correctness — the compiler is in the TCB (Vyper `@nonreentrant`, Curve 2023)

**Family:** compiler / toolchain trust (codegen correctness) — language-specific reentrancy guard
**References:** the Curve incident (July 2023, ~$70M, several pools); Vyper advisory GHSA-5824-cm3x-3c38. The lesson generalizes to any compiler in the TCB.
**Severity when present:** = severity of the now-unguarded reentrancy = **BY CUSTODY of the reentered contract** (Curve pools custodied TVL ⇒ Critical/drain). The codegen bug is severity-neutral in itself; it INHERITS the severity of whatever the broken guard was protecting. Run [[severity-gate-funds-at-risk]].
**Detection by Slither/Aderyn:** NO — and structurally so: the SOURCE is correct. Source/AST-level analyzers see a valid `@nonreentrant` guard and clean ordering; the defect exists only in the emitted bytecode. The ultimate detector blind spot — the bug is *not in the code*.
**Solodit tags:** vyper, reentrancy, compiler-bug, codegen, toolchain, nonreentrant, curve, source-vs-bytecode

---

## Core mechanism

In EVM languages that are NOT Solidity (Vyper, Fe, Huff, …) a protection that
reads correct at SOURCE level can be silently broken by the COMPILER. The guard
you audit is not necessarily the guard that ships — the compiler sits between
them and is part of the trusted computing base (TCB).

Curve July-2023 is the canonical instance. Vyper's `@nonreentrant("<key>")`
decorator is meant to allocate ONE shared storage-slot mutex per key, so every
function tagged with that key mutually excludes. In **0.2.15 / 0.2.16 / 0.3.0**
the codegen was wrong (GHSA-5824-cm3x-3c38):

> "named re-entrancy locks are allocated incorrectly. Each function using a
>  named re-entrancy lock gets a unique lock regardless of the key."

Two functions sharing key `"lock"` got SEPARATE slots → no mutual exclusion → an
attacker re-enters a sibling function during an external-call window (e.g.
`remove_liquidity` sending ETH to the receiver) and manipulates pool balances /
virtual price. The `@nonreentrant` annotation was present, correct, and reviewed
— and did nothing. **~$70M** drained across CRV/ETH, alETH/ETH, msETH/ETH,
pETH/ETH. **Fixed in 0.3.1.**

## Replicated PoC (the root cause, not the anecdote)

Reproduction (not included in this repo): ONE source
`NonReentrantDemo.vy` (no version pragma) compiled UNCHANGED with 0.3.0 and
0.3.1; the init bytecode of each is deployed in a Foundry test (no
forge-std/cheatcodes). Three independent angles, all on disk:

- **Behavioral (2 tests PASS):** 0.3.0 → cross-function reentry SUCCEEDS,
  `counter == 1`; 0.3.1 → reentry REVERTS (shared lock), `counter == 0`.
- **Static (the embedded init bytecode):** 0.3.0 `entrant()` guards storage
  **slot 0** (`600054…6001600055`), `reenter_target()` guards **slot 1**
  (`600154…6001600155`) — two locks; 0.3.1 both guard **slot 0** — one lock.
- **Layout (`vyper -f layout`):** 0.3.0 puts `counter` at **slot 2** (two lock
  slots burned: 0 and 1); 0.3.1 puts it at **slot 1** (one). Same source,
  divergent storage layout.

The artifact IS the proof: the security delta comes ONLY from the compiler
version. (Honest scope: this is a minimal repro of the *root cause*, not a
mainnet fork of the Curve pools — no archive RPC was available; the compile-diff
is strictly stronger for *this* lesson, since a fork treats the compiler bug as
a black box.)

## Minimal vulnerable pattern (source)

```vyper
counter: public(uint256)

@external
@nonreentrant("lock")              # same key as reenter_target()
def entrant():
    raw_call(msg.sender, b"")       # external-call window (cf. remove_liquidity's ETH send)

@external
@nonreentrant("lock")              # MUST be mutually exclusive with entrant() ...
def reenter_target():
    self.counter += 1               # ... but on 0.3.0 it isn't — different lock slot
```
Source is correct under check-effects-interaction *intent*; the guard is the
whole defense, and the buggy compiler does not emit it as a shared mutex.

## The transferable lesson (the headline, not Vyper trivia)

**Auditing a non-Solidity EVM contract is incomplete without pinning and vetting
the compiler version.** A source-level guard is a *claim*; the bytecode is the
*fact*. A compiler can: mis-emit a reentrancy/lock guard (this case); lay out
storage unexpectedly (slot collisions / packing); optimize away or reorder a
check; mishandle `raw_call` / `create` / `default_return_value` / array bounds.
Generalizes past Vyper — solc has shipped its own codegen CVEs (ABIEncoderV2
storage-array bugs, optimizer constant bugs, memory/`keccak` bugs). "Reviewed
source is correct" NEVER implies "deployed bytecode is correct."

## Required conditions

1. Contract in a language whose compiler version has a known codegen defect on a
   security primitive (reentrancy guard, storage layout, bounds, return value).
2. The deployed bytecode was produced by a vulnerable version (recover it from
   the `# @version` pragma / verified-source metadata / bytecode fingerprint).
3. A reachable path the *source-level* guard claims to protect but the *emitted*
   guard does not.

## Detection heuristic

- **Pin the compiler version FIRST.** Read `# @version`; for deployed code
  recover it from verified-source metadata / Sourcify / bytecode fingerprint.
  Cross-reference the language's advisories (Vyper GHSA list — the
  0.2.15/0.2.16/0.3.0 `nonreentrant` bug; later `default_return_value`,
  `raw_call`, `nonpayable` default, sqrt/array bugs).
- **Treat the toolchain as TCB.** Add "compiler version vetted vs known codegen
  issues?" to the checklist for ANY Vyper/Fe/Huff target. A clean source review
  does not discharge it.
- **Don't trust a source-level guard you cannot see in the bytecode.** For a
  security-critical primitive (reentrancy lock, access check), confirm it at the
  bytecode / storage-layout level (`vyper -f layout` / `-f asm`, or deploy and
  test) instead of assuming the annotation took effect.
- Static analyzers (Slither/Aderyn) will NOT help — they read source/AST. The
  only effective detectors are version↔advisory cross-referencing and
  bytecode/behavioral verification.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the codegen bug inherits the reentered
  function's severity BY CUSTODY (Curve pools custodied TVL ⇒ Critical; a guard
  over a stateless function ⇒ capped). The bug is the *enabler*, not the grade.
- [[fork-behavior-divergence-checklist]] — sibling "what you read ≠ what runs":
  there a fork's behavior diverges from canonical source; here the compiler's
  bytecode diverges from the source you audited. Same auditor failure mode.
- [[hook-callback-missing-onlypoolmanager]] — same END STATE (unguarded
  reentrancy into a custodial pool) via a different root cause: guard absent in
  source vs. guard present-but-miscompiled.
- Advisory **GHSA-5824-cm3x-3c38** (affected 0.2.15/0.2.16/0.3.0, fixed 0.3.1).
  Locus of mechanism: the `@nonreentrant("lock")`
  lock-slot allocation — 0.3.0 emits one slot per function (slots 0 & 1), 0.3.1
  one shared slot (0).
