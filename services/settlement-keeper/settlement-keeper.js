#!/usr/bin/env node
/**
 * SuperPaymaster V3 Settlement Keeper
 *
 * 功能:
 * 1. 每小时监听FeeRecorded事件
 * 2. 获取历史ETH/USD价格 (CoinGecko + 缓存)
 * 3. 计算应扣PNT数量
 * 4. 执行链下结算
 *
 * 运行: node keeper/settlement-keeper.js
 * Cron: 0 * * * * (每小时)
 */

const ethers = require("ethers");
const fs = require("fs");
const path = require("path");

// ============ 配置 ============

const CONFIG = {
  // RPC
  rpcUrl: process.env.OPTIMISM_RPC_URL || "https://mainnet.optimism.io",

  // 合约地址
  settlement: process.env.SETTLEMENT_ADDRESS,
  treasury: process.env.TREASURY_ADDRESS,

  // 私钥 (Keeper钱包)
  privateKey: process.env.KEEPER_PRIVATE_KEY,

  // PNT价格 (固定 $0.02)
  pntPriceUSD: 0.02,

  // 价格缓存文件
  cacheFile: path.join(__dirname, "price-cache.json"),

  // CoinGecko API
  coingeckoAPI: "https://api.coingecko.com/api/v3",

  // 每次处理的最大记录数
  maxRecordsPerBatch: 100,

  // 查询事件的区块范围 (1小时约180个区块 on Optimism)
  blockRange: 500,
};

// ============ 价格缓存 ============

class PriceCache {
  constructor(cacheFile) {
    this.cacheFile = cacheFile;
    this.cache = this.loadCache();
  }

  loadCache() {
    try {
      if (fs.existsSync(this.cacheFile)) {
        const data = fs.readFileSync(this.cacheFile, "utf8");
        return JSON.parse(data);
      }
    } catch (error) {
      console.error("Failed to load cache:", error);
    }
    return {};
  }

  saveCache() {
    try {
      fs.writeFileSync(this.cacheFile, JSON.stringify(this.cache, null, 2));
    } catch (error) {
      console.error("Failed to save cache:", error);
    }
  }

  get(date) {
    return this.cache[date];
  }

  set(date, ethPrice) {
    this.cache[date] = {
      ethPrice,
      timestamp: Date.now(),
      source: "coingecko",
    };
    this.saveCache();
  }
}

// ============ 价格API ============

class PriceOracle {
  constructor(apiUrl, cache) {
    this.apiUrl = apiUrl;
    this.cache = cache;
  }

  async getHistoricalETHPrice(timestamp) {
    // 转换为日期格式 (YYYY-MM-DD)
    const date = new Date(timestamp * 1000).toISOString().split("T")[0];

    // 检查缓存
    const cached = this.cache.get(date);
    if (cached) {
      console.log(`Cache hit for ${date}: $${cached.ethPrice}`);
      return cached.ethPrice;
    }

    // 调用CoinGecko API
    console.log(`Fetching ETH price for ${date}...`);
    const url = `${this.apiUrl}/coins/ethereum/history?date=${this.formatDate(date)}`;

    try {
      const response = await fetch(url);
      const data = await response.json();

      if (!data.market_data || !data.market_data.current_price) {
        throw new Error("Invalid API response");
      }

      const ethPrice = data.market_data.current_price.usd;

      // 价格异常检测 (>50% 变化)
      this.detectPriceAnomaly(date, ethPrice);

      // 缓存
      this.cache.set(date, ethPrice);

      console.log(`ETH price on ${date}: $${ethPrice}`);
      return ethPrice;
    } catch (error) {
      console.error(`Failed to fetch price for ${date}:`, error);

      // Fallback: 使用固定价格
      console.warn(`Using fallback price: $2500`);
      return 2500;
    }
  }

  detectPriceAnomaly(currentDate, currentPrice) {
    // 获取前一天的价格
    const prevDate = new Date(currentDate);
    prevDate.setDate(prevDate.getDate() - 1);
    const prevDateStr = prevDate.toISOString().split("T")[0];

    const prevCached = this.cache.get(prevDateStr);
    if (!prevCached) {
      return; // 没有历史数据，跳过检测
    }

    const prevPrice = prevCached.ethPrice;
    const priceChange = Math.abs(currentPrice - prevPrice) / prevPrice;

    if (priceChange > 0.5) {
      const changePercent = (priceChange * 100).toFixed(2);
      console.warn("\n" + "⚠️".repeat(40));
      console.warn(`🚨 PRICE ANOMALY DETECTED! 🚨`);
      console.warn(`Date: ${currentDate}`);
      console.warn(`Previous Price: $${prevPrice.toFixed(2)} (${prevDateStr})`);
      console.warn(`Current Price: $${currentPrice.toFixed(2)}`);
      console.warn(`Change: ${changePercent}% (>${50}% threshold)`);
      console.warn(
        `Direction: ${currentPrice > prevPrice ? "📈 UP" : "📉 DOWN"}`,
      );
      console.warn("⚠️".repeat(40) + "\n");

      // TODO: Send alert to monitoring service (Slack/Discord/Email)
      // await this.sendAlert({
      //   type: 'PRICE_ANOMALY',
      //   date: currentDate,
      //   prevPrice,
      //   currentPrice,
      //   changePercent
      // });
    }
  }

  formatDate(isoDate) {
    // CoinGecko格式: DD-MM-YYYY
    const [year, month, day] = isoDate.split("-");
    return `${day}-${month}-${year}`;
  }
}

// ============ Settlement Keeper ============

class SettlementKeeper {
  constructor(config) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.wallet = new ethers.Wallet(config.privateKey, this.provider);

    // 价格缓存和Oracle
    this.priceCache = new PriceCache(config.cacheFile);
    this.priceOracle = new PriceOracle(config.coingeckoAPI, this.priceCache);

    // 合约ABI (简化版)
    this.settlementABI = [
      "event FeeRecorded(bytes32 indexed recordKey, address indexed paymaster, address indexed user, address token, uint256 amount, bytes32 userOpHash)",
      "function settleFees(bytes32[] calldata recordKeys, bytes32 settlementHash) external",
      "function feeRate() external view returns (uint256)",
      "function getFeeRecord(bytes32 recordKey) external view returns (tuple(address paymaster, address user, address token, uint256 amount, uint256 timestamp, uint8 status, bytes32 userOpHash, bytes32 settlementHash))",
    ];

    this.gasTokenABI = [
      "function transferFrom(address from, address to, uint256 amount) external returns (bool)",
      "function balanceOf(address account) external view returns (uint256)",
      "function allowance(address owner, address spender) external view returns (uint256)",
    ];

    this.settlement = new ethers.Contract(
      config.settlement,
      this.settlementABI,
      this.wallet,
    );
  }

  async run() {
    console.log("=".repeat(80));
    console.log("SuperPaymaster V3 Settlement Keeper");
    console.log("Time:", new Date().toISOString());
    console.log("=".repeat(80));

    try {
      // 1. 获取最新区块
      const latestBlock = await this.provider.getBlockNumber();
      const fromBlock = latestBlock - this.config.blockRange;

      console.log(
        `\nQuerying events from block ${fromBlock} to ${latestBlock}...`,
      );

      // 2. 查询FeeRecorded事件
      const events = await this.settlement.queryFilter(
        this.settlement.filters.FeeRecorded(),
        fromBlock,
        latestBlock,
      );

      console.log(`Found ${events.length} FeeRecorded events\n`);

      if (events.length === 0) {
        console.log("No pending records to settle");
        return;
      }

      // 3. 处理每个事件
      const recordsToSettle = [];

      for (const event of events.slice(0, this.config.maxRecordsPerBatch)) {
        const { recordKey, paymaster, user, token, amount, userOpHash } =
          event.args;

        console.log(`\n--- Processing Record ${recordKey.slice(0, 10)}... ---`);
        console.log(`User: ${user}`);
        console.log(`Token: ${token}`);
        console.log(`Amount: ${ethers.formatUnits(amount, "gwei")} Gwei`);

        try {
          // 获取完整记录 (包含timestamp)
          const record = await this.settlement.getFeeRecord(recordKey);

          // 检查状态
          if (record.status !== 0) {
            // 0 = Pending
            console.log(`Skipped: status=${record.status} (not pending)`);
            continue;
          }

          // 计算应扣PNT
          const pntAmount = await this.calculatePNT(
            record.amount, // gasGwei (uint256)
            record.timestamp, // timestamp
          );

          console.log(`Calculated PNT: ${ethers.formatEther(pntAmount)} PNT`);

          // 检查用户余额和授权
          const gasToken = new ethers.Contract(
            token,
            this.gasTokenABI,
            this.provider,
          );
          const balance = await gasToken.balanceOf(user);
          const allowance = await gasToken.allowance(
            user,
            this.config.settlement,
          );

          console.log(`User balance: ${ethers.formatEther(balance)} PNT`);
          console.log(`Allowance: ${ethers.formatEther(allowance)} PNT`);

          if (balance < pntAmount) {
            console.warn(`⚠️  Insufficient balance! Skipping...`);
            continue;
          }

          if (allowance < pntAmount) {
            console.warn(`⚠️  Insufficient allowance! Skipping...`);
            continue;
          }

          // 执行transferFrom
          // TODO: 批量转账优化 - Batch Transfer Optimization
          // 当前实现: 逐个执行 transferFrom，每条记录一个交易
          // 未来改进: 使用 Multicall (ERC-4337 Account) 批量提交所有转账
          //   - 降低gas成本 (N个转账 → 1个multicall)
          //   - 提高吞吐量 (原子性批量处理)
          //   - 简化链上Settlement调用 (一次性标记所有记录为Settled)
          // 实现方案:
          //   1. 收集所有 transferFrom calldata
          //   2. 使用 Multicall3 合约批量执行
          //   3. 全部成功后调用 Settlement.settleFees()
          console.log(
            `Transferring ${ethers.formatEther(pntAmount)} PNT from ${user} to ${this.config.treasury}...`,
          );

          const tx = await gasToken
            .connect(this.wallet)
            .transferFrom(user, this.config.treasury, pntAmount);

          console.log(`Transfer TX: ${tx.hash}`);
          await tx.wait();
          console.log(`✅ Transfer confirmed`);

          // 加入结算列表
          recordsToSettle.push(recordKey);
        } catch (error) {
          console.error(`❌ Failed to process record:`, error.message);
          // 继续处理下一条
        }
      }

      // 4. 批量结算
      if (recordsToSettle.length > 0) {
        console.log(`\n${"=".repeat(80)}`);
        console.log(`Settling ${recordsToSettle.length} records...`);

        const settlementHash = ethers.id(
          `settlement-${Date.now()}-${Math.random()}`,
        );

        const tx = await this.settlement.settleFees(
          recordsToSettle,
          settlementHash,
        );
        console.log(`Settlement TX: ${tx.hash}`);

        await tx.wait();
        console.log(`✅ Settlement confirmed!`);
        console.log(`Settlement Hash: ${settlementHash}`);
      } else {
        console.log(`\nNo records to settle (all skipped or failed)`);
      }
    } catch (error) {
      console.error("\n❌ Keeper error:", error);
      throw error;
    } finally {
      console.log(`\n${"=".repeat(80)}`);
      console.log("Keeper run completed");
      console.log("=".repeat(80));
    }
  }

  async calculatePNT(gasGwei, timestamp) {
    // 1. 获取历史ETH价格
    const ethPriceUSD = await this.priceOracle.getHistoricalETHPrice(
      Number(timestamp),
    );

    // 2. 转换gasGwei为ETH
    const gasETH = (Number(gasGwei) * 1e9) / 1e18; // Gwei to ETH

    // 3. 计算USD成本
    const gasCostUSD = gasETH * ethPriceUSD;

    // 4. 计算PNT数量
    let pntAmount = gasCostUSD / this.config.pntPriceUSD;

    // 5. 获取手续费率
    const feeRate = await this.settlement.feeRate();

    // 6. 添加手续费
    pntAmount = (pntAmount * (10000 + Number(feeRate))) / 10000;

    // 7. 转换为wei (18 decimals)
    return ethers.parseEther(pntAmount.toString());
  }
}

// ============ 主函数 ============

async function main() {
  // 验证环境变量
  if (!CONFIG.settlement) {
    console.error("Error: SETTLEMENT_ADDRESS not set");
    process.exit(1);
  }

  if (!CONFIG.treasury) {
    console.error("Error: TREASURY_ADDRESS not set");
    process.exit(1);
  }

  if (!CONFIG.privateKey) {
    console.error("Error: KEEPER_PRIVATE_KEY not set");
    process.exit(1);
  }

  const keeper = new SettlementKeeper(CONFIG);
  await keeper.run();
}

// 运行
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { SettlementKeeper, PriceOracle, PriceCache };
