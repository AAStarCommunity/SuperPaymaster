const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider("https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N");
  const deployerKey = "0x2717524c39f8b8ab74c902dc712e590fee36993774119c1e06d31daa4b0fbc81";
  const deployer = new ethers.Wallet(deployerKey, provider);
  
  const submitter = "0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d";
  const amount = ethers.parseEther("0.1");
  
  console.log("Sending 0.1 ETH from deployer to submitter...");
  const tx = await deployer.sendTransaction({
    to: submitter,
    value: amount
  });
  
  console.log("Transaction hash:", tx.hash);
  console.log("Waiting for confirmation...");
  
  const receipt = await tx.wait();
  console.log("✅ Transfer confirmed in block:", receipt.blockNumber);
  
  const newBalance = await provider.getBalance(submitter);
  console.log("Submitter new balance:", ethers.formatEther(newBalance), "ETH");
}

main().catch(console.error);
