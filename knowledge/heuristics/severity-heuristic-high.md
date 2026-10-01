# Heuristic: when a bug is HIGH — permissionless + atomic profit + core invariant, with an actor-authorization branch

Rule for assigning HIGH severity, its counter-indications and a downgrade branch for bugs whose
trigger belongs to the owner/manager. Used together with [[severity-gate-funds-at-risk]]: this rule is
**necessary**; the funds-at-risk gate is the condition that makes it **sufficient**.

**Family:** severity calibration
**Detection by Slither/Aderyn:** N/A (severity heuristic, not a code pattern)
**Solodit tags:** severity-calibration, donation, permissionless, core-invariant, trust-model, actor-authorization

---

## HIGH rule

Bugs that are simultaneously (permissionless) + (demonstrable or trivially composable atomic
profit) + (affect a core invariant) are HIGH, even if they require a donation as a
precondition.

1. **Permissionless** — does not require a privileged role for the attacker. The "permissionless in
   the relevant sense" case also counts: the victim runs their normal flow and the attacker only
   preconditions external state.
2. **Atomic profit** — the path fits in one transaction or is trivially composable; cost of the
   precondition < profit.
3. **Core invariant** — peg, solvency/collateralization, fee/yield accounting, governance
   integrity, critical lifecycle.

Public example: AXION (Sherlock #552), H-1 `unfarmBuyBurn` — permissionless manipulation of
`liquidity()` in a V3 pool that skews the AMO's sizing (see
[[single-sided-lp-v3-liquidity-inflation]]).

## Counters (downgrade to Medium or Low)

Any of these breaks the rule:

- **Requires a malicious admin** → component 1 broken.
- **Donation cost > possible profit** → component 2 broken (not atomic, not composable, the attacker loses).
- **Only affects an auxiliary function** → component 3 broken (does not touch a core invariant).
- **Post-call mitigation in the same flow** (e.g. a TWAP peg check that rejects the manipulated
  path) → component 2 broken in practice.
- **Atomicity broken by an epoch boundary / commit-reveal** → component 2 broken.
- **Trigger is manager/owner-only + the README excludes manager malice + an off-chain recovery
  exists** → LOW/QA even if the damage is irreversible on-chain (see branch below).

If exactly one component is weakened but not broken (probabilistic, not deterministic):
**Medium**.

---

## Actor-authorization branch (trust-model downgrade)

Before assigning severity to a **stuck funds / irreversible degradation** bug, walk this tree. It
replaces the "MED floor for irreversibility + multi-user" reflex, which turns out to be
overconfident under a strict trust model.

```
Does the bug's trigger require an owner/manager action (not an unprivileged actor)?
├── NO (triggered by an unprivileged / permissionless actor)
│     └── severity per the HIGH rule above (no downgrade applies)
└── YES (manager/owner-only trigger)
      │
      ├── Does the README/scope explicitly exclude "issues requiring malicious intent" from the owner/manager?
      │     ├── NO  → keep MED/HIGH according to impact (the trust model does not protect the sponsor)
      │     └── YES → continue
      │
      └── Is there a documented off-chain recovery path (manage() arbitrary call, rescue, upgrade)?
            ├── YES → severity = LOW / QA
            │         (irreversible damage on-chain but recoverable by the honest manager;
            │          the judge treats it as a manager error, not an exploitable vuln)
            └── NO  → severity = MEDIUM
                      (real irreversibility with no escape + multi-user impact)
```

**Why:** the judge applies the README's scope-limiter **literally**. If the README says
"issues requiring malicious intent [from the owner/manager] are out of scope", a bug that only
triggers through a manager error (input without a lower bound, `fulfill(0)`, …) and that the manager
can undo with an existing off-chain path is not a rankable vuln.

**Public example — Panoptic Hypovault (Code4rena 2025-06):** `fulfillDeposits(0)` bricks the epoch's
`executeDeposit` via a `mulDiv(0,0,0)` revert (and its twin on the withdrawal side).
Manager-only trigger, README excludes manager malice, off-chain recovery via `manage()`
→ official **Low/QA**. By contrast, the sign error in `poolExposure1` in the same contest (official
H-01) is HIGH: it is permissionless in its effect (anyone deposits/withdraws against the wrong NAV)
and does not enter this branch.

---

## Calibration nodes

### Node A — TOTAL and PERMANENT fee loss can be HIGH (not auto-MED)

"Protocol revenue loss" is not MED by default. If the loss is **total + permanent +
deterministic** (not a drip, not conditional), it can be HIGH even if no attacker pockets it.
Example: Yieldoor (Sherlock 2025-02) — a `feeRecipient` without a setter and a decimals error in the
fee calculation were two independent HIGHs. The absence of external atomic profit lowers the
*theft* vector, not the *definite loss* vector.

### Node B — CONFIG-DEPENDENT freeze → MED by default (not HIGH)

A freeze / locked-funds bug is **MED by default** if its activation depends on a specific
configuration (decimals pair, denomination token, position state), even if the damage is permanent
for the affected positions. It goes up to HIGH only if it affects a broad class with no
configuration precondition, or if there is universal direct loss. Example: Yieldoor, "Locked funds"
(M-9) from a copy-pasted withdraw that only triggers with denomination == token1.

**Meta:** severity bias is bidirectional and can go both ways in the same audit. Before fixing the
headline, calibrate each finding against Sherlock's two rules: *definite loss → High* /
*requires specific states → Medium*.

### Node C — the HIGH rule is necessary but not sufficient

Sequence/Trails (Code4rena 2025-11): an arbitrary-call-as-Router met the shape of the rule
(permissionless + atomic + core invariant) and was still capped at **Low** (Findings 09+10), because
the impersonated contract is a **stateless** singleton that does not custody user funds in normal
operation. The "atomic profit" must be over **real user funds in normal operation**: always pass
[[severity-gate-funds-at-risk]].

---

## Cross-refs

- [[severity-gate-funds-at-risk]] — the sufficiency condition for the HIGH rule.
- [[surgical-blindness-escalation]] — related shadow audit process.
- `prompts/refutation-anti-patterns.md` AP-3 — the severity floor that the actor-authorization
  branch bounds.
