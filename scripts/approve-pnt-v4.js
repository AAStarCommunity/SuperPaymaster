require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// This script approves PNT tokens to PaymasterV4

const SIMPLE_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN =
  process.env.GAS_TOKEN_ADDRESS ||
  "0x090e34709a592210158aa49a969e4a04e3a29ebd";
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const SimpleAccountABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
];

const ERC20ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("=== Approve PNT to PaymasterV4 ===\n");
  console.log("Signer:", signer.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("PaymasterV4:", PAYMASTER_V4);
  console.log("PNT Token:", PNT_TOKEN);

  const accountContract = new ethers.Contract(
    SIMPLE_ACCOUNT,
    SimpleAccountABI,
    signer,
  );
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Check current allowance
  const currentAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
  console.log("\nCurrent Allowance:", ethers.formatUnits(currentAllowance, 18), "PNT");

  // Approve unlimited amount (or you can specify a fixed amount)
  const approveAmount = ethers.MaxUint256; // Unlimited approval
  console.log("\nApproving unlimited PNT to PaymasterV4...");

  // Construct approve calldata
  const approveCalldata = pntContract.interface.encodeFunctionData("approve", [
    PAYMASTER_V4,
    approveAmount,
  ]);

  // Execute via SimpleAccount
  const executeCalldata = accountContract.interface.encodeFunctionData(
    "execute",
    [PNT_TOKEN, 0, approveCalldata],
  );

  try {
    // Send transaction directly to SimpleAccount (not via EntryPoint)
    const tx = await signer.sendTransaction({
      to: SIMPLE_ACCOUNT,
      data: executeCalldata,
      gasLimit: 100000n,
    });

    console.log("✅ Transaction submitted!");
    console.log("Transaction hash:", tx.hash);
    console.log("Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log("\nWaiting for confirmation...");
    const receipt = await tx.wait();
    console.log("✅ Approval completed! Block:", receipt.blockNumber);
    console.log("Status:", receipt.status === 1 ? "Success" : "Failed");

    // Check new allowance
    const newAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, PAYMASTER_V4);
    console.log("\nNew Allowance:", ethers.formatUnits(newAllowance, 18), "PNT");
    console.log("✅ SimpleAccount can now use PaymasterV4 to pay gas with PNT!");
  } catch (error) {
    console.error("\n❌ Transaction failed:");
    console.error(error.message);
    if (error.data) {
      console.error("Error data:", error.data);
    }
    throw error;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
