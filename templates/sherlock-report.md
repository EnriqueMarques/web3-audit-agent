[High/Medium] - [Specific title: Contract.function impact]

## Summary

[2-3 sentences. Bug, impact, who triggers it.]

## Vulnerability Detail

[Detailed technical explanation. Include code references with line numbers.]

```solidity
// src/Contract.sol:142-150
function vulnerable() external {
    // ...
}
```

[Explain the mechanism step by step.]

## Impact

[Quantify in concrete terms:]
- What is lost / damaged / inaccessible
- Who is affected
- Conditions under which the impact materializes

Per Sherlock judging criteria, this is **[High/Medium]** because:
- [Cite the specific Sherlock judging rule that applies]
- [Justify why the conditions of that rule are met]

## Code Snippet

[Paste the complete vulnerable function or relevant code block.]

```solidity
[code]
```

## Tool used

Manual review + Foundry PoC.

## Recommendation

[Concrete fix with code.]

```solidity
[fixed code]
```

[1-2 sentences explaining why this addresses root cause.]

## Proof of Concept

```solidity
// test/Exploit.t.sol
[paste test]
```

To reproduce:
```bash
forge test --match-test test_exploit -vvv
```

Expected output demonstrating the exploit:
```
[paste output]
```
