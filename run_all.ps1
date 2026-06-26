param(
    [ValidateSet("all", "deps", "merkle", "prover-toml", "proof", "deploy", "submit", "clean")]
    [string]$Target = "all"
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$MerkleDir = "$Root\merkle"
$CircuitDir = "$Root\circuits\compliance"
$CircuitTarget = "$CircuitDir\target"
$ProofsDir = "$Root\proofs"
$ProofFile = "$ProofsDir\compliance.proof"
$VkFile = "$ProofsDir\vk"
$PublicInputsFile = "$ProofsDir\public_inputs"

function Step($msg) {
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function CheckDeps {
    Step "Checking prerequisites"
    $missing = @()
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { $missing += "node" }
    if (-not (Get-Command nargo -ErrorAction SilentlyContinue)) { $missing += "nargo" }
    if (-not (Get-Command bb -ErrorAction SilentlyContinue)) { $missing += "bb" }
    if (-not (Get-Command stellar -ErrorAction SilentlyContinue)) { $missing += "stellar" }
    if ($missing.Count -gt 0) {
        Write-Host "Missing: $($missing -join ', ')" -ForegroundColor Red
        exit 1
    }
    Write-Host "  All prerequisites found." -ForegroundColor Green
}

function MerkleDeps {
    Step "Installing Merkle dependencies"
    if (-not (Test-Path "$MerkleDir\node_modules")) {
        Push-Location $MerkleDir
        npm install --silent
        Pop-Location
    } else {
        Write-Host "  node_modules exists, skipping."
    }
}

function MerkleData {
    Step "Building Merkle trees"
    Push-Location $MerkleDir
    node build_tree.js
    Pop-Location
}

function ProverToml {
    Step "Generating Prover.toml"
    node "$Root\scripts\generate_prover_toml.js"
}

function CircuitProof {
    Step "Compiling circuit"
    Push-Location $CircuitDir
    nargo check
    nargo compile
    nargo execute
    Pop-Location

    $Bytecode = "$CircuitTarget\compliance.json"
    $Witness = "$CircuitTarget\compliance.gz"
    if (-not (Test-Path $Bytecode) -or -not (Test-Path $Witness)) {
        Write-Host "Missing circuit artifacts" -ForegroundColor Red
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $ProofsDir | Out-Null

    Step "Detecting bb version"
    $BB_MAJOR = (bb --version | Select-Object -First 1) -replace '[^0-9].*', ''
    if (-not $BB_MAJOR) { $BB_MAJOR = 0 }
    Write-Host "  bb major version: $BB_MAJOR"

    Step "Generating UltraHonk proof + VK"
    if ([int]$BB_MAJOR -ge 5) {
        bb prove --scheme ultra_honk --oracle_hash keccak `
            --bytecode_path $Bytecode --witness_path $Witness `
            --output_path $CircuitTarget --output_format binary --write_vk
    } else {
        bb prove --scheme ultra_honk --oracle_hash keccak `
            --bytecode_path $Bytecode --witness_path $Witness `
            --output_path $CircuitTarget --output_format bytes_and_fields
        bb write_vk --scheme ultra_honk --oracle_hash keccak `
            --bytecode_path $Bytecode --output_path $CircuitTarget `
            --output_format bytes_and_fields
    }

    # Flatten nested output dirs from bb (same as rs-soroban-ultrahonk)
    if (Test-Path "$CircuitTarget/vk/vk") {
        Move-Item "$CircuitTarget/vk/vk" "$CircuitTarget/vk.tmp" -Force
        Remove-Item "$CircuitTarget/vk" -Recurse -Force
        Move-Item "$CircuitTarget/vk.tmp" "$CircuitTarget/vk" -Force
    }

    Copy-Item "$CircuitTarget\proof" $ProofFile -Force
    Copy-Item "$CircuitTarget\public_inputs" $PublicInputsFile -Force
    Copy-Item "$CircuitTarget\vk" $VkFile -Force

    Step "Local verification"
    bb verify --scheme ultra_honk --oracle_hash keccak `
        -p "$CircuitTarget\proof" -k "$CircuitTarget\vk" -i "$CircuitTarget\public_inputs"

    Write-Host "`nProof generated successfully!" -ForegroundColor Green
    Write-Host "  Proof:         $ProofFile"
    Write-Host "  Public inputs: $PublicInputsFile"
    Write-Host "  VK:            $VkFile"
}

function Deploy {
    Step "Deploying Soroban contract"
    # Requires Git Bash or WSL in PATH for .sh scripts
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        bash "$Root\scripts\deploy_contract.sh"
    } else {
        Write-Host "bash not found — run deploy_contract.sh in Git Bash/WSL" -ForegroundColor Yellow
    }
}

function Submit {
    Step "Submitting proof on-chain"
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        bash "$Root\scripts\submit_proof.sh"
    } else {
        Write-Host "bash not found — run submit_proof.sh in Git Bash/WSL" -ForegroundColor Yellow
    }
}

function Clean {
    Step "Cleaning generated artifacts"
    if (Test-Path $CircuitTarget) { Remove-Item -Recurse -Force $CircuitTarget }
    if (Test-Path $ProofsDir) { Remove-Item -Recurse -Force $ProofsDir }
    if (Test-Path "$MerkleDir\merkle_data.json") { Remove-Item -Force "$MerkleDir\merkle_data.json" }
    if (Test-Path "$Root\demo_inputs.json") { Remove-Item -Force "$Root\demo_inputs.json" }
    if (Test-Path "$CircuitDir\Prover.toml") { Remove-Item -Force "$CircuitDir\Prover.toml" }
    Write-Host "  Done." -ForegroundColor Green
}

# ── Dispatch ───────────────────────────────────────────────────────────────
switch ($Target) {
    "all" {
        CheckDeps
        MerkleDeps
        MerkleData
        ProverToml
        CircuitProof
        Write-Host "`nAll done! Run: .\run_all.ps1 -Target deploy" -ForegroundColor Yellow
    }
    "deps" { CheckDeps; MerkleDeps }
    "merkle" { MerkleData }
    "prover-toml" { ProverToml }
    "proof" { CircuitProof }
    "deploy" { Deploy }
    "submit" { Submit }
    "clean" { Clean }
}
