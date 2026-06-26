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

echo -e "${BLUE}Submitting proof to contract $CONTRACT_ID on $STELLAR_NETWORK_NAME...${NC}"

stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$STELLAR_SOURCE_ACCOUNT" \
  --network "$STELLAR_NETWORK_NAME" \
  --send yes \
  -- \
  verify_compliance \
  --proof_bytes-file-path "$PROOF" \
  --public_inputs-file-path "$PUBLIC_INPUTS"

echo -e "\n${GREEN}Compliance verified on-chain!${NC}"

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
