#!/usr/bin/env node
/**
 * AOA+ 模式测试 - 使用 SuperPaymasterV2
 * 测试场景：Account A 向 B 转账 0.5 aPNTs
 * 使用 aPNTs 支付 gas fee，运营方消耗 aPNTs
 */
const { ethers } = require("ethers");
const {
  getOwner2Signer,
  getProvider,
  getContract,
  CONTRACTS,
  ACCOUNT_A,
  ACCOUNT_B,
  DEPLOYER_ADDRESS,
} = require("./utils/config");
const contractChecker = require("./utils/contract-checker");
const logger = require("./utils/logger");
const { buildUserOp, signUserOp, executeUserOp, parseUserOperationEvent } = require("./utils/userOp");

// 测试配置
const TEST_CONFIG = {
  TRANSFER_AMOUNT: ethers.parseEther("0.5"),
  BENEFICIARY: DEPLOYER_ADDRESS, // EntryPoint handleOps 的 beneficiary
};

async function main() {
  logger.section("🧪 AOA+ 模式测试（SuperPaymasterV2）");
  logger.info("测试场景：Account A 向 B 转账 0.5 aPNTs");
  logger.info("使用 SuperPaymasterV2 支付 gas（aPNTs）");
  logger.blank();

  try {
    // ============= 1. 准备签名者和合约 =============
    logger.subsection("准备签名者和合约");

    const owner2 = getOwner2Signer();
    const provider = getProvider();

    // 检查 aPNTs 地址
    const aPNTsAddress = CONTRACTS.APNTS || process.env.APNTS_ADDRESS;
    if (!aPNTsAddress) {
      logger.error("❌ aPNTs 地址未配置");
      logger.warning("请先运行 2-setup-communities-and-xpnts.js");
      process.exit(1);
    }

    logger.address("Account A (Sender)", ACCOUNT_A);
    logger.address("Account B (Receiver)", ACCOUNT_B);
    logger.address("SuperPaymasterV2", CONTRACTS.SUPER_PAYMASTER_V2);
    logger.address("aPNTs", aPNTsAddress);
    logger.address("Beneficiary", TEST_CONFIG.BENEFICIARY);
    logger.blank();

    const aPNTs = getContract("ERC20", aPNTsAddress, provider);
    const superPaymaster = getContract("SUPER_PAYMASTER_V2", CONTRACTS.SUPER_PAYMASTER_V2, provider);

    // ============= 2. 记录初始余额 =============
    logger.section("📊 记录初始余额");

    logger.subsection("Account A");
    const accountA_aPNTsBefore = await aPNTs.balanceOf(ACCOUNT_A);
    const accountA_ethBefore = await provider.getBalance(ACCOUNT_A);
    logger.amount("aPNTs 余额", ethers.formatEther(accountA_aPNTsBefore), "aPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountA_ethBefore), "ETH");

    logger.subsection("Account B");
    const accountB_aPNTsBefore = await aPNTs.balanceOf(ACCOUNT_B);
    const accountB_ethBefore = await provider.getBalance(ACCOUNT_B);
    logger.amount("aPNTs 余额", ethers.formatEther(accountB_aPNTsBefore), "aPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountB_ethBefore), "ETH");

    // 记录运营方状态
    logger.subsection("运营方（Deployer）");
    const operatorInfoBefore = await superPaymaster.operators(DEPLOYER_ADDRESS);
    logger.amount("aPNTs 余额", ethers.formatEther(operatorInfoBefore.aPNTsBalance), "aPNTs");
    logger.amount("Total Spent", ethers.formatEther(operatorInfoBefore.totalSpent), "aPNTs");

    // SuperPaymaster Treasury
    logger.subsection("SuperPaymaster Treasury");
    const treasuryAPNTsBefore = await superPaymaster.treasuryAPNTs();
    logger.amount("Treasury aPNTs", ethers.formatEther(treasuryAPNTsBefore), "aPNTs");
    logger.blank();

    // 检查 A 的余额是否充足
    const requiredAmount = TEST_CONFIG.TRANSFER_AMOUNT + ethers.parseEther("0.01"); // 转账 + 预估 gas
    if (accountA_aPNTsBefore < requiredAmount) {
      logger.error(`❌ Account A aPNTs 余额不足`);
      logger.amount("当前余额", ethers.formatEther(accountA_aPNTsBefore), "aPNTs");
      logger.amount("所需余额", ethers.formatEther(requiredAmount), "aPNTs");
      logger.warning("请先运行 3-mint-assets-to-accounts.js");
      process.exit(1);
    }

    // 检查运营方 aPNTs 余额
    if (operatorInfoBefore.aPNTsBalance < ethers.parseEther("10")) {
      logger.warning("⚠️  运营方 aPNTs 余额较低，可能不足以支付 gas");
      logger.warning("如果测试失败，请先充值运营方 aPNTs");
    }

    // ============= 3. 构建 callData =============
    logger.section("🔨 构建 UserOperation");

    logger.subsection("步骤 1：构建 callData");
    logger.info(`构建转账 ${ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT)} aPNTs 的 callData...`);

    // aPNTs.transfer(accountB, amount)
    const transferCallData = aPNTs.interface.encodeFunctionData("transfer", [
      ACCOUNT_B,
      TEST_CONFIG.TRANSFER_AMOUNT
    ]);
    logger.data("Transfer CallData 长度", transferCallData.length);

    // SimpleAccount.execute(dest, value, func)
    const accountA = getContract("SIMPLE_ACCOUNT", ACCOUNT_A, provider);
    const executeCallData = accountA.interface.encodeFunctionData("execute", [
      aPNTsAddress,      // dest
      0,                 // value (0 ETH)
      transferCallData   // func
    ]);
    logger.data("Execute CallData 长度", executeCallData.length);
    logger.blank();

    // ============= 4. 构建 UserOperation =============
    logger.subsection("步骤 2：构建 UserOperation");

    const userOp = await buildUserOp({
      sender: ACCOUNT_A,
      callData: executeCallData,
      paymasterAddress: CONTRACTS.SUPER_PAYMASTER_V2,
      operatorAddress: DEPLOYER_ADDRESS,  // AOA+ 模式使用 operator address
      callGasLimit: 100000n,
      verificationGasLimit: 200000n,
      preVerificationGas: 50000n,
      paymasterVerificationGasLimit: 150000n,
      paymasterPostOpGasLimit: 50000n,
    });

    logger.success("✅ UserOperation 构建完成");
    logger.blank();

    // ============= 5. 签名 UserOperation =============
    logger.subsection("步骤 3：签名 UserOperation");
    logger.info("使用 OWNER2 签名...");

    const signature = await signUserOp(userOp, owner2);
    userOp.signature = signature;

    logger.success("✅ UserOperation 签名完成");
    logger.blank();

    // ============= 6. 执行 UserOperation =============
    logger.section("🚀 执行 UserOperation");

    const receipt = await executeUserOp(
      userOp,
      TEST_CONFIG.BENEFICIARY,
      owner2  // 使用 OWNER2 发送交易
    );

    logger.blank();

    // ============= 7. 解析事件 =============
    const userOpEvent = parseUserOperationEvent(receipt);
    logger.blank();

    // ============= 8. 记录最终余额 =============
    logger.section("📊 记录最终余额");

    logger.subsection("Account A");
    const accountA_aPNTsAfter = await aPNTs.balanceOf(ACCOUNT_A);
    const accountA_ethAfter = await provider.getBalance(ACCOUNT_A);
    logger.amount("aPNTs 余额", ethers.formatEther(accountA_aPNTsAfter), "aPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountA_ethAfter), "ETH");

    const accountA_aPNTsDelta = accountA_aPNTsBefore - accountA_aPNTsAfter;
    const accountA_ethDelta = accountA_ethBefore - accountA_ethAfter;
    logger.amount("aPNTs 变化", "-" + ethers.formatEther(accountA_aPNTsDelta), "aPNTs");
    logger.amount("ETH 变化", ethers.formatEther(accountA_ethDelta), "ETH");

    logger.subsection("Account B");
    const accountB_aPNTsAfter = await aPNTs.balanceOf(ACCOUNT_B);
    const accountB_ethAfter = await provider.getBalance(ACCOUNT_B);
    logger.amount("aPNTs 余额", ethers.formatEther(accountB_aPNTsAfter), "aPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountB_ethAfter), "ETH");

    const accountB_aPNTsDelta = accountB_aPNTsAfter - accountB_aPNTsBefore;
    const accountB_ethDelta = accountB_ethAfter - accountB_ethBefore;
    logger.amount("aPNTs 变化", "+" + ethers.formatEther(accountB_aPNTsDelta), "aPNTs");
    logger.amount("ETH 变化", ethers.formatEther(accountB_ethDelta), "ETH");

    // 运营方状态
    logger.subsection("运营方（Deployer）");
    const operatorInfoAfter = await superPaymaster.operators(DEPLOYER_ADDRESS);
    const operatorAPNTsDelta = operatorInfoBefore.aPNTsBalance - operatorInfoAfter.aPNTsBalance;
    const operatorSpentDelta = operatorInfoAfter.totalSpent - operatorInfoBefore.totalSpent;

    logger.amount("aPNTs 余额", ethers.formatEther(operatorInfoAfter.aPNTsBalance), "aPNTs");
    logger.amount("Total Spent", ethers.formatEther(operatorInfoAfter.totalSpent), "aPNTs");
    logger.amount("aPNTs 消耗", ethers.formatEther(operatorAPNTsDelta), "aPNTs");
    logger.amount("Spent 增加", ethers.formatEther(operatorSpentDelta), "aPNTs");

    // SuperPaymaster Treasury
    logger.subsection("SuperPaymaster Treasury");
    const treasuryAPNTsAfter = await superPaymaster.treasuryAPNTs();
    const treasuryDelta = treasuryAPNTsAfter - treasuryAPNTsBefore;
    logger.amount("Treasury aPNTs", ethers.formatEther(treasuryAPNTsAfter), "aPNTs");
    logger.amount("Treasury 增加", ethers.formatEther(treasuryDelta), "aPNTs");
    logger.blank();

    // ============= 9. 验证结果 =============
    logger.section("✅ 验证测试结果");

    const checks = {
      transferSuccess: false,
      gaslessSuccess: false,
      gasFeeCorrect: false,
      operatorConsumed: false,
      treasuryIncreased: false,
    };

    // 检查 1: B 收到了正确的转账金额
    checks.transferSuccess = accountB_aPNTsDelta === TEST_CONFIG.TRANSFER_AMOUNT;
    logger.check(
      `Account B 收到 ${ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT)} aPNTs`,
      checks.transferSuccess
    );
    if (!checks.transferSuccess) {
      logger.warning(`实际收到: ${ethers.formatEther(accountB_aPNTsDelta)} aPNTs`);
    }

    // 检查 2: A 的 ETH 余额不变（gasless）
    checks.gaslessSuccess = accountA_ethDelta === 0n;
    logger.check("Account A ETH 余额不变（gasless）", checks.gaslessSuccess);
    if (!checks.gaslessSuccess) {
      logger.warning(`ETH 变化: ${ethers.formatEther(accountA_ethDelta)} ETH`);
    }

    // 检查 3: A 的 aPNTs 扣除 = 转账金额 + gas fee
    const expectedGasFee = accountA_aPNTsDelta - TEST_CONFIG.TRANSFER_AMOUNT;
    checks.gasFeeCorrect = expectedGasFee > 0n && expectedGasFee < ethers.parseEther("0.1"); // Gas fee 应该 < 0.1 aPNTs
    logger.check("Gas fee 合理（< 0.1 aPNTs）", checks.gasFeeCorrect);
    logger.amount("实际 Gas Fee", ethers.formatEther(expectedGasFee), "aPNTs");

    // 检查 4: 运营方 aPNTs 被消耗
    checks.operatorConsumed = operatorAPNTsDelta > 0n;
    logger.check("运营方 aPNTs 被消耗", checks.operatorConsumed);
    if (!checks.operatorConsumed) {
      logger.warning("运营方 aPNTs 未消耗");
    }

    // 检查 5: SuperPaymaster Treasury 增加
    checks.treasuryIncreased = treasuryDelta > 0n;
    logger.check("SuperPaymaster Treasury 增加", checks.treasuryIncreased);
    if (!checks.treasuryIncreased) {
      logger.warning("Treasury 未增加");
    }

    // 检查 6: B 的 ETH 余额不变
    const accountB_ethUnchanged = accountB_ethDelta === 0n;
    logger.check("Account B ETH 余额不变", accountB_ethUnchanged);

    logger.blank();

    // ============= 10. 总结 =============
    logger.section("📋 测试总结");

    const summary = [
      ["检查项", "结果"],
      ["转账成功", checks.transferSuccess ? "✅ 通过" : "❌ 失败"],
      ["Gasless 交易", checks.gaslessSuccess ? "✅ 通过" : "❌ 失败"],
      ["Gas Fee 合理", checks.gasFeeCorrect ? "✅ 通过" : "❌ 失败"],
      ["运营方消耗 aPNTs", checks.operatorConsumed ? "✅ 通过" : "❌ 失败"],
      ["Treasury 增加", checks.treasuryIncreased ? "✅ 通过" : "❌ 失败"],
      ["UserOp 成功", userOpEvent?.success ? "✅ 通过" : "❌ 失败"],
    ];

    logger.table(summary[0], summary.slice(1));

    const detailSummary = [
      ["指标", "数值"],
      ["转账金额", ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT) + " aPNTs"],
      ["用户 Gas Fee", ethers.formatEther(expectedGasFee) + " aPNTs"],
      ["运营方消耗", ethers.formatEther(operatorAPNTsDelta) + " aPNTs"],
      ["Treasury 增加", ethers.formatEther(treasuryDelta) + " aPNTs"],
      ["Account A ETH 变化", ethers.formatEther(accountA_ethDelta) + " ETH"],
      ["实际 Gas 消耗", userOpEvent?.actualGasUsed.toString() || "N/A"],
      ["交易哈希", receipt.transactionHash],
    ];

    logger.table(detailSummary[0], detailSummary.slice(1));

    const allPassed = Object.values(checks).every(v => v) && userOpEvent?.success;

    if (allPassed) {
      logger.success("🎉 AOA+ 模式测试通过！");
      logger.success("✅ SuperPaymasterV2 成功代付 gas");
      logger.success("✅ 用户使用 aPNTs 支付 gas fee");
      logger.success("✅ 运营方消耗 aPNTs 提供服务");
      logger.success("✅ 实现了真正的 gasless 交易");
    } else {
      logger.error("❌ 部分测试未通过，请检查日志");
    }

    logger.blank();

    // ============= 11. AOA vs AOA+ 对比 =============
    logger.section("📊 AOA vs AOA+ 模式对比");

    const comparison = [
      ["特性", "AOA (PaymasterV4.1)", "AOA+ (SuperPaymasterV2)"],
      ["用户支付", "xPNTs", "xPNTs"],
      ["Paymaster 消耗", "无", "aPNTs（运营方账户）"],
      ["流动性要求", "社区自己准备", "运营方共享池"],
      ["部署难度", "较高（需要运营）", "低（使用共享服务）"],
      ["适用场景", "大型社区", "小型社区/测试"],
      ["Gas 优化", "直接结算", "双层结算"],
    ];

    logger.table(comparison[0], comparison.slice(1));

    logger.blank();

    // ============= 12. 下一步 =============
    logger.section("📝 完成！");
    logger.success("✅ 所有测试完成");
    logger.info("你已经成功测试了 ERC-4337 的两种 Paymaster 模式");
    logger.info("现在可以根据需求选择合适的模式部署到生产环境");

  } catch (error) {
    logger.error(`测试失败: ${error.message}`);
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
