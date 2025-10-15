require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(process.env.OWNER_PRIVATE_KEY, provider);
  
  const NEW_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";
  const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
  const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
  
  const SimpleAccountABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external"
  ];
  
  const ERC20ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)"
  ];
  
  const account = new ethers.Contract(NEW_ACCOUNT, SimpleAccountABI, owner);
  const pnt = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  
  console.log("=== Approving PaymasterV4 to spend PNT ===\n");
  console.log("Account:", NEW_ACCOUNT);
  console.log("Paymaster:", PAYMASTER_V4);
  
  const approveCalldata = pnt.interface.encodeFunctionData("approve", [
    PAYMASTER_V4,
    ethers.MaxUint256
  ]);
  
  console.log("\nSending approve transaction...");
  const tx = await account.execute(PNT_TOKEN, 0, approveCalldata);
  console.log("Transaction hash:", tx.hash);
  
  await tx.wait();
  console.log("✅ Approval confirmed!");
  
  // Verify
  const allowance = await pnt.allowance(NEW_ACCOUNT, PAYMASTER_V4);
  console.log("\nAllowance:", ethers.formatEther(allowance), "PNT");
}

main().catch(console.error);
