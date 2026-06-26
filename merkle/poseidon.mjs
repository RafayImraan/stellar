/**
 * Poseidon BN254 hash helpers matching Noir's poseidon::bn254::{hash_1, hash_2}.
 *
 * Uses circomlibjs Poseidon (BN254, t=3) which aligns with Barretenberg/Noir
 * field hashing for 1- and 2-element inputs.
 */

import { buildPoseidon } from "circomlibjs";

let _poseidon = null;

async function getPoseidon() {
  if (!_poseidon) {
    _poseidon = await buildPoseidon();
  }
  return _poseidon;
}

/** Convert bigint to decimal string (Noir Field literal format). */
export function fieldToDecimal(value) {
  return value.toString();
}

/** Convert hex string (0x...) to bigint. */
export function hexToField(hex) {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  return BigInt("0x" + clean);
}

/** Reduce to BN254 field element. */
export function toField(value) {
  const v = BigInt(value) % FIELD_MODULUS;
  return v;
}

/** hash_1([x]) — single input Poseidon hash. */
export async function hash1(x) {
  const poseidon = await getPoseidon();
  const out = poseidon([BigInt(x)]);
  return toField(poseidon.F.toObject(out));
}

/** hash_2([a, b]) — two-input Poseidon hash (Merkle parent). */
export async function hash2(a, b) {
  const poseidon = await getPoseidon();
  const out = poseidon([BigInt(a), BigInt(b)]);
  return toField(poseidon.F.toObject(out));
}

/** Encode ISO country code (2 chars) to a Field via Poseidon hash. */
export async function jurisdictionToField(code) {
  if (code.length !== 2) {
    throw new Error(`Country code must be 2 chars, got: ${code}`);
  }
  const packed =
    (BigInt(code.charCodeAt(0)) << 8n) | BigInt(code.charCodeAt(1));
  return hash1(packed);
}

/** Hash a Stellar-style address string to a Field (demo: hash the UTF-8 bytes). */
export async function addressToField(address) {
  // Pack address into field chunks and hash — simplified for demo
  let acc = 0n;
  for (let i = 0; i < address.length; i++) {
    acc = (acc * 256n + BigInt(address.charCodeAt(i))) % (2n ** 254n);
  }
  return hash1(acc);
}

/** BN254 field modulus (for comparisons). */
export const FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export function assertField(value) {
  const v = BigInt(value) % FIELD_MODULUS;
  return v;
}
