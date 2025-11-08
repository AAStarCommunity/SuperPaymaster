const { ethers } = require("ethers");

// Test paymasterAndData construction
const PAYMASTER_V4 = "0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38";
const BREAD_TOKEN = "0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621";

console.log("Debugging PaymasterAndData Construction\n");

console.log("Inputs:");
console.log("  PAYMASTER_V4:", PAYMASTER_V4, "length:", PAYMASTER_V4.length);
console.log("  BREAD_TOKEN:", BREAD_TOKEN, "length:", BREAD_TOKEN.length);

// Method 1: Using ethers.concat
const paymasterAndData1 = ethers.concat([
  PAYMASTER_V4,
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
  BREAD_TOKEN,
]);

console.log("\nMethod 1 (ethers.concat with addresses as-is):");
console.log("  Result:", paymasterAndData1);
console.log("  Length:", paymasterAndData1.length);

// Method 2: Using getBytes first
const paymasterAndData2 = ethers.concat([
  ethers.getBytes(PAYMASTER_V4),
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
  ethers.getBytes(BREAD_TOKEN),
]);

console.log("\nMethod 2 (ethers.concat with getBytes):");
console.log("  Result:", paymasterAndData2);
console.log("  Length:", paymasterAndData2.length);

// Method 3: Manual hexlify
const pmVerifyGas = ethers.zeroPadValue(ethers.toBeHex(200000n), 16);
const pmPostOpGas = ethers.zeroPadValue(ethers.toBeHex(100000n), 16);

console.log("\nIndividual parts:");
console.log("  Paymaster:", PAYMASTER_V4, "length:", ethers.getBytes(PAYMASTER_V4).length);
console.log("  VerifyGas:", pmVerifyGas, "length:", ethers.getBytes(pmVerifyGas).length);
console.log("  PostOpGas:", pmPostOpGas, "length:", ethers.getBytes(pmPostOpGas).length);
console.log("  GasToken:", BREAD_TOKEN, "length:", ethers.getBytes(BREAD_TOKEN).length);

// Total should be: 20 + 16 + 16 + 20 = 72 bytes
console.log("\nExpected total: 72 bytes");
console.log("Actual (Method 1):", paymasterAndData1.length);
console.log("Actual (Method 2):", paymasterAndData2.length);

// Parse the result
if (paymasterAndData2.length === 72) {
  console.log("\n✅ Correct length!");
  console.log("\nParsed components:");
  console.log("  Paymaster:", ethers.hexlify(paymasterAndData2.slice(0, 20)));
  console.log("  VerifyGas:", ethers.hexlify(paymasterAndData2.slice(20, 36)));
  console.log("  PostOpGas:", ethers.hexlify(paymasterAndData2.slice(36, 52)));
  console.log("  GasToken:", ethers.hexlify(paymasterAndData2.slice(52, 72)));
} else {
  console.log("\n❌ Incorrect length!");
}
