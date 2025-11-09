#!/usr/bin/env node
/**
 * AOA 模式测试 - 使用 PaymasterV4.1
 * 测试场景：Account A 向 B 转账 0.5 bPNTs
 * 使用 bPNTs 支付 gas fee
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
  logger.section("🧪 AOA 模式测试（PaymasterV4.1）");
  logger.info("测试场景：Account A 向 B 转账 0.5 bPNTs");
  logger.info("使用 PaymasterV4.1 支付 gas（bPNTs）");
  logger.blank();

  try {
    // ============= 1. 准备签名者和合约 =============
    logger.subsection("准备签名者和合约");

    const owner2 = getOwner2Signer();
    const provider = getProvider();

    // 检查 bPNTs 地址
    const bPNTsAddress = CONTRACTS.BPNTS || process.env.BPNTS_ADDRESS;
    if (!bPNTsAddress) {
      logger.error("❌ bPNTs 地址未配置");
      logger.warning("请先运行 2-setup-communities-and-xpnts.js");
      process.exit(1);
    }

    logger.address("Account A (Sender)", ACCOUNT_A);
    logger.address("Account B (Receiver)", ACCOUNT_B);
    logger.address("PaymasterV4.1", CONTRACTS.PAYMASTER_V4_1);
    logger.address("bPNTs", bPNTsAddress);
    logger.address("Beneficiary", TEST_CONFIG.BENEFICIARY);
    logger.blank();

    const bPNTs = getContract("ERC20", bPNTsAddress, provider);

    // ============= 2. 记录初始余额 =============
    logger.section("📊 记录初始余额");

    logger.subsection("Account A");
    const accountA_bPNTsBefore = await bPNTs.balanceOf(ACCOUNT_A);
    const accountA_ethBefore = await provider.getBalance(ACCOUNT_A);
    logger.amount("bPNTs 余额", ethers.formatEther(accountA_bPNTsBefore), "bPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountA_ethBefore), "ETH");

    logger.subsection("Account B");
    const accountB_bPNTsBefore = await bPNTs.balanceOf(ACCOUNT_B);
    const accountB_ethBefore = await provider.getBalance(ACCOUNT_B);
    logger.amount("bPNTs 余额", ethers.formatEther(accountB_bPNTsBefore), "bPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountB_ethBefore), "ETH");
    logger.blank();

    // 检查 A 的余额是否充足
    const requiredAmount = TEST_CONFIG.TRANSFER_AMOUNT + ethers.parseEther("0.01"); // 转账 + 预估 gas
    if (accountA_bPNTsBefore < requiredAmount) {
      logger.error(`❌ Account A bPNTs 余额不足`);
      logger.amount("当前余额", ethers.formatEther(accountA_bPNTsBefore), "bPNTs");
      logger.amount("所需余额", ethers.formatEther(requiredAmount), "bPNTs");
      logger.warning("请先运行 3-mint-assets-to-accounts.js");
      process.exit(1);
    }

    // ============= 3. 构建 callData =============
    logger.section("🔨 构建 UserOperation");

    logger.subsection("步骤 1：构建 callData");
    logger.info(`构建转账 ${ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT)} bPNTs 的 callData...`);

    // bPNTs.transfer(accountB, amount)
    const transferCallData = bPNTs.interface.encodeFunctionData("transfer", [
      ACCOUNT_B,
      TEST_CONFIG.TRANSFER_AMOUNT
    ]);
    logger.data("Transfer CallData 长度", transferCallData.length);

    // SimpleAccount.execute(dest, value, func)
    const accountA = getContract("SIMPLE_ACCOUNT", ACCOUNT_A, provider);
    const executeCallData = accountA.interface.encodeFunctionData("execute", [
      bPNTsAddress,      // dest
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
      paymasterAddress: CONTRACTS.PAYMASTER_V4_1,
      xPNTsAddress: bPNTsAddress,
      callGasLimit: 100000n,
      verificationGasLimit: 200000n,
      preVerificationGas: 50000n,
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
    const accountA_bPNTsAfter = await bPNTs.balanceOf(ACCOUNT_A);
    const accountA_ethAfter = await provider.getBalance(ACCOUNT_A);
    logger.amount("bPNTs 余额", ethers.formatEther(accountA_bPNTsAfter), "bPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountA_ethAfter), "ETH");

    const accountA_bPNTsDelta = accountA_bPNTsBefore - accountA_bPNTsAfter;
    const accountA_ethDelta = accountA_ethBefore - accountA_ethAfter;
    logger.amount("bPNTs 变化", "-" + ethers.formatEther(accountA_bPNTsDelta), "bPNTs");
    logger.amount("ETH 变化", ethers.formatEther(accountA_ethDelta), "ETH");

    logger.subsection("Account B");
    const accountB_bPNTsAfter = await bPNTs.balanceOf(ACCOUNT_B);
    const accountB_ethAfter = await provider.getBalance(ACCOUNT_B);
    logger.amount("bPNTs 余额", ethers.formatEther(accountB_bPNTsAfter), "bPNTs");
    logger.amount("ETH 余额", ethers.formatEther(accountB_ethAfter), "ETH");

    const accountB_bPNTsDelta = accountB_bPNTsAfter - accountB_bPNTsBefore;
    const accountB_ethDelta = accountB_ethAfter - accountB_ethBefore;
    logger.amount("bPNTs 变化", "+" + ethers.formatEther(accountB_bPNTsDelta), "bPNTs");
    logger.amount("ETH 变化", ethers.formatEther(accountB_ethDelta), "ETH");
    logger.blank();

    // ============= 9. 验证结果 =============
    logger.section("✅ 验证测试结果");

    const checks = {
      transferSuccess: false,
      gaslessSuccess: false,
      gasFeeCorrect: false,
    };

    // 检查 1: B 收到了正确的转账金额
    checks.transferSuccess = accountB_bPNTsDelta === TEST_CONFIG.TRANSFER_AMOUNT;
    logger.check(
      `Account B 收到 ${ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT)} bPNTs`,
      checks.transferSuccess
    );
    if (!checks.transferSuccess) {
      logger.warning(`实际收到: ${ethers.formatEther(accountB_bPNTsDelta)} bPNTs`);
    }

    // 检查 2: A 的 ETH 余额不变（gasless）
    checks.gaslessSuccess = accountA_ethDelta === 0n;
    logger.check("Account A ETH 余额不变（gasless）", checks.gaslessSuccess);
    if (!checks.gaslessSuccess) {
      logger.warning(`ETH 变化: ${ethers.formatEther(accountA_ethDelta)} ETH`);
    }

    // 检查 3: A 的 bPNTs 扣除 = 转账金额 + gas fee
    const expectedGasFee = accountA_bPNTsDelta - TEST_CONFIG.TRANSFER_AMOUNT;
    checks.gasFeeCorrect = expectedGasFee > 0n && expectedGasFee < ethers.parseEther("0.1"); // Gas fee 应该 < 0.1 bPNTs
    logger.check("Gas fee 合理（< 0.1 bPNTs）", checks.gasFeeCorrect);
    logger.amount("实际 Gas Fee", ethers.formatEther(expectedGasFee), "bPNTs");

    // 检查 4: B 的 ETH 余额不变
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
      ["UserOp 成功", userOpEvent?.success ? "✅ 通过" : "❌ 失败"],
    ];

    logger.table(summary[0], summary.slice(1));

    const detailSummary = [
      ["指标", "数值"],
      ["转账金额", ethers.formatEther(TEST_CONFIG.TRANSFER_AMOUNT) + " bPNTs"],
      ["Gas Fee (bPNTs)", ethers.formatEther(expectedGasFee) + " bPNTs"],
      ["Account A ETH 变化", ethers.formatEther(accountA_ethDelta) + " ETH"],
      ["实际 Gas 消耗", userOpEvent?.actualGasUsed.toString() || "N/A"],
      ["交易哈希", receipt.transactionHash],
    ];

    logger.table(detailSummary[0], detailSummary.slice(1));

    const allPassed = Object.values(checks).every(v => v) && userOpEvent?.success;

    if (allPassed) {
      logger.success("🎉 AOA 模式测试通过！");
      logger.success("✅ PaymasterV4.1 成功代付 gas");
      logger.success("✅ 用户使用 bPNTs 支付 gas fee");
      logger.success("✅ 实现了真正的 gasless 交易");
    } else {
      logger.error("❌ 部分测试未通过，请检查日志");
    }

    logger.blank();

    // ============= 11. 下一步 =============
    logger.section("📝 下一步操作");
    logger.info("1. 运行 5-test-aoa-plus-paymaster.js 测试 AOA+ 模式");
    logger.info("2. 比较两种模式的 gas 消耗和用户体验");

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
