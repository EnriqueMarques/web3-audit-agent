# Pattern: LayerZero OFT shared-decimals precision (uint64 truncation + custom-`_debitView` over-credit)

**Family:** precision / cross-chain value conservation (LayerZero OFT / OFTAdapter)
**References:** a real finding on PING's OFT (dust + fee). The *severity by custody* shares the gate with [[severity-gate-funds-at-risk]].
**Severity when present:** **DEPENDS ON CUSTODY AND MAGNITUDE** — mint/burn OFT receiver ⇒ supply inflation/deflation (High-class); OFTAdapter receiver ⇒ drain/strand of locked TVL (Critical-class); dust-per-tx magnitude ⇒ Medium. NOT one fixed grade.
**Detection by Slither/Aderyn:** NO (it is a semantic invariant — src-debit must equal dst-credit *in SD* — plus a silent C-style cast that no detector flags as loss)
**Solodit tags:** layerzero, oft, oftadapter, shared-decimals, precision, truncation, cross-chain, severity-by-custody

---

## Core mechanism

An OFT moves value cross-chain in **shared decimals (SD = `uint64`)**, default `sharedDecimals()=6`. Conversion:

```
decimalConversionRate = 10**(localDecimals - sharedDecimals())   // constructor, reads the VIRTUAL sharedDecimals()
_toSD(amountLD) = uint64(amountLD / rate)    // OFTCore._toSD:335-336  — C-style cast, SILENT, no SafeCast/revert
_toLD(amountSD) = amountSD * rate            // OFTCore._toLD:326
_removeDust(amountLD) = (amountLD / rate) * rate   // strips sub-SD dust
```

**The cross-chain invariant** the design must preserve:
```
burn|lock(amountSentLD)  ==  mint|unlock( _toLD(_toSD(amountReceivedLD)) )
```
It holds **iff** `amountReceivedLD` is dust-free **AND** `amountReceivedLD/rate ≤ uint64.max` **AND** `amountSentLD == amountReceivedLD`. Break any clause and src-debit ≠ dst-credit. Two reusable break modes:

- **(A) `uint64` silent truncation → ALWAYS UNDER-credit (self-loss).** If `amountLD/rate > uint64.max`, the cast wraps. This happens when `rate=1` (author overrode `sharedDecimals()` *up* to `localDecimals`, defeating the whole SD design — explicitly warned against at `OFTCore:77-81`) or for ultra-high-supply tokens that kept default 6 SD but transact > ~18.45e12 units. **The slippage check in `_debitView:360` runs in LD *before* `_toSD`, so it gives ZERO protection** against the wire truncation. PoC: `BadSDOFT` sends 20e18, `_debitView` reports sent=received=20e18 (slippage passes), but the DVN-signed packet carries `amountSD = uint64(20e18) = 0x158e460913d00000 = 1.553e18` → dst credits 1.553e18, src burned 20e18; **exactly 2^64 wei vanish.**

- **(B) custom `_debitView`/`_debit` with `received ≠ sent` → OVER- or UNDER-credit.** Any override that computes the burn/lock side and the mint/unlock side asymmetrically (a fee subtracted from one but not the other; dust mis-ordered vs a fee — the **PING** class) breaks conservation every transfer. PoC: a 10% fee subtracted from the SENT side but credited GROSS to the RECEIVED side ⇒ `received(10e18) > sent(9e18)`.

## Severity by custody + magnitude (the two discriminators — the gate's worked example)

The SAME over-credit bug (B) has a different ceiling depending on the **receiver's custody type**, and a different point within that ceiling depending on **per-tx magnitude**:

| receiver custody | (a) naive | (b) gate | (c) official |
|---|---|---|---|
| mint/burn OFT (supply inflation) | Critical | **HIGH** — no pot here; inflates mesh supply / dilutes holders (Critical only if a redeemable sink exists) | — |
| OFTAdapter (drain locked TVL) | Critical | **CRITICAL confirmed** — unlocks more real value than was burned ⇒ underbacks others' deposits, in normal op, permissionless | — |
| PING dust-magnitude instance | High | **MEDIUM** — same class & direction, but imbalance < 1 SD unit/tx (dust) ⇒ magnitude caps it | **Medium** (PING, *real*) |

- **Custody** sets the ceiling/direction: OFT mint/burn = supply inflation (High-class, no custodied pot to drain); OFTAdapter lock/unlock = **drain of others' custodied TVL** (Critical-class — the symmetric "confirm Critical", cf. [[hook-callback-missing-onlypoolmanager]] Cork). PoC end-state on the adapter: `adapter=90e18 < OFT-supply=91e18` ⇒ underbacked.
- **Magnitude** places it within that ceiling: PING's per-tx dust → Medium; a full-fee over-credit → Critical-for-adapter.
- For shape (A) truncation the gate reads **MED (target-conditional)**: the loss is the sender's OWN funds (self-inflicted under a documented misconfig), *escalating to HIGH only if the specific target token's normal supply/transfer genuinely exceeds the uint64 SD cap*. Official checklist grades the primitive **High**; the gate is one notch more conservative — a legitimate disagreement whose lesson is "grade *whose* funds in normal op, not the primitive."
- **AP-honesty:** shape (A) is the documented `_toSD` truncation replicated faithfully; shape (B) is a *constructed minimal representative* of the custom-`_debitView` over-credit class — NOT a claim that it is PING's exact arithmetic (PING = the dust-magnitude member). The point is the class, not one instance.

## Minimal vulnerable patterns

```solidity
// (A) defeats SD by overriding it UP → rate becomes 1 → uint64 truncation for amount > ~18.45 tokens
function sharedDecimals() public pure override returns (uint8) { return 18; } // == localDecimals; BUG

// (B) custom fee: subtracted from SENT but RECEIVED kept gross → over-credit every transfer
function _debitView(uint256 a, uint256 m, uint32) internal view override
    returns (uint256 amountSentLD, uint256 amountReceivedLD)
{
    uint256 fee = a * 1000 / 10000;
    amountReceivedLD = _removeDust(a);          // GROSS credited
    amountSentLD     = _removeDust(a) - fee;    // NET debited  ← asymmetry = the bug
    if (amountReceivedLD < m) revert SlippageExceeded(amountReceivedLD, m);
}
```
Verified with a Foundry PoC against the real LayerZero core (in-repo `TestHelper`).

## Required conditions

1. An OFT/OFTAdapter where `_toSD` can truncate (rate=1, or supply/amount > uint64.max·rate) **or** a custom `_debit`/`_debitView` with asymmetric sent/received.
2. The slippage/min-output check, if any, runs in LD before the SD encoding (so it cannot catch truncation).
3. Receiver custody type determines severity: adapter (locked TVL) = drain/Critical; plain OFT (mint/burn) = inflation/High; magnitude (dust vs full) places it within.

## Detection heuristic

- Any OFT that **overrides `sharedDecimals()`** — *up* toward `localDecimals` is a red flag (rate→1, truncation). Cross-check against the cap note `OFTCore:77-81`.
- Any **custom `_debitView`/`_debit`/`_credit`**: verify `amountSentLD == amountReceivedLD` after dust removal, and that fees apply symmetrically to both sides. Asymmetry = conservation break.
- Ultra-high-supply tokens on default 6 SD: does normal transfer size exceed `uint64.max * rate`?
- Check the slippage check's domain: if it runs in LD before `_toSD`, it does NOT protect against wire truncation.
- **Set severity by the receiver's custody** (adapter vs OFT) and the per-tx magnitude — run [[severity-gate-funds-at-risk]].
- Grep: `_toSD`, `_removeDust`, `sharedDecimals`, `_debitView`, `_debit`, `decimalConversionRate`, `OFTAdapter`.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the by-custody gate (this pattern adds the **custody axis** worked example: OFT inflation vs Adapter TVL-drain, dust-magnitude → Medium).
- [[hook-callback-missing-onlypoolmanager]] — the V4 CONFIRM-Critical analog (custodied TVL drained).
- [[erc4626-totalassets-balanceof]] — sibling "accounting invariant a detector can't see" (supply/asset conservation).
- Target notes: `knowledge/target-notes/layerzero-v2.md` §5 (OFTCore) + §6 point 7 + §7 (B3).
- Loci @ pin `9c741e7`: `OFTCore._toSD:335-336` (uint64 cast) / `_toLD:326` / `_removeDust:317` / `_debitView:349-363` (slippage `:360`) / `sharedDecimals:83` (cap `:77-81`) / ctor rate `:54-57`; custody `OFT._debit:56`/`_credit:78` (mint/burn) vs `OFTAdapter._debit:74`/`_credit:96` (lock/unlock).
