.PHONY: all check-deps check-versions setup-versions merkle-deps merkle-data prover-toml circuit-proof deploy submit clean

# ── Required tool versions ─────────────────────────────────────────────────
BB_REQUIRED := 0.87.0
NARGO_REQUIRED := 1.0.0-beta.9

# ── Barretenberg bb binary ─────────────────────────────────────────────────
# Prefer the explicit bbup install path; fall back to PATH
BB := $(HOME)/.bb/bb
ifeq ($(wildcard $(BB)),)
  BB := bb
endif

# Detect bb version — v5+ uses --output_format binary + --write_vk combined
# Older versions (0.x) need --output_format bytes_and_fields + separate bb write_vk
BB_MAJOR := $(shell $(BB) --version 2>/dev/null | head -1 | sed 's/[^0-9].*//' || echo 0)
ifeq ($(shell [ "$(BB_MAJOR)" -ge 5 ] && echo 1 || echo 0), 1)
  BB_USE_V5 := 1
else
  BB_USE_V5 := 0
endif

# ── Paths ──────────────────────────────────────────────────────────────────
MERKLE_DIR    := merkle
MERKLE_DATA   := merkle/merkle_data.json
DEMO_INPUTS   := demo_inputs.json
PROVER_TOML   := circuits/compliance/Prover.toml
CIRCUIT_DIR   := circuits/compliance
CIRCUIT_TARGET:= circuits/compliance/target
PROOFS_DIR    := proofs
PROOF_FILE    := proofs/compliance.proof
VK_FILE       := proofs/vk
PUBLIC_INPUTS_FILE := proofs/public_inputs

# ── Default: run everything ───────────────────────────────────────────────
all: check-deps merkle-deps merkle-data circuit-proof

# ── Prerequisite checks ───────────────────────────────────────────────────
check-deps: check-versions
	@echo "=== Checking prerequisites ==="
	@command -v node >/dev/null 2>&1 || { echo "Missing: node (Node.js 18+)"; exit 1; }
	@command -v nargo >/dev/null 2>&1 || { echo "Missing: nargo (run noirup)"; exit 1; }
	@$(BB) --version >/dev/null 2>&1 || { echo "Missing: barretenberg bb (run bbup)"; exit 1; }
	@echo "  All prerequisites found."

# ── Check tool versions match what verifier expects ───────────────────────
check-versions:
	@echo "=== Checking tool versions ==="
	@BB_VER=$$($(BB) --version 2>/dev/null | head -1); \
	 echo "  bb: $$BB_VER"; \
	 if echo "$$BB_VER" | grep -q "^$(BB_REQUIRED)"; then \
	   echo "    -> compatible with verifier ✓"; \
	 else \
	   echo "    -> required: $(BB_REQUIRED) (run: make setup-versions)"; \
	   [ "$(BB_USE_V5)" = "1" ] && { echo "    -> WARNING: bb v5 proof format not supported by on-chain verifier!"; } || true; \
	 fi
	@NARGO_VER=$$(nargo --version 2>/dev/null | head -1); \
	 echo "  nargo: $$NARGO_VER"; \
	 if echo "$$NARGO_VER" | grep -q "$(NARGO_REQUIRED)"; then \
	   echo "    -> compatible ✓"; \
	 else \
	   echo "    -> required: $(NARGO_REQUIRED) (run: make setup-versions)"; \
	 fi

# ── Install required tool versions ────────────────────────────────────────
setup-versions:
	@echo "=== Installing required tool versions ==="
	@echo "  Installing bb $(BB_REQUIRED)..."
	bbup -v "$(BB_REQUIRED)"
	@echo "  Installing nargo $(NARGO_REQUIRED)..."
	noirup -v "$(NARGO_REQUIRED)"
	@echo "  Done. Run 'make check-versions' to verify."

check-stellar:
	@command -v stellar >/dev/null 2>&1 || { echo "Missing: stellar CLI (cargo install stellar-cli --locked)"; exit 1; }

# ── Install Merkle Node.js deps ────────────────────────────────────────────
merkle-deps:
	@echo "=== Installing Merkle dependencies ==="
	@if [ ! -d "$(MERKLE_DIR)/node_modules" ]; then \
		cd "$(MERKLE_DIR)" && npm install --silent; \
	else \
		echo "  node_modules exists, skipping."; \
	fi

# ── Build Merkle trees + generate demo_inputs.json ────────────────────────
$(MERKLE_DATA) $(DEMO_INPUTS): merkle-deps
	@echo "=== Building Merkle trees ==="
	cd "$(MERKLE_DIR)" && node build_tree.js

merkle-data: $(MERKLE_DATA)

# ── Generate Prover.toml ──────────────────────────────────────────────────
$(PROVER_TOML): $(MERKLE_DATA)
	@echo "=== Generating Prover.toml ==="
	node scripts/generate_prover_toml.js

prover-toml: $(PROVER_TOML)

# ── Compile circuit, generate UltraHonk proof + VK, verify locally ────────
$(PROOF_FILE) $(VK_FILE) $(PUBLIC_INPUTS_FILE): $(PROVER_TOML)
	@echo "=== Compiling circuit ==="
	cd "$(CIRCUIT_DIR)" && nargo check && nargo compile && nargo execute
	@echo "=== Generating UltraHonk proof ==="
	mkdir -p "$(PROOFS_DIR)"
ifeq ($(BB_USE_V5),1)
	$(BB) prove \
		--scheme ultra_honk \
		--oracle_hash keccak \
		--bytecode_path "$(CIRCUIT_TARGET)/compliance.json" \
		--witness_path "$(CIRCUIT_TARGET)/compliance.gz" \
		--output_path "$(CIRCUIT_TARGET)" \
		--output_format binary \
		--write_vk
else
	$(BB) prove \
		--scheme ultra_honk \
		--oracle_hash keccak \
		--bytecode_path "$(CIRCUIT_TARGET)/compliance.json" \
		--witness_path "$(CIRCUIT_TARGET)/compliance.gz" \
		--output_path "$(CIRCUIT_TARGET)" \
		--output_format bytes_and_fields
	$(BB) write_vk \
		--scheme ultra_honk \
		--oracle_hash keccak \
		--bytecode_path "$(CIRCUIT_TARGET)/compliance.json" \
		--output_path "$(CIRCUIT_TARGET)" \
		--output_format bytes_and_fields
endif
	@# Flatten nested output dirs from bb (same as rs-soroban-ultrahonk)
	@if [ -d "$(CIRCUIT_TARGET)/vk/vk" ]; then \
		mv "$(CIRCUIT_TARGET)/vk/vk" "$(CIRCUIT_TARGET)/vk.tmp"; \
		rm -rf "$(CIRCUIT_TARGET)/vk"; \
		mv "$(CIRCUIT_TARGET)/vk.tmp" "$(CIRCUIT_TARGET)/vk"; \
	fi
	cp "$(CIRCUIT_TARGET)/proof" "$(PROOF_FILE)"
	cp "$(CIRCUIT_TARGET)/public_inputs" "$(PUBLIC_INPUTS_FILE)"
	cp "$(CIRCUIT_TARGET)/vk" "$(VK_FILE)"
	@echo "=== Local verification ==="
ifeq ($(BB_USE_V5),1)
	$(BB) verify \
		--scheme ultra_honk \
		--oracle_hash keccak \
		-p "$(CIRCUIT_TARGET)/proof" \
		-k "$(CIRCUIT_TARGET)/vk" \
		-i "$(CIRCUIT_TARGET)/public_inputs"
else
	$(BB) verify \
		--scheme ultra_honk \
		--oracle_hash keccak \
		--proof_path "$(CIRCUIT_TARGET)/proof" \
		--verification_key_path "$(CIRCUIT_TARGET)/vk" \
		--public_inputs_path "$(CIRCUIT_TARGET)/public_inputs"
endif
	@echo ""
	@echo "Proof generated successfully!"
	@echo "  Proof:         $(PROOF_FILE)"
	@echo "  Public inputs: $(PUBLIC_INPUTS_FILE)"
	@echo "  VK:            $(VK_FILE)"

circuit-proof: $(PROOF_FILE)

# ── Deploy contract to Stellar testnet ─────────────────────────────────────
deploy: check-stellar
	@echo "=== Deploying Soroban contract ==="
	bash scripts/deploy_contract.sh

# ── Submit proof to deployed contract ─────────────────────────────────────
submit: check-stellar
	@echo "=== Submitting proof on-chain ==="
	bash scripts/submit_proof.sh

# ── Clean generated artifacts ─────────────────────────────────────────────
clean:
	@echo "=== Cleaning ==="
	rm -rf "$(CIRCUIT_TARGET)"
	rm -rf "$(PROOFS_DIR)"
	rm -f "$(MERKLE_DATA)"
	rm -f "$(DEMO_INPUTS)"
	rm -f "$(PROVER_TOML)"
	@echo "  Done."
