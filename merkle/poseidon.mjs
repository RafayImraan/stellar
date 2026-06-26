/**
 * Hash helpers matching Noir's std::hash::blake2s-based Merkle tree hashing.
 *
 * Uses Node.js crypto BLAKE2s (guaranteed parity with Noir circuit).
 */

import { createHash } from "crypto";

/** Convert bigint to 32-byte big-endian Uint8Array (matches Noir's to_be_bytes()). */
function bigintToBytes32(n) {
  const hex = n.toString(16).padStart(64, "0");
  return new Uint8Array(Buffer.from(hex, "hex"));
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

/**
 * BLAKE2s-based pair hash — concatenate two field elements as 32-byte BE,
 * hash with BLAKE2s, convert result back to Field.
 * Matches Noir's hash_pair() in the compliance circuit (std::hash::blake2s).
 */
export function blake2sPair(a, b) {
  const aBytes = bigintToBytes32(BigInt(a));
  const bBytes = bigintToBytes32(BigInt(b));
  const combined = new Uint8Array(64);
  combined.set(aBytes, 0);
  combined.set(bBytes, 32);
  const hash = createHash("BLAKE2s-256").update(Buffer.from(combined)).digest();
  return BigInt("0x" + hash.toString("hex")) % FIELD_MODULUS;
}

/** BLAKE2s-based single-input hash (for leaf encoding). */
export function blake2sSingle(x) {
  const bytes = bigintToBytes32(BigInt(x));
  const hash = createHash("BLAKE2s-256").update(Buffer.from(bytes)).digest();
  return BigInt("0x" + hash.toString("hex")) % FIELD_MODULUS;
}

/** Encode ISO country code (2 chars) to a Field via BLAKE2s. */
export function jurisdictionToField(code) {
  if (code.length !== 2) {
    throw new Error(`Country code must be 2 chars, got: ${code}`);
  }
  const packed =
    (BigInt(code.charCodeAt(0)) << 8n) | BigInt(code.charCodeAt(1));
  return blake2sSingle(packed);
}

/** Hash a Stellar-style address string to a Field (BLAKE2s of packed bytes). */
export function addressToField(address) {
  let acc = 0n;
  for (let i = 0; i < address.length; i++) {
    acc = (acc * 256n + BigInt(address.charCodeAt(i))) % (2n ** 254n);
  }
  return blake2sSingle(acc);
}

/** BN254 field modulus (for comparisons). */
export const FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export function assertField(value) {
  const v = BigInt(value) % FIELD_MODULUS;
  return v;
}
