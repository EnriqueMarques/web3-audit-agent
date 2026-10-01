#!/usr/bin/env bash
# analyze.sh — Static analysis pipeline over a Foundry target
#
# Usage:
#   ./tools/analyze.sh [target-path] [output-directory]
#   ./tools/analyze.sh ./target ./findings/<slug>
#
# - target-path must be the root of a Foundry project (contains foundry.toml).
# - To limit Aderyn to a subdirectory, export SCOPE with the path relative to the target:
#     SCOPE="src/vault/" ./tools/analyze.sh ./target ./findings/<slug>
# - Tools that are not installed are skipped with a warning; the rest of the pipeline continues.

set -euo pipefail

TARGET="${1:-./target}"
OUTPUT="${2:-./findings/analysis}"

if [ ! -f "$TARGET/foundry.toml" ]; then
    echo "✗ $TARGET is not the root of a Foundry project (foundry.toml missing)."
    exit 1
fi

# Absolute paths: the script cds into the target and OUTPUT must not resolve inside it.
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
TARGET="$(cd "$TARGET" && pwd)"
mkdir -p "$OUTPUT"/{static,storage,callgraph,solodit-queries}

have() { command -v "$1" >/dev/null 2>&1; }
skip() { echo "  ↷ $1 not installed — skipped"; }

echo "=========================================="
echo "Static analysis pipeline"
echo "Target: $TARGET"
echo "Output: $OUTPUT"
echo "=========================================="

cd "$TARGET"

# Source directory according to foundry.toml (src by default)
SRC_DIR="$(forge config --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("src","src"))' 2>/dev/null || echo src)"
[ -d "$SRC_DIR" ] || SRC_DIR="src"

# === 1. Build ===
echo ""
echo "[1/8] Building target..."
if ! forge build 2>&1 | tee "$OUTPUT/build.log"; then
    echo "✗ Build failed. Check $OUTPUT/build.log"
    exit 1
fi
echo "✓ Build OK"

# === 2. Sizes + solc warnings ===
echo ""
echo "[2/8] Contract sizes and solc warnings..."
forge build --sizes > "$OUTPUT/static/sizes.txt" 2>&1 || true
forge build --force 2>&1 | grep -i "warning" > "$OUTPUT/static/solc-warnings.txt" || true
echo "✓ Sizes and warnings"

# === 3. Slither ===
echo ""
echo "[3/8] Slither..."
if have slither; then
    slither . --json "$OUTPUT/static/slither-raw.json" > "$OUTPUT/static/slither.log" 2>&1 || true
    slither . --print human-summary > "$OUTPUT/static/slither-summary.txt" 2>&1 || true
    echo "✓ Slither"
else
    skip slither
fi

# === 4. Aderyn ===
echo ""
echo "[4/8] Aderyn..."
if have aderyn; then
    if [ -n "${SCOPE:-}" ]; then
        aderyn . --src "$SCOPE" -o "$OUTPUT/static/aderyn-report.md" > "$OUTPUT/static/aderyn.log" 2>&1 || echo "  Aderyn finished with warnings (see aderyn.log)"
    else
        aderyn . -o "$OUTPUT/static/aderyn-report.md" > "$OUTPUT/static/aderyn.log" 2>&1 || echo "  Aderyn finished with warnings (see aderyn.log)"
    fi
    echo "✓ Aderyn"
else
    skip aderyn
fi

# === 5. Semgrep ===
echo ""
echo "[5/8] Semgrep..."
if have semgrep; then
    semgrep --config=p/smart-contracts --json -o "$OUTPUT/static/semgrep.json" "$SRC_DIR" > "$OUTPUT/static/semgrep.log" 2>&1 || true
    echo "✓ Semgrep"
else
    skip semgrep
fi

# === 6. Storage layouts ===
echo ""
echo "[6/8] Storage layouts..."
find "$SRC_DIR" -name "*.sol" -print0 | while IFS= read -r -d '' sol_file; do
    sed -nE 's/^[[:space:]]*contract[[:space:]]+([A-Za-z0-9_]+).*/\1/p' "$sol_file" | while read -r contract; do
        forge inspect "$contract" storageLayout > "$OUTPUT/storage/$contract.txt" 2>/dev/null \
            || rm -f "$OUTPUT/storage/$contract.txt"
    done
done
echo "✓ $(find "$OUTPUT/storage" -name '*.txt' | wc -l | tr -d ' ') layouts extracted"

# === 7. Call graphs ===
echo ""
echo "[7/8] Call graphs..."
if have slither; then
    slither . --print call-graph > "$OUTPUT/callgraph/call-graph.txt" 2>&1 || true
    slither . --print inheritance-graph > "$OUTPUT/callgraph/inheritance.txt" 2>&1 || true
    # Slither writes the .dot files to the current directory; move them to the output
    find . -maxdepth 1 -name "*.dot" -exec mv {} "$OUTPUT/callgraph/" \; 2>/dev/null || true
    echo "✓ Call graphs"
else
    skip slither
fi

# === 8. External integrations ===
echo ""
echo "[8/8] External integrations..."
section() {
    echo "## $1"
    local hits
    hits="$(grep -rnE "$2" "$SRC_DIR" 2>/dev/null | head -20 || true)"
    echo "${hits:-(none)}"
    echo ""
}
{
    echo "# External integrations detected"
    echo ""
    section "Aave"                    "IAaveV3Pool|ILendingPool|IPool"
    section "Compound"                "ICToken|IComptroller"
    section "Uniswap"                 "IUniswapV2|IUniswapV3|ISwapRouter|IPoolManager"
    section "Curve"                   "ICurve|StableSwap"
    section "Chainlink"               "AggregatorV3|IChainlink"
    section "LayerZero/CCIP/Wormhole" "ILayerZero|ICCIP|IRouterClient|IWormhole"
    section "Permit2"                 "IPermit2|permit2"
    section "ERC4626 Vaults"          "ERC4626|IERC4626"
} > "$OUTPUT/integrations.md"
echo "✓ Integrations"

# === Suggested Solodit queries ===
{
    echo "# Suggested Solodit queries based on this codebase"
    echo ""
    if grep -rq "ERC4626" "$SRC_DIR" 2>/dev/null; then
        echo "- 'ERC4626 inflation'"
        echo "- 'first depositor'"
    fi
    if grep -rqE "getReserves|slot0" "$SRC_DIR" 2>/dev/null; then
        echo "- 'spot price manipulation'"
        echo "- 'oracle manipulation flashloan'"
    fi
    if grep -rqE "permit|Permit2" "$SRC_DIR" 2>/dev/null; then
        echo "- 'permit front-running'"
        echo "- 'permit2 race'"
    fi
    if grep -rqE "ILayerZero|ICCIP" "$SRC_DIR" 2>/dev/null; then
        echo "- 'cross-chain replay'"
        echo "- 'bridge mint burn asymmetry'"
    fi
    if grep -rq "liquidate" "$SRC_DIR" 2>/dev/null; then
        echo "- 'self liquidation'"
        echo "- 'liquidation MEV'"
    fi
    if grep -rqE "delegatecall|UUPS" "$SRC_DIR" 2>/dev/null; then
        echo "- 'uninitialized implementation'"
        echo "- 'storage collision proxy'"
    fi
} > "$OUTPUT/solodit-queries/suggested.md"

echo ""
echo "=========================================="
echo "Analysis complete"
echo "=========================================="
echo "  Static analysis:  $OUTPUT/static/"
echo "  Storage layouts:  $OUTPUT/storage/"
echo "  Call graphs:      $OUTPUT/callgraph/"
echo "  Integrations:     $OUTPUT/integrations.md"
echo "  Solodit queries:  $OUTPUT/solodit-queries/suggested.md"
echo ""
echo "Next: triage with subagents/static-sweep-agent.md → static-triage.md"
