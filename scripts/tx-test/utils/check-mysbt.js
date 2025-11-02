const { ethers } = require("ethers");
const { getProvider, getDeployerSigner, CONTRACTS } = require("./config");

async function main() {
  const provider = getProvider();
  const deployer = getDeployerSigner();
  const mySBTAddress = CONTRACTS.MYSBT;

  console.log("MySBT:", mySBTAddress);
  console.log("Deployer:", deployer.address);
  console.log();

  const mySBT = new ethers.Contract(
    mySBTAddress,
    [
      "function owner() view returns (address)",
      "function balanceOf(address) view returns (uint256)",
      "function tokenURI(uint256) view returns (string)",
    ],
    provider
  );

  try {
    const owner = await mySBT.owner();
    console.log("MySBT Owner:", owner);
  } catch (e) {
    console.log("MySBT Owner: Error -", e.message);
  }

  const balance = await mySBT.balanceOf("0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584");
  console.log("Account A balance:", balance.toString());
}

main();
