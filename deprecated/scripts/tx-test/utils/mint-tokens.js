/**
 * Mint bPNTs to test accounts
 */
const { ethers } = require("ethers");
const { getDeployerSigner, CONTRACTS, ACCOUNT_A, ACCOUNT_B } = require("./config");
const logger = require("./logger");

async function main() {
  logger.section("Mint bPNTs to Test Accounts");

  const deployer = getDeployerSigner();
  const bPNTsAddress = process.env.APNTS_ADDRESS;  // 使用 aPNTs (deployer 拥有)

  if (!bPNTsAddress) {
    logger.error("BPNTS_ADDRESS not found in .env");
    process.exit(1);
  }

  logger.address("bPNTs Contract", bPNTsAddress);
  logger.address("Deployer", deployer.address);

  // Create contract instance with minimal ABI
  const bPNTs = new ethers.Contract(
    bPNTsAddress,
    [
      "function mint(address to, uint256 amount)",
      "function balanceOf(address) view returns (uint256)",
      "function decimals() view returns (uint8)",
    ],
    deployer
  );

  try {
    // Check current balances
    logger.subsection("Current Balances");
    const balanceA = await bPNTs.balanceOf(ACCOUNT_A);
    const balanceB = await bPNTs.balanceOf(ACCOUNT_B);
    logger.amount("Account A", ethers.formatEther(balanceA), "bPNTs");
    logger.amount("Account B", ethers.formatEther(balanceB), "bPNTs");

    // Mint 1000 bPNTs to each account
    const mintAmount = ethers.parseEther("1000");

    logger.subsection("Minting bPNTs");
    logger.amount("Mint Amount", "1000", "bPNTs per account");

    logger.info("Minting to Account A...");
    const tx1 = await bPNTs.mint(ACCOUNT_A, mintAmount);
    await tx1.wait();
    logger.success(`✅ Minted to Account A: ${tx1.hash}`);

    logger.info("Minting to Account B...");
    const tx2 = await bPNTs.mint(ACCOUNT_B, mintAmount);
    await tx2.wait();
    logger.success(`✅ Minted to Account B: ${tx2.hash}`);

    // Check new balances
    logger.subsection("New Balances");
    const newBalanceA = await bPNTs.balanceOf(ACCOUNT_A);
    const newBalanceB = await bPNTs.balanceOf(ACCOUNT_B);
    logger.amount("Account A", ethers.formatEther(newBalanceA), "bPNTs");
    logger.amount("Account B", ethers.formatEther(newBalanceB), "bPNTs");

    logger.success("\n✅ Mint completed successfully!");

  } catch (error) {
    logger.error(`Mint failed: ${error.message}`);
    if (error.data) {
      logger.error(`Revert data: ${error.data}`);
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
