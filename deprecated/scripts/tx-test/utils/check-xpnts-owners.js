/**
 * Check both aPNTs and bPNTs ownership
 */
const { ethers } = require("ethers");
const { getProvider, DEPLOYER_ADDRESS } = require("./config");

async function main() {
  const provider = getProvider();
  const aPNTsAddress = process.env.APNTS_ADDRESS;
  const bPNTsAddress = process.env.BPNTS_ADDRESS;

  const abi = [
    "function communityOwner() view returns (address)",
    "function FACTORY() view returns (address)",
  ];

  console.log("Deployer:", DEPLOYER_ADDRESS);
  console.log();

  // Check aPNTs
  const aPNTs = new ethers.Contract(aPNTsAddress, abi, provider);
  const aPNTsOwner = await aPNTs.communityOwner();
  const aPNTsFactory = await aPNTs.FACTORY();

  console.log("aPNTs:", aPNTsAddress);
  console.log("  Community Owner:", aPNTsOwner);
  console.log("  Factory:", aPNTsFactory);
  console.log("  Is deployer the owner?", aPNTsOwner.toLowerCase() === DEPLOYER_ADDRESS.toLowerCase());
  console.log();

  // Check bPNTs
  const bPNTs = new ethers.Contract(bPNTsAddress, abi, provider);
  const bPNTsOwner = await bPNTs.communityOwner();
  const bPNTsFactory = await bPNTs.FACTORY();

  console.log("bPNTs:", bPNTsAddress);
  console.log("  Community Owner:", bPNTsOwner);
  console.log("  Factory:", bPNTsFactory);
  console.log("  Is deployer the owner?", bPNTsOwner.toLowerCase() === DEPLOYER_ADDRESS.toLowerCase());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
