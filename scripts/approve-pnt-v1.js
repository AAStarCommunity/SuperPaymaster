require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner = new ethers.Wallet(process.env.OWNER_PRIVATE_KEY, provider);
  
  const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
  const SIMPLE_ACCOUNT_V1 = "0xc2701F12eE436cD300B889FBC0B979e6E97623C8";
  const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
  
  const SimpleAccountABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external"
  ];
  
  const ERC20ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)"
  ];
  
  const account = new ethers.Contract(SIMPLE_ACCOUNT_V1, SimpleAccountABI, owner);
  const pnt = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  
  console.log("Approving PaymasterV4 to spend PNT from SimpleAccount V1...");
  
  const approveCalldata = pnt.interface.encodeFunctionData("approve", [
    PAYMASTER_V4,
    ethers.MaxUint256
  ]);
  
  const tx = await account.execute(PNT_TOKEN, 0, approveCalldata);
  console.log("Transaction hash:", tx.hash);
  
  await tx.wait();
  console.log("✅ Approval confirmed");
}

main().catch(console.error);
