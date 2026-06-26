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

# ── VK format check + conversion ──────────────────────────────────────────
# Main branch verifier expects 1760-byte VK (4×u64 header + 27 G1 points).
# bb v5 produces 1888 bytes (3×Fr header + 28 G1). Convert if needed.
VK_BYTES=$(wc -c < "$VK_PATH" 2>/dev/null || echo 0)
if [ "$VK_BYTES" = "1888" ]; then
  echo -e "${YELLOW}VK is 1888 bytes (bb v5) — converting to 1760 bytes for main branch verifier...${NC}"
  node "$SCRIPT_DIR/convert_vk.js" "$VK_PATH"
  VK_BYTES=$(wc -c < "$VK_PATH" 2>/dev/null || echo 0)
  echo -e "${GREEN}VK converted to $VK_BYTES bytes.${NC}"
elif [ "$VK_BYTES" = "1760" ]; then
  echo -e "${GREEN}VK is 1760 bytes (compatible with main branch verifier).${NC}"
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

# ── Helper: check VK stored on chain ──────────────────────────────────────
check_vk_stored() {
  local cid="$1"
  if VK_CHECK=$(stellar contract invoke \
    --id "$cid" \
    --source "$STELLAR_SOURCE_ACCOUNT" \
    --network "$STELLAR_NETWORK_NAME" \
    -- \
    vk_bytes 2>&1); then
    echo -e "${GREEN}VK stored successfully.${NC}"
    return 0
  else
    echo -e "${YELLOW}VK not yet stored: $VK_CHECK${NC}"
    return 1
  fi
}

# ── Helper: save contract ID to .env ──────────────────────────────────────
save_contract_id() {
  local cid="$1"
  if [ -f "$ROOT_DIR/.env" ]; then
    sed -i "/^CONTRACT_ID=/d" "$ROOT_DIR/.env" 2>/dev/null || true
    sed -i "/^STELLAR_NETWORK_NAME=/d" "$ROOT_DIR/.env" 2>/dev/null || true
  fi
  echo "CONTRACT_ID=$cid" >> "$ROOT_DIR/.env"
  echo "STELLAR_NETWORK_NAME=$STELLAR_NETWORK_NAME" >> "$ROOT_DIR/.env"
  echo -e "\n${GREEN}Contract deployed!${NC}"
  echo "  Contract ID: $cid"
  echo "  Saved to:    $ROOT_DIR/.env"
}

# ── Multi-approach deploy (set +e so individual failures don't abort) ────
set +e

# ── Helper: attempt deploy, return contract ID or empty on failure ────────
try_deploy() {
  local desc="$1"
  shift
  echo -e "${BLUE}=== Deploying to $STELLAR_NETWORK_NAME ($desc) ===${NC}"
  local output
  output=$(stellar contract deploy "$@" 2>&1) || {
    echo -e "${YELLOW}  $desc failed.${NC}"
    return 1
  }
  # Trim whitespace
  output="${output#"${output%%[![:space:]]*}"}"
  output="${output%"${output##*[![:space:]]}"}"
  # Stellar contract IDs are 56 hex chars
  if [ "${#output}" -eq 56 ]; then
    save_contract_id "$output" >&2
    echo "$output"
    return 0
  fi
  echo -e "${YELLOW}  $desc output didn't look like a contract ID: $output${NC}" >&2
  return 1
}

CONTRACT_ID=""

# ── Approach A: deploy with --vk_bytes-file-path (stellar-cli 3.x) ──────
CONTRACT_ID=$(try_deploy "file-path args" \
  --wasm "$WASM" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  -- \
  --vk_bytes-file-path "$VK_PATH") || CONTRACT_ID=""

if [ -n "$CONTRACT_ID" ] && check_vk_stored "$CONTRACT_ID"; then
  set -e; exit 0
fi

# ── Approach B: deploy with --vk_bytes (hex-encoded) ──────────────────────
VK_HEX=$(xxd -p -c 1000000 "$VK_PATH" 2>/dev/null || od -An -tx1 "$VK_PATH" | tr -d ' \n')
CONTRACT_ID=$(try_deploy "hex args" \
  --wasm "$WASM" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  -- \
  --vk_bytes "$VK_HEX") || CONTRACT_ID=""

if [ -n "$CONTRACT_ID" ] && check_vk_stored "$CONTRACT_ID"; then
  set -e; exit 0
fi

# ── Approach C: deploy WITHOUT constructor args, then call set_vk() ──────
CONTRACT_ID=$(try_deploy "no args, then set_vk" \
  --wasm "$WASM" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME") || CONTRACT_ID=""

if [ -z "$CONTRACT_ID" ]; then
  echo -e "${RED}All deploy approaches failed.${NC}"
  set -e; exit 1
fi

echo -e "${BLUE}=== Calling set_vk() on deployed contract ===${NC}"
stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  --send yes \
  -- \
  set_vk \
  --vk_bytes "$VK_HEX"

if check_vk_stored "$CONTRACT_ID"; then
  echo -e "${GREEN}VK initialized via set_vk().${NC}"
else
  echo -e "${RED}set_vk() also failed — trying --vk_bytes-file-path with set_vk...${NC}"
  stellar contract invoke \
    --id "$CONTRACT_ID" \
    --source "$STELLAR_SOURCE_ACCOUNT" \
    --network "$STELLAR_NETWORK_NAME" \
    --send yes \
    -- \
    set_vk \
    --vk_bytes-file-path "$VK_PATH"
  check_vk_stored "$CONTRACT_ID" || {
    echo -e "${RED}All approaches exhausted. Contract deployed but VK not set.${NC}"
    echo -e "${YELLOW}Try manually:${NC}"
    echo "  stellar contract invoke --id $CONTRACT_ID --source $STELLAR_SOURCE_ACCOUNT --network $STELLAR_NETWORK_NAME --send yes -- set_vk --vk_bytes-file-path $VK_PATH"
    exit 1
  }
fi
