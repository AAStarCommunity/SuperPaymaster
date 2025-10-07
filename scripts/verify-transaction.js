require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

// 从环境变量读取配置（禁止硬编码）
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const SETTLEMENT_ADDRESS =
  process.env.SETTLEMENT_ADDRESS || process.env.SETTLEMENT_CONTRACT;
const PNT_TOKEN = process.env.GAS_TOKEN_ADDRESS || process.env.PNTS_TOKEN;
const PAYMASTER_V3 =
  process.env.PAYMASTER_V3 || process.env.PAYMASTER_V3_ADDRESS;

// 事件签名
const EVENT_SIGNATURES = {
  Transfer:
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
  FeeRecorded:
    "0x59bc8c26c3ac31a3be75ec594a8cb634f78f31b308aeac90e49b01771c4ea92c", // FeeRecorded(bytes32,address,address,address,uint256,bytes32)
  UserOperationEvent:
    "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f",
  UserOperationRevertReason:
    "0xf62676f440ff169a3a9afdbf812e89e7f95975ee8e5c31214ffdef631c5f4792",
  GasRecorded:
    "0x70e0197164703995c4c19d162383b1af76fe5faa74392a5491ee98ab3d810d7f",
};

async function verifyTransaction(txHash) {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);

  console.log("=== 交易验证脚本 ===\n");
  console.log(`交易哈希: ${txHash}`);
  console.log(`Etherscan: https://sepolia.etherscan.io/tx/${txHash}\n`);

  // 获取交易回执
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt) {
    console.log("❌ 交易未找到或尚未确认");
    return;
  }

  console.log(`状态: ${receipt.status === 1 ? "✅ 成功" : "❌ 失败"}`);
  console.log(`区块: ${receipt.blockNumber}`);
  console.log(`Gas Used: ${receipt.gasUsed.toString()}\n`);

  let results = {
    pntTransfer: false,
    settlementRecorded: false,
    userOpSuccess: false,
    userOpReverted: false,
    gasCostRecorded: false,
  };

  // 分析所有事件
  console.log("=== 事件分析 ===\n");

  for (const log of receipt.logs) {
    const topic0 = log.topics[0];

    // 1. 检查 PNT Transfer 事件
    if (
      topic0 === EVENT_SIGNATURES.Transfer &&
      log.address.toLowerCase() === PNT_TOKEN.toLowerCase()
    ) {
      results.pntTransfer = true;
      const from = ethers.getAddress("0x" + log.topics[1].slice(26));
      const to = ethers.getAddress("0x" + log.topics[2].slice(26));
      const amount = ethers.formatUnits(log.data, 18);

      console.log("✅ PNT Token 转账成功");
      console.log(`   From: ${from}`);
      console.log(`   To:   ${to}`);
      console.log(`   Amount: ${amount} PNT\n`);
    }

    // 2. 检查 Settlement FeeRecorded 事件
    if (
      topic0 === EVENT_SIGNATURES.FeeRecorded &&
      log.address.toLowerCase() === SETTLEMENT_ADDRESS.toLowerCase()
    ) {
      results.settlementRecorded = true;
      // FeeRecorded(bytes32 indexed recordKey, address indexed paymaster, address indexed user, address token, uint256 amount, bytes32 userOpHash)
      const recordKey = log.topics[1];
      const paymaster = ethers.getAddress("0x" + log.topics[2].slice(26));
      const user = ethers.getAddress("0x" + log.topics[3].slice(26));

      // 解码 data (token, amount, userOpHash)
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["address", "uint256", "bytes32"],
        log.data,
      );

      console.log("✅ Settlement 记账成功");
      console.log(`   RecordKey: ${recordKey}`);
      console.log(`   Paymaster: ${paymaster}`);
      console.log(`   User: ${user}`);
      console.log(`   Token: ${decoded[0]}`);
      console.log(`   Amount: ${decoded[1].toString()} Gwei`);
      console.log(`   UserOpHash: ${decoded[2]}\n`);
    }

    // 3. 检查 PaymasterV3 GasRecorded 事件
    if (
      topic0 === EVENT_SIGNATURES.GasRecorded &&
      log.address.toLowerCase() === PAYMASTER_V3.toLowerCase()
    ) {
      results.gasCostRecorded = true;
      // GasRecorded(address indexed user, uint256 gasCost, address indexed token)
      const user = ethers.getAddress("0x" + log.topics[1].slice(26));
      const token = ethers.getAddress("0x" + log.topics[2].slice(26));

      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["uint256"],
        log.data,
      );

      console.log("✅ PaymasterV3 Gas 记录成功");
      console.log(`   User: ${user}`);
      console.log(`   Token: ${token}`);
      console.log(`   Gas Cost: ${ethers.formatEther(decoded[0])} ETH\n`);
    }

    // 4. 检查 UserOperationEvent
    if (topic0 === EVENT_SIGNATURES.UserOperationEvent) {
      const userOpHash = log.topics[1];
      const sender = ethers.getAddress("0x" + log.topics[2].slice(26));
      const paymaster = ethers.getAddress("0x" + log.topics[3].slice(26));

      // 解码 data (nonce, success, actualGasCost, actualGasUsed)
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["uint256", "bool", "uint256", "uint256"],
        log.data,
      );

      results.userOpSuccess = decoded[1]; // success flag

      console.log("📋 UserOperation 执行结果");
      console.log(`   UserOpHash: ${userOpHash}`);
      console.log(`   Sender: ${sender}`);
      console.log(`   Paymaster: ${paymaster}`);
      console.log(`   Nonce: ${decoded[0].toString()}`);
      console.log(`   Success: ${decoded[1] ? "✅ true" : "❌ false"}`);
      console.log(`   Actual Gas Cost: ${ethers.formatEther(decoded[2])} ETH`);
      console.log(`   Actual Gas Used: ${decoded[3].toString()}\n`);
    }

    // 5. 检查 UserOperationRevertReason
    if (topic0 === EVENT_SIGNATURES.UserOperationRevertReason) {
      results.userOpReverted = true;
      const userOpHash = log.topics[1];
      const sender = ethers.getAddress("0x" + log.topics[2].slice(26));

      // 解码 data (nonce, revertReason)
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["uint256", "bytes"],
        log.data,
      );

      console.log("⚠️  UserOperation 内部调用 Revert");
      console.log(`   UserOpHash: ${userOpHash}`);
      console.log(`   Sender: ${sender}`);
      console.log(`   Nonce: ${decoded[0].toString()}`);
      console.log(`   Revert Reason (hex): ${ethers.hexlify(decoded[1])}`);

      // 尝试解码错误选择器
      if (decoded[1].length >= 4) {
        const errorSelector = ethers.hexlify(decoded[1].slice(0, 4));
        console.log(`   Error Selector: ${errorSelector}`);
      }
      console.log();
    }
  }

  // 总结
  console.log("=== 验证总结 ===\n");

  const checks = [
    { name: "PNT Token 转账", passed: results.pntTransfer },
    { name: "Settlement 记账", passed: results.settlementRecorded },
    { name: "PaymasterV3 Gas 记录", passed: results.gasCostRecorded },
    { name: "UserOp 执行成功", passed: results.userOpSuccess },
  ];

  let allPassed = true;
  for (const check of checks) {
    const status = check.passed ? "✅ 通过" : "❌ 失败";
    console.log(`${status} - ${check.name}`);
    if (!check.passed) allPassed = false;
  }

  if (results.userOpReverted) {
    console.log("⚠️  警告 - UserOp 内部调用发生 Revert");
    allPassed = false;
  }

  console.log();
  if (allPassed) {
    console.log("🎉 所有检查通过！交易执行成功。");
  } else {
    console.log("❌ 部分检查失败，请查看上面的详细信息。");
  }

  return results;
}

// 主函数
async function main() {
  const txHash = process.argv[2];

  if (!txHash || !txHash.startsWith("0x")) {
    console.log("用法: node verify-transaction.js <交易哈希>\n");
    console.log("示例:");
    console.log(
      "  node verify-transaction.js 0x9dab3911c26c635f89b1f58711706e85ad39f7695bf04e44ceb7a4118d51dc35",
    );
    process.exit(1);
  }

  await verifyTransaction(txHash);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n错误:", error.message);
    process.exit(1);
  });
