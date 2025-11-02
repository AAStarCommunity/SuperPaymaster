#!/usr/bin/env node
/**
 * Mint 资产给测试账户
 * 1. Mint 1000 GToken 给 OWNER2 和 Account A/B/C
 * 2. Mint 1 个 SBT 给测试账户
 * 3. Mint 1000 aPNTs 和 bPNTs 给测试账户
 */
const { ethers } = require("ethers");
const {
  getDeployerSigner,
  getOwner2Signer,
  getContract,
  CONTRACTS,
  DEPLOYER_ADDRESS,
  OWNER2_ADDRESS,
  ACCOUNT_A,
  ACCOUNT_B,
  ACCOUNT_C,
} = require("./utils/config");
const contractChecker = require("./utils/contract-checker");
const logger = require("./utils/logger");

// Mint 配置
const MINT_CONFIG = {
  GTOKEN_AMOUNT: ethers.parseEther("1000"),
  SBT_COUNT: 1,
  XPNTS_AMOUNT: ethers.parseEther("1000"),
};

// 需要 mint 资产的账户列表
const TEST_ACCOUNTS = [
  { name: "OWNER2", address: OWNER2_ADDRESS },
  { name: "Account A", address: ACCOUNT_A },
  { name: "Account B", address: ACCOUNT_B },
  { name: "Account C", address: ACCOUNT_C },
];

async function mintGToken(gToken, toAddress, toName, amount) {
  logger.info(`Mint ${ethers.formatEther(amount)} GT 给 ${toName}...`);

  try {
    // 检查当前余额
    const currentBalance = await gToken.balanceOf(toAddress);
    logger.amount("当前余额", ethers.formatEther(currentBalance), "GT");

    // 如果余额已经 >= 目标数量，跳过
    if (currentBalance >= amount) {
      logger.success(`✅ ${toName} 已有足够的 GToken，跳过 mint`);
      return { skipped: true, balance: currentBalance };
    }

    // Mint
    const tx = await gToken.mint(toAddress, amount);
    logger.info(`交易已发送: ${tx.hash}`);

    const receipt = await tx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);

    // 检查新余额
    const newBalance = await gToken.balanceOf(toAddress);
    logger.amount("新余额", ethers.formatEther(newBalance), "GT");

    return { skipped: false, balance: newBalance, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`Mint 失败: ${error.message}`);
    throw error;
  }
}

async function mintSBT(mySBT, gToken, signer, toAddress, toName) {
  logger.info(`Mint SBT 给 ${toName}...`);

  try {
    // 检查当前 SBT 数量
    const currentBalance = await mySBT.balanceOf(toAddress);
    logger.data("当前 SBT 数量", currentBalance.toString());

    // 如果已有 SBT，跳过
    if (currentBalance >= MINT_CONFIG.SBT_COUNT) {
      logger.success(`✅ ${toName} 已有 SBT，跳过 mint`);
      return { skipped: true, balance: currentBalance };
    }

    // 获取 mint fee
    const mintFee = await mySBT.mintFee();
    logger.amount("Mint Fee", ethers.formatEther(mintFee), "GT");

    // Approve GToken 给 MySBT
    logger.info("Approve GToken...");
    const approveTx = await gToken.connect(signer).approve(
      CONTRACTS.MYSBT,
      mintFee
    );
    await approveTx.wait();
    logger.success("✅ Approve 成功");

    // Mint SBT
    // 注意：需要传入 communityId（从 Registry 获取）
    // 这里使用 AAStar 社区（假设已注册）
    const registry = getContract("REGISTRY", CONTRACTS.REGISTRY, signer);
    let communityId;
    try {
      communityId = await registry.getCommunityId("aastar.eth");
    } catch (error) {
      logger.warning("⚠️  无法获取 AAStar 社区 ID，使用 ID = 1");
      communityId = 1n;
    }

    logger.data("社区 ID", communityId.toString());

    const mintTx = await mySBT.connect(signer).mintSBT(communityId);
    logger.info(`交易已发送: ${mintTx.hash}`);

    const receipt = await mintTx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);

    // 检查新余额
    const newBalance = await mySBT.balanceOf(toAddress);
    logger.data("新 SBT 数量", newBalance.toString());

    return { skipped: false, balance: newBalance, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`Mint SBT 失败: ${error.message}`);

    // 特殊处理：如果是 Simple Account，需要通过 UserOp 调用
    if (toAddress === ACCOUNT_A || toAddress === ACCOUNT_B || toAddress === ACCOUNT_C) {
      logger.warning(`⚠️  ${toName} 是 Simple Account，需要通过 EntryPoint 调用`);
      logger.warning("跳过 SBT mint，请手动执行或使用 UserOp");
      return { skipped: true, error: error.message };
    }

    throw error;
  }
}

async function mintXPNTs(xpnts, toAddress, toName, amount, symbol) {
  logger.info(`Mint ${ethers.formatEther(amount)} ${symbol} 给 ${toName}...`);

  try {
    // 检查当前余额
    const currentBalance = await xpnts.balanceOf(toAddress);
    logger.amount("当前余额", ethers.formatEther(currentBalance), symbol);

    // 如果余额已经 >= 目标数量，跳过
    if (currentBalance >= amount) {
      logger.success(`✅ ${toName} 已有足够的 ${symbol}，跳过 mint`);
      return { skipped: true, balance: currentBalance };
    }

    // Mint
    const tx = await xpnts.mint(toAddress, amount);
    logger.info(`交易已发送: ${tx.hash}`);

    const receipt = await tx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);

    // 检查新余额
    const newBalance = await xpnts.balanceOf(toAddress);
    logger.amount("新余额", ethers.formatEther(newBalance), symbol);

    return { skipped: false, balance: newBalance, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`Mint ${symbol} 失败: ${error.message}`);
    throw error;
  }
}

async function main() {
  logger.section("💰 Mint 资产给测试账户");
  logger.info("准备测试所需的 GToken、SBT 和 xPNTs");
  logger.blank();

  try {
    // ============= 1. 准备签名者和合约 =============
    const deployer = getDeployerSigner();
    const owner2 = getOwner2Signer();

    const gToken = getContract("GTOKEN", CONTRACTS.GTOKEN, deployer);
    const mySBT = getContract("ERC721", CONTRACTS.MYSBT, deployer);

    // 检查 xPNTs 地址
    const aPNTsAddress = CONTRACTS.APNTS || process.env.APNTS_ADDRESS;
    const bPNTsAddress = CONTRACTS.BPNTS || process.env.BPNTS_ADDRESS;

    if (!aPNTsAddress || !bPNTsAddress) {
      logger.error("❌ xPNTs 地址未配置");
      logger.warning("请先运行 2-setup-communities-and-xpnts.js");
      process.exit(1);
    }

    const aPNTs = getContract("ERC20", aPNTsAddress, deployer);
    const bPNTs = getContract("ERC20", bPNTsAddress, deployer);

    logger.address("aPNTs", aPNTsAddress);
    logger.address("bPNTs", bPNTsAddress);
    logger.blank();

    // ============= 2. Mint GToken =============
    logger.section("🪙 Mint GToken");

    const gtokenResults = {};
    for (const account of TEST_ACCOUNTS) {
      logger.subsection(account.name);
      gtokenResults[account.name] = await mintGToken(
        gToken,
        account.address,
        account.name,
        MINT_CONFIG.GTOKEN_AMOUNT
      );
      logger.blank();
    }

    // ============= 3. Mint SBT =============
    logger.section("🎫 Mint SBT");

    const sbtResults = {};

    // OWNER2（使用 owner2 signer）
    logger.subsection("OWNER2");
    sbtResults.OWNER2 = await mintSBT(
      mySBT,
      gToken,
      owner2,
      OWNER2_ADDRESS,
      "OWNER2"
    );
    logger.blank();

    // Account A/B/C（需要特殊处理，因为是 Simple Account）
    for (const account of TEST_ACCOUNTS.slice(1)) { // 跳过 OWNER2
      logger.subsection(account.name);
      logger.warning(`⚠️  ${account.name} 是 Simple Account`);
      logger.warning("需要通过 UserOperation 调用 mintSBT");
      logger.info("暂时跳过，将在交易测试中处理");
      sbtResults[account.name] = { skipped: true, reason: "Simple Account" };
      logger.blank();
    }

    // ============= 4. Mint aPNTs =============
    logger.section("🔵 Mint aPNTs");

    const apntsResults = {};
    for (const account of TEST_ACCOUNTS) {
      logger.subsection(account.name);
      apntsResults[account.name] = await mintXPNTs(
        aPNTs,
        account.address,
        account.name,
        MINT_CONFIG.XPNTS_AMOUNT,
        "aPNTs"
      );
      logger.blank();
    }

    // ============= 5. Mint bPNTs =============
    logger.section("🟣 Mint bPNTs");

    const bpntsResults = {};
    for (const account of TEST_ACCOUNTS) {
      logger.subsection(account.name);
      bpntsResults[account.name] = await mintXPNTs(
        bPNTs,
        account.address,
        account.name,
        MINT_CONFIG.XPNTS_AMOUNT,
        "bPNTs"
      );
      logger.blank();
    }

    // ============= 6. 总结 =============
    logger.section("📊 Mint 总结");

    const summary = [
      ["账户", "GToken", "SBT", "aPNTs", "bPNTs"],
    ];

    for (const account of TEST_ACCOUNTS) {
      summary.push([
        account.name,
        gtokenResults[account.name].skipped ? "已有" : "✅ 新 Mint",
        sbtResults[account.name].skipped ? "跳过" : "✅ 新 Mint",
        apntsResults[account.name].skipped ? "已有" : "✅ 新 Mint",
        bpntsResults[account.name].skipped ? "已有" : "✅ 新 Mint",
      ]);
    }

    logger.table(summary[0], summary.slice(1));

    // ============= 7. 验证余额 =============
    logger.section("✅ 验证最终余额");

    for (const account of TEST_ACCOUNTS) {
      logger.subsection(account.name);
      await contractChecker.checkBalance(CONTRACTS.GTOKEN, account.address, account.name, "GT");
      await contractChecker.checkSBTBalance(account.address, account.name);
      await contractChecker.checkBalance(aPNTsAddress, account.address, account.name, "aPNTs");
      await contractChecker.checkBalance(bPNTsAddress, account.address, account.name, "bPNTs");
      logger.blank();
    }

    // ============= 8. 下一步操作 =============
    logger.section("📝 下一步操作");
    logger.warning("⚠️  Simple Account (A/B/C) 的 SBT 需要手动处理");
    logger.info("1. 运行 0-check-deployed-contracts.js 验证完整状态");
    logger.info("2. 运行 4-test-aoa-paymaster.js 测试 AOA 模式");
    logger.info("3. 运行 5-test-aoa-plus-paymaster.js 测试 AOA+ 模式");

    logger.blank();
    logger.success("✅ 资产 Mint 完成");

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
