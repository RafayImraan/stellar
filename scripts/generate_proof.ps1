# generate_proof.ps1 — Windows PowerShell version of generate_proof.sh
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$env:Path = "$env:USERPROFILE\.nargo\bin;$env:USERPROFILE\.bb\bin;$env:Path"

Write-Host "=== Step 1: Build Merkle trees ===" -ForegroundColor Cyan
Push-Location "$Root\merkle"
if (-not (Test-Path node_modules)) { npm install --silent }
node build_tree.js
Pop-Location

Write-Host "=== Step 2: Generate Prover.toml ===" -ForegroundColor Cyan
node "$Root\scripts\generate_prover_toml.js"

Write-Host "=== Step 3: Compile & execute circuit ===" -ForegroundColor Cyan
Push-Location "$Root\circuits\compliance"
nargo check
nargo compile
nargo execute
Pop-Location

$CircuitTarget = "$Root\circuits\compliance\target"
$Bytecode = "$CircuitTarget\compliance.json"
$Witness = "$CircuitTarget\compliance.gz"

if (-not (Test-Path $Bytecode) -or -not (Test-Path $Witness)) {
    Write-Error "Missing circuit artifacts"
}

New-Item -ItemType Directory -Force -Path "$Root\proofs" | Out-Null

Write-Host "=== Step 4: Detect bb version ===" -ForegroundColor Cyan
$BB_MAJOR = (bb --version | Select-Object -First 1) -replace '[^0-9].*', ''
if (-not $BB_MAJOR) { $BB_MAJOR = 0 }
Write-Host "  bb major version: $BB_MAJOR"

Write-Host "=== Step 5: Generate UltraHonk proof ===" -ForegroundColor Cyan
if ([int]$BB_MAJOR -ge 5) {
  bb prove --scheme ultra_honk --oracle_hash keccak `
    --bytecode_path $Bytecode --witness_path $Witness `
    --output_path $CircuitTarget --output_format binary --write_vk
} else {
  bb prove --scheme ultra_honk --oracle_hash keccak `
    --bytecode_path $Bytecode --witness_path $Witness `
    --output_path $CircuitTarget --output_format bytes_and_fields

  Write-Host "=== Step 5b: Generate verification key ===" -ForegroundColor Cyan
  bb write_vk --scheme ultra_honk --oracle_hash keccak `
    --bytecode_path $Bytecode --output_path $CircuitTarget `
    --output_format bytes_and_fields
}

Copy-Item "$CircuitTarget\proof" "$Root\proofs\compliance.proof" -Force
Copy-Item "$CircuitTarget\public_inputs" "$Root\proofs\public_inputs" -Force
Copy-Item "$CircuitTarget\vk" "$Root\proofs\vk" -Force

Write-Host "=== Step 6: Local verification ===" -ForegroundColor Cyan
if ([int]$BB_MAJOR -ge 5) {
  bb verify --scheme ultra_honk --oracle_hash keccak `
    -p "$CircuitTarget\proof" -k "$CircuitTarget\vk" -i "$CircuitTarget\public_inputs"
} else {
  bb verify --scheme ultra_honk --oracle_hash keccak `
    -p "$CircuitTarget\proof" -k "$CircuitTarget\vk" -i "$CircuitTarget\public_inputs"
}

Write-Host "`nProof generated successfully!" -ForegroundColor Green
