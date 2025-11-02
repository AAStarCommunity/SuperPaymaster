/**
 * UserOperation 构建工具
 * 支持 EntryPoint v0.7 的 UserOperation 格式
 */
const { ethers } = require("ethers");
const { getProvider, getContract, CONTRACTS, CHAIN_ID } = require("./config");
const logger = require("./logger");

/**
 * 构建 UserOperation
 */
async function buildUserOp(params) {
  const {
    sender,                  // Simple Account 地址
    callData,                // 执行的 callData
    paymasterAddress,        // Paymaster 地址
    operatorAddress = null,  // AOA+: Operator 地址
    xPNTsAddress = null,    // AOA: Gas Token 地址
    nonce = null,           // 可选，自动获取
    callGasLimit = 100000n,
    verificationGasLimit = 150000n,
    preVerificationGas = 21000n,
    maxFeePerGas = null,    // 可选，自动获取
    maxPriorityFeePerGas = null, // 可选，自动获取
    paymasterVerificationGasLimit = 100000n,  // Paymaster verification gas
    paymasterPostOpGasLimit = 50000n,         // Paymaster postOp gas
  } = params;

  const provider = getProvider();

  // 获取 nonce
  let userNonce = nonce;
  if (userNonce === null) {
    const entryPoint = getContract("ENTRYPOINT", CONTRACTS.ENTRYPOINT, provider);
    userNonce = await entryPoint.getNonce(sender, 0);
    logger.data("Nonce", userNonce.toString());
  }

  // 获取 gas price
  const feeData = await provider.getFeeData();
  const actualMaxFeePerGas = maxFeePerGas || feeData.maxFeePerGas || ethers.parseUnits("10", "gwei");
  const actualMaxPriorityFeePerGas = maxPriorityFeePerGas || feeData.maxPriorityFeePerGas || ethers.parseUnits("1", "gwei");

  logger.amount("Max Fee Per Gas", ethers.formatUnits(actualMaxFeePerGas, "gwei"), "gwei");
  logger.amount("Max Priority Fee", ethers.formatUnits(actualMaxPriorityFeePerGas, "gwei"), "gwei");

  // 构建 paymasterAndData
  let paymasterAndData;

  if (operatorAddress) {
    // AOA+ 模式 (SuperPaymasterV2) - EntryPoint v0.7 格式
    // [0:20]   paymaster address (20 bytes)
    // [20:36]  verificationGasLimit (16 bytes / uint128)
    // [36:52]  postOpGasLimit (16 bytes / uint128)
    // [52:72]  operator address (20 bytes, custom data)
    logger.info("构建 AOA+ 模式 paymasterAndData...");
    logger.address("Operator", operatorAddress);

    paymasterAndData = ethers.concat([
      paymasterAddress,                                    // 20 bytes
      ethers.toBeHex(paymasterVerificationGasLimit, 16),   // 16 bytes (uint128)
      ethers.toBeHex(paymasterPostOpGasLimit, 16),         // 16 bytes (uint128)
      operatorAddress,                                     // 20 bytes
    ]);
  } else if (xPNTsAddress) {
    // AOA 模式 (PaymasterV4.1) - EntryPoint v0.7 格式
    // [0:20]   paymaster address (20 bytes)
    // [20:36]  verificationGasLimit (16 bytes / uint128)
    // [36:52]  postOpGasLimit (16 bytes / uint128)
    // [52:72]  xPNTs address (20 bytes, custom data)
    // [72:78]  validUntil (6 bytes)
    // [78:84]  validAfter (6 bytes)
    logger.info("构建 AOA 模式 paymasterAndData...");
    logger.address("xPNTs Token", xPNTsAddress);

    paymasterAndData = ethers.concat([
      paymasterAddress,                                    // 20 bytes
      ethers.toBeHex(paymasterVerificationGasLimit, 16),   // 16 bytes (uint128)
      ethers.toBeHex(paymasterPostOpGasLimit, 16),         // 16 bytes (uint128)
      xPNTsAddress,                                        // 20 bytes
      ethers.zeroPadValue("0x", 6),                        // validUntil (6 bytes) - 0 表示无限期
      ethers.zeroPadValue("0x", 6),                        // validAfter (6 bytes) - 0 表示立即生效
    ]);
  } else {
    throw new Error("必须提供 operatorAddress (AOA+) 或 xPNTsAddress (AOA)");
  }

  logger.data("Paymaster And Data 长度", paymasterAndData.length);
  logger.data("Paymaster And Data", paymasterAndData);

  // 构建 UserOperation
  const userOp = {
    sender,
    nonce: userNonce,
    initCode: "0x",  // 已部署的账户，initCode 为空
    callData,
    callGasLimit,
    verificationGasLimit,
    preVerificationGas,
    maxFeePerGas: actualMaxFeePerGas,
    maxPriorityFeePerGas: actualMaxPriorityFeePerGas,
    paymasterAndData,
    signature: "0x",  // 稍后签名
  };

  return userOp;
}

/**
 * 计算 userOpHash
 */
async function getUserOpHash(userOp) {
  const provider = getProvider();
  const entryPoint = getContract("ENTRYPOINT", CONTRACTS.ENTRYPOINT, provider);

  // 将 UserOp 转换为 tuple 格式
  const userOpTuple = [
    userOp.sender,
    userOp.nonce,
    userOp.initCode,
    userOp.callData,
    userOp.callGasLimit,
    userOp.verificationGasLimit,
    userOp.preVerificationGas,
    userOp.maxFeePerGas,
    userOp.maxPriorityFeePerGas,
    userOp.paymasterAndData,
    userOp.signature,
  ];

  const hash = await entryPoint.getUserOpHash(userOpTuple);
  logger.data("UserOp Hash", hash);

  return hash;
}

/**
 * 签名 UserOperation（使用 EIP-191）
 */
async function signUserOp(userOp, signer) {
  logger.info("签名 UserOperation...");

  // 获取 userOpHash
  const userOpHash = await getUserOpHash(userOp);

  // 使用 EIP-191 签名（\x19Ethereum Signed Message:\n32）
  const signature = await signer.signMessage(ethers.getBytes(userOpHash));

  logger.data("Signature", signature);

  return signature;
}

/**
 * 执行 UserOperation
 */
async function executeUserOp(userOp, beneficiary, signer) {
  logger.subsection("执行 UserOperation");

  const entryPoint = getContract("ENTRYPOINT", CONTRACTS.ENTRYPOINT, signer);

  // 将 UserOp 转换为 tuple 格式
  const userOpTuple = [
    userOp.sender,
    userOp.nonce,
    userOp.initCode,
    userOp.callData,
    userOp.callGasLimit,
    userOp.verificationGasLimit,
    userOp.preVerificationGas,
    userOp.maxFeePerGas,
    userOp.maxPriorityFeePerGas,
    userOp.paymasterAndData,
    userOp.signature,
  ];

  logger.info("调用 EntryPoint.handleOps...");
  logger.address("Beneficiary", beneficiary);

  try {
    const tx = await entryPoint.handleOps([userOpTuple], beneficiary);
    logger.info(`交易已发送: ${tx.hash}`);

    logger.info("等待交易确认...");
    const receipt = await tx.wait();

    logger.success(`✅ 交易确认: ${receipt.transactionHash}`);
    logger.data("Gas 消耗", receipt.gasUsed.toString());
    logger.data("Effective Gas Price", ethers.formatUnits(receipt.gasPrice || 0n, "gwei") + " gwei");

    return receipt;

  } catch (error) {
    logger.error(`执行失败: ${error.message}`);

    // 尝试解析 revert 原因
    if (error.data) {
      logger.error(`Revert data: ${error.data}`);
    }

    throw error;
  }
}

/**
 * 解析 UserOperationEvent
 */
function parseUserOperationEvent(receipt) {
  logger.subsection("解析 UserOperationEvent");

  const entryPointInterface = new ethers.Interface([
    "event UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)"
  ]);

  for (const log of receipt.logs) {
    try {
      const parsed = entryPointInterface.parseLog({
        topics: log.topics,
        data: log.data
      });

      if (parsed && parsed.name === "UserOperationEvent") {
        const event = parsed.args;

        logger.success("✅ 找到 UserOperationEvent");
        logger.data("UserOp Hash", event.userOpHash);
        logger.address("Sender", event.sender);
        logger.address("Paymaster", event.paymaster);
        logger.data("Nonce", event.nonce.toString());
        logger.check("Success", event.success);
        logger.amount("Actual Gas Cost", ethers.formatEther(event.actualGasCost), "ETH");
        logger.data("Actual Gas Used", event.actualGasUsed.toString());

        return event;
      }
    } catch (e) {
      // 不是 UserOperationEvent，跳过
    }
  }

  logger.warning("⚠️  未找到 UserOperationEvent");
  return null;
}

module.exports = {
  buildUserOp,
  getUserOpHash,
  signUserOp,
  executeUserOp,
  parseUserOperationEvent,
};
