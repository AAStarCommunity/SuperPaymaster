/**
 * 移除 PaymasterV4.1 的 SBT 要求
 */
const { ethers } = require("ethers");
const sharedConfig = require("@aastar/shared-config");
const { getDeployerSigner } = require("./utils/config");
const logger = require("./utils/logger");

async function main() {
  logger.section("🔧  移除 PaymasterV4.1 SBT 要求");
  logger.blank();

  const deployer = getDeployerSigner();
  const sepolia = sharedConfig.CONTRACTS.sepolia;
  const paymasterAddress = sepolia.paymaster.paymasterV4_1;

  logger.address("PaymasterV4.1", paymasterAddress);
  logger.blank();

  const paymaster = new ethers.Contract(
    paymasterAddress,
    [
      "function getSupportedSBTs() view returns (address[])",
      "function removeSBT(address) external",
      "function owner() view returns (address)",
    ],
    deployer
  );

  // 获取当前 SBTs
  const sbts = await paymaster.getSupportedSBTs();
  logger.info(`当前支持 ${sbts.length} 个 SBT`);

  for (const sbt of sbts) {
    logger.address("  - SBT", sbt);
  }
  logger.blank();

  // 移除所有 SBT
  logger.subsection("移除所有 SBT");

  for (const sbt of sbts) {
    logger.info(`移除 SBT: ${sbt}...`);
    const tx = await paymaster.removeSBT(sbt);
    logger.info(`交易已发送: ${tx.hash}`);
    await tx.wait();
    logger.success(`✅ 已移除`);
  }

  logger.blank();
  logger.success("✅ 所有 SBT 已移除");
  logger.info("PaymasterV4.1 不再要求 SBT");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
