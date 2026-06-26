#!/usr/bin/env node
// convert_vk.js — Convert bb v5 1888-byte VK to old 1760-byte format
//
// bb v5 VK (1888 bytes):
//   3 × Fr header (96 bytes): log_circuit_size, public_inputs_size, pub_inputs_offset
//   28 × G1 point (64 bytes each = 1792 bytes)
//
// Old VK (1760 bytes):
//   4 × u64 header (32 bytes): circuit_size, log_circuit_size, public_inputs_size, pub_inputs_offset
//   27 × G1 point (64 bytes each = 1728 bytes)
//
// Conversion: extract last 8 bytes of each Fr as u64, compute circuit_size = 1<<log_n,
// write 4 u64 header, copy first 27 G1 points, discard the 28th (ecc_op_wire).

const fs = require("fs");

const VK_HEADER_FRS = 3;
const VK_HEADER_FR_BYTES = VK_HEADER_FRS * 32; // 96
const VK_NUM_POINTS_NEW = 28;
const VK_NUM_POINTS_OLD = 27;
const G1_BYTES = 64;
const VK_BYTES_NEW = VK_HEADER_FR_BYTES + VK_NUM_POINTS_NEW * G1_BYTES; // 1888
const VK_BYTES_OLD = 4 * 8 + VK_NUM_POINTS_OLD * G1_BYTES; // 1760

function readU64BE(buf, offset) {
  return buf.readBigUInt64BE(offset);
}

function extractLastU64(fr) {
  return readU64BE(fr, 24);
}

function convertVk(inputPath, outputPath) {
  const data = fs.readFileSync(inputPath);

  if (data.length !== VK_BYTES_NEW) {
    // Maybe it's already old format?
    if (data.length === VK_BYTES_OLD) {
      console.log(`VK is already ${VK_BYTES_OLD} bytes (old format) — copying as-is.`);
      fs.writeFileSync(outputPath, data);
      return;
    }
    console.error(
      `Expected ${VK_BYTES_NEW} bytes (bb v5) or ${VK_BYTES_OLD} bytes (old), got ${data.length}`
    );
    process.exit(1);
  }

  // Extract 3 Fr values → last 8 bytes of each
  const logCircuitSize = Number(extractLastU64(data.subarray(0, 32)));
  const publicInputsSize = Number(extractLastU64(data.subarray(32, 64)));
  const pubInputsOffset = Number(extractLastU64(data.subarray(64, 96)));

  const circuitSize = 1 << logCircuitSize;

  console.log(
    `VK: circuit_size=${circuitSize} log_n=${logCircuitSize} ` +
      `pub_inputs=${publicInputsSize} offset=${pubInputsOffset}`
  );

  // Build old-format header: 4 u64 big-endian
  const header = Buffer.alloc(32);
  header.writeBigUInt64BE(BigInt(circuitSize), 0);
  header.writeBigUInt64BE(BigInt(logCircuitSize), 8);
  header.writeBigUInt64BE(BigInt(publicInputsSize), 16);
  header.writeBigUInt64BE(BigInt(pubInputsOffset), 24);

  // Copy first 27 G1 points (skip the 28th ecc_op_wire)
  const g1Points = data.subarray(VK_HEADER_FR_BYTES, VK_HEADER_FR_BYTES + VK_NUM_POINTS_OLD * G1_BYTES);

  const output = Buffer.concat([header, g1Points]);
  fs.writeFileSync(outputPath, output);

  console.log(`Converted VK: ${VK_BYTES_NEW} → ${output.length} bytes → ${outputPath}`);
}

// CLI
const args = process.argv.slice(2);
const inputPath = args[0] || "proofs/vk";
const outputPath = args[1] || inputPath;

convertVk(inputPath, outputPath);
