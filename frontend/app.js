/**
 * ZK Remittance Frontend
 *
 * Connects Freighter wallet and submits pre-generated UltraHonk proofs
 * to the Soroban compliance verifier contract.
 *
 * Note: Full ZK proof generation requires nargo + bb CLI (see README).
 * This UI handles on-chain verification only.
 */

import {
  Contract,
  rpc,
  TransactionBuilder,
  Networks,
  BASE_FEE,
  nativeToScVal,
} from "https://cdn.jsdelivr.net/npm/@stellar/stellar-sdk@13.0.0/+esm";

import {
  isConnected,
  requestAccess,
  getPublicKey,
  signTransaction,
} from "https://cdn.jsdelivr.net/npm/@stellar/freighter-api@5.0.0/+esm";

const TESTNET_RPC = "https://soroban-testnet.stellar.org";
const TESTNET_PASSPHRASE = Networks.TESTNET;

const els = {
  connectWallet: document.getElementById("connectWallet"),
  form: document.getElementById("complianceForm"),
  address: document.getElementById("address"),
  amount: document.getElementById("amount"),
  jurisdiction: document.getElementById("jurisdiction"),
  contractId: document.getElementById("contractId"),
  proofFile: document.getElementById("proofFile"),
  publicInputsFile: document.getElementById("publicInputsFile"),
  loadDemo: document.getElementById("loadDemo"),
  submitBtn: document.getElementById("submitBtn"),
  status: document.getElementById("status"),
  result: document.getElementById("result"),
};

let walletPublicKey = null;
let proofBytes = null;
let publicInputsBytes = null;

function showStatus(msg, isError = false) {
  els.status.textContent = msg;
  els.status.classList.remove("hidden");
  els.status.style.borderColor = isError ? "var(--error)" : "var(--purple)";
}

function showResult(success, msg) {
  els.result.textContent = msg;
  els.result.className = `result ${success ? "success" : "error"}`;
  els.result.classList.remove("hidden");
}

function updateSubmitState() {
  const ready =
    walletPublicKey &&
    els.contractId.value.trim() &&
    proofBytes &&
    publicInputsBytes;
  els.submitBtn.disabled = !ready;
}

async function connectFreighter() {
  try {
    const connected = await isConnected();
    if (!connected) {
      await requestAccess();
    }
    walletPublicKey = await getPublicKey();
    els.connectWallet.textContent = `${walletPublicKey.slice(0, 4)}…${walletPublicKey.slice(-4)}`;
    if (!els.address.value) {
      els.address.value = walletPublicKey;
    }
    showStatus(`Wallet connected: ${walletPublicKey}`);
    updateSubmitState();
  } catch (err) {
    showStatus(`Freighter error: ${err.message}`, true);
  }
}

async function readFileAsBytes(input) {
  const file = input.files?.[0];
  if (!file) return null;
  const buffer = await file.arrayBuffer();
  return new Uint8Array(buffer);
}

async function fetchArtifact(path) {
  const resp = await fetch(path);
  if (!resp.ok) throw new Error(`Failed to load ${path}`);
  return new Uint8Array(await resp.arrayBuffer());
}

async function loadDemoArtifacts() {
  showStatus("Loading demo proof artifacts…");
  try {
    proofBytes = await fetchArtifact("../proofs/compliance.proof");
    publicInputsBytes = await fetchArtifact("../proofs/public_inputs");

    // Load demo inputs for form prefill
    const demoResp = await fetch("../demo_inputs.json");
    if (demoResp.ok) {
      const demo = await demoResp.json();
      els.amount.value = demo.amount;
      els.jurisdiction.value = demo.jurisdiction || "PK";
    }

    // Try loading contract ID from env hint file
    showStatus("Demo artifacts loaded. Set contract ID and connect wallet.");
    updateSubmitState();
  } catch (err) {
    showStatus(
      `Demo artifacts not found. Run ./scripts/generate_proof.sh first. (${err.message})`,
      true
    );
  }
}

/**
 * Build and submit verify_compliance contract call via Freighter.
 */
async function submitProof(e) {
  e.preventDefault();
  els.result.classList.add("hidden");

  const contractId = els.contractId.value.trim();
  if (!contractId || !proofBytes || !publicInputsBytes) {
    showResult(false, "❌ Missing contract ID or proof files");
    return;
  }

  showStatus("Building transaction…");
  els.submitBtn.disabled = true;

  try {
    const server = new rpc.Server(TESTNET_RPC);

    const sourceAccount = await server.getAccount(walletPublicKey);

    const contract = new Contract(contractId);

    const operation = contract.call(
      "verify_compliance",
      nativeToScVal(proofBytes, { type: "bytes" }),
      nativeToScVal(publicInputsBytes, { type: "bytes" })
    );

    let tx = new TransactionBuilder(sourceAccount, {
      fee: BASE_FEE,
      networkPassphrase: TESTNET_PASSPHRASE,
    })
      .addOperation(operation)
      .setTimeout(300)
      .build();

    // Simulate to get resource fees
    showStatus("Simulating transaction…");
    const simulated = await server.simulateTransaction(tx);

    if (rpc.Api.isSimulationError(simulated)) {
      throw new Error(simulated.error || "Simulation failed");
    }

    tx = rpc.assembleTransaction(tx, simulated).build();

    showStatus("Sign with Freighter…");
    const signedXdr = await signTransaction(tx.toXDR(), {
      networkPassphrase: TESTNET_PASSPHRASE,
      accountToSign: walletPublicKey,
    });

    if (signedXdr.error) {
      throw new Error(signedXdr.error);
    }

    const signedTx = TransactionBuilder.fromXDR(
      signedXdr.signedTxXdr,
      TESTNET_PASSPHRASE
    );

    showStatus("Submitting to Stellar testnet…");
    const sendResult = await server.sendTransaction(signedTx);

    if (sendResult.status === "PENDING") {
      showStatus("Waiting for confirmation…");
      let getResult = await server.getTransaction(sendResult.hash);
      while (getResult.status === "NOT_FOUND") {
        await new Promise((r) => setTimeout(r, 1000));
        getResult = await server.getTransaction(sendResult.hash);
      }

      if (getResult.status === "SUCCESS") {
        showResult(true, "✅ Compliant — Transaction Approved");
        showStatus(`Tx hash: ${sendResult.hash}`);
      } else {
        throw new Error(`Transaction failed: ${getResult.status}`);
      }
    } else {
      throw new Error(`Send failed: ${sendResult.status}`);
    }
  } catch (err) {
    console.error(err);
    showResult(false, `❌ Rejected — ${err.message}`);
    showStatus(err.message, true);
  } finally {
    updateSubmitState();
  }
}

// Event listeners
els.connectWallet.addEventListener("click", connectFreighter);
els.loadDemo.addEventListener("click", loadDemoArtifacts);
els.proofFile.addEventListener("change", async () => {
  proofBytes = await readFileAsBytes(els.proofFile);
  updateSubmitState();
});
els.publicInputsFile.addEventListener("change", async () => {
  publicInputsBytes = await readFileAsBytes(els.publicInputsFile);
  updateSubmitState();
});
els.contractId.addEventListener("input", updateSubmitState);
els.form.addEventListener("submit", submitProof);

// Auto-connect if Freighter already authorized
isConnected().then((c) => {
  if (c) connectFreighter();
});
