require("dotenv").config({ path: "env/.env" });
const { ethers } = require("ethers");

/**
 * Complete flow to mint MySBT:
 * 1. Mint GToken to test account
 * 2. Approve mintFee to MySBT
 * 3. Stake minLockAmount to GTokenStaking
 * 4. Approve staking to lock stake
 * 5. Mint MySBT (as deployer acting as registered community)
 */

const MYSBT = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
const GTOKEN = "0x868F843723a98c6EECC4BF0aF3352C53d5004147";
const GTOKEN_STAKING = "0xD8235F8920815175BD46f76a2cb99e15E02cED68";
const TEST_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const GToken_ABI = [
  "function owner() view returns (address)",
  "function balanceOf(address) view returns (uint256)",
  "function mint(address to, uint256 amount) external",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function decimals() view returns (uint8)",
];

const GTokenStaking_ABI = [
  "function stake(uint256 amount) external",
  "function getStakedBalance(address user) view returns (uint256)",
];

const MySBT_ABI = [
  "function REGISTRY() view returns (address)",
  "function minLockAmount() view returns (uint256)",
  "function mintFee() view returns (uint256)",
  "function userToSBT(address) view returns (uint256)",
  "function setRegistry(address) external",
  "function mintOrAddMembership(address user, string metadata) external returns (uint256 tokenId, bool isNewMint)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const deployer = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║          Mint MySBT with GToken Staking                       ║");
  console.log("╚════════════════════════════════════════════════════════════════╝\n");

  console.log("Deployer:", deployer.address);
  console.log("Test Account:", TEST_ACCOUNT);
  console.log("");

  const gtoken = new ethers.Contract(GTOKEN, GToken_ABI, deployer);
  const staking = new ethers.Contract(GTOKEN_STAKING, GTokenStaking_ABI, deployer);
  const sbt = new ethers.Contract(MYSBT, MySBT_ABI, deployer);

  // Check if already has SBT
  const existingTokenId = await sbt.userToSBT(TEST_ACCOUNT);
  if (existingTokenId > 0n) {
    console.log("✅ Test account already has SBT (Token ID:", existingTokenId.toString() + ")");
    return;
  }

  // Get required amounts
  const minLockAmount = await sbt.minLockAmount();
  const mintFee = await sbt.mintFee();
  const totalNeeded = minLockAmount + mintFee;

  console.log("📊 Requirements:");
  console.log("   Lock amount:", ethers.formatEther(minLockAmount), "GToken");
  console.log("   Mint fee:", ethers.formatEther(mintFee), "GToken");
  console.log("   Total needed:", ethers.formatEther(totalNeeded), "GToken\n");

  // Step 1: Mint GToken to test account
  console.log("💳 Step 1: Mint GToken to test account");
  const currentBalance = await gtoken.balanceOf(TEST_ACCOUNT);
  console.log("   Current balance:", ethers.formatEther(currentBalance), "GToken");

  if (currentBalance < totalNeeded) {
    const mintAmount = totalNeeded - currentBalance;
    console.log("   Minting", ethers.formatEther(mintAmount), "GToken...");

    const mintTx = await gtoken.mint(TEST_ACCOUNT, mintAmount, {
      gasLimit: 200000n,
    });
    console.log("   Transaction:", mintTx.hash);
    await mintTx.wait();
    console.log("   ✅ GToken minted\n");
  } else {
    console.log("   ✅ Sufficient GToken balance\n");
  }

  // Step 2: Approve mintFee to MySBT
  console.log("💳 Step 2: Approve mintFee to MySBT");
  const gtokenAsUser = gtoken.connect(testAccount);
  const approveTx = await gtokenAsUser.approve(MYSBT, mintFee, {
    gasLimit: 100000n,
  });
  console.log("   Transaction:", approveTx.hash);
  await approveTx.wait();
  console.log("   ✅ mintFee approved\n");

  // Step 3: Stake minLockAmount
  console.log("💳 Step 3: Stake GToken");
  const currentStaked = await staking.getStakedBalance(TEST_ACCOUNT);
  console.log("   Current staked:", ethers.formatEther(currentStaked), "GToken");

  if (currentStaked < minLockAmount) {
    const stakeAmount = minLockAmount - currentStaked;
    console.log("   Staking", ethers.formatEther(stakeAmount), "GToken...");

    // First approve staking contract
    const approveStakingTx = await gtokenAsUser.approve(GTOKEN_STAKING, stakeAmount, {
      gasLimit: 100000n,
    });
    await approveStakingTx.wait();
    console.log("   ✅ Staking approved");

    // Then stake
    const stakeTx = await staking.stake(stakeAmount, {
      gasLimit: 200000n,
    });
    console.log("   Transaction:", stakeTx.hash);
    await stakeTx.wait();
    console.log("   ✅ GToken staked\n");
  } else {
    console.log("   ✅ Sufficient staked balance\n");
  }

  // Step 4: Temporarily disable Registry check (as DAO)
  console.log("💳 Step 4: Disable Registry temporarily");
  const oldRegistry = await sbt.REGISTRY();
  console.log("   Current Registry:", oldRegistry);

  const setRegistryTx = await sbt.setRegistry(ethers.ZeroAddress, {
    gasLimit: 200000n,
  });
  console.log("   Transaction:", setRegistryTx.hash);
  await setRegistryTx.wait();
  console.log("   ✅ Registry disabled\n");

  // Step 5: Mint MySBT
  console.log("💳 Step 5: Mint MySBT");
  const metadata = "Test SBT for PaymasterV4 Testing";

  try {
    const mintSBTTx = await sbt.mintOrAddMembership(TEST_ACCOUNT, metadata, {
      gasLimit: 500000n,
    });
    console.log("   Transaction:", mintSBTTx.hash);
    await mintSBTTx.wait();
    console.log("   ✅ MySBT minted!\n");

    const tokenId = await sbt.userToSBT(TEST_ACCOUNT);
    console.log("   Token ID:", tokenId.toString());
  } catch (error) {
    console.error("   ❌ Mint failed:", error.message);
  }

  // Step 6: Restore Registry
  console.log("\n💳 Step 6: Restore Registry");
  const restoreTx = await sbt.setRegistry(oldRegistry, {
    gasLimit: 200000n,
  });
  console.log("   Transaction:", restoreTx.hash);
  await restoreTx.wait();
  console.log("   ✅ Registry restored\n");

  console.log("╔════════════════════════════════════════════════════════════════╗");
  console.log("║                 ✅ READY FOR TESTING                           ║");
  console.log("║                                                                ║");
  console.log("║  Now run: node scripts/test-paymaster-v4-bread.js             ║");
  console.log("╚════════════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
