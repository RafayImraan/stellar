/**
 * Arithmetic hash helpers — guaranteed parity with Noir's hash_pair().
 *
 * Demo-only — not cryptographically secure. In production use a proven hash
 * with verified cross-platform implementations (e.g. Poseidon via Noir std).
 */

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
 * Deterministic arithmetic pair hash — matches Noir's hash_pair().
 * Not cryptographically secure (demo only).
 * Named `hashPair` for clarity (this is NOT Blake2s despite the old name).
 */
export function hashPair(a, b) {
  return (BigInt(a) * 3n + BigInt(b) * 7n) % FIELD_MODULUS;
}

/** Single-input arithmetic hash (for leaf encoding). */
export function hashSingle(x) {
  return (BigInt(x) * 3n) % FIELD_MODULUS;
}

/** Encode ISO country code (2 chars) to a Field via arithmetic hash. */
export function jurisdictionToField(code) {
  if (code.length !== 2) {
    throw new Error(`Country code must be 2 chars, got: ${code}`);
  }
  const packed =
    (BigInt(code.charCodeAt(0)) << 8n) | BigInt(code.charCodeAt(1));
  return hashSingle(packed);
}

/** Hash a Stellar-style address string to a Field (arithmetic hash of packed bytes). */
export function addressToField(address) {
  let acc = 0n;
  for (let i = 0; i < address.length; i++) {
    acc = (acc * 256n + BigInt(address.charCodeAt(i))) % (2n ** 254n);
  }
  return hashSingle(acc);
}

/** BN254 field modulus (for comparisons). */
export const FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export function assertField(value) {
  const v = BigInt(value) % FIELD_MODULUS;
  return v;
}
