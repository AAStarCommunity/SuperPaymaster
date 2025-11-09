/**
 * 合约检查工具 - 验证合约部署状态和配置
 */
const { ethers } = require("ethers");
const { getProvider, getContract, CONTRACTS, ABIS } = require("./config");
const logger = require("./logger");

class ContractChecker {
  constructor() {
    this.provider = getProvider();
  }

  /**
   * 检查地址是否是合约
   */
  async isContract(address) {
    try {
      const code = await this.provider.getCode(address);
      return code !== "0x" && code.length > 2;
    } catch (error) {
      logger.error(`检查合约失败 ${address}: ${error.message}`);
      return false;
    }
  }

  /**
   * 检查 GToken 和 GTokenStaking 绑定
   */
  async checkGTokenBinding() {
    logger.subsection("检查 GToken 和 GTokenStaking 绑定");

    try {
      const gTokenStaking = getContract(
        "GTOKEN_STAKING",
        CONTRACTS.GTOKEN_STAKING,
        this.provider
      );

      const boundGToken = await gTokenStaking.gToken();
      const isCorrect = boundGToken.toLowerCase() === CONTRACTS.GTOKEN.toLowerCase();

      logger.check(`GTokenStaking 绑定的 GToken: ${boundGToken}`, isCorrect);
      logger.check(`预期 GToken 地址: ${CONTRACTS.GTOKEN}`, isCorrect);

      return isCorrect;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 检查 GTokenStaking Locker 配置
   */
  async checkLockerConfig(lockerAddress, lockerName) {
    logger.info(`检查 ${lockerName} locker 配置...`);

    try {
      const gTokenStaking = getContract(
        "GTOKEN_STAKING",
        CONTRACTS.GTOKEN_STAKING,
        this.provider
      );

      const config = await gTokenStaking.lockerConfigs(lockerAddress);
      const isActive = config[0]; // isActive 是第一个字段

      logger.check(`${lockerName} isActive`, isActive);
      logger.data("Locker 地址", lockerAddress);

      return isActive;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 检查 SuperPaymasterV2 配置
   */
  async checkSuperPaymasterV2Config() {
    logger.subsection("检查 SuperPaymasterV2 配置");

    try {
      const superPaymaster = getContract(
        "SUPER_PAYMASTER_V2",
        CONTRACTS.SUPER_PAYMASTER_V2,
        this.provider
      );

      // 检查最小质押
      const minStake = await superPaymaster.minOperatorStake();
      const expectedMinStake = ethers.parseEther("30");
      const minStakeCorrect = minStake === expectedMinStake;

      logger.amount("最小运营方质押", ethers.formatEther(minStake), "GT");
      logger.check("最小质押 = 30 GT", minStakeCorrect);

      // 检查 aPNTs 价格
      const aPNTsPrice = await superPaymaster.aPNTsPriceUSD();
      const expectedPrice = ethers.parseEther("0.02");
      const priceCorrect = aPNTsPrice === expectedPrice;

      logger.amount("aPNTs 价格", ethers.formatEther(aPNTsPrice), "USD");
      logger.check("aPNTs 价格 = 0.02 USD", priceCorrect);

      return minStakeCorrect && priceCorrect;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 检查 xPNTs 的 autoApprovedSpenders
   */
  async checkXPNTsAutoApprove(xpntsAddress, expectedSpenders, xpntsName) {
    logger.subsection(`检查 ${xpntsName} autoApprovedSpenders`);

    try {
      const xpnts = getContract("XPNTS", xpntsAddress, this.provider);

      let allCorrect = true;
      for (let i = 0; i < expectedSpenders.length; i++) {
        try {
          const spender = await xpnts.autoApprovedSpenders(i);
          const isCorrect = spender.toLowerCase() === expectedSpenders[i].toLowerCase();

          logger.check(
            `autoApprovedSpenders[${i}] = ${expectedSpenders[i]}`,
            isCorrect
          );
          logger.data(`实际值[${i}]`, spender);

          allCorrect = allCorrect && isCorrect;
        } catch (error) {
          logger.error(`读取 autoApprovedSpenders[${i}] 失败: ${error.message}`);
          allCorrect = false;
        }
      }

      return allCorrect;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 检查账户余额
   */
  async checkBalance(tokenAddress, accountAddress, accountName, tokenSymbol) {
    try {
      const token = getContract("ERC20", tokenAddress, this.provider);
      const balance = await token.balanceOf(accountAddress);

      logger.amount(
        `${accountName} ${tokenSymbol} 余额`,
        ethers.formatEther(balance),
        tokenSymbol
      );

      return balance;
    } catch (error) {
      logger.error(`检查余额失败: ${error.message}`);
      return ethers.parseEther("0");
    }
  }

  /**
   * 检查 SBT 余额
   */
  async checkSBTBalance(accountAddress, accountName) {
    try {
      const sbt = getContract("ERC721", CONTRACTS.MYSBT, this.provider);
      const balance = await sbt.balanceOf(accountAddress);

      logger.data(`${accountName} SBT 数量`, balance.toString());

      return balance;
    } catch (error) {
      logger.error(`检查 SBT 余额失败: ${error.message}`);
      return 0n;
    }
  }

  /**
   * 检查 Simple Account 部署状态
   */
  async checkSimpleAccount(address, expectedOwner, accountName) {
    logger.info(`检查 ${accountName} (${address})...`);

    const isContract = await this.isContract(address);
    logger.check(`${accountName} 是合约`, isContract);

    if (!isContract) {
      return false;
    }

    try {
      const account = getContract("SIMPLE_ACCOUNT", address, this.provider);
      const owner = await account.owner();
      const ownerCorrect = owner.toLowerCase() === expectedOwner.toLowerCase();

      logger.check(`Owner = ${expectedOwner}`, ownerCorrect);
      logger.data("实际 Owner", owner);

      return ownerCorrect;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 批量检查 Simple Accounts
   */
  async checkAllSimpleAccounts(accounts) {
    logger.subsection("检查 Simple Accounts 部署状态");

    const results = {};
    for (const [name, { address, expectedOwner }] of Object.entries(accounts)) {
      results[name] = await this.checkSimpleAccount(address, expectedOwner, name);
    }

    return results;
  }

  /**
   * 检查运营方注册状态（SuperPaymasterV2）
   */
  async checkOperatorRegistration(operatorAddress) {
    logger.subsection("检查运营方注册状态");

    try {
      const superPaymaster = getContract(
        "SUPER_PAYMASTER_V2",
        CONTRACTS.SUPER_PAYMASTER_V2,
        this.provider
      );

      const operatorInfo = await superPaymaster.operators(operatorAddress);
      const isRegistered = operatorInfo.isActive;

      logger.check("运营方已注册", isRegistered);

      if (isRegistered) {
        logger.amount("质押的 stGToken", ethers.formatEther(operatorInfo.stakedAmount), "stGT");
        logger.amount("aPNTs 余额", ethers.formatEther(operatorInfo.aPNTsBalance), "aPNTs");
        logger.amount("总消费", ethers.formatEther(operatorInfo.totalSpent), "aPNTs");
        logger.address("Treasury", operatorInfo.treasury);
      }

      return isRegistered;
    } catch (error) {
      logger.error(`检查失败: ${error.message}`);
      return false;
    }
  }

  /**
   * 完整的前置检查
   */
  async performFullPreCheck() {
    logger.section("📋 前置检查：验证合约部署和配置");

    const checks = {
      gTokenBinding: false,
      superPaymasterLocker: false,
      registryLocker: false,
      superPaymasterConfig: false,
    };

    // 1. 检查 GToken 绑定
    checks.gTokenBinding = await this.checkGTokenBinding();

    // 2. 检查 Lockers
    logger.subsection("检查 GTokenStaking Locker 配置");
    checks.superPaymasterLocker = await this.checkLockerConfig(
      CONTRACTS.SUPER_PAYMASTER_V2,
      "SuperPaymasterV2"
    );
    checks.registryLocker = await this.checkLockerConfig(
      CONTRACTS.REGISTRY,
      "Registry"
    );

    // 3. 检查 SuperPaymasterV2 配置
    checks.superPaymasterConfig = await this.checkSuperPaymasterV2Config();

    // 总结
    logger.blank();
    logger.divider();
    const allPassed = Object.values(checks).every(v => v);

    if (allPassed) {
      logger.success("✅ 所有前置检查通过");
    } else {
      logger.error("❌ 部分检查未通过，请先修复配置");
    }

    return checks;
  }
}

module.exports = new ContractChecker();
module.exports.ContractChecker = ContractChecker;
