# Target notes — LayerZero V2 (EVM endpoint + DVN/Executor + OApp/OFT)

> **Line-by-line read.** All `file:line` cites are at pin **`9c741e7`** of the LayerZero-v2 repo (EVM tree frozen since `943ce4a`, 2024-11-11), under `packages/layerzero-v2/evm/`. Package roots abbreviated: `P/` = `protocol/contracts/`, `M/` = `messagelib/contracts/`, `O/` = `oapp/contracts/`.

---

## §0 — Mental model: the V2 message lifecycle and where trust lives

A LayerZero V2 message crosses a chain boundary in **four on-chain steps split across two chains**, mediated by **off-chain workers** (DVNs + Executor) that the protocol does NOT trust blindly — it trusts a *per-OApp configurable* set:

```
SRC chain                                 DST chain
---------                                 ---------
OApp.send                                 (off-chain: DVNs observe PacketSent,
  → EndpointV2.send (STEP 1)               sign the payloadHash)
    → _outbound (++nonce, eager)
    → sendLib.send → emit PacketSent  ──►  DVN → ReceiveUln302.verify  (writes hashLookup[h][p][dvn])
                                           anyone → ReceiveUln302.commitVerification (STEP 2)
                                             → _checkVerifiable (DVN QUORUM)
                                             → endpoint.verify → _inbound (writes inboundPayloadHash)
                                           Executor → endpoint.lzReceive (STEP 3)
                                             → _clearPayload (hash gate + lazy nonce)
                                             → receiver.lzReceive(...)
                                             → [optional] endpoint.sendCompose
                                           Executor → endpoint.lzCompose (STEP 3b)
                                             → composer.lzCompose(...)
```

**The single security invariant of the endpoint:** a message executes on the destination **iff** its `keccak256(guid‖message)` equals the `inboundPayloadHash` slot that the OApp's **configured receive library** wrote — and that library wrote it only after the OApp's **configured DVN quorum** attested. Everything else (executor identity, gas, msg.value, ordering) is convention, not enforcement.

**Two nested trust layers, both OApp-configurable (this is the V2 thesis vs V1's fixed ULN):**
1. **Endpoint → MessageLib**: `EndpointV2.verify` only accepts a payload-hash write from `isValidReceiveLibrary` (the OApp's configured receive lib, or an old lib still in its grace window). `MessageLibManager`.
2. **MessageLib → DVN set**: `ReceiveUln302.commitVerification` only commits when `_checkVerifiable` passes the OApp's `UlnConfig` (required-DVN AND + optional-DVN threshold). `ReceiveUlnBase`/`UlnBase`.

An OApp that **never configures** anything inherits LayerZero's *default* lib + *default* DVN config (`MessageLibManager.defaultReceiveLibrary`, `UlnBase` DEFAULT path). That is a real trust assumption, not a neutral fallback (see §7 B4).

**Backward-compat naming (EndpointV2.sol:18-37):** `chainId→eid`, `adapterParams→options`, `userApplication→oapp`, `srcAddress/dstAddress→sender/receiver`, `payload→message`. **V2 has NO `receivePayload`/`storedPayload`/`retryPayload`/`forceResumeReceive`/`UltraLightNode`** — those are V1. The V2 analog of "stuck stored payload + forceResume" is `inboundPayloadHash` + the `skip`/`nilify`/`burn`/`clear` recovery primitives (§2).

---

## §1 — EndpointV2: send / verify / lzReceive / clear  (Area 1)  `P/EndpointV2.sol` (369 L)

`EndpointV2 is ILayerZeroEndpointV2, MessagingChannel, MessageLibManager, MessagingComposer, MessagingContext` — a **singleton per chain**, identified by immutable `eid`. State it owns directly: `lzToken` (38), `delegates` (40).

### Send path (STEP 0/1)
- `quote:55` — view; builds the `Packet` with `outboundNonce+1` and the GUID, resolves `getSendLibrary(sender,dstEid)`, returns `sendLib.quote`. On-chain quote ⇒ price race (natspec 48-52): excess native is refunded, shortfall reverts.
- `send:83` — `payable sendContext(dstEid, msg.sender)` (reentrancy guard, §1.4). Calls `_send`, then asserts fees and pays.
- `_send:111` — the real work: `_outbound` (eager `++nonce`, `MessagingChannel:28`) → build `Packet` + `GUID.generate` → `getSendLibrary` → `sendLib.send(packet, options, payInLzToken)` returns `(fee, encodedPacket)` → **`emit PacketSent(encodedPacket, options, sendLibrary)`** (139-141). This single event is the off-chain signal DVNs+Executor listen to.
- Fee settlement: `_assertMessagingFee:305` (supplied ≥ required, else `LZ_InsufficientFee`), `_payToken:244` / `_payNative:269` (pay lib, refund excess to `_refundAddress`). `_suppliedLzToken:287` reverts `LZ_ZeroLzTokenFee` if payInLzToken but balance 0 (race guard against lzToken swap).

**Invariants assumed (send):** the sendLib is honest about `fee`/`encodedPacket` (the endpoint forwards whatever the lib returns); `_outbound` nonce is monotonic per `(sender,dstEid,receiver)`; the OApp transferred fees *before* calling (STEP 1 natspec 80).

### Inbound write path (STEP 2) — `verify:151` (THE inbound authorization)
```solidity
if (!isValidReceiveLibrary(_receiver, _origin.srcEid, msg.sender)) revert LZ_InvalidReceiveLibrary; // (1)
uint64 lazyNonce = lazyInboundNonce[_receiver][srcEid][sender];
if (!_initializable(_origin, _receiver, lazyNonce)) revert LZ_PathNotInitializable;               // (2)
if (!_verifiable(_origin, _receiver, lazyNonce)) revert LZ_PathNotVerifiable;                      // (3)
_inbound(_receiver, srcEid, sender, nonce, _payloadHash);                                          // (4)
```
- **(1) is the write-authorization for the entire inbound side:** only the OApp's configured receive lib (`MessageLibManager.isValidReceiveLibrary:108`) may write a payload hash. The DVN quorum is checked *inside the lib* before it calls `verify` — the endpoint trusts the lib, the lib enforces the quorum.
- **(2) `_initializable:333`** = `lazyInboundNonce > 0 || receiver.allowInitializePath(origin)`. The very first message on a `(receiver,srcEid,sender)` path needs the receiver to opt in via `allowInitializePath` (§5, B5). After the first, the path is "open".
- **(3) `_verifiable:344`** = `nonce > lazyInboundNonce || inboundPayloadHash[...][nonce] != EMPTY`. You may verify a fresh slot above the cursor, OR **re-verify** a not-yet-executed slot (hash still present). You may NOT (re)verify a slot ≤ cursor whose hash was deleted by execution → **replay protection**. A *nilified* slot (hash = NIL, not EMPTY) IS re-verifiable; a *burned* slot (hash deleted) is not (§2).

### Execution path (STEP 3) — `lzReceive:172` (permissionless, content-bound)
```solidity
_clearPayload(_receiver, srcEid, sender, nonce, abi.encodePacked(_guid, _message)); // hash gate + lazy nonce
ILayerZeroReceiver(_receiver).lzReceive{ value: msg.value }(_origin, _guid, _message, msg.sender, _extraData);
```
- **No caller auth.** Anyone can call `lzReceive`. Security = `_clearPayload` (§2) reverts unless `keccak(guid‖message)` matches the verified `inboundPayloadHash`. So execution is *permissionless but content-bound*: you can only execute a message that a quorum already attested, exactly as attested.
- **Clear-before-call (179):** `_clearPayload` deletes the hash *before* the external call ⇒ a re-entrant `lzReceive` for the same nonce finds an empty slot and reverts. Reentrancy across *different* messages is still possible (by design).
- **`msg.sender` is forwarded to the receiver as `_executor`** and `_extraData` is explicitly "untrusted" (natspec 165, 171). The receiver MAY assert these but the endpoint does not.
- **`msg.value` is forwarded verbatim** (181) — and is whatever the *caller* supplied, NOT what the sender paid the executor for (§4, B6).

### Pull-execution / recovery — `clear:211`
`_assertAuthorized(_oapp)` then `_clearPayload` (same gate) without calling the receiver: the OApp marks a verified message as executed/burnt without running its logic. PULL vs PUSH. The cleared message is "effectively burnt" (natspec 206).

### Misc
- `lzReceiveAlert:191` / (composer `lzComposeAlert`) — pure event emitters the Executor calls when execution fails in its try/catch; no state.
- `setDelegate:327` — `delegates[msg.sender] = _delegate`; the delegate is authorized alongside the OApp in `_assertAuthorized:355` (so a delegate can set libs, skip/nilify/burn, clear, setConfig).
- `setLzToken`/`recoverToken` — onlyOwner (LZ).
- `EndpointV2Alt.sol` (52 L, not core to bug map): variant where native gas-token is an ERC-20 — overrides `_payNative`/`_suppliedNative`/`nativeToken`.

### §1.4 Send reentrancy guard — `MessagingContext.sol` (36 L)
`sendContext(dstEid, sender)` modifier (16): reverts `LZ_SendReentrancy` if already in a send; packs `(eid<<160)|sender` into `_sendContext` so a nested call can read `getSendContext`. Only guards the **send** direction (receive has its own clear-before-call guard). Lets an OApp send a reply during a receive (separate contexts).

---

## §2 — MessagingChannel: nonces, lazy inbound nonce, recovery  (Area 2)  `P/MessagingChannel.sol` (161 L)

The replay/ordering/grief core. Sentinels: `EMPTY_PAYLOAD_HASH = 0` (10), `NIL_PAYLOAD_HASH = type(uint256).max` (11). Three mappings keyed by `(receiver|sender, srcEid|dstEid, sender|receiver, [nonce])`: `lazyInboundNonce` (16), `inboundPayloadHash` (18), `outboundNonce` (20).

### The nonce asymmetry (the central design)
- **Outbound is EAGER:** `_outbound:28` does `++outboundNonce` on every send. Monotonic, gapless, per path.
- **Inbound is LAZY:** `_inbound:37` just writes `inboundPayloadHash[...][nonce] = hash` at *whatever nonce* was verified — **it does NOT advance any cursor** ⇒ messages can be **verified out of order** (a DVN can attest nonce 7 before nonce 3). Reverts if hash==EMPTY (44) so an EMPTY slot always means "not verified".
- `lazyInboundNonce` is a **checkpoint cursor**, advanced only by `_clearPayload`/`skip`. `inboundNonce():54` computes the *actual* contiguous-verified high-water mark on demand by walking `lazyInboundNonce → while(_hasPayloadHash(cursor+1)) cursor++`. Examples in natspec 53: `[1,2,3,4,6,7]→4`, `[1,2,6,8,10]→2`. **Can OOG** with a huge verified backlog, "trivially fixed by clearing some prior messages" (51) — a latent griefing/liveness footnote.

### `_clearPayload:126` — the ordering enforcement + hash gate
```solidity
uint64 currentNonce = lazyInboundNonce[...];
if (_nonce > currentNonce) {
    for (uint64 i = currentNonce + 1; i <= _nonce; ++i)
        if (!_hasPayloadHash(..., i)) revert LZ_InvalidNonce(i);   // (A) all ≤ N must be VERIFIED
    lazyInboundNonce[...] = _nonce;                                 // (B) advance cursor
}
actualHash = keccak256(_payload);
bytes32 expectedHash = inboundPayloadHash[...][_nonce];
if (expectedHash != actualHash) revert LZ_PayloadHashNotFound(...); // (C) content gate
delete inboundPayloadHash[...][_nonce];                             // (D) consume (replay protection)
```
**Channel ordering invariant (precise):** executing nonce N requires **all nonces ≤ N to be verified** (have non-EMPTY hashes) — (A). It does **NOT** require nonces < N to be **executed**. So once 1..N are verified, you can execute them in ANY order; after executing N, `lazyInboundNonce = N` but 1..N-1 hashes still present and individually executable (their `_nonce < currentNonce` skips the loop). **The channel enforces contiguous VERIFICATION, not contiguous EXECUTION.**
- (D) deletes the hash ⇒ a message executes **exactly once** (re-exec finds EMPTY, (C) reverts).
- A **reverting** `receiver.lzReceive` reverts the whole tx including (D) ⇒ the hash is restored ⇒ the message can be retried. **The channel never bricks on a revert.** (This is why B2's "block" is an OApp-level, not channel-level, property — §7.)

### Recovery primitives (the privileged toolbox = V2's `forceResumeReceive`)
All gated by `_assertAuthorized(_oapp)` (160, impl `EndpointV2:355` = oapp **or its delegate**):
| Fn | Line | Precondition | Effect | Reversible? |
|----|------|--------------|--------|-------------|
| `skip` | 82 | `_nonce == inboundNonce()+1` | `lazyInboundNonce = _nonce`; abandons that one msg (censors next) | the slot is jumped, never executed |
| `nilify` | 95 | `curHash == _payloadHash` (provided) | sets slot to `NIL` ⇒ not executable until **re-verified** | YES — DVNs can re-attest, `commitVerification` re-writes |
| `burn` | 112 | `_nonce ≤ lazyInboundNonce` && `curHash != EMPTY` | `delete` slot permanently | NO — never re-verifiable/executable |
| `clear` (Endpoint) | `EndpointV2:211` | authorized | PULL-execute (consume w/o running logic) | NO |

**Subtle (nilify, 100-101):** can't nilify a slot ≤ lazyInboundNonce that is already EMPTY (would be a no-op/confusion). **Subtle (skip, 85):** the explicit `_nonce` arg prevents a race where you meant to skip N but N got consumed first. These are the **only** ways to unstick an ordered channel, and they are **owner/delegate-only** ⇒ if an integrator's ordered OApp jams and the owner can't/won't call them, messages behind the jam are stuck (B2).

`nextGuid:155` — view, the GUID the next outbound message will carry.

---

## §3 — MessageLibManager + ULN: lib resolution + DVN quorum  (Area 3)

### `P/MessageLibManager.sol` (324 L) — which library is trusted for `(OApp, eid)`
- Registry: `registerLibrary:140` (onlyOwner, must pass ERC165 `IMessageLib`); `blockedLibrary` (constructor, reverts on send/quote) is the canonical "disable this path" lib.
- Resolution (lazy default): `getSendLibrary:83` = `sendLibrary[oapp][dstEid]` else `defaultSendLibrary[dstEid]` (revert if 0). `getReceiveLibrary:96` analogous, returns `isDefault`.
- **`isValidReceiveLibrary:108`** (the gate `EndpointV2.verify` calls): true if `actualLib == expectedLib`, **OR** the lib matches a still-valid grace-period `Timeout` (123-131). The grace window exists for lib version migrations — a *second* lib is temporarily trusted. (Audit angle: an over-long or mis-set timeout widens the trusted-writer set.)
- OApp setters (`_assertAuthorized`): `setSendLibrary:227`, `setReceiveLibrary:245` (+ grace period, must be non-DEFAULT both sides, 263), `setReceiveLibraryTimeout:279`, `setConfig:307` (pass-through to `lib.setConfig`).
- **LZ-owner setters (the trust root for unconfigured OApps):** `setDefaultSendLibrary:157`, `setDefaultReceiveLibrary:171` (+ grace), `setDefaultReceiveLibraryTimeout:200`. **B4:** any OApp on the default lib is subject to these — LZ can migrate/block the default lib under it.

**Invariants assumed:** a registered lib correctly self-reports `messageLibType` (send vs receive, modifiers `isSendLib`/`isReceiveLib`) and `isSupportedEid`; the OApp trusts whatever lib it points at (default = trust LZ).

### `M/uln/UlnBase.sol` (195 L) — the DVN config and default/custom merge
`UlnConfig` (8): `confirmations(u64)`, `requiredDVNCount(u8)`, `optionalDVNCount(u8)`, `optionalDVNThreshold(u8)`, `requiredDVNs[]`, `optionalDVNs[]`. Reserved values: `DEFAULT=0`, `NIL_DVN_COUNT=u8.max`, `NIL_CONFIRMATIONS=u64.max`, `MAX_COUNT=127` (so total DVNs ≤ 254 < u8.max, for DVNOptions packing).
- **`getUlnConfig:74` (the merge — subtle):** per field, `custom==DEFAULT(0)` ⇒ take LZ default; `custom==NIL` ⇒ literal 0/none (OApp explicitly overrides default *down*); else custom. So `0` means "inherit", and to say "I want ZERO optional DVNs even though the default has some" the OApp uses NIL. **`_assertAtLeastOneDVN:146`** runs on the *merged* result ⇒ final config always has `requiredDVNCount>0 OR optionalDVNThreshold>0` (can't end with zero verification). Comment 116: "it is possible that some default config result into 0 dvns" → the assert is the backstop.
- `_setConfig:151` validation: required list sorted-ascending no-dups (`_assertNoDuplicates:187`), `optionalDVNThreshold ∈ (0, optionalDVNCount]`, counts match list lengths, ≤ MAX_COUNT. Default config (`setDefaultUlnConfigs:55`, onlyOwner) is **stricter**: no NIL allowed, must have ≥1 DVN literally.

### `M/uln/ReceiveUlnBase.sol` (125 L) — DVN attestation + quorum check (THE heart)
- `hashLookup[headerHash][payloadHash][dvn] = Verification(submitted, confirmations)` (18).
- **`_verify:43` is PERMISSIONLESS:** `hashLookup[keccak(header)][payloadHash][msg.sender] = (true, confirmations)`. **Any address** can write an attestation *as itself*. It only counts if `msg.sender` is in the OApp's configured DVN list ⇒ a non-configured attester is harmless noise. **DVN identity = the configured address; there is no on-chain "is this a real DVN" registry at this layer.**
- `_verified:48` = `submitted && confirmations >= requiredConfirmation`.
- **`_checkVerifiable:90` (the quorum):**
  ```
  if requiredDVNCount>0:  for each required DVN: if !_verified(...) return false   // AND of all required
                          if optionalDVNCount==0: return true                       // early-out
  threshold = optionalDVNThreshold
  for each optional DVN: if _verified(...) { threshold--; if threshold==0 return true }  // M-of-N optional
  return false
  ```
  **Required = unanimous AND; optional = threshold-of-N; pass = (all required) AND (≥threshold optional).** `_config.confirmations` is the SAME bar applied to every DVN (each stored `confirmations` must be ≥ it).
- `_verifyAndReclaimStorage:59` — `_checkVerifiable` (revert `LZ_ULN_Verifying` if not) then **deletes** all required+optional `hashLookup` entries (gas reclaim; also prevents the same attestations satisfying a *re-verify* without DVNs re-signing).
- `_assertHeader:79` — header length **must be exactly 81 bytes**, version == 1, `dstEid == localEid`.

**Security model:** a single honest required DVN can **block** (never sign) → liveness DoS, but **cannot forge**. Forgery needs *all* required DVNs + `threshold` optional DVNs to collude/be-compromised. The OApp's whole security reduces to its chosen DVN set's honesty + the confirmations bar.

### `M/uln/uln302/ReceiveUln302.sol` (85 L) — the glue
- `setConfig:33` — `onlyEndpoint`; only `CONFIG_TYPE_ULN(2)` → `_setUlnConfig`.
- **`commitVerification:48` (STEP 2 commit, permissionless):** `_assertHeader` → read `receiver`/`srcEid` from header → `getUlnConfig(receiver, srcEid)` → `_verifyAndReclaimStorage(config, headerHash, payloadHash)` → `endpoint.verify(Origin(srcEid, sender, nonce), receiver, payloadHash)`. Anyone can push the commit once the DVNs have signed; the endpoint then re-checks `isValidReceiveLibrary(receiver, srcEid, msg.sender==this lib)`.
- `verify:64` — thin permissionless wrapper over `_verify` (a DVN calls this to attest).
- `version()` = (3,0,2). (`SendUln302`/`SendUlnBase` symmetric on the send side: assign DVN/Executor jobs, collect fees, emit — not on the inbound critical path; skimmed.)

---

## §4 — Executor + lzCompose: execution and compose  (Area 4)

### `P/MessagingComposer.sol` (80 L) — the compose channel (B1 root)
- State: `composeQueue[from][to][guid][index] = messageHash` (13). Sentinels `NO_MESSAGE_HASH=0` (10), `RECEIVED_MESSAGE_HASH=1` (11).
- **`sendCompose:23` is PERMISSIONLESS:** `composeQueue[msg.sender][_to][_guid][_index] = keccak(_message)`; reverts `LZ_ComposeExists` if already queued. **`from` is bound to `msg.sender`** — anyone can queue a compose *from themselves* to any `_to`. Natspec 17 is explicit: **"the composer MUST assert the sender because anyone can send compose msg with this function."**
- **`lzCompose:39`:** checks `composeQueue[_from][_to][_guid][_index] == keccak(_message)` (else `LZ_ComposeNotFound`); sets slot to `RECEIVED` (reentrancy guard, 56 — kept non-zero on purpose so it can't be re-queued); calls `_to.lzCompose{value: msg.value}(_from, _guid, _message, msg.sender, _extraData)` (57).
  - The composer (`_to`) receives `_from` = whoever queued it, and **its own `msg.sender` = the EndpointV2** (the endpoint makes the call).
  - **B1 — the two checks a composer MUST do:** (a) `msg.sender == address(endpoint)` (only the endpoint delivers) AND (b) `_from == expected source` (the trusted OFT/OApp, not an attacker who called `sendCompose`). Missing (b): an attacker calls `sendCompose(victimComposer, guid, idx, evilMsg)` (queues `[attacker][victim][guid][idx]`) then `lzCompose(attacker, victim, guid, idx, evilMsg, ...)` → endpoint calls `victim.lzCompose(attacker, …)`. If the composer ignores `_from`, it processes attacker-chosen data.
  - **Funds window:** in the OFT flow the tokens are credited to the composer *in `OFTCore._lzReceive`* (§5) **before** the compose runs, so the composer typically already holds the funds the composed action operates on.

### `M/Executor.sol` (306 L) — the off-chain executor's on-chain face (B6 root)
- Permissioned worker: `WorkerUpgradeable` + `ReentrancyGuard` + role-gated. `dstConfig[dstEid]` holds `lzReceiveBaseGas`, `nativeCap`, `lzComposeBaseGas`, multiplier, floor.
- **`execute302:131`** (`onlyRole(ADMIN_ROLE)`, nonReentrant): `try endpoint.lzReceive{ value: msg.value, gas: _executionParams.gasLimit }(...)` catch → `endpoint.lzReceiveAlert`. **The `value` and `gas` come from the executor's OWN call params**, not bound on-chain to the options the sender purchased. Combined with `lzReceive` being permissionless (§1), the "execution options" (gas/msg.value/nativeDrop) are an **off-chain agreement** the executor is trusted to honor — the protocol enforces none of it. A receiver that assumes a specific delivered `msg.value`/gas is trusting the executor (and that no one front-runs with a 0-value `lzReceive`).
- `compose302:156` — same shape for `lzCompose`.
- **`nativeDrop:106` / `_nativeDrop:288`** (`onlyRole(ADMIN_ROLE)`): loops `param.receiver.call{value, gas}("")` — **records `success[i]` but never reverts on failure** (301). A failed drop is silently skipped; recipients must not assume the drop landed.
- `assignJob:230` (`onlyRole(MESSAGE_LIB_ROLE)`) — the send lib quotes the executor's fee at send time. `nativeDropAndExecute302:191` deducts the drop from `msg.value` before forwarding the remainder to `lzReceive`.

**Net (options):** gas / msg.value / nativeDrop / ordered-delivery are **all** off-chain executor conventions keyed off the emitted `options`. On-chain, only the verified payload hash is enforced. This is the recurring "options are not a guarantee" surface (§7 B6).

---

## §5 — OApp / OFT application layer  (Area 5)  `O/oapp/`, `O/oft/`

This is the **realistic target surface** — bounty targets are OApp/OFT integrators, not the hardened endpoint.

### `O/oapp/OAppCore.sol` (83 L) + `OAppReceiver.sol` (122 L) — peer auth, init, ordering
- `peers[eid] = bytes32 peer` (17). `setPeer:43` onlyOwner. `_getPeerOrRevert:67` reverts `NoPeer` if unset. Constructor wires `endpoint.setDelegate(_delegate)` (30).
- **`lzReceive:95` (the OApp inbound auth — both checks matter):**
  ```solidity
  if (address(endpoint) != msg.sender) revert OnlyEndpoint;            // only the endpoint
  if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer; // only the trusted remote
  _lzReceive(...);
  ```
  This is the canonical pair: **endpoint-only + peer-only**. A custom receiver that bypasses `OAppReceiver` and forgets either is the classic integration bug.
- **`allowInitializePath:63`** default = `peers[origin.srcEid] == origin.sender` (B5 root): safe by default (peer-bound). A custom override that returns `true` unconditionally lets ANY src open a path (then verification still needs the DVN quorum, so impact is bounded — but it removes one gate).
- **`nextNonce:78` default = 0 = NO ordered enforcement.** Ordered delivery is **opt-in**: the OApp overrides it to return `inboundNonce+1`; the off-chain **executor reads it and delivers strictly in order, stopping on a revert** (natspec 73-76: "required by the off-chain executor… also enforced by the OApp"). **B2 root:** ordered mode + a permanently-reverting nonce ⇒ the executor never advances past it ⇒ everything behind it is stuck until the owner/delegate `skip`/`nilify`/`clear`s it (§2). The channel itself stays healthy; the integrator's liveness does not.
- `isComposeMsgSender:46` default = `_sender == address(this)`.

### `O/oapp/OAppSender.sol` (124 L) — send-side
- `_lzSend:74` → `_payNative:104` requires **`msg.value == _nativeFee` exactly** → `endpoint.send{value}(MessagingParams(dstEid, _getPeerOrRevert(dstEid), …), refund)`. **Footgun (natspec 98-99):** an OApp sending **multiple** LZ messages in one tx must override `_payNative`, else the second `_lzSend` sees the already-spent `msg.value` and reverts/misprices. (Composability bug class; not in the shortlist but a real integrator trap.)
- `_payLzToken:116` pulls lzToken from `msg.sender` to the endpoint.

### `O/oft/OFTCore.sol` (399 L) — cross-chain token accounting (B3 root)
- **Decimals model:** `sharedDecimals():83` default **6**; `decimalConversionRate = 10**(localDecimals - sharedDecimals)` (constructor 56, requires `localDecimals ≥ sharedDecimals`). SD amounts are **uint64**. Natspec 77-81 is explicit: 6 SD ⇒ cap ≈ 18.45e12 units (uint64.max); **"over uint64.max will need some sort of outbound cap / totalSupply cap"** or a smaller `sharedDecimals`.
- **The conversion primitives:**
  - `_removeDust:317` = `(amountLD / rate) * rate` — floors LD to SD granularity (drops sub-SD dust).
  - `_toSD:335` = `uint64(amountLD / rate)` — **the truncation point.** Safe while `amountLD/rate ≤ uint64.max`. **If a custom OFT sets `sharedDecimals == localDecimals` (rate = 1), `_toSD = uint64(amountLD)` truncates SILENTLY for `amountLD > uint64.max`** → on the dst, `_toLD:326 = amountSD * rate` reconstructs the *truncated* amount ⇒ src-debit ≠ dst-credit ⇒ supply/lock invariant broken. (Config-dependent: needs huge supply or rate=1.)
  - `_toLD:326` = `amountSD * rate`.
- **`_debitView:349`** (default, no fee): `amountSentLD = _removeDust(amountLD); amountReceivedLD = amountSentLD; require(received ≥ minAmountLD) else SlippageExceeded`. So default **sent == received**.
- **`_debit:377` / `_credit:394` are abstract** — the concrete custody model:
  - **`OFT._debit:56`** = `_debitView` then `_burn(from, amountSentLD)`; **`OFT._credit:78`** = `_mint(to, amountLD)` (to→0xdead if 0). **Mint/burn ⇒ the OFT does NOT custody user funds**; a precision/over-credit bug *inflates supply* (still serious, but no "drain a pot").
  - **`OFTAdapter._debit:74`** = `_debitView` then `innerToken.safeTransferFrom(from, this, amountSentLD)` (**LOCK**); **`OFTAdapter._credit:96`** = `innerToken.safeTransfer(to, amountLD)` (**UNLOCK**). **The adapter CUSTODIES the locked TVL** ⇒ an over-credit / precision bug literally **drains the locked pool** until empty (then DoS). Warnings (14-18, 70-72): exactly ONE adapter per mesh; assumes lossless transfers (fee-on-transfer inner token breaks `amountSent==amountReceived` → needs pre/post balance check).
  - **B3 gate discriminator (custody):** same precision bug → **mint/burn OFT = supply inflation**; **OFTAdapter = drain of real locked TVL.** The PING/dust+custom-fee finding lives in a non-default `_debit` that applies a fee but mishandles dust ordering (fee before/after `_removeDust`).
- **`_lzReceive:240` (credit + optional compose):** `_credit(toAddress, _toLD(amountSD), srcEid)` then, if `_message.isComposed()`, `endpoint.sendCompose(toAddress, _guid, 0, OFTComposeMsgCodec.encode(nonce, srcEid, amountReceivedLD, composeMsg))` (267). **The compose is queued with `from = address(this)` (the OFT)** and **tokens are already credited** to `toAddress` ⇒ the composer holds them when its `lzCompose` runs (ties to B1).
- `_buildMsgAndOptions:206` — `OFTMsgCodec.encode(to, _toSD(amount), composeMsg)`; msgType `SEND(1)`/`SEND_AND_CALL(2)`; `combineOptions` merges enforced+caller options; optional `msgInspector`.

### Codecs (exact byte layout — matters for crafting/decoding PoC messages)
- **`OFTMsgCodec` (83 L):** `[sendTo:32][amountSD:8]` (+ `[composeFrom:32][composeMsg]` if composed). `isComposed:35` = `len > 40`. `amountSD:53` = `uint64(bytes8(...))`. `encode:18` injects `msg.sender` as `composeFrom` (26).
- **`OFTComposeMsgCodec` (91 L):** `[nonce:8][srcEid:4][amountLD:32][composeFrom:32][composeMsg]`. The composer reads `composeFrom` (original src sender, from offset 44) + `amountLD` (offset 12) — **a composer that trusts `amountLD` from the message without checking the actual token balance received is the over-trust variant of B1.**
- **`P/messagelib/libs/PacketV1Codec.sol` (108 L):** wire packet = `[version:1][nonce:8][srcEid:4][sender:32][dstEid:4][receiver:32]` = 81-byte header, then `[guid:32][message]` payload. `payloadHash:105` = `keccak(guid‖message)` — the exact value DVNs sign and `_clearPayload` checks.

---

## §6 — Top subtle points (cross-cutting — the ones that matter in real audits)

1. **Execution is permissionless but content-bound.** `EndpointV2.lzReceive` has no caller check; the only gate is `_clearPayload`'s `keccak(guid‖message) == inboundPayloadHash`. Corollary: anything an OApp wants to assert about *who/how* delivered (executor, msg.value, gas) it must assert itself — the endpoint won't.

2. **Inbound write-authorization is one line:** `isValidReceiveLibrary` in `verify:152`. Everything that makes a message "real" funnels through the OApp's configured receive lib. The DVN quorum is enforced *inside that lib* (`_checkVerifiable`), not by the endpoint.

3. **DVN quorum = required-AND + optional-threshold, with a hard "≥1 DVN" backstop** on the merged config (`_assertAtLeastOneDVN`). A required DVN can DoS (block) but not forge; forgery needs the whole quorum. `_verify` is permissionless — identity is the *configured address*, attestations from non-members are noise.

4. **The nonce is lazy and the channel enforces contiguous VERIFICATION, not EXECUTION.** Out-of-order *execution* is allowed once 1..N are verified; ordered *delivery* is an OApp+executor convention (`nextNonce`), not a channel property. A revert never bricks the channel (hash is restored); it only jams an *ordered* integrator that lacks recovery wiring.

5. **Recovery is owner/delegate-only** (`skip`/`nilify`/`burn`/`clear`, all via `_assertAuthorized`). This is the V2 `forceResumeReceive`. `nilify` is reversible (re-verifiable), `burn`/`skip`/`clear` abandon the message. A jammed ordered OApp with no accessible recovery = stuck (B2).

6. **`sendCompose` is permissionless and binds `from = msg.sender`** ⇒ a composer MUST check both `msg.sender == endpoint` AND `_from == expected source`. Tokens are credited before the compose runs (funds window). (B1.)

7. **OFT SD is uint64**; default 6 SD is a real (if high) cap. `_toSD` truncates silently when `amountLD/rate > uint64.max` (rate=1 or huge supply). `_removeDust` ordering vs custom fees is the dust-loss surface. **Custody splits severity: adapter locks TVL (drain), plain OFT mints (inflate).** (B3.)

8. **Options buy nothing on-chain.** gas/msg.value/nativeDrop/ordered are off-chain executor agreements. (B6.)

9. **Defaults are trust, not neutrality.** An OApp on default lib + default DVN config delegates both trust layers to LayerZero's owner keys (`setDefault*`, `setDefaultUlnConfigs`). (B4.)

---

## §7 — Bug-class → code mapping (re-verified `file:line` @ `9c741e7`)

| Class (shortlist) | Where the mechanism lives (file:line @ 9c741e7) | The exact invariant the bug breaks |
|---|---|---|
| **B1 — compose origin not validated** (executor/compose) | `P/MessagingComposer.sendCompose:23` (permissionless, `from=msg.sender`) + `lzCompose:39` (call at `:57`) ; legit producer `O/oft/OFTCore._lzReceive:267` (`from=OFT`, tokens credited at `:251`) ; codec `O/oft/libs/OFTComposeMsgCodec` (`composeFrom@44`, `amountLD@12`) | composer must assert `msg.sender==endpoint` **and** `_from==trusted source`; default OApp gives neither for an *arbitrary* composer |
| **B2 — ordered delivery, permanently-reverting nonce → stuck** (nonce/replay/ordering) | `O/oapp/OAppReceiver.nextNonce:78` (0=unordered; opt-in ordered) + `lzReceive:95` ; channel `P/MessagingChannel._clearPayload:126` (verify-contiguous gate `:137-139`), recovery `skip:82`/`nilify:95`/`burn:112`, `EndpointV2.clear:211` ; `_assertAuthorized` (`EndpointV2:355`) | ordered liveness depends on the executor advancing; recovery is owner/delegate-only; channel never bricks but a recovery-less integrator does |
| **B3 — OFT shared-decimals precision** (OFT accounting) | `O/oft/OFTCore._toSD:335` (uint64 cast) / `_removeDust:317` / `_toLD:326` / `_debitView:349` / `sharedDecimals:83` (cap note `:77`) ; custody `OFT._debit:56`/`_credit:78` (mint/burn) vs `OFTAdapter._debit:74`/`_credit:96` (lock/unlock) | src-debit must equal dst-credit in SD; truncation/dust/fee-ordering breaks it; severity gated by custody (adapter TVL vs OFT supply) |
| B4 (alt) — unconfigured OApp trusts LZ defaults (config/trust) | `P/MessageLibManager.getReceiveLibrary:96` + `setDefaultReceiveLibrary:171` / `getSendLibrary:83` + `setDefaultSendLibrary:157` ; `M/uln/UlnBase.getUlnConfig:74` (DEFAULT merge) + `setDefaultUlnConfigs:55` | an OApp on defaults delegates both trust layers to LZ owner keys |
| B5 (alt) — `allowInitializePath` override too permissive (config/verification) | `O/oapp/OAppReceiver.allowInitializePath:63` (safe default = peer-bound) ; `P/EndpointV2._initializable:333` + `verify:151` | first-message path gate; a `return true` override removes it (impact bounded by the still-required DVN quorum) |
| B6 (alt) — execution options not enforced (executor) | `M/Executor.execute302:131` (value/gas from caller) / `compose302:156` / `nativeDrop:106`+`_nativeDrop:288` (ignores success `:301`) ; `P/EndpointV2.lzReceive:181` (forwards caller `msg.value`) | gas/msg.value/nativeDrop are off-chain agreements; a receiver assuming them trusts the executor |

**DVN-verification quorum (the "core security" reference loci, for any verification-class finding):** `M/uln/ReceiveUlnBase._checkVerifiable:90` (AND required + threshold optional), `_verify:43` (permissionless attest), `_verified:48`, `_verifyAndReclaimStorage:59` ; `M/uln/UlnBase.getUlnConfig:74` + `_assertAtLeastOneDVN:146` ; `M/uln/uln302/ReceiveUln302.commitVerification:48`.
