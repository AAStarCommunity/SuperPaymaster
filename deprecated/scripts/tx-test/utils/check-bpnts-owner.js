/**
 * Check bPNTs contract owner
 */
const { ethers } = require("ethers");
const { getProvider } = require("./config");

async function main() {
  const provider = getProvider();
  const bPNTsAddress = process.env.BPNTS_ADDRESS;

  const bPNTs = new ethers.Contract(
    bPNTsAddress,
    [
      "function communityOwner() view returns (address)",
      "function FACTORY() view returns (address)",
    ],
    provider
  );

  const owner = await bPNTs.communityOwner();
  const factory = await bPNTs.FACTORY();

  console.log("bPNTs Contract:", bPNTsAddress);
  console.log("Community Owner:", owner);
  console.log("Factory:", factory);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
