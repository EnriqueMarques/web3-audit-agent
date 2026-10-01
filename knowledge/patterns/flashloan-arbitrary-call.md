# Pattern: Arbitrary Call as the Protocol (Flashloan/Callback)

**Family:** Arbitrary external call with caller-controlled target+data
**Reference example:** Damn Vulnerable DeFi v4 — Truster (Critical); Sequence/Trails, Code4rena 2025-11 (official Low)
**Severity when present:** **DEPENDS ON CUSTODY** (see "Severity by custody" below) — it is NOT automatically Critical.
**Detection by Slither/Aderyn:** NO
**Solodit tags:** flashloan, arbitrary-call, callback, approval, severity-by-custody

---

## Core mechanism

Any contract that executes `target.call(data)` — or any wrapper like
`Address.functionCall(target, data)` — where both `target` and `data`
are controlled by the caller, effectively grants the caller the ability
to impersonate the contract in any on-chain interaction.

The contract becomes an unwitting proxy: the call executes with
`msg.sender = vulnerable contract`, not with `msg.sender = caller`.

The root cause is not the approval. The root cause is the unrestricted
external call. The approval is the cheapest exploitation path.

## Minimal vulnerable pattern

```solidity
function flashLoan(uint256 amount, address borrower, address target, bytes calldata data)
    external
    nonReentrant  // nonReentrant is irrelevant here — it blocks reentrancy,
                  // not arbitrary-call abuse
{
    uint256 balanceBefore = token.balanceOf(address(this));
    token.transfer(borrower, amount);
    target.functionCall(data);         // ← arbitrary call as this contract
    require(token.balanceOf(address(this)) >= balanceBefore);
}
```

The repayment check guards against direct token theft during the callback.
It does NOT prevent state changes with deferred economic consequences
(approvals, votes, role grants, LP operations).

## Canonical exploitation: approval hijack + drain

The cleanest exploit path because `amount = 0` trivializes the balance check,
so there is no repayment constraint:

```
Step 1 — attacker calls:
  flashLoan(amount=0, borrower=self, target=token,
            data=abi.encodeCall(token.approve, (self, pool_balance)))
  → pool executes token.approve(attacker, pool_balance) [msg.sender=pool]
  → balance check: pool_balance >= pool_balance ✅ (nothing moved)

Step 2 — attacker calls:
  token.transferFrom(pool, attacker, pool_balance)
  → drain complete
```

Single-transaction variant: wrap both steps in a constructor,
deployed by the attacker (1 CREATE = nonce +1, satisfies any "single tx" constraint).

## Other exploitation variants

The approval is one path. Any privileged on-chain position the contract holds
can be exercised. Examples:

- **Governance hijack:** `target = governance`, `data = castVote(proposal, FOR)`
  → contract votes on behalf of the protocol
- **LP drain:** `target = AMM`, `data = removeLiquidity(contract_LP_balance, ...)`
  → protocol's LP position drained
- **Role escalation:** `target = access_control`, `data = grantRole(ADMIN, attacker)`
  → attacker becomes admin if the contract holds an admin role
- **Cross-protocol drain:** `target = other_vault`, `data = withdraw(contract_shares, ...)`
  → any yield position the contract holds

The attack surface is proportional to the on-chain footprint of the vulnerable
contract: the more it owns or controls, the more the attacker can extract.

## Severity by custody

The mechanism (impersonation) may ALWAYS be present, but severity is gated by
**what the impersonated contract custodies in NORMAL operation**:

| Case | What the contract custodies | Severity |
|---|---|---|
| DVD Truster | the lending pool IS the TVL (the protocol's tokens) | **Critical** |
| Sequence/Trails, Code4rena 2025-11 (Findings 09+10) | **Stateless** singleton router; only stray/dust (in normal operation the funds live in the wallet via delegatecall) | **LOW** |

Rule: `drainable impersonation` + `the contract custodies TVL/collateral/user deposits in the normal flow` → HIGH/Critical. If the contract is stateless / only retains residue / the funds live in another context → **ceiling of LOW/MED**, however clean the PoC is. Pass the [[severity-gate-funds-at-risk]] gate BEFORE labeling anything HIGH/Critical. Apply it as a checklist, not as a judgment call: it is easy to oversell a clean PoC against a contract that custodies nothing.

## Required conditions

1. Contract executes `target.call(data)` (or equivalent) during a user-initiated flow
2. Both `target` and `data` are fully controlled by the caller (no restriction)
3. Contract holds at least one privileged on-chain position (tokens, approvals,
   roles, LP shares, governance weight, ...)

## Mitigations — what to look for (absence = vulnerability)

| Mitigation | Pattern |
|------------|---------|
| Target whitelist | `require(approvedTargets[target])` |
| Sensitive address blacklist | `require(target != address(token))` |
| Selector allowlist | `require(allowedSelectors[bytes4(data)])` |
| Caller-bound target | `require(target == borrower)` |
| Stateless callback design | callback cannot persist state changes |

**Warning about selector blacklists:** denying one specific selector
(e.g. `!= approve.selector`) is insufficient — bypassable via `transferFrom`,
`permit`, `increaseAllowance`, or simply by changing `target`. Only a
selector allowlist or a restriction on `target` is robust.

## Detection heuristic

Grep in flashloan/lending/callback functions:
```
\.call\(
functionCall\(
functionCallWithValue\(
```
If the function takes `address target` AND `bytes calldata data` from the caller
and both are unrestricted → immediate Critical candidate.

Verify: does the contract hold tokens, approvals, roles, or LP **in NORMAL operation** (not only in the PoC's precondition)?
- If it custodies TVL/collateral/user deposits → Critical/HIGH.
- If it is stateless / only dust / the funds live in another context → **LOW/MED** (see "Severity by custody" + [[severity-gate-funds-at-risk]]). Do NOT assume an automatic Critical.

## Cross-reference

- **Truster (Damn Vulnerable DeFi v4):** the canonical training example.
- **Historical Solodit tags:** search `"arbitrary call"` + `"flashloan callback"`
