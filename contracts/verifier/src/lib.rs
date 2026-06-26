#![no_std]

//! ZK Remittance Compliance Verifier — Soroban Smart Contract
//!
//! Verifies UltraHonk ZK proofs from the compliance Noir circuit and tracks
//! nullifiers to prevent proof replay. Based on rs-soroban-ultrahonk PR#26
//! (bb v5 / protocol 25 compatible).

use soroban_sdk::{
    contract, contracterror, contractevent, contractimpl, symbol_short, Bytes, BytesN, Env, Map,
    Symbol,
};
use ultrahonk_soroban_verifier::{verifier::VerifyError, SorobanEc, UltraHonkVerifier};

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
    /// VK byte slice does not match expected length or parameters.
    VkInvalid = 1,
    /// Cryptographic verification failed.
    InvalidProof = 2,
    /// No VK has been stored in contract instance storage.
    VkNotSet = 3,
    /// Constructor has already been called; VK is immutable.
    AlreadyInitialized = 4,
    /// Public inputs buffer has wrong length for this circuit.
    InvalidPublicInputs = 5,
    /// Nullifier has already been consumed (replay attempt).
    NullifierAlreadyUsed = 6,
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
        let _ = UltraHonkVerifier::new(&env, &vk_bytes).map_err(|_| Error::VkInvalid)?;
        env.storage().instance().set(&Self::key_vk(), &vk_bytes);
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
    fn extract_nullifier(public_inputs: &Bytes) -> Result<BytesN<32>, Error> {
        let expected_len = (NUM_PUBLIC_INPUTS * FIELD_BYTES) as usize;
        if public_inputs.len() as usize != expected_len {
            return Err(Error::InvalidPublicInputs);
        }
        let offset = (NULLIFIER_INDEX * FIELD_BYTES) as u32;
        let slice = public_inputs.slice(offset..offset + FIELD_BYTES);
        let mut arr = [0u8; 32];
        slice.copy_into_slice(&mut arr);
        Ok(BytesN::from_array(arr))
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
        let nullifier = Self::extract_nullifier(&public_inputs)?;

        let mut map = Self::nullifiers(&env);
        if map.get(nullifier.clone()).unwrap_or(false) {
            return Err(Error::NullifierAlreadyUsed);
        }

        let vk_bytes: Bytes = env
            .storage()
            .instance()
            .get(&Self::key_vk())
            .ok_or(Error::VkNotSet)?;

        let verifier = UltraHonkVerifier::new(&env, &vk_bytes).map_err(|_| Error::VkInvalid)?;

        verifier
            .verify(&proof_bytes, &public_inputs)
            .map_err(|_| Error::InvalidProof)?;

        map.set(nullifier.clone(), true);
        Self::set_nullifiers(&env, map);

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
