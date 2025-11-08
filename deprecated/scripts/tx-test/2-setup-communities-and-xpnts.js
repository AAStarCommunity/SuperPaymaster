#!/usr/bin/env node
/**
 * 设置社区和 xPNTs 脚本
 * 1. 注册 AAStar 和 BuilderDAO 社区到 Registry
 * 2. 使用 xPNTsFactory 部署 aPNTs 和 bPNTs
 * 3. 验证 autoApprovedSpenders 配置
 */
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const {
  getDeployerSigner,
  getContract,
  CONTRACTS,
  DEPLOYER_ADDRESS,
} = require("./utils/config");
const contractChecker = require("./utils/contract-checker");
const logger = require("./utils/logger");

// 社区配置
const COMMUNITIES = {
  AASTAR: {
    name: "AAStar",
    ensName: "aastar.eth",
    initialStake: ethers.parseEther("50"),
    xpntsName: "AAStar Points",
    xpntsSymbol: "aPNTs",
    autoApprovedSpenders: [CONTRACTS.SUPER_PAYMASTER_V2], // 只 approve SuperPaymasterV2
  },
  BUILDERDAO: {
    name: "BuilderDAO",
    ensName: "builderdao.eth",
    initialStake: ethers.parseEther("50"),
    xpntsName: "BuilderDAO Points",
    xpntsSymbol: "bPNTs",
    autoApprovedSpenders: [
      CONTRACTS.PAYMASTER_V4_1,
      CONTRACTS.SUPER_PAYMASTER_V2
    ], // approve 两个 paymaster
  },
};

async function registerCommunity(registry, gToken, deployer, communityConfig) {
  logger.subsection(`注册社区: ${communityConfig.name}`);

  try {
    // 检查是否已注册
    let communityId;
    try {
      communityId = await registry.getCommunityId(communityConfig.ensName);
      logger.data("社区 ID", communityId.toString());

      // 如果 ID > 0，说明已注册
      if (communityId > 0n) {
        logger.success(`✅ 社区 ${communityConfig.name} 已注册`);

        // 获取社区信息
        const communityInfo = await registry.communities(communityId);
        logger.address("Owner", communityInfo.owner);
        logger.data("ENS Name", communityInfo.ensName);

        return { exists: true, communityId };
      }
    } catch (error) {
      // getCommunityId 可能会 revert，说明未注册
      logger.info(`社区 ${communityConfig.name} 未注册`);
    }

    // 未注册，开始注册
    logger.info("开始注册社区...");

    // 1. Approve GToken
    logger.info(`Approve ${ethers.formatEther(communityConfig.initialStake)} GT 给 Registry...`);
    const approveTx = await gToken.approve(
      CONTRACTS.REGISTRY,
      communityConfig.initialStake
    );
    await approveTx.wait();
    logger.success("✅ Approve 成功");

    // 2. 注册社区
    logger.info("调用 registerCommunity...");
    const registerTx = await registry.registerCommunity(
      communityConfig.name,
      communityConfig.ensName,
      communityConfig.initialStake
    );
    logger.info(`交易已发送: ${registerTx.hash}`);

    const receipt = await registerTx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);
    logger.data("Gas 消耗", receipt.gasUsed.toString());

    // 3. 获取社区 ID
    communityId = await registry.getCommunityId(communityConfig.ensName);
    logger.data("社区 ID", communityId.toString());
    logger.success(`✅ 社区 ${communityConfig.name} 注册成功`);

    return { exists: false, communityId, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`注册失败: ${error.message}`);
    throw error;
  }
}

async function deployXPNTs(factory, deployer, communityId, xpntsConfig) {
  logger.subsection(`部署 ${xpntsConfig.xpntsSymbol}`);

  try {
    // 检查是否已部署
    let xpntsAddress;
    try {
      xpntsAddress = await factory.getCommunityToken(communityId);

      // 如果地址不是 0x0，说明已部署
      if (xpntsAddress !== ethers.ZeroAddress) {
        logger.address(`${xpntsConfig.xpntsSymbol} 地址`, xpntsAddress);
        logger.success(`✅ ${xpntsConfig.xpntsSymbol} 已部署`);

        // 验证 autoApprovedSpenders
        const isContract = await contractChecker.isContract(xpntsAddress);
        if (isContract) {
          await contractChecker.checkXPNTsAutoApprove(
            xpntsAddress,
            xpntsConfig.autoApprovedSpenders,
            xpntsConfig.xpntsSymbol
          );
        }

        return { exists: true, address: xpntsAddress };
      }
    } catch (error) {
      // getCommunityToken 可能会 revert，说明未部署
      logger.info(`${xpntsConfig.xpntsSymbol} 未部署`);
    }

    // 未部署，开始部署
    logger.info("开始部署 xPNTs...");
    logger.data("社区 ID", communityId.toString());
    logger.data("Token 名称", xpntsConfig.xpntsName);
    logger.data("Token 符号", xpntsConfig.xpntsSymbol);
    logger.data("Auto Approved Spenders", xpntsConfig.autoApprovedSpenders.length);

    xpntsConfig.autoApprovedSpenders.forEach((spender, i) => {
      logger.address(`  [${i}]`, spender);
    });

    // 调用 deployToken
    const deployTx = await factory.deployToken(
      communityId,
      xpntsConfig.xpntsName,
      xpntsConfig.xpntsSymbol,
      xpntsConfig.autoApprovedSpenders
    );
    logger.info(`交易已发送: ${deployTx.hash}`);

    const receipt = await deployTx.wait();
    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);
    logger.data("Gas 消耗", receipt.gasUsed.toString());

    // 获取部署的地址
    xpntsAddress = await factory.getCommunityToken(communityId);
    logger.address(`${xpntsConfig.xpntsSymbol} 地址`, xpntsAddress);

    // 验证部署
    const isContract = await contractChecker.isContract(xpntsAddress);
    logger.check("成功部署为合约", isContract);

    // 验证 autoApprovedSpenders
    if (isContract) {
      await contractChecker.checkXPNTsAutoApprove(
        xpntsAddress,
        xpntsConfig.autoApprovedSpenders,
        xpntsConfig.xpntsSymbol
      );
    }

    logger.success(`✅ ${xpntsConfig.xpntsSymbol} 部署成功`);

    return { exists: false, address: xpntsAddress, tx: receipt.transactionHash };

  } catch (error) {
    logger.error(`部署失败: ${error.message}`);
    throw error;
  }
}

function updateEnvFile(aPNTsAddress, bPNTsAddress) {
  logger.subsection("更新 .env 文件");

  const envPath = path.join(__dirname, "../../.env");

  try {
    let envContent = "";
    if (fs.existsSync(envPath)) {
      envContent = fs.readFileSync(envPath, "utf8");
    }

    // 更新或添加 APNTS_ADDRESS
    if (envContent.includes("APNTS_ADDRESS=")) {
      envContent = envContent.replace(
        /APNTS_ADDRESS=.*/,
        `APNTS_ADDRESS="${aPNTsAddress}"`
      );
    } else {
      envContent += `\nAPNTS_ADDRESS="${aPNTsAddress}"\n`;
    }

    // 更新或添加 BPNTS_ADDRESS
    if (envContent.includes("BPNTS_ADDRESS=")) {
      envContent = envContent.replace(
        /BPNTS_ADDRESS=.*/,
        `BPNTS_ADDRESS="${bPNTsAddress}"`
      );
    } else {
      envContent += `BPNTS_ADDRESS="${bPNTsAddress}"\n`;
    }

    fs.writeFileSync(envPath, envContent, "utf8");
    logger.success("✅ .env 文件已更新");
    logger.data("aPNTs", aPNTsAddress);
    logger.data("bPNTs", bPNTsAddress);

  } catch (error) {
    logger.warning(`⚠️  更新 .env 文件失败: ${error.message}`);
  }
}

async function main() {
  logger.section("🏛️ 设置社区和 xPNTs");
  logger.info("注册社区并部署 Gas Token");
  logger.blank();

  try {
    // ============= 1. 准备签名者和合约 =============
    const deployer = getDeployerSigner();
    logger.address("Deployer 地址", DEPLOYER_ADDRESS);

    const registry = getContract("REGISTRY", CONTRACTS.REGISTRY, deployer);
    const gToken = getContract("GTOKEN", CONTRACTS.GTOKEN, deployer);
    const xPNTsFactory = getContract("XPNTS_FACTORY", CONTRACTS.XPNTS_FACTORY, deployer);

    logger.blank();

    // 检查 Deployer 的 GToken 余额
    const gtBalance = await gToken.balanceOf(DEPLOYER_ADDRESS);
    const requiredGT = COMMUNITIES.AASTAR.initialStake + COMMUNITIES.BUILDERDAO.initialStake;

    logger.subsection("检查 Deployer GToken 余额");
    logger.amount("当前余额", ethers.formatEther(gtBalance), "GT");
    logger.amount("所需余额", ethers.formatEther(requiredGT), "GT");

    if (gtBalance < requiredGT) {
      logger.error(`❌ GToken 余额不足，需要 ${ethers.formatEther(requiredGT)} GT`);
      logger.warning("请先 mint GToken 给 Deployer");
      process.exit(1);
    }
    logger.success("✅ GToken 余额充足");
    logger.blank();

    // ============= 2. 注册 AAStar 社区 =============
    logger.section("🌟 AAStar 社区");
    const aastarResult = await registerCommunity(
      registry,
      gToken,
      deployer,
      COMMUNITIES.AASTAR
    );
    logger.blank();

    // ============= 3. 部署 aPNTs =============
    const aPNTsResult = await deployXPNTs(
      xPNTsFactory,
      deployer,
      aastarResult.communityId,
      COMMUNITIES.AASTAR
    );
    logger.blank();

    // ============= 4. 注册 BuilderDAO 社区 =============
    logger.section("🏗️ BuilderDAO 社区");
    const builderDAOResult = await registerCommunity(
      registry,
      gToken,
      deployer,
      COMMUNITIES.BUILDERDAO
    );
    logger.blank();

    // ============= 5. 部署 bPNTs =============
    const bPNTsResult = await deployXPNTs(
      xPNTsFactory,
      deployer,
      builderDAOResult.communityId,
      COMMUNITIES.BUILDERDAO
    );
    logger.blank();

    // ============= 6. 总结 =============
    logger.section("📊 设置总结");

    const summary = [
      ["项目", "名称", "地址/ID", "状态"],
      [
        "AAStar 社区",
        COMMUNITIES.AASTAR.ensName,
        `ID: ${aastarResult.communityId}`,
        aastarResult.exists ? "已存在" : "新创建"
      ],
      [
        "aPNTs",
        COMMUNITIES.AASTAR.xpntsSymbol,
        aPNTsResult.address,
        aPNTsResult.exists ? "已存在" : "新部署"
      ],
      [
        "BuilderDAO 社区",
        COMMUNITIES.BUILDERDAO.ensName,
        `ID: ${builderDAOResult.communityId}`,
        builderDAOResult.exists ? "已存在" : "新创建"
      ],
      [
        "bPNTs",
        COMMUNITIES.BUILDERDAO.xpntsSymbol,
        bPNTsResult.address,
        bPNTsResult.exists ? "已存在" : "新部署"
      ],
    ];

    logger.table(summary[0], summary.slice(1));

    // ============= 7. 更新 .env 文件 =============
    updateEnvFile(aPNTsResult.address, bPNTsResult.address);
    logger.blank();

    // ============= 8. 下一步操作 =============
    logger.section("📝 下一步操作");
    logger.info("1. 重新运行 0-check-deployed-contracts.js 验证配置");
    logger.info("2. 运行 3-mint-assets-to-accounts.js 准备测试资产");
    logger.info("3. 确保 .env 文件已更新（已自动完成）");

    logger.blank();
    logger.success("✅ 社区和 xPNTs 设置完成");

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
