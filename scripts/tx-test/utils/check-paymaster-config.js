/**
 * Check PaymasterV4.1 configuration
 */
const { ethers } = require("ethers");
const { getProvider, CONTRACTS } = require("./config");

async function main() {
  const provider = getProvider();

  const paymaster = new ethers.Contract(
    CONTRACTS.PAYMASTER_V4_1,
    [
      "function registry() view returns (address)",
      "function xPNTsFactory() view returns (address)",
      "function mySBT() view returns (address)",
      "function owner() view returns (address)",
    ],
    provider
  );

  console.log("PaymasterV4.1:", CONTRACTS.PAYMASTER_V4_1);
  console.log();

  try {
    const registry = await paymaster.registry();
    console.log("Registry:", registry);
  } catch (e) {
    console.log("Registry: Not set or error -", e.message);
  }

  try {
    const factory = await paymaster.xPNTsFactory();
    console.log("xPNTsFactory:", factory);
  } catch (e) {
    console.log("xPNTsFactory: Not set or error -", e.message);
  }

  try {
    const sbt = await paymaster.mySBT();
    console.log("MySBT:", sbt);
  } catch (e) {
    console.log("MySBT: Not set or error -", e.message);
  }

  try {
    const owner = await paymaster.owner();
    console.log("Owner:", owner);
  } catch (e) {
    console.log("Owner: Not set or error -", e.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
