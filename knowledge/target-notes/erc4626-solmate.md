# ERC4626 Implementations -- Solmate

## Quirks observed

- **mulDivDown:** division truncating downwards. Favors the protocol
  in deposit/redeem at a 1:1 ratio -- produces 0 dust (verified in DVD Unstoppable
  Test D: 1000 iterations, NET CHANGE = 0).
- **totalSupply() and totalAssets() are independent reads** -- they can
  diverge if the child contract does not implement internal accounting.
- **Solmate ERC20 includes INITIAL_CHAIN_ID** in the domain separator (native
  cross-chain replay protection, verified when DVD Unstoppable H11 was refuted).
- **nonReentrant in Solady** (if the vault uses Solady instead of Solmate) uses
  transient storage (TLOAD/TSTORE). It only blocks functions that take the same
  lock. A `flashLoan()` without its own `nonReentrant` does NOT set the lock, so
  a `deposit()` inside the callback passes the lock without trouble.

## Common implementation pitfalls

- **A totalAssets() override returning balanceOf(this) with no internal
  accounting** -- vulnerable to donation, flashloan callback, token injection.
  See `knowledge/patterns/erc4626-totalassets-balanceof.md`.
- **flashLoan() without nonReentrant** -- allows deposit/withdraw during the
  callback while the vault balance is depleted, creating share inflation.
- **Missing _decimalsOffset() override** -- inflation attack on the first
  depositor (not applicable to Unstoppable: the vault was not empty and the deployer
  made a seed deposit).
- **setFeeRecipient without an address(this) check** -- if the feeRecipient can be
  set to the vault itself, fees would accumulate in totalAssets without touching
  totalSupply. Solmate's UnstoppableVault mitigates this explicitly (verified).

## Detection commands

```bash
# Detect vaults using Solmate ERC4626
grep -rn "is ERC4626" src/

# Detect totalAssets with a direct balanceOf
grep -rn "function totalAssets" src/
grep -rn "balanceOf(address(this))" src/ | grep -i "asset\|token"

# Detect flashLoan without nonReentrant
grep -rn "function flashLoan" src/
# Check manually whether it has the nonReentrant modifier

# Detect setFeeRecipient without a check
grep -rn "setFeeRecipient\|feeRecipient" src/
```

## Security properties verified

| Property | Status | Evidence |
|----------|--------|---------|
| mulDivDown neutral at 1:1 ratio | VERIFIED SAFE | Test D: 1000 iters, NET=0 |
| INITIAL_CHAIN_ID in domain separator | VERIFIED SAFE | H11 refuted |
| feeRecipient != address(this) check | VERIFIED SAFE | L117 explicit check |
| flashLoan nonReentrant | VULNERABLE | H4 confirmed -- missing nonReentrant |
| totalAssets via balanceOf | VULNERABLE | H1+H4 confirmed |

## Targets audited using Solmate ERC4626

| Date | Target | Findings |
|------|--------|---------|
| 2026-05 | DVD Unstoppable (training) | H1 (Critical), H4 (Critical) -- same root cause |
