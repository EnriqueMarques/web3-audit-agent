# [Severity] [Short Specific Title]

## Description

[Concise paragraph: what the bug is, where it lives, what it allows.]

## Severity rationale

According to Cantina's severity guidelines:

**Likelihood:** [High/Medium/Low] — [reasoning]
**Impact:** [High/Medium/Low] — [reasoning]
**Severity:** [resulting severity]

## Finding Description

### Location
- File: `src/<file>.sol`
- Function: `<functionName>`
- Lines: X-Y

### Vulnerable code

```solidity
[paste relevant code]
```

### Root cause analysis

[Detailed explanation of why this is a vulnerability. What assumption breaks. What invariant fails.]

## Impact Explanation

[Concrete impact, with numbers if possible.]

- Direct loss: $X
- Affected parties: [users / LPs / protocol]
- Conditions: [what must be true for exploit]
- Reversibility: [none / partial via X]

## Proof of Concept

```solidity
[Foundry test demonstrating the exploit]
```

Reproduction:
```bash
forge test --match-test <name> -vvv
```

Output:
```
[expected output with concrete numbers]
```

## Recommendation

```solidity
[fix code]
```

### Why this fix

[Explain why the fix addresses root cause and not just symptoms.]

### Alternative considered

[If applicable, briefly mention alternative fixes and why your recommendation is preferred.]
