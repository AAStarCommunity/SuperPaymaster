const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider("https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N");
  const submitter = "0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d";
  const deployer = "0x411BD567E46C0781248dbB6a9211891C032885e5";
  
  const submitterBalance = await provider.getBalance(submitter);
  const deployerBalance = await provider.getBalance(deployer);
  
  console.log("Submitter (0xc8d1...af3d):", ethers.formatEther(submitterBalance), "ETH");
  console.log("Deployer (0x411B...85e5):", ethers.formatEther(deployerBalance), "ETH");
}

main().catch(console.error);
