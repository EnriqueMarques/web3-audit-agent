#!/usr/bin/env bash
# setup.sh — Installs and verifies the Web3 Bounty Hunter toolchain.
# Tested on macOS and Linux (Ubuntu/Debian).
#
# Usage:
#   ./tools/setup.sh           # installs whatever is missing and verifies
#   ./tools/setup.sh --check   # only verifies, installs nothing

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

FAILED=()

have() { command -v "$1" >/dev/null 2>&1; }

# Installs a Python tool in an isolated environment (uv > pipx > pip --user).
install_py_tool() {
    local pkg="$1"
    if have uv; then
        uv tool install "$pkg" || uv tool upgrade "$pkg"
    elif have pipx; then
        pipx install "$pkg" || pipx upgrade "$pkg"
    elif have pip3; then
        pip3 install --user --upgrade "$pkg"
    else
        echo "ERROR: no uv, pipx or pip3 found. Install Python 3 first."
        return 1
    fi
}

echo "=========================================="
echo "Web3 Bounty Hunter — Toolchain Setup"
echo "=========================================="

case "$OSTYPE" in
    darwin*) OS="macos" ;;
    linux-gnu*) OS="linux" ;;
    *) echo "Unsupported OS ($OSTYPE). Manual installation required."; exit 1 ;;
esac
echo "Detected OS: $OS"

if ! $CHECK_ONLY; then
    # === Foundry (essential) ===
    echo ""
    echo "[Foundry]"
    if ! have forge; then
        curl -L https://foundry.paradigm.xyz | bash
    fi
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup || FAILED+=("foundry")

    # === Python tools: Slither, Halmos, Semgrep ===
    echo ""
    echo "[Slither]"
    install_py_tool slither-analyzer || FAILED+=("slither")

    echo ""
    echo "[Halmos]"
    install_py_tool halmos || FAILED+=("halmos")

    echo ""
    echo "[Semgrep]"
    if [ "$OS" = "macos" ] && have brew; then
        brew install semgrep || brew upgrade semgrep || FAILED+=("semgrep")
    else
        install_py_tool semgrep || FAILED+=("semgrep")
    fi

    # === Aderyn (Rust) ===
    echo ""
    echo "[Aderyn]"
    if ! have aderyn; then
        if ! have cargo; then
            echo "Installing Rust..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            # shellcheck disable=SC1091
            source "$HOME/.cargo/env"
        fi
        cargo install aderyn || FAILED+=("aderyn")
    fi
fi

# === Verification ===
export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

echo ""
echo "=========================================="
echo "Verification"
echo "=========================================="

MISSING=()
check_tool() {
    local tool="$1" required="$2"
    if have "$tool"; then
        echo "✓ $tool: $("$tool" --version 2>/dev/null | head -1)"
    else
        echo "✗ $tool: NOT INSTALLED"
        [ "$required" = "required" ] && MISSING+=("$tool")
    fi
}

check_tool forge   required
check_tool cast    required
check_tool anvil   required
check_tool slither required
check_tool aderyn  required
check_tool semgrep optional
check_tool halmos  optional

echo ""
echo "Optional (manual installation):"
echo "  - Echidna: https://github.com/crytic/echidna#installation"
echo "  - Medusa:  go install github.com/crytic/medusa@latest"
echo "  - Mythril: uv tool install mythril (slow to install)"

echo ""
echo "=========================================="
echo "Manual configuration"
echo "=========================================="
echo "RPC endpoints for fork PoCs (add them to ~/.zshrc or ~/.bashrc):"
echo "  export MAINNET_RPC=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
echo "  export ARBITRUM_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY"
echo "  export OPTIMISM_RPC=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY"
echo "  export BASE_RPC=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY"
echo "Free keys: https://www.alchemy.com or https://www.infura.io"
echo ""
echo "Solodit (historical findings search): free account at https://solodit.cyfrin.io"
echo ""

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "⚠ Failed installations: ${FAILED[*]}"
fi
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "✗ Missing essential tools: ${MISSING[*]}"
    exit 1
fi
echo "✓ Toolchain ready."
