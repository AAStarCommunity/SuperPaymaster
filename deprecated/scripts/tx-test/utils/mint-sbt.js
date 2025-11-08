/**
 * Mint MySBT to test accounts
 */
const { ethers } = require("ethers");
const {
  getDeployerSigner,
  ACCOUNT_A,
  ACCOUNT_B,
  CONTRACTS,
} = require("./config");
const logger = require("./logger");

async function main() {
  logger.section("🎫  Mint MySBT to Test Accounts");
  logger.blank();

  const deployer = getDeployerSigner();
  const mySBTAddress = CONTRACTS.MYSBT;

  logger.address("MySBT", mySBTAddress);
  logger.address("Account A", ACCOUNT_A);
  logger.address("Account B", ACCOUNT_B);
  logger.blank();

  const mySBT = new ethers.Contract(
    mySBTAddress,
    [
      "function mint(address to)",
      "function balanceOf(address owner) view returns (uint256)",
    ],
    deployer
  );

  // Check and mint for Account A
  logger.subsection("Account A");
  const balanceA = await mySBT.balanceOf(ACCOUNT_A);
  logger.data("当前余额", balanceA.toString());

  if (balanceA === 0n) {
    logger.info("Minting MySBT to Account A...");
    const tx1 = await mySBT.mint(ACCOUNT_A);
    logger.info(`Transaction sent: ${tx1.hash}`);
    await tx1.wait();
    logger.success("✅ Minted to Account A");

    const newBalance = await mySBT.balanceOf(ACCOUNT_A);
    logger.data("新余额", newBalance.toString());
  } else {
    logger.success("✅ Account A already has MySBT");
  }

  logger.blank();

  // Check and mint for Account B
  logger.subsection("Account B");
  const balanceB = await mySBT.balanceOf(ACCOUNT_B);
  logger.data("当前余额", balanceB.toString());

  if (balanceB === 0n) {
    logger.info("Minting MySBT to Account B...");
    const tx2 = await mySBT.mint(ACCOUNT_B);
    logger.info(`Transaction sent: ${tx2.hash}`);
    await tx2.wait();
    logger.success("✅ Minted to Account B");

    const newBalance = await mySBT.balanceOf(ACCOUNT_B);
    logger.data("新余额", newBalance.toString());
  } else {
    logger.success("✅ Account B already has MySBT");
  }

  logger.blank();
  logger.success("✅ SBT minting complete");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
