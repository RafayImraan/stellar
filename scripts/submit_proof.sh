#!/usr/bin/env bash
# submit_proof.sh — Submit compliance proof to deployed Soroban contract
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

PROOF="$PROOFS_DIR/compliance.proof"
PUBLIC_INPUTS="$PROOFS_DIR/public_inputs"

if [ ! -f "$PROOF" ] || [ ! -f "$PUBLIC_INPUTS" ]; then
  echo -e "${RED}Proof artifacts not found. Run ./scripts/generate_proof.sh first.${NC}"
  exit 1
fi

# Load contract ID from .env
if [ -f "$ROOT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
fi

if [ -z "${CONTRACT_ID:-}" ]; then
  echo -e "${RED}CONTRACT_ID not set. Run ./scripts/deploy_contract.sh first.${NC}"
  exit 1
fi

# Pre-compute hex versions for fallback approaches
PROOF_HEX=$(xxd -p -c 1000000 "$PROOF" 2>/dev/null || od -An -tx1 "$PROOF" | tr -d ' \n')
PUBLIC_INPUTS_HEX=$(xxd -p -c 1000000 "$PUBLIC_INPUTS" 2>/dev/null || od -An -tx1 "$PUBLIC_INPUTS" | tr -d ' \n')

echo -e "${BLUE}Submitting proof to contract $CONTRACT_ID on $STELLAR_NETWORK_NAME...${NC}"

# Approach A: file-path args (stellar-cli 3.x)
if stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  --send yes \
  -- \
  verify_compliance \
  --proof_bytes-file-path "$PROOF" \
  --public_inputs-file-path "$PUBLIC_INPUTS" 2>&1; then
  echo -e "\n${GREEN}Compliance verified on-chain!${NC}"
else
  echo -e "${YELLOW}Approach A failed — trying approach B (hex args)...${NC}"
  # Approach B: hex-encoded args
  stellar contract invoke \
    --id "$CONTRACT_ID" \
    --source "$STELLAR_SOURCE_ACCOUNT" \
    --network "$STELLAR_NETWORK_NAME" \
    --send yes \
    -- \
    verify_compliance \
    --proof_bytes "$PROOF_HEX" \
    --public_inputs "$PUBLIC_INPUTS_HEX" || {
    echo -e "${RED}Proof submission failed.${NC}"
    echo -e "${YELLOW}Try manually:${NC}"
    echo "  stellar contract invoke --id $CONTRACT_ID --source $STELLAR_SOURCE_ACCOUNT --network $STELLAR_NETWORK_NAME --send yes -- verify_compliance --proof_bytes-file-path $PROOF --public_inputs-file-path $PUBLIC_INPUTS"
    exit 1
  }
  echo -e "\n${GREEN}Compliance verified on-chain!${NC}"
fi

# Query nullifier status (extract from public inputs — last 32 bytes of 160-byte file)
NULLIFIER_HEX=""
if command -v xxd >/dev/null 2>&1; then
  NULLIFIER_HEX=$(xxd -p -s 128 -l 32 "$PUBLIC_INPUTS" | tr -d '\n')
elif command -v od >/dev/null 2>&1; then
  NULLIFIER_HEX=$(od -An -tx1 -j 128 -N 32 "$PUBLIC_INPUTS" | tr -d ' \n')
fi
if [ -n "$NULLIFIER_HEX" ]; then
  echo -e "${BLUE}Nullifier (hex): 0x${NULLIFIER_HEX}${NC}"
fi
