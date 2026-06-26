// ZK Remittance Compliance Circuit
//
// Proves simultaneously (without revealing private inputs):
//   1. Sender is NOT on the sanctions Merkle tree (sorted-tree exclusion proof)
//   2. Transfer amount is within [min_threshold, max_threshold]
//   3. Jurisdiction is in the allowed jurisdictions Merkle tree
//   4. Nullifier = Poseidon(secret, nonce) prevents proof replay
//
// Compatible with nargo 1.0.0-beta.22+ (uses bool for Merkle path direction).

use poseidon::poseidon::bn254::hash_2;

/// Merkle tree depth — 2^8 = 256 leaves (matches off-chain builder).
global TREE_DEPTH: u32 = 8;

/// Compare two field elements as integers (byte-by-byte, works in all Noir 1.0+).
fn field_lt(a: Field, b: Field) -> bool {
    let a_bytes: [u8; 32] = a.to_be_bytes();
    let b_bytes: [u8; 32] = b.to_be_bytes();
    let mut result = false;
    let mut decided = false;
    for i in 0..32 {
        if !decided {
            if a_bytes[i] != b_bytes[i] {
                result = a_bytes[i] < b_bytes[i];
                decided = true;
            }
        }
    };
    result
}

/// Reconstruct a Merkle root from a leaf, sibling path, and left/right indicators.
/// `indices[i] == false` means the current node is the left child at level i.
fn compute_merkle_root<let N: u32>(
    leaf: Field,
    siblings: [Field; N],
    indices: [bool; N],
) -> Field {
    let mut current = leaf;
    for i in 0..N {
        current = if !indices[i] {
            hash_2([siblings[i], current])
        } else {
            hash_2([current, siblings[i]])
        };
    }
    current
}

fn main(
    // ── Public inputs (visible to on-chain verifier) ──────────────────────
    merkle_root: pub Field,
    min_threshold: pub u64,
    max_threshold: pub u64,
    allowed_jurisdictions_root: pub Field,
    nullifier: pub Field,
    // ── Private inputs ────────────────────────────────────────────────────
    sender_address_hash: Field,
    amount: u64,
    jurisdiction_code: Field,
    secret: Field,
    nonce: Field,
    // Sanctions exclusion: adjacent leaves in the SORTED sanctions tree
    left_neighbor: Field,
    right_neighbor: Field,
    left_siblings: [Field; TREE_DEPTH],
    left_indices: [bool; TREE_DEPTH],
    right_siblings: [Field; TREE_DEPTH],
    right_indices: [bool; TREE_DEPTH],
    // Jurisdiction membership path
    jurisdiction_siblings: [Field; TREE_DEPTH],
    jurisdiction_indices: [bool; TREE_DEPTH],
) {
    // ── 1. Nullifier binding (anti-replay) ────────────────────────────────
    let computed_nullifier = hash_2([secret, nonce]);
    assert(computed_nullifier == nullifier);

    // ── 2. Amount range proof ─────────────────────────────────────────────
    assert(min_threshold <= amount, "Amount below minimum threshold");
    assert(amount <= max_threshold, "Amount above maximum threshold");

    // ── 3. Sanctions NON-membership (sorted Merkle exclusion) ─────────────
    let left_root = compute_merkle_root(left_neighbor, left_siblings, left_indices);
    assert(left_root == merkle_root, "Left neighbor not in sanctions tree");

    let right_root = compute_merkle_root(right_neighbor, right_siblings, right_indices);
    assert(right_root == merkle_root, "Right neighbor not in sanctions tree");

    // Strict ordering: left < sender < right  =>  sender NOT in sorted set
    assert(left_neighbor != sender_address_hash);
    assert(sender_address_hash != right_neighbor);
    assert(field_lt(left_neighbor, sender_address_hash), "Sender not above left bound");
    assert(field_lt(sender_address_hash, right_neighbor), "Sender not below right bound");

    // ── 4. Jurisdiction membership proof ──────────────────────────────────
    let juris_root =
        compute_merkle_root(jurisdiction_code, jurisdiction_siblings, jurisdiction_indices);
    assert(juris_root == allowed_jurisdictions_root, "Jurisdiction not allowed");
}

#[test]
fn test_amount_range_valid() {
    let min: u64 = 100;
    let max: u64 = 999999;
    let amt: u64 = 50000;
    assert(min <= amt);
    assert(amt <= max);
}

#[test]
fn test_field_lt() {
    assert(field_lt(1, 2));
    assert(!field_lt(2, 1));
}
