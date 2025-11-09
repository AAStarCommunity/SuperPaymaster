/**
 * Check xPNTsFactory ownership and permissions
 */
const { ethers } = require("ethers");
const { getProvider, DEPLOYER_ADDRESS } = require("./config");

async function main() {
  const provider = getProvider();
  const factoryAddress = "0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd";
  const bPNTsAddress = process.env.BPNTS_ADDRESS;

  const factory = new ethers.Contract(
    factoryAddress,
    [
      "function owner() view returns (address)",
      "function mintToExistingCommunity(address xPNTsToken, address to, uint256 amount)",
    ],
    provider
  );

  try {
    const factoryOwner = await factory.owner();
    console.log("Factory:", factoryAddress);
    console.log("Factory Owner:", factoryOwner);
    console.log("Deployer:", DEPLOYER_ADDRESS);
    console.log("Is deployer the factory owner?", factoryOwner.toLowerCase() === DEPLOYER_ADDRESS.toLowerCase());
  } catch (error) {
    console.log("Error checking factory owner:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
