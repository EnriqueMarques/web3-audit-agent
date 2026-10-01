# [SEVERITY] - [Short, specific title naming Contract.function and impact]

## Summary

[2-3 sentences. What is the bug, what is lost, who can execute it. The judge reads this first and decides whether to read the rest.]

## Severity classification

According to the [Immunefi Vulnerability Severity Classification System v2.3](https://immunefi.com/immunefi-vulnerability-severity-classification-system-v2-3/), this issue qualifies as **[Critical/High/Medium]** because:

- **Impact:** [e.g. "Direct theft of user funds at-rest" — quote exact category]
- **Likelihood:** [e.g. "High — any user can execute without preconditions"]

Funds at risk: **$X** (based on TVL at block N).

## Vulnerability details

### Affected code

`src/<Contract>.sol` lines [X-Y]:

```solidity
[paste vulnerable code with line numbers if possible]
```

### Root cause

[Explain in 1-2 paragraphs why this is a bug. What assumption is broken. What invariant fails.]

### Attack flow

1. **Setup:** [What state is needed before attack]
2. **Step 1:** Attacker calls `function()` with parameters [...]
3. **Step 2:** This causes [internal state change]
4. **Step 3:** Attacker exploits the inconsistent state by [...]
5. **Result:** Attacker gains $X, victim loses $Y

### Why existing protections don't help

[Address obvious mitigations the reader might think of:]
- The `nonReentrant` modifier doesn't apply because [...]
- The access control passes because [...]

## Impact

| Metric | Value |
|--------|-------|
| Funds at risk | $X (Y USDC, at block Z) |
| Affected users | All depositors / specific subset |
| Time to detect | Immediate (transaction visible on-chain) |
| Reversibility | None / Possible via emergency pause |
| Frequency | One-shot / Repeatable |

## Proof of Concept

### Setup

```bash
git clone <repo with PoC>
cd poc
forge install
forge test --match-contract ExploitTest -vvv
```

### Expected output

```
[paste actual output of the test, with profit numbers visible]
```

### Test code

```solidity
[paste test/Exploit.t.sol contents]
```

### Trace highlights

```
[paste relevant lines from forge -vvvv showing the exploit]
```

## Mitigation

### Recommended fix

```solidity
[paste fixed code with explanation of what changed]
```

### Why this works

[1-2 sentences explaining the fix addresses the root cause.]

### Alternative mitigations considered

- **Adding `nonReentrant`:** Would prevent the bug but doesn't address root cause (state ordering). Higher gas cost.
- **Off-chain monitoring:** Insufficient because attack is atomic.

## References

- Affected commit: [hash]
- Related findings on Solodit: [links if any]
- Audit reports that missed this: [if applicable]

## Disclosure timeline

- [Date]: Bug discovered
- [Date]: This report submitted to Immunefi

---

**Researcher contact:** [your handle / email]
**Wallet for bounty payment:** [address]
