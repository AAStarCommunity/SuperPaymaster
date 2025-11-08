#!/usr/bin/env node
/**
 * 配置 PaymasterV4.1
 * 设置 xPNTsFactory 和 MySBT 地址
 */
const { ethers } = require("ethers");
const sharedConfig = require("@aastar/shared-config");
const {
  getDeployerSigner,
  getProvider,
} = require("./utils/config");
const logger = require("./utils/logger");

async function main() {
  logger.section("⚙️  配置 PaymasterV4.1");
  logger.blank();

  const deployer = getDeployerSigner();
  const provider = getProvider();
  const sepolia = sharedConfig.CONTRACTS.sepolia;

  const paymasterAddress = sepolia.paymaster.paymasterV4_1;
  const xPNTsFactoryAddress = sepolia.tokens.xPNTsFactory;
  const mySBTAddress = sepolia.tokens.mySBT;

  logger.address("PaymasterV4.1", paymasterAddress);
  logger.address("xPNTsFactory", xPNTsFactoryAddress);
  logger.address("MySBT", mySBTAddress);
  logger.address("Deployer", deployer.address);
  logger.blank();

  // 创建 Paymaster 合约实例
  const paymaster = new ethers.Contract(
    paymasterAddress,
    [
      "function addSBT(address) external",
      "function addGasToken(address) external",
      "function getSupportedSBTs() view returns (address[])",
      "function getSupportedGasTokens() view returns (address[])",
      "function isSBTSupported(address) view returns (bool)",
      "function isGasTokenSupported(address) view returns (bool)",
      "function owner() view returns (address)",
    ],
    deployer
  );

  // 检查当前配置
  logger.subsection("检查当前配置");

  const owner = await paymaster.owner();
  logger.address("Owner", owner);

  if (owner.toLowerCase() !== deployer.address.toLowerCase()) {
    logger.error("❌ Deployer 不是 Paymaster owner，无法配置");
    logger.address("Expected", deployer.address);
    logger.address("Actual", owner);
    process.exit(1);
  }

  logger.success("✅ Deployer 是 Paymaster owner");
  logger.blank();

  // 获取当前已支持的 SBT 和 GasToken
  const supportedSBTs = await paymaster.getSupportedSBTs();
  const supportedGasTokens = await paymaster.getSupportedGasTokens();

  logger.info(`当前已支持 ${supportedSBTs.length} 个 SBT`);
  for (const sbt of supportedSBTs) {
    logger.address("  - SBT", sbt);
  }
  logger.blank();

  logger.info(`当前已支持 ${supportedGasTokens.length} 个 GasToken`);
  for (const token of supportedGasTokens) {
    logger.address("  - GasToken", token);
  }
  logger.blank();

  // 添加 MySBT（如果还没有）
  logger.subsection("1️⃣  添加 MySBT");

  const isSBTSupported = await paymaster.isSBTSupported(mySBTAddress);
  if (isSBTSupported) {
    logger.success("✅ MySBT 已支持，跳过");
  } else {
    logger.info("发送交易添加 MySBT...");
    const tx = await paymaster.addSBT(mySBTAddress);
    logger.info(`交易已发送: ${tx.hash}`);

    logger.info("等待交易确认...");
    const receipt = await tx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);

    // 验证
    const isNowSupported = await paymaster.isSBTSupported(mySBTAddress);
    if (isNowSupported) {
      logger.success("✅ MySBT 添加成功");
    } else {
      logger.error("❌ MySBT 添加失败");
    }
  }

  logger.blank();

  // 添加 xPNTs（使用 aPNTs - 0xBD0710596010a157B88cd141d797E8Ad4bb2306b）
  logger.subsection("2️⃣  添加 xPNTs (aPNTs)");

  const aPNTsAddress = process.env.APNTS_ADDRESS || "0xBD0710596010a157B88cd141d797E8Ad4bb2306b";
  logger.address("aPNTs", aPNTsAddress);

  const isGasTokenSupported = await paymaster.isGasTokenSupported(aPNTsAddress);
  if (isGasTokenSupported) {
    logger.success("✅ aPNTs 已支持，跳过");
  } else {
    logger.info("发送交易添加 aPNTs...");
    const tx = await paymaster.addGasToken(aPNTsAddress);
    logger.info(`交易已发送: ${tx.hash}`);

    logger.info("等待交易确认...");
    const receipt = await tx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);

    // 验证
    const isNowSupported = await paymaster.isGasTokenSupported(aPNTsAddress);
    if (isNowSupported) {
      logger.success("✅ aPNTs 添加成功");
    } else {
      logger.error("❌ aPNTs 添加失败");
    }
  }

  logger.blank();
  logger.success("✅ PaymasterV4.1 配置完成");
  logger.blank();
  logger.info("下一步: 运行 node scripts/tx-test/4-test-aoa-paymaster.js");
}

// 运行
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      logger.error(`脚本执行失败: ${error.message}`);
      console.error(error);
      process.exit(1);
    });
}

module.exports = main;
