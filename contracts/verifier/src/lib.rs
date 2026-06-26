#![no_std]

//! ZK Remittance Compliance Verifier — Soroban Smart Contract
//!
//! Verifies UltraHonk ZK proofs from the compliance Noir circuit and tracks
//! nullifiers to prevent proof replay. Based on rs-soroban-ultrahonk patterns.

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, symbol_short, Bytes, BytesN, Env, Map,
    Symbol,
};
use ultrahonk_soroban_verifier::{UltraHonkVerifier, VkLoadError, PROOF_BYTES};

/// Number of public inputs in the compliance circuit (must match circuit order).
const NUM_PUBLIC_INPUTS: u32 = 5;
/// Each BN254 field element is serialized as 32 bytes in UltraHonk public inputs.
const FIELD_BYTES: u32 = 32;
/// Index of the nullifier in the public inputs array (0-based).
const NULLIFIER_INDEX: u32 = 4;

#[contract]
pub struct ComplianceVerifier;

#[contracterror]
#[repr(u32)]
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Error {
    /// VK byte slice does not match the expected exact length.
    VkInvalidLength = 1,
    /// VK header contains out-of-range structural parameters.
    VkInvalidParameters = 2,
    /// Proof byte slice does not match the expected exact length.
    ProofParseError = 3,
    /// Cryptographic verification failed.
    InvalidProof = 4,
    /// No VK has been stored in contract instance storage.
    VkNotSet = 5,
    /// Constructor has already been called; VK is immutable.
    AlreadyInitialized = 6,
    /// Public inputs buffer has wrong length for this circuit.
    InvalidPublicInputs = 7,
    /// Nullifier has already been consumed (replay attempt).
    NullifierAlreadyUsed = 8,
}

/// Emitted when a compliance proof is successfully verified.
#[contractevent]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComplianceVerified {
    pub nullifier: BytesN<32>,
    pub timestamp: u64,
}

#[contractimpl]
impl ComplianceVerifier {
    fn key_vk() -> Symbol {
        symbol_short!("vk")
    }

    fn key_nullifiers() -> Symbol {
        symbol_short!("nulls")
    }

    /// Initialize the contract with the UltraHonk verification key (immutable after deploy).
    pub fn __constructor(env: Env, vk_bytes: Bytes) -> Result<(), Error> {
        if env.storage().instance().has(&Self::key_vk()) {
            return Err(Error::AlreadyInitialized);
        }
        let _ = UltraHonkVerifier::new(&env, &vk_bytes).map_err(|e| match e {
            VkLoadError::WrongLength => Error::VkInvalidLength,
            VkLoadError::InvalidParameters => Error::VkInvalidParameters,
        })?;
        env.storage().instance().set(&Self::key_vk(), &vk_bytes);
        // Nullifier set stored in instance storage (demo-friendly, no TTL bump needed)
        let nullifiers: Map<BytesN<32>, bool> = Map::new(&env);
        env.storage().instance().set(&Self::key_nullifiers(), &nullifiers);
        Ok(())
    }

    /// Return stored VK bytes for auditability.
    pub fn vk_bytes(env: Env) -> Result<Bytes, Error> {
        env.storage()
            .instance()
            .get(&Self::key_vk())
            .ok_or(Error::VkNotSet)
    }

    /// Extract the nullifier field (32 bytes) from serialized public inputs.
    fn extract_nullifier(env: &Env, public_inputs: &Bytes) -> Result<BytesN<32>, Error> {
        let expected_len = (NUM_PUBLIC_INPUTS * FIELD_BYTES) as usize;
        if public_inputs.len() as usize != expected_len {
            return Err(Error::InvalidPublicInputs);
        }
        let offset = (NULLIFIER_INDEX * FIELD_BYTES) as u32;
        let slice = public_inputs.slice(offset..offset + FIELD_BYTES);
        let mut arr = [0u8; 32];
        slice.copy_into_slice(&mut arr);
        Ok(BytesN::from_array(&env, &arr))
    }

    fn nullifiers(env: &Env) -> Map<BytesN<32>, bool> {
        env.storage()
            .instance()
            .get(&Self::key_nullifiers())
            .unwrap_or_else(|| Map::new(env))
    }

    fn set_nullifiers(env: &Env, map: Map<BytesN<32>, bool>) {
        env.storage().instance().set(&Self::key_nullifiers(), &map);
    }

    /// Verify a compliance ZK proof and record the nullifier to prevent replay.
    ///
    /// Returns `true` on success. Rejects if proof is invalid or nullifier was used.
    pub fn verify_compliance(
        env: Env,
        proof_bytes: Bytes,
        public_inputs: Bytes,
    ) -> Result<bool, Error> {
        if proof_bytes.len() as usize != PROOF_BYTES {
            return Err(Error::ProofParseError);
        }

        let nullifier = Self::extract_nullifier(&env, &public_inputs)?;

        // Replay protection
        let mut map = Self::nullifiers(&env);
        if map.get(nullifier.clone()).unwrap_or(false) {
            return Err(Error::NullifierAlreadyUsed);
        }

        let vk_bytes: Bytes = env
            .storage()
            .instance()
            .get(&Self::key_vk())
            .ok_or(Error::VkNotSet)?;

        let verifier = UltraHonkVerifier::new(&env, &vk_bytes).map_err(|e| match e {
            VkLoadError::WrongLength => Error::VkInvalidLength,
            VkLoadError::InvalidParameters => Error::VkInvalidParameters,
        })?;

        verifier
            .verify(&env, &proof_bytes, &public_inputs)
            .map_err(|_| Error::InvalidProof)?;

        // Mark nullifier as used
        map.set(nullifier.clone(), true);
        Self::set_nullifiers(&env, map);

        // Emit compliance event
        ComplianceVerified {
            nullifier,
            timestamp: env.ledger().timestamp(),
        }
        .publish(&env);

        Ok(true)
    }

    /// Query whether a nullifier has already been used (compliance recorded).
    pub fn is_compliant(env: Env, nullifier: BytesN<32>) -> bool {
        Self::nullifiers(&env)
            .get(nullifier)
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use soroban_sdk::testutils::Ledger as _;

    #[test]
    fn rejects_invalid_public_input_length() {
        let env = Env::default();
        env.mock_all_auths();
        let bad_inputs = Bytes::from_slice(&env, &[0u8; 64]);
        let proof = Bytes::from_slice(&env, &[0u8; PROOF_BYTES]);
        // Without VK set, we won't reach verify — test extract via verify_compliance path
        let result = ComplianceVerifier::verify_compliance(env, proof, bad_inputs);
        assert_eq!(result, Err(Error::InvalidPublicInputs));
    }
}
