# Duplicate Check Workflow

The #1 rejection reason in bug bounties is duplicates. This document is a **mandatory checklist** before every submission.

**Time invested:** 30-60 minutes per finding. It saves hours of submitting + waiting + being rejected.

---

## Why it matters so much

### For Immunefi

- **Only the first valid report gets paid.** If the bug was reported 3 days ago, your submission is worth zero.
- Some platforms **disqualify researchers** who submit known duplicates.
- The project may have **patched it silently** without disclosure → your PoC no longer works.

### For contests

- Duplicates **split the payout** among researchers (typically).
- Some contests give a **bonus to the first reporter** of the bug.
- Reporting bugs already in the contest's "Known Issues" = a penalty in some formats.

---

## Full checklist

### For Immunefi (the whole list, no shortcuts)

#### 1. Immunefi program disclosure history

URL: `https://immunefi.com/bug-bounty/<project-slug>/`

- [ ] Read EVERY public disclosure of the project
- [ ] Not just titles — open each one and read the summary
- [ ] Mark any bug similar to yours (same contract, same category)

If you find an exact match: **discard your submission**. If you find a partial one: document the explicit difference in the report.

#### 2. The project's GitHub

```bash
cd target/
git log --since="6 months ago" --all -- <vulnerable-file>.sol
git log --since="6 months ago" --grep="security\|fix\|vulnerability\|patch"
```

- [ ] Is there a recent commit touching your vulnerable line? Possibly a silent patch.
- [ ] A closed issue mentioning something similar? Possibly already known.
- [ ] A recent pull request described as a "security fix"? Read the diff.

#### 3. Solodit search

URL: `https://solodit.cyfrin.io`

- [ ] Search by project name
- [ ] Search by bug category + project name
- [ ] Filter by date, last 12 months

If you find an identical finding:
- Is it from the same project? → likely already known
- Is it from another, similar project? → calibrate severity, don't discard

#### 4. Search engines

```
site:github.com <project-name> <vulnerability-keywords>
site:medium.com <project-name> exploit
site:twitter.com <project-name> vulnerability
"<project-name>" <bug-category>
```

- [ ] Results from the last 6 months
- [ ] Read blog posts that look relevant
- [ ] Twitter of the project's devs and well-known researchers

#### 5. The project's Discord / Telegram

- [ ] Join the project's public server (don't announce that you are going to report)
- [ ] Search the history of the `#dev`, `#announcements`, `#security` channels
- [ ] Terms: "fixed", "patched", "vulnerability", "audit", your bug category

#### 6. rekt.news

URL: `https://rekt.news`

- [ ] Is the project on the leaderboard?
- [ ] Is there a recent article about the project?

If they were hacked recently and it is NOT disclosed on Immunefi: it is very unlikely to be bounty-eligible (projects usually close the program after a hack).

#### 7. Previous audits

Typical URLs:
- `https://github.com/<project>/audits` or `<project>/security`
- `https://github.com/spearbit/portfolio` (search by client)
- `https://github.com/Cyfrin/audit-reports`

- [ ] Read ALL of the project's previous reports
- [ ] Verify that your finding is NOT in any of them
- [ ] If it partially is: document how yours is different

#### 8. Code4rena / Sherlock / Cantina archives

- [ ] Did the project have a past contest? Read the findings.
- [ ] Similar protocols (forks)? Read the findings of the originals.

URLs:
- `https://code4rena.com/reports`
- `https://github.com/sherlock-protocol/sherlock-reports`
- `https://cantina.xyz/portfolio`

---

### For contests (short list)

Contests have official "Known Issues". Start there:

#### 1. Contest documents

- [ ] Read the contest repo's README in full
- [ ] "Known Issues" / "Out of scope" section — **memorize it**
- [ ] "Areas of focus" section — the sponsor tells you what to look for
- [ ] Previous audit reports of the project (linked)

#### 2. Public contest findings

Some contests show submissions partially or fully:

- [ ] Cantina: sometimes visible
- [ ] C4: in the post-judging phase, all visible
- [ ] Sherlock: visible to high-tier Watsons

If you see your bug already submitted: still submit (it may be a duplicate share) but adjust expectations.

#### 3. Frequent questions in the contest Discord

Sponsors sometimes clarify "X is by design" in Q&A — your finding about X = invalid.

---

## How to handle partial matches

Sometimes you find a **similar but not identical** finding. Decision tree:

```
Same contract, same vulnerable function, same root cause?
  ├─ YES → DUPLICATE, don't submit
  └─ NO →
      Same contract, same function, different root cause?
        ├─ YES → submit, but document the explicit difference
        └─ NO →
            Same conceptual category (e.g., "oracle manip"), different vector?
              ├─ YES → submit, calibrate severity
              └─ NO  → submit with confidence
```

**In the report**, if you found a similar finding:

```markdown
## Differentiation from prior findings

This issue differs from [Finding XYZ in audit ABC] in the following ways:
- The prior finding addressed [Y] in function [foo()]
- This finding addresses [Z] in function [bar()]
- The mitigation suggested for the prior finding does NOT address this issue because [...]
```

This **protects you** from the judge calling it a duplicate and demonstrates rigor.

---

## When to do the duplicate check

### Option A: Before the PoC (quick)

Pros: if it is an obvious duplicate, you save 5-10h of PoC dev.
Cons: you spend time dupe-checking hypotheses that don't pan out.

### Option B: After the PoC but before the report (recommended)

Pros: you only dupe-check validated bugs → high ROI.
Cons: if it is a duplicate, you lost the PoC time.

### Option C: After the report draft (not recommended)

Pros: none.
Cons: you already spent all the time.

**Recommendation:** Quick scan (10 min) before the PoC. Deep dupe-check (1 hour) before the final report.

---

## Documenting the check

In the hunt directory, one file for all findings (one section per finding):

```
findings/<slug>/
├── dupe-check.md
└── ...
```

`dupe-check.md`:

```markdown
# Duplicate Check — H1 Inflation Attack

Date: 2026-XX-XX
Result: NOT DUPLICATE / SIMILAR FOUND / DUPLICATE

## Sources checked
- [x] Immunefi disclosure history (12 disclosures, none related)
- [x] GitHub commits last 6 months (no relevant changes to Vault.sol since v1.2)
- [x] Solodit search "ERC4626 inflation" + project name (3 results, all on different projects)
- [x] Twitter / Discord (no recent mentions)
- [x] Audit reports (Spearbit 2024, Cyfrin 2025) — neither identified this specific path
- [x] rekt.news — project not listed

## Similar findings found

### Finding A: Inflation in Vault X (Cyfrin audit, 2024)
- Protocol: Different (Yearn-style, this is Aave-style)
- Function: Different (deposit() vs mint())
- Root cause: Same conceptually but different vector

This is documented in the report under "Differentiation from prior findings".

## Conclusion

NOT DUPLICATE. Submit with high confidence.
```

If after submitting you are told "duplicate", you have evidence of your due diligence — useful for escalating to a mediator.

---

## Heuristic shortcuts (when you are short on time)

If you only have 15 minutes for the dupe-check:

1. **Solodit search:** project name + bug category (5 min)
2. **GitHub:** `git log --since=3-months --grep=security` (3 min)
3. **Twitter search:** project name + bug category, last 90 days (5 min)
4. **Immunefi disclosure history** (2 min)

It is less than ideal but catches most duplicates. Only use it if you genuinely don't have 1h available.
