#!/usr/bin/env node
/**
 * 创建 Simple Account 脚本
 * 使用 SimpleAccountFactory 创建 Account A/B/C
 */
const { ethers } = require("ethers");
const {
  getOwner2Signer,
  getProvider,
  getContract,
  ACCOUNT_A,
  ACCOUNT_B,
  ACCOUNT_C,
  OWNER2_ADDRESS,
} = require("./utils/config");
const contractChecker = require("./utils/contract-checker");
const logger = require("./utils/logger");

// SimpleAccountFactory 地址（官方或自定义）
const SIMPLE_ACCOUNT_FACTORY = process.env.SIMPLE_ACCOUNT_FACTORY ||
  "0x9406Cc6185a346906296840746125a0E44976454"; // 官方 v0.7

async function createAccount(factory, owner, salt, expectedAddress, accountName) {
  logger.info(`创建 ${accountName}...`);

  // 先检查是否已存在
  const exists = await contractChecker.isContract(expectedAddress);
  if (exists) {
    logger.success(`✅ ${accountName} 已存在: ${expectedAddress}`);

    // 验证 owner
    const account = getContract("SIMPLE_ACCOUNT", expectedAddress, getProvider());
    const actualOwner = await account.owner();
    const ownerCorrect = actualOwner.toLowerCase() === owner.toLowerCase();

    logger.check(`Owner 正确 (${owner})`, ownerCorrect);
    return { exists: true, address: expectedAddress };
  }

  // 不存在，创建新账户
  logger.info(`${accountName} 不存在，开始创建...`);

  try {
    // 调用 createAccount
    const tx = await factory.createAccount(owner, salt);
    logger.info(`交易已发送: ${tx.hash}`);

    const receipt = await tx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);
    logger.data("Gas 消耗", receipt.gasUsed.toString());

    // 获取创建的地址
    const createdAddress = await factory.getAddress(owner, salt);
    logger.address(`${accountName} 地址`, createdAddress);

    // 验证地址
    const addressMatch = createdAddress.toLowerCase() === expectedAddress.toLowerCase();
    logger.check("地址匹配预期", addressMatch);

    if (!addressMatch) {
      logger.warning(`⚠️  地址不匹配！预期: ${expectedAddress}, 实际: ${createdAddress}`);
    }

    // 验证部署
    const isContract = await contractChecker.isContract(createdAddress);
    logger.check("成功部署为合约", isContract);

    return { exists: false, address: createdAddress, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`创建失败: ${error.message}`);

    // 检查是否是 "already deployed" 错误
    if (error.message.includes("already deployed") || error.message.includes("already exists")) {
      logger.info("账户可能已在之前的交易中创建，验证中...");
      const address = await factory.getAddress(owner, salt);
      const exists = await contractChecker.isContract(address);

      if (exists) {
        logger.success(`✅ 账户已存在: ${address}`);
        return { exists: true, address };
      }
    }

    throw error;
  }
}

async function main() {
  logger.section("👤 创建 Simple Account");
  logger.info("使用 SimpleAccountFactory 创建测试账户");
  logger.blank();

  try {
    // ============= 1. 准备签名者和工厂合约 =============
    const owner2 = getOwner2Signer();
    logger.address("OWNER2 地址", OWNER2_ADDRESS);
    logger.address("SimpleAccountFactory", SIMPLE_ACCOUNT_FACTORY);
    logger.blank();

    // 检查工厂合约是否存在
    const factoryExists = await contractChecker.isContract(SIMPLE_ACCOUNT_FACTORY);
    if (!factoryExists) {
      logger.error(`❌ SimpleAccountFactory 未部署: ${SIMPLE_ACCOUNT_FACTORY}`);
      logger.warning("请设置正确的 SIMPLE_ACCOUNT_FACTORY 环境变量");
      process.exit(1);
    }
    logger.success("✅ SimpleAccountFactory 已部署");

    const factory = getContract(
      "SIMPLE_ACCOUNT_FACTORY",
      SIMPLE_ACCOUNT_FACTORY,
      owner2
    );

    // ============= 2. 创建 Account A (salt = 0) =============
    logger.subsection("创建 Account A");
    const accountA = await createAccount(
      factory,
      OWNER2_ADDRESS,
      0,
      ACCOUNT_A,
      "Account A"
    );
    logger.blank();

    // ============= 3. 创建 Account B (salt = 1) =============
    logger.subsection("创建 Account B");
    const accountB = await createAccount(
      factory,
      OWNER2_ADDRESS,
      1,
      ACCOUNT_B,
      "Account B"
    );
    logger.blank();

    // ============= 4. 创建 Account C (salt = 2) =============
    logger.subsection("创建 Account C");
    const accountC = await createAccount(
      factory,
      OWNER2_ADDRESS,
      2,
      ACCOUNT_C,
      "Account C"
    );
    logger.blank();

    // ============= 5. 总结 =============
    logger.section("📊 创建总结");

    const summary = [
      ["账户", "地址", "状态", "交易哈希"],
      [
        "Account A",
        accountA.address,
        accountA.exists ? "已存在" : "新创建",
        accountA.tx || "N/A"
      ],
      [
        "Account B",
        accountB.address,
        accountB.exists ? "已存在" : "新创建",
        accountB.tx || "N/A"
      ],
      [
        "Account C",
        accountC.address,
        accountC.exists ? "已存在" : "新创建",
        accountC.tx || "N/A"
      ],
    ];

    logger.table(summary[0], summary.slice(1));

    // ============= 6. 验证所有账户 =============
    logger.section("✅ 验证所有账户");

    const accounts = {
      "Account A": { address: accountA.address, expectedOwner: OWNER2_ADDRESS },
      "Account B": { address: accountB.address, expectedOwner: OWNER2_ADDRESS },
      "Account C": { address: accountC.address, expectedOwner: OWNER2_ADDRESS },
    };

    const accountStatus = await contractChecker.checkAllSimpleAccounts(accounts);
    const allValid = Object.values(accountStatus).every(v => v);

    logger.blank();
    if (allValid) {
      logger.success("✅ 所有 Simple Account 创建成功并验证通过");
    } else {
      logger.error("❌ 部分账户验证失败，请检查");
    }

    // ============= 7. 下一步操作 =============
    logger.section("📝 下一步操作");
    logger.info("1. 运行 2-setup-communities-and-xpnts.js 设置社区和 xPNTs");
    logger.info("2. 运行 3-mint-assets-to-accounts.js 准备测试资产");
    logger.info("3. 运行 0-check-deployed-contracts.js 验证完整状态");

  } catch (error) {
    logger.error(`脚本执行失败: ${error.message}`);
    console.error(error);
    process.exit(1);
  }
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
