# Pattern: ERC4626 totalAssets() = balanceOf is fragile

**Family:** Vault / ERC4626
**Reference example:** Damn Vulnerable DeFi v4 — Unstoppable
**Severity when present:** DEPENDS on the custody discriminator (see "Severity discriminator" below) — NOT always Critical. Donated token unrelated to the backing = Critical; donated token = backing collateral = Low.
**Detection by Slither/Aderyn:** NO
**Solodit tags:** vault, erc4626, donation, balance-based-validation

---

## Trigger condition

ERC4626 vault implementation where:

```solidity
function totalAssets() public view returns (uint256) {
    return asset.balanceOf(address(this));
}
```

(Sometimes wrapped in `nonReadReentrant` modifier -- that doesn't help
against the attacks below.)

## Why it's fragile

The ERC20 standard guarantees that anyone can transfer tokens to any
address. The vault's invariant assumes only its own functions modify
its balance. This assumption is invalid.

## Attack vectors

### Vector A: Direct donation
Attacker calls `asset.transfer(address(vault), 1)`. Now
`totalAssets > convertToShares(totalSupply)`. Any function that strictly
checks `S == A` reverts permanently.

### Vector B: Flashloan callback deposit
If `flashLoan()` is missing `nonReentrant`, the callback can call
`deposit()` while the vault's balance is temporarily depleted. Shares
mint at deflated NAV, creating permanent S > A imbalance + economic
extraction.

### Vector C: Token injection in callback
Vault receives tokens during a callback (e.g., from a DEX swap), but
the callback can inject extra tokens directly. Same outcome as Vector A.

## Detection heuristic for future hunts

```bash
grep -rn "balanceOf(address(this))" src/ | grep -i "asset\|token"
```

For each match, check:
1. Is there a strict equality check using totalAssets() anywhere?
2. Does flashLoan() (or any external callback) lack nonReentrant?
3. Does the vault accept tokens via direct transfer?

If 1 + (2 or 3) -> likely bug.

## Defenses

### Defense A: Internal accounting

```solidity
uint256 internalTotalAssets;

function deposit(uint256 amount, address receiver) public override
    returns (uint256 shares)
{
    asset.safeTransferFrom(msg.sender, address(this), amount);
    internalTotalAssets += amount;
    // mint shares...
}

function totalAssets() public view override returns (uint256) {
    return internalTotalAssets;
}
```

### Defense B: Pre-loan snapshot in flashLoan

```solidity
function flashLoan(...) external nonReentrant {
    uint256 snapshot = totalAssets();
    asset.transfer(receiver, amount);
    receiver.onFlashLoan(...);
    asset.safeTransferFrom(receiver, address(this), amount + fee);
    require(totalAssets() == snapshot + fee, "balance mismatch");
}
```

Note: nonReentrant alone may not be sufficient if the vault accepts
ERC777 tokens or has other reentry vectors. Internal accounting is
preferred.

## Severity discriminator — is the donated token UNRELATED to, or IDENTICAL to, the asset backing the principal?

The balance-conflation mechanism can be present and still NOT be Critical.
The discriminator is **what relationship the donated token has with the principal at risk**:

- **Donated token UNRELATED to the backing accounting (Unstoppable) → Critical.**
  The donation breaks an invariant (S==A) without contributing value that backs anything → freeze/extraction of other people's funds.
- **Donated token IDENTICAL to the asset backing the principal → Low.**
  Example (Twyne, a credit vault on top of Euler): `_isNotExternallyLiquidated = totalAssetsDepositedOrReserved <= asset().balanceOf(this)`, and `asset()` (the donated eToken) **is enabled as the CV's own Euler collateral**. Donating to mask/freeze the ext-liq **re-collateralizes the principal with the donation itself** → the LPs' claim ends up backed by what was donated → self-defeating, with no uncovered loss. Naive Critical → gated to **Low**.

**Rule:** facing a donation-driven balance conflation, ask BEFORE assigning severity:
*is the token the attacker donates the same asset that backs the principal they intend to damage?* If so, the donation backs it (self-defeating → Low/MED); if it is unrelated, there is a real loss (Critical/High). Cross-check with [[severity-gate-funds-at-risk]] (custody axis).

## Where I've seen it

- Damn Vulnerable DeFi v4 — Unstoppable — unrelated token → Critical.
- Twyne (a credit vault on top of Euler) — donated token = backing collateral → re-collateralization → Low.

## Search keywords for Solodit

- "ERC4626 inflation"
- "totalAssets balanceOf"
- "flashloan deposit reentrancy"
- "vault donation attack"
- "share price manipulation"
