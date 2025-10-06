require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

const ENTRYPOINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const PAYMASTER = "0x1568da4ea1E2C34255218b6DaBb2458b57B35805";
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const EntryPointABI = [
  "function addStake(uint32 unstakeDelaySec) external payable",
  "function getDepositInfo(address account) external view returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  const entryPoint = new ethers.Contract(ENTRYPOINT, EntryPointABI, signer);

  console.log("=== Add Stake to PaymasterV3 ===\n");

  // Check current deposit info
  const depositInfo = await entryPoint.getDepositInfo(PAYMASTER);
  console.log("Current deposit info:");
  console.log(`  Deposit: ${ethers.formatEther(depositInfo.deposit)} ETH`);
  console.log(`  Staked: ${depositInfo.staked}`);
  console.log(`  Stake: ${ethers.formatEther(depositInfo.stake)} ETH`);
  console.log(`  Unstake Delay: ${depositInfo.unstakeDelaySec} seconds`);
  console.log(`  Withdraw Time: ${depositInfo.withdrawTime}\n`);

  // Add stake: 0.1 ETH with 86400 seconds (1 day) unstake delay
  const stakeAmount = ethers.parseEther("0.1");
  const unstakeDelay = 86400; // 1 day

  console.log(`Adding stake: ${ethers.formatEther(stakeAmount)} ETH`);
  console.log(`Unstake delay: ${unstakeDelay} seconds\n`);

  // Check signer balance
  const balance = await provider.getBalance(signer.address);
  console.log(`Signer balance: ${ethers.formatEther(balance)} ETH`);

  if (balance < stakeAmount) {
    console.error("❌ Insufficient balance for staking");
    return;
  }

  // Execute addStake from PaymasterV3 owner
  console.log("Sending transaction from:", signer.address);

  const paymasterContract = new ethers.Contract(
    PAYMASTER,
    ["function addStake(uint32 unstakeDelaySec) external payable"],
    signer,
  );

  const tx = await paymasterContract.addStake(unstakeDelay, {
    value: stakeAmount,
  });
  console.log(`Transaction hash: ${tx.hash}`);

  const receipt = await tx.wait();
  console.log(`✅ Stake added! Block: ${receipt.blockNumber}\n`);

  // Verify new deposit info
  const newDepositInfo = await entryPoint.getDepositInfo(PAYMASTER);
  console.log("New deposit info:");
  console.log(`  Deposit: ${ethers.formatEther(newDepositInfo.deposit)} ETH`);
  console.log(`  Staked: ${newDepositInfo.staked}`);
  console.log(`  Stake: ${ethers.formatEther(newDepositInfo.stake)} ETH`);
  console.log(`  Unstake Delay: ${newDepositInfo.unstakeDelaySec} seconds`);
  console.log(`  Withdraw Time: ${newDepositInfo.withdrawTime}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
