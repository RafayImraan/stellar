#!/usr/bin/env bash
# Shared configuration for ZK Remittance scripts
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env overrides
if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

export STELLAR_NETWORK_NAME="${STELLAR_NETWORK_NAME:-testnet}"

case "$STELLAR_NETWORK_NAME" in
  testnet)
    export STELLAR_RPC_URL="${STELLAR_RPC_URL:-https://soroban-testnet.stellar.org}"
    export STELLAR_NETWORK_PASSPHRASE="${STELLAR_NETWORK_PASSPHRASE:-Test SDF Network ; September 2015}"
    ;;
  local)
    export STELLAR_RPC_URL="${STELLAR_RPC_URL:-http://localhost:8000/soroban/rpc}"
    export STELLAR_NETWORK_PASSPHRASE="${STELLAR_NETWORK_PASSPHRASE:-Standalone Network ; February 2017}"
    ;;
  *)
    export STELLAR_RPC_URL="${STELLAR_RPC_URL:-https://soroban-testnet.stellar.org}"
    export STELLAR_NETWORK_PASSPHRASE="${STELLAR_NETWORK_PASSPHRASE:-Test SDF Network ; September 2015}"
    ;;
esac

export STELLAR_SOURCE_ACCOUNT="${STELLAR_SOURCE_ACCOUNT:-alice}"
export CONTRACT_ID_FILE="$ROOT_DIR/.env.contract_id"

CIRCUIT_DIR="$ROOT_DIR/circuits/compliance"
CIRCUIT_TARGET="$CIRCUIT_DIR/target"
PROOFS_DIR="$ROOT_DIR/proofs"
CONTRACT_DIR="$ROOT_DIR/contracts/verifier"
MERKLE_DIR="$ROOT_DIR/merkle"

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export NC='\033[0m'
