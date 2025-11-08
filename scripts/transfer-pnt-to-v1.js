require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  
  const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
  const SIMPLE_ACCOUNT_V1 = "0xc2701F12eE436cD300B889FBC0B979e6E97623C8";
  
  const ERC20ABI = [
    "function transfer(address to, uint256 amount) external returns (bool)",
    "function balanceOf(address) external view returns (uint256)"
  ];
  
  const pnt = new ethers.Contract(PNT_TOKEN, ERC20ABI, deployer);
  
  console.log("Transferring 100 PNT to SimpleAccount V1...");
  const amount = ethers.parseEther("100");
  
  const tx = await pnt.transfer(SIMPLE_ACCOUNT_V1, amount);
  console.log("Transaction hash:", tx.hash);
  
  await tx.wait();
  console.log("✅ Transfer confirmed");
  
  const balance = await pnt.balanceOf(SIMPLE_ACCOUNT_V1);
  console.log("New balance:", ethers.formatEther(balance), "PNT");
}

main().catch(console.error);
