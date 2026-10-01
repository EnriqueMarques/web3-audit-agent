# Pattern: "mint-on-redeem with no vault balance gate" — solvency rests on rounding + the sum invariant

**Family:** accounting / accounting conflation (the "there is no balance to conflate — it is MINTED" case)
**Type:** discriminator + defensive reference
**Reference example:** Polymarket V2 CTF (correct implementation)
**Cross-ref:** [[flashloan-repayment-balance-conflation]], [[erc4626-totalassets-balanceof]], [[severity-gate-funds-at-risk]]

---

## The pattern
Some protocols do NOT keep a real collateral balance against which to validate
the redeem: they **mint** the collateral on redeem (`COLLATERAL_TOKEN.mint(_to, payout)`) and
**burn** it on split/deposit. There is no "does the vault have enough?". (Polymarket V2:
`BaseModule.redeem`.) This INVERTS the usual check: in a classic ERC4626 the bug
is inflating `totalAssets()=balanceOf` with a donation; here **there is no balance to
conflate** — solvency depends 100% on the *accounting* never minting more than
was burned.

## Where it can fail (the two axes to verify)
1. **Sum invariant (INV-SUM).** The whole system rests on the pieces that
   make up a position summing exactly to one unit (e.g. `res[0]+res[1]==DENOM`
   per condition).

> **Note — this card is incomplete.** The rest of axis 1, axis 2 (rounding
> direction of the minted collateral), and the sections "The binary for a hunt",
> "Sweep method" and "Where I have seen it (correct → folds)" are not present in
> this English version. The complete original is kept outside this repository.