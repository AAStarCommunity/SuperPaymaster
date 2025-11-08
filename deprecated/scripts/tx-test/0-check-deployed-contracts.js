#!/usr/bin/env node
/**
 * 前置检查脚本 - 验证所有合约部署状态和配置
 * 基于 @aastar/shared-config v0.2.10
 */
const {
  CONTRACTS,
  ACCOUNT_A,
  ACCOUNT_B,
  ACCOUNT_C,
  OWNER2_ADDRESS,
  DEPLOYER_ADDRESS,
} = require("./utils/config");
const contractChecker = require("./utils/contract-checker");
const logger = require("./utils/logger");

async function main() {
  logger.section("🔍 合约部署状态检查");
  logger.info("基于 @aastar/shared-config v0.2.10");
  logger.blank();

  try {
    // ============= 1. 检查核心合约部署 =============
    logger.subsection("1. 检查核心合约部署");

    const coreContracts = {
      "GToken": CONTRACTS.GTOKEN,
      "GTokenStaking": CONTRACTS.GTOKEN_STAKING,
      "Registry": CONTRACTS.REGISTRY,
      "SuperPaymasterV2": CONTRACTS.SUPER_PAYMASTER_V2,
      "PaymasterFactory": CONTRACTS.PAYMASTER_FACTORY,
      "xPNTsFactory": CONTRACTS.XPNTS_FACTORY,
      "MySBT": CONTRACTS.MYSBT,
      "PaymasterV4.1": CONTRACTS.PAYMASTER_V4_1,
      "EntryPoint": CONTRACTS.ENTRYPOINT,
    };

    const deploymentStatus = {};
    for (const [name, address] of Object.entries(coreContracts)) {
      const isDeployed = await contractChecker.isContract(address);
      deploymentStatus[name] = isDeployed;
      logger.check(`${name.padEnd(20)} ${address}`, isDeployed);
    }

    const allDeployed = Object.values(deploymentStatus).every(v => v);
    if (!allDeployed) {
      logger.error("❌ 部分核心合约未部署，请检查 shared-config");
      return;
    }

    logger.success("✅ 所有核心合约已部署");
    logger.blank();

    // ============= 2. 检查合约配置 =============
    await contractChecker.performFullPreCheck();

    // ============= 3. 检查测试代币部署 =============
    logger.section("📦 检查测试代币部署");

    if (CONTRACTS.APNTS) {
      const aPNTsDeployed = await contractChecker.isContract(CONTRACTS.APNTS);
      logger.check(`aPNTs ${CONTRACTS.APNTS}`, aPNTsDeployed);

      if (aPNTsDeployed) {
        await contractChecker.checkXPNTsAutoApprove(
          CONTRACTS.APNTS,
          [CONTRACTS.SUPER_PAYMASTER_V2],
          "aPNTs"
        );
      }
    } else {
      logger.warning("⚠️  aPNTs 地址未配置，需要部署");
    }

    logger.blank();

    if (CONTRACTS.BPNTS) {
      const bPNTsDeployed = await contractChecker.isContract(CONTRACTS.BPNTS);
      logger.check(`bPNTs ${CONTRACTS.BPNTS}`, bPNTsDeployed);

      if (bPNTsDeployed) {
        await contractChecker.checkXPNTsAutoApprove(
          CONTRACTS.BPNTS,
          [CONTRACTS.PAYMASTER_V4_1, CONTRACTS.SUPER_PAYMASTER_V2],
          "bPNTs"
        );
      }
    } else {
      logger.warning("⚠️  bPNTs 地址未配置，需要部署");
    }

    // ============= 4. 检查测试账户状态 =============
    logger.section("👤 检查测试账户状态");

    const accounts = {
      "Account A": { address: ACCOUNT_A, expectedOwner: OWNER2_ADDRESS },
      "Account B": { address: ACCOUNT_B, expectedOwner: OWNER2_ADDRESS },
      "Account C": { address: ACCOUNT_C, expectedOwner: OWNER2_ADDRESS },
    };

    const accountStatus = await contractChecker.checkAllSimpleAccounts(accounts);

    logger.blank();
    const allAccountsDeployed = Object.values(accountStatus).every(v => v);
    if (!allAccountsDeployed) {
      logger.warning("⚠️  部分 Simple Account 未部署，运行 1-create-simple-accounts.js");
    } else {
      logger.success("✅ 所有 Simple Account 已部署");
    }

    // ============= 5. 检查测试账户资产 =============
    if (allAccountsDeployed) {
      logger.section("💰 检查测试账户资产");

      // 检查 GToken 余额
      logger.subsection("GToken 余额");
      await contractChecker.checkBalance(CONTRACTS.GTOKEN, OWNER2_ADDRESS, "OWNER2", "GT");
      await contractChecker.checkBalance(CONTRACTS.GTOKEN, ACCOUNT_A, "Account A", "GT");
      await contractChecker.checkBalance(CONTRACTS.GTOKEN, ACCOUNT_B, "Account B", "GT");
      await contractChecker.checkBalance(CONTRACTS.GTOKEN, ACCOUNT_C, "Account C", "GT");

      // 检查 SBT 余额
      logger.subsection("SBT 余额");
      await contractChecker.checkSBTBalance(OWNER2_ADDRESS, "OWNER2");
      await contractChecker.checkSBTBalance(ACCOUNT_A, "Account A");
      await contractChecker.checkSBTBalance(ACCOUNT_B, "Account B");
      await contractChecker.checkSBTBalance(ACCOUNT_C, "Account C");

      // 检查 xPNTs 余额
      if (CONTRACTS.APNTS) {
        logger.subsection("aPNTs 余额");
        await contractChecker.checkBalance(CONTRACTS.APNTS, OWNER2_ADDRESS, "OWNER2", "aPNTs");
        await contractChecker.checkBalance(CONTRACTS.APNTS, ACCOUNT_A, "Account A", "aPNTs");
        await contractChecker.checkBalance(CONTRACTS.APNTS, ACCOUNT_B, "Account B", "aPNTs");
        await contractChecker.checkBalance(CONTRACTS.APNTS, ACCOUNT_C, "Account C", "aPNTs");
      }

      if (CONTRACTS.BPNTS) {
        logger.subsection("bPNTs 余额");
        await contractChecker.checkBalance(CONTRACTS.BPNTS, OWNER2_ADDRESS, "OWNER2", "bPNTs");
        await contractChecker.checkBalance(CONTRACTS.BPNTS, ACCOUNT_A, "Account A", "bPNTs");
        await contractChecker.checkBalance(CONTRACTS.BPNTS, ACCOUNT_B, "Account B", "bPNTs");
        await contractChecker.checkBalance(CONTRACTS.BPNTS, ACCOUNT_C, "Account C", "bPNTs");
      }
    }

    // ============= 6. 检查运营方状态 =============
    logger.section("🏢 检查运营方注册状态");
    await contractChecker.checkOperatorRegistration(DEPLOYER_ADDRESS);

    // ============= 7. 总结 =============
    logger.section("📊 检查总结");

    const summary = [
      ["检查项", "状态"],
      ["核心合约部署", allDeployed ? "✅ 通过" : "❌ 失败"],
      ["合约配置", "✅ 通过"],
      ["测试代币部署", CONTRACTS.APNTS && CONTRACTS.BPNTS ? "✅ 通过" : "⚠️  部分未部署"],
      ["Simple Accounts", allAccountsDeployed ? "✅ 通过" : "⚠️  需要创建"],
      ["运营方注册", "需要检查上方输出"],
    ];

    logger.table(summary[0], summary.slice(1));

    // 下一步建议
    logger.section("📝 下一步操作建议");

    if (!CONTRACTS.APNTS || !CONTRACTS.BPNTS) {
      logger.warning("1. 运行 2-setup-communities-and-xpnts.js 部署测试代币");
    }

    if (!allAccountsDeployed) {
      logger.warning("2. 运行 1-create-simple-accounts.js 创建测试账户");
    }

    logger.info("3. 运行 3-mint-assets-to-accounts.js 准备测试资产");
    logger.info("4. 运行 4-test-aoa-paymaster.js 测试 AOA 模式");
    logger.info("5. 运行 5-test-aoa-plus-paymaster.js 测试 AOA+ 模式");

    logger.blank();
    logger.success("✅ 检查完成");

  } catch (error) {
    logger.error(`检查失败: ${error.message}`);
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
