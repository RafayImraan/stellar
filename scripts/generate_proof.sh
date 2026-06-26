#!/usr/bin/env bash
# generate_proof.sh — Build Merkle data, populate Prover.toml, compile circuit, generate proof
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.sh"

export PATH="$HOME/.nargo/bin:$HOME/.bb:$PATH"

if ! command -v bb >/dev/null 2>&1; then
  echo -e "${YELLOW}bb not found — install with: bbup${NC}"
  echo -e "${YELLOW}If bbup requires a version flag, try: bbup -v 0.87.0${NC}"
  exit 1
fi

echo -e "${BLUE}=== Step 1: Build Merkle trees ===${NC}"
pushd "$MERKLE_DIR" >/dev/null
if [ ! -d node_modules ]; then
  npm install --silent
fi
node build_tree.js
popd >/dev/null

echo -e "${BLUE}=== Step 2: Generate Prover.toml ===${NC}"
node "$SCRIPT_DIR/generate_prover_toml.js"

echo -e "${BLUE}=== Step 3: Compile & execute circuit ===${NC}"
pushd "$CIRCUIT_DIR" >/dev/null
nargo check
nargo compile
nargo execute
popd >/dev/null

PROJECT_NAME="compliance"
BYTECODE="$CIRCUIT_TARGET/${PROJECT_NAME}.json"
WITNESS="$CIRCUIT_TARGET/${PROJECT_NAME}.gz"

if [ ! -f "$BYTECODE" ] || [ ! -f "$WITNESS" ]; then
  echo -e "${RED}Missing circuit artifacts. Expected:${NC}"
  echo "  $BYTECODE"
  echo "  $WITNESS"
  exit 1
fi

mkdir -p "$PROOFS_DIR"

echo -e "${BLUE}=== Step 4: Detect bb version ===${NC}"
BB_MAJOR=$(bb --version 2>/dev/null | head -1 | sed 's/[^0-9].*//' || echo 0)
echo "  bb major version: $BB_MAJOR"

echo -e "${BLUE}=== Step 5: Generate UltraHonk proof (bb) ===${NC}"
if [ "$BB_MAJOR" -ge 5 ] 2>/dev/null; then
  bb prove \
    --scheme ultra_honk \
    --oracle_hash keccak \
    --bytecode_path "$BYTECODE" \
    --witness_path "$WITNESS" \
    --output_path "$CIRCUIT_TARGET" \
    --output_format binary \
    --write_vk
else
  bb prove \
    --scheme ultra_honk \
    --oracle_hash keccak \
    --bytecode_path "$BYTECODE" \
    --witness_path "$WITNESS" \
    --output_path "$CIRCUIT_TARGET" \
    --output_format bytes_and_fields
  bb write_vk \
    --scheme ultra_honk \
    --oracle_hash keccak \
    --bytecode_path "$BYTECODE" \
    --output_path "$CIRCUIT_TARGET" \
    --output_format bytes_and_fields
fi

echo -e "${BLUE}=== Step 6: Copy artifacts ===${NC}"

# Flatten nested output dirs from bb (same as rs-soroban-ultrahonk)
if [ -d "$CIRCUIT_TARGET/vk/vk" ]; then
  mv "$CIRCUIT_TARGET/vk/vk" "$CIRCUIT_TARGET/vk.tmp"
  rm -rf "$CIRCUIT_TARGET/vk"
  mv "$CIRCUIT_TARGET/vk.tmp" "$CIRCUIT_TARGET/vk"
fi

# Copy artifacts to proofs/
cp "$CIRCUIT_TARGET/proof" "$PROOFS_DIR/compliance.proof"
cp "$CIRCUIT_TARGET/public_inputs" "$PROOFS_DIR/public_inputs"
cp "$CIRCUIT_TARGET/vk" "$PROOFS_DIR/vk"

echo -e "${BLUE}=== Step 7: Local verification (bb verify) ===${NC}"
if [ "$BB_MAJOR" -ge 5 ] 2>/dev/null; then
  bb verify \
    --scheme ultra_honk \
    --oracle_hash keccak \
    -p "$CIRCUIT_TARGET/proof" \
    -k "$CIRCUIT_TARGET/vk" \
    -i "$CIRCUIT_TARGET/public_inputs"
else
  bb verify \
    --scheme ultra_honk \
    --oracle_hash keccak \
    --proof_path "$CIRCUIT_TARGET/proof" \
    --verification_key_path "$CIRCUIT_TARGET/vk" \
    --public_inputs_path "$CIRCUIT_TARGET/public_inputs"
fi

echo -e "\n${GREEN}Proof generated successfully!${NC}"
echo "  Proof:         $PROOFS_DIR/compliance.proof"
echo "  Public inputs: $PROOFS_DIR/public_inputs"
echo "  VK:            $PROOFS_DIR/vk"
echo ""
echo -e "${YELLOW}Note: nargo prove/verify were removed in Noir 1.0 — we use bb prove/verify.${NC}"
