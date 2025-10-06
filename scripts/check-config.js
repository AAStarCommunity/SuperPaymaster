require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

const CONTRACTS = {
  ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  SIMPLE_ACCOUNT_FACTORY: "0x70F0DBca273a836CbA609B10673A52EED2D15625",
  PAYMASTER_V3: "0x1568da4ea1E2C34255218b6DaBb2458b57B35805",
  SETTLEMENT: "0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5",
  PNT_TOKEN: "0xf2996D81b264d071f99FD13d76D15A9258f4cFa9",
  SBT: "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f", // PaymasterV3 实际配置的 SBT
  SIMPLE_ACCOUNT: "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
  OWNER: "0x411BD567E46C0781248dbB6a9211891C032885e5",
};

const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);

  console.log("=== SuperPaymaster V3 配置检查 ===\n");

  // 1. 检查 PaymasterV3 配置
  console.log("1. PaymasterV3 配置:");
  console.log(`   地址: ${CONTRACTS.PAYMASTER_V3}`);

  const paymasterABI = [
    "function sbtContract() external view returns (address)",
    "function gasToken() external view returns (address)",
    "function settlementContract() external view returns (address)",
    "function minTokenBalance() external view returns (uint256)",
    "function paused() external view returns (bool)",
    "function entryPoint() external view returns (address)",
  ];

  const paymaster = new ethers.Contract(
    CONTRACTS.PAYMASTER_V3,
    paymasterABI,
    provider,
  );

  try {
    const sbtContract = await paymaster.sbtContract();
    const gasToken = await paymaster.gasToken();
    const settlementContract = await paymaster.settlementContract();
    const minTokenBalance = await paymaster.minTokenBalance();
    const paused = await paymaster.paused();
    const entryPoint = await paymaster.entryPoint();

    console.log(`   - sbtContract: ${sbtContract}`);
    console.log(
      `     ${sbtContract === CONTRACTS.SBT ? "✅" : "❌"} ${sbtContract === CONTRACTS.SBT ? "正确" : "配置错误!"}`,
    );

    console.log(`   - gasToken: ${gasToken}`);
    console.log(
      `     ${gasToken === CONTRACTS.PNT_TOKEN ? "✅" : "❌"} ${gasToken === CONTRACTS.PNT_TOKEN ? "正确" : "配置错误!"}`,
    );

    console.log(`   - settlementContract: ${settlementContract}`);
    console.log(
      `     ${settlementContract === CONTRACTS.SETTLEMENT ? "✅" : "❌"} ${settlementContract === CONTRACTS.SETTLEMENT ? "正确" : "配置错误!"}`,
    );

    console.log(
      `   - minTokenBalance: ${ethers.formatUnits(minTokenBalance, 18)} PNT`,
    );
    console.log(
      `     ${minTokenBalance === ethers.parseUnits("10", 18) ? "✅" : "⚠️"} ${minTokenBalance === ethers.parseUnits("10", 18) ? "正确 (10 PNT)" : "非预期值"}`,
    );

    console.log(`   - paused: ${paused}`);
    console.log(
      `     ${!paused ? "✅" : "❌"} ${!paused ? "未暂停" : "已暂停!"}`,
    );

    console.log(`   - entryPoint: ${entryPoint}`);
    console.log(
      `     ${entryPoint === CONTRACTS.ENTRYPOINT ? "✅" : "❌"} ${entryPoint === CONTRACTS.ENTRYPOINT ? "正确" : "配置错误!"}`,
    );
  } catch (error) {
    console.log(`   ❌ 读取配置失败: ${error.message}`);
  }

  // 2. 检查 EntryPoint deposit/stake
  console.log("\n2. PaymasterV3 EntryPoint 存款/质押:");
  const entryPointABI = [
    "function getDepositInfo(address account) external view returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime)",
  ];

  const entryPointContract = new ethers.Contract(
    CONTRACTS.ENTRYPOINT,
    entryPointABI,
    provider,
  );

  try {
    const depositInfo = await entryPointContract.getDepositInfo(
      CONTRACTS.PAYMASTER_V3,
    );
    console.log(`   - Deposit: ${ethers.formatEther(depositInfo.deposit)} ETH`);
    console.log(`   - Staked: ${depositInfo.staked}`);
    console.log(`   - Stake: ${ethers.formatEther(depositInfo.stake)} ETH`);
    console.log(
      `   - Unstake Delay: ${depositInfo.unstakeDelaySec.toString()} seconds (${Number(depositInfo.unstakeDelaySec) / 86400} days)`,
    );

    if (depositInfo.deposit > 0n) {
      console.log(`   ✅ Deposit 充足`);
    } else {
      console.log(`   ⚠️  Deposit 为 0,需要充值`);
    }

    if (depositInfo.staked && depositInfo.stake >= ethers.parseEther("0.1")) {
      console.log(`   ✅ Stake 充足 (>= 0.1 ETH)`);
    } else {
      console.log(`   ⚠️  Stake 不足或未质押`);
    }
  } catch (error) {
    console.log(`   ❌ 读取失败: ${error.message}`);
  }

  // 3. 检查 SimpleAccount 余额
  console.log("\n3. SimpleAccount 测试账户:");
  console.log(`   地址: ${CONTRACTS.SIMPLE_ACCOUNT}`);

  const erc20ABI = [
    "function balanceOf(address) external view returns (uint256)",
  ];
  const pntContract = new ethers.Contract(
    CONTRACTS.PNT_TOKEN,
    erc20ABI,
    provider,
  );
  const sbtContract = new ethers.Contract(CONTRACTS.SBT, erc20ABI, provider);

  try {
    const pntBalance = await pntContract.balanceOf(CONTRACTS.SIMPLE_ACCOUNT);
    console.log(`   - PNT 余额: ${ethers.formatUnits(pntBalance, 18)} PNT`);
    console.log(
      `     ${pntBalance >= ethers.parseUnits("10", 18) ? "✅" : "❌"} ${pntBalance >= ethers.parseUnits("10", 18) ? "满足最低要求 (>= 10 PNT)" : "不足 10 PNT!"}`,
    );

    const sbtBalance = await sbtContract.balanceOf(CONTRACTS.SIMPLE_ACCOUNT);
    console.log(`   - SBT 余额: ${sbtBalance.toString()}`);
    console.log(
      `     ${sbtBalance >= 1n ? "✅" : "❌"} ${sbtBalance >= 1n ? "满足要求 (>= 1)" : "没有 SBT!"}`,
    );

    const ethBalance = await provider.getBalance(CONTRACTS.SIMPLE_ACCOUNT);
    console.log(`   - ETH 余额: ${ethers.formatEther(ethBalance)} ETH`);
    console.log(
      `     ${ethBalance > 0n ? "✅" : "⚠️"} ${ethBalance > 0n ? "有余额" : "余额为 0"}`,
    );
  } catch (error) {
    console.log(`   ❌ 读取失败: ${error.message}`);
  }

  // 4. 检查合约部署状态
  console.log("\n4. 合约部署状态:");
  for (const [name, address] of Object.entries(CONTRACTS)) {
    if (name === "OWNER") continue;
    try {
      const code = await provider.getCode(address);
      const deployed = code !== "0x";
      console.log(
        `   ${deployed ? "✅" : "❌"} ${name}: ${deployed ? "已部署" : "未部署"}`,
      );
    } catch (error) {
      console.log(`   ❌ ${name}: 检查失败`);
    }
  }

  console.log("\n=== 配置检查完成 ===");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
