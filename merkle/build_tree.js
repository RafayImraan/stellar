#!/usr/bin/env node
/**
 * build_tree.js — Merkle tree builder for ZK Remittance Compliance
 *
 * Builds two depth-8 arithmetic-hash Merkle trees:
 *   1. Sanctions list (sorted) — generates exclusion witnesses for non-members
 *   2. Allowed jurisdictions — generates membership witnesses
 *
 * Outputs merkle/merkle_data.json for proof generation scripts.
 */

import { writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import {
  hashPair,
  hashSingle,
  hexToField,
  fieldToDecimal,
  jurisdictionToField,
  addressToField,
  assertField,
  FIELD_MODULUS,
} from "./poseidon.mjs";

/** Upper-bound sentinel leaf for sorted sanctions exclusion proofs. */
const SENTINEL_MAX = FIELD_MODULUS - 1n;

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const TREE_DEPTH = 8;
const LEAF_COUNT = 2 ** TREE_DEPTH; // 256

// ── Hardcoded demo sanctions (20 fake address hashes as hex) ───────────────
const SANCTIONED_HEX = [
  "0x0000000000000000000000000000000000000000000000000000000000000DEAD",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD1",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD2",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD3",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD4",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD5",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD6",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD7",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD8",
  "0x0000000000000000000000000000000000000000000000000000000000000BAD9",
  "0x0000000000000000000000000000000000000000000000000000000000000BA01",
  "0x0000000000000000000000000000000000000000000000000000000000000BA02",
  "0x0000000000000000000000000000000000000000000000000000000000000BA03",
  "0x0000000000000000000000000000000000000000000000000000000000000BA04",
  "0x0000000000000000000000000000000000000000000000000000000000000BA05",
  "0x0000000000000000000000000000000000000000000000000000000000000BA06",
  "0x0000000000000000000000000000000000000000000000000000000000000BA07",
  "0x0000000000000000000000000000000000000000000000000000000000000BA08",
  "0x0000000000000000000000000000000000000000000000000000000000000BA09",
  "0x0000000000000000000000000000000000000000000000000000000000000BA10",
];

const ALLOWED_JURISDICTIONS = ["PK", "US", "GB", "AE", "SA", "DE", "FR", "CA", "AU", "SG"];

/**
 * Build a full binary Merkle tree from leaves (padded to LEAF_COUNT).
 * Returns { root, layers, leaves }.
 */
function buildMerkleTree(rawLeaves) {
  const leaves = new Array(LEAF_COUNT).fill(0n);
  for (let i = 0; i < rawLeaves.length && i < LEAF_COUNT; i++) {
    leaves[i] = assertField(rawLeaves[i]);
  }

  const layers = [leaves];
  let current = leaves;

  for (let d = 0; d < TREE_DEPTH; d++) {
    const next = [];
    for (let i = 0; i < current.length; i += 2) {
      next.push(hashPair(current[i], current[i + 1]));
    }
    layers.push(next);
    current = next;
  }

  return { root: current[0], layers, leaves };
}

/**
 * Generate Merkle proof for leaf at index.
 * indices[i] = 0 if current node is left child at level i.
 */
function getMerkleProof(layers, leafIndex) {
  const siblings = [];
  const indices = [];
  let idx = leafIndex;

  for (let level = 0; level < TREE_DEPTH; level++) {
    const layer = layers[level];
    const isRight = idx % 2 === 1;
    const siblingIdx = isRight ? idx - 1 : idx + 1;
    siblings.push(layer[siblingIdx] ?? 0n);
    indices.push(isRight ? "1" : "0");
    idx = Math.floor(idx / 2);
  }

  return { siblings, indices };
}

/**
 * Build sorted sanctions tree: sort unique sanctioned hashes, pad with zeros.
 */
function buildSanctionsTree() {
  const sanctioned = SANCTIONED_HEX.map(hexToField).sort((a, b) =>
    a < b ? -1 : a > b ? 1 : 0
  );
  // Sorted leaves: [0, ...sanctions..., SENTINEL_MAX, ...padding zeros]
  const sortedLeaves = [0n, ...sanctioned, SENTINEL_MAX];
  while (sortedLeaves.length < LEAF_COUNT) sortedLeaves.push(0n);

  return buildMerkleTree(sortedLeaves);
}

/**
 * Find exclusion witness (left, right neighbors) for target NOT in sorted leaves.
 */
function findExclusionWitness(leaves, target) {
  // Active sorted chain: 0, sanctions..., SENTINEL_MAX (zeros at tail ignored)
  const chain = leaves.filter((v, i) => v !== 0n || i === 0);
  const uniqueChain = [...new Set(chain.map((v) => v.toString()))].map((s) =>
    BigInt(s)
  );
  uniqueChain.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

  let left = 0n;
  let right = SENTINEL_MAX;

  for (let i = 0; i < uniqueChain.length - 1; i++) {
    if (uniqueChain[i] < target && target < uniqueChain[i + 1]) {
      left = uniqueChain[i];
      right = uniqueChain[i + 1];
      break;
    }
  }

  const leftIdx = leaves.findIndex((v) => v === left);
  const rightIdx = leaves.findIndex((v) => v === right);

  if (leftIdx < 0 || rightIdx < 0) {
    throw new Error(`Could not locate exclusion neighbors for target ${target}`);
  }

  return { left, right, leftIdx, rightIdx };
}

function formatProof(layers, leafIndex) {
  const { siblings, indices } = getMerkleProof(layers, leafIndex);
  return {
    siblings: siblings.map(fieldToDecimal),
    indices: indices.map(String),
  };
}

function main() {
  console.log("Building Merkle trees for ZK Remittance Compliance...\n");

  // ── Sanctions tree ──────────────────────────────────────────────────────
  const sanctions = buildSanctionsTree();
  console.log(`Sanctions root: ${fieldToDecimal(sanctions.root)}`);

  // Demo compliant sender (NOT in sanctions list)
  const demoAddress = "GCKFBEIYTKP6RQBQA5H4G2H5Q4H4G2H5Q4H4G2H5Q4H4G2H5Q4DEMO01";
  const senderHash = addressToField(demoAddress);
  console.log(`Demo sender hash: ${fieldToDecimal(senderHash)}`);

  const exclusion = findExclusionWitness(sanctions.leaves, senderHash);
  const leftProof = formatProof(sanctions.layers, exclusion.leftIdx);
  const rightProof = formatProof(sanctions.layers, exclusion.rightIdx);

  // ── Jurisdictions tree ──────────────────────────────────────────────────
  const jurisdictionFields = ALLOWED_JURISDICTIONS.map((code) =>
    jurisdictionToField(code)
  );
  const jurisTree = buildMerkleTree(jurisdictionFields);
  console.log(`Jurisdictions root: ${fieldToDecimal(jurisTree.root)}`);

  const demoJurisdiction = "PK";
  const demoJurisField = jurisdictionToField(demoJurisdiction);
  const jurisIdx = jurisTree.leaves.findIndex((v) => v === demoJurisField);
  const jurisProof = formatProof(jurisTree.layers, jurisIdx);

  // ── Demo secrets ────────────────────────────────────────────────────────
  const secret = 1234567890123456789012345678901234567890123456789012345678901234n;
  const nonce = 9876543210987654321098765432109876543210987654321098765432109876n;
  const nullifier = hashPair(secret, nonce);

  const output = {
    tree_depth: TREE_DEPTH,
    sanctions: {
      root: fieldToDecimal(sanctions.root),
      count: SANCTIONED_HEX.length,
      sanctioned_hashes: SANCTIONED_HEX,
      leaves: sanctions.leaves.map(fieldToDecimal),
    },
    jurisdictions: {
      root: fieldToDecimal(jurisTree.root),
      allowed: ALLOWED_JURISDICTIONS,
      leaf_fields: jurisdictionFields.map(fieldToDecimal),
    },
    demo: {
      address: demoAddress,
      sender_address_hash: fieldToDecimal(senderHash),
      amount: 50000,
      min_threshold: 100,
      max_threshold: 999999,
      jurisdiction: demoJurisdiction,
      jurisdiction_code: fieldToDecimal(demoJurisField),
      secret: fieldToDecimal(secret),
      nonce: fieldToDecimal(nonce),
      nullifier: fieldToDecimal(nullifier),
      exclusion: {
        left_neighbor: fieldToDecimal(exclusion.left),
        right_neighbor: fieldToDecimal(exclusion.right),
        left_siblings: leftProof.siblings,
        left_indices: leftProof.indices,
        right_siblings: rightProof.siblings,
        right_indices: rightProof.indices,
      },
      jurisdiction_proof: {
        siblings: jurisProof.siblings,
        indices: jurisProof.indices,
      },
    },
  };

  const outPath = join(__dirname, "merkle_data.json");
  writeFileSync(outPath, JSON.stringify(output, null, 2));
  console.log(`\nWrote ${outPath}`);

  // Also write demo_inputs.json at project root
  const demoPath = join(ROOT, "demo_inputs.json");
  writeFileSync(demoPath, JSON.stringify(output.demo, null, 2));
  console.log(`Wrote ${demoPath}`);

  return output;
}

main();
