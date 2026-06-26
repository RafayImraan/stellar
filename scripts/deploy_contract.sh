#!/usr/bin/env bash
# deploy_contract.sh — Build Soroban verifier and deploy to Stellar testnet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

VK_PATH="$CIRCUIT_TARGET/vk"

if [ ! -f "$VK_PATH" ]; then
  echo -e "${YELLOW}VK not found — running proof generation first...${NC}"
  bash "$SCRIPT_DIR/generate_proof.sh"
fi

# ── VK format check ────────────────────────────────────────────────────────
# Now using rs-soroban-ultrahonk PR#26 which supports bb v5 protocol 25 VK
# format (1888 bytes = 3×Fr header + 28 G1 points).
VK_BYTES=$(wc -c < "$VK_PATH" 2>/dev/null || echo 0)
if [ "$VK_BYTES" = "1888" ]; then
  echo -e "${GREEN}VK is 1888 bytes (bb v5 protocol 25 — compatible with PR#26).${NC}"
elif [ "$VK_BYTES" = "1760" ]; then
  echo -e "${YELLOW}VK is 1760 bytes (old format). Install latest bb: bbup${NC}"
fi

echo -e "${BLUE}=== Building Soroban contract ===${NC}"
pushd "$CONTRACT_DIR" >/dev/null
stellar contract build
popd >/dev/null

WASM="$CONTRACT_DIR/target/wasm32v1-none/release/compliance_verifier.wasm"

if [ ! -f "$WASM" ]; then
  # stellar contract build may output to workspace target
  WASM="$ROOT_DIR/target/wasm32v1-none/release/compliance_verifier.wasm"
fi

if [ ! -f "$WASM" ]; then
  echo -e "${RED}WASM not found after build. Run: cd contracts/verifier && stellar contract build${NC}"
  exit 1
fi

echo -e "${BLUE}=== Funding source account (if needed) ===${NC}"
if [ "$STELLAR_NETWORK_NAME" = "testnet" ]; then
  stellar keys generate "$STELLAR_SOURCE_ACCOUNT" --network testnet 2>/dev/null || true
  stellar keys fund "$STELLAR_SOURCE_ACCOUNT" --network testnet 2>/dev/null || true
elif [ "$STELLAR_NETWORK_NAME" = "local" ]; then
  stellar keys generate "$STELLAR_SOURCE_ACCOUNT" --network local 2>/dev/null || true
  stellar keys fund "$STELLAR_SOURCE_ACCOUNT" --network local 2>/dev/null || true
fi

echo -e "${BLUE}=== Deploying to $STELLAR_NETWORK_NAME ===${NC}"
CONTRACT_ID=$(stellar contract deploy \
  --wasm "$WASM" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  -- \
  --vk-bytes-file-path "$VK_PATH")

echo "CONTRACT_ID=$CONTRACT_ID" > "$ROOT_DIR/.env"
echo "STELLAR_NETWORK_NAME=$STELLAR_NETWORK_NAME" >> "$ROOT_DIR/.env"

echo -e "\n${GREEN}Contract deployed!${NC}"
echo "  Contract ID: $CONTRACT_ID"
echo "  Saved to:    $ROOT_DIR/.env"
