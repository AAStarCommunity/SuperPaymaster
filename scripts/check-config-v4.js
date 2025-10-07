require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

const CONTRACTS = {
  ENTRYPOINT:
    process.env.ENTRYPOINT_V07 || "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  SIMPLE_ACCOUNT_FACTORY: "0x70F0DBca273a836CbA609B10673A52EED2D15625",
  PAYMASTER_V4: "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
  REGISTRY: process.env.SUPER_PAYMASTER || "0x838da93c815a6E45Aa50429529da9106C0621eF0",
  PNT_TOKEN: process.env.GAS_TOKEN_ADDRESS || "0x090e34709a592210158aa49a969e4a04e3a29ebd",
  SBT: process.env.SBT_CONTRACT_ADDRESS || "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
  SIMPLE_ACCOUNT: "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
  OWNER:
    process.env.OWNER_ADDRESS || "0x411BD567E46C0781248dbB6a9211891C032885e5",
};

const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);

  console.log("=== SuperPaymaster V4 配置检查 ===\n");

  // 1. 检查 PaymasterV4 配置
  console.log("1. PaymasterV4 配置:");
  console.log(`   地址: ${CONTRACTS.PAYMASTER_V4}`);

  const paymasterABI = [
    "function owner() external view returns (address)",
    "function treasury() external view returns (address)",
    "function gasToUSDRate() external view returns (uint256)",
    "function pntPriceUSD() external view returns (uint256)",
    "function serviceFeeRate() external view returns (uint256)",
    "function maxGasCostCap() external view returns (uint256)",
    "function minTokenBalance() external view returns (uint256)",
    "function paused() external view returns (bool)",
    "function entryPoint() external view returns (address)",
    "function isSBTSupported(address) external view returns (bool)",
    "function isGasTokenSupported(address) external view returns (bool)",
  ];

  const paymaster = new ethers.Contract(
    CONTRACTS.PAYMASTER_V4,
    paymasterABI,
    provider,
  );

  try {
    const owner = await paymaster.owner();
    const treasury = await paymaster.treasury();
    const gasToUSDRate = await paymaster.gasToUSDRate();
    const pntPriceUSD = await paymaster.pntPriceUSD();
    const serviceFeeRate = await paymaster.serviceFeeRate();
    const maxGasCostCap = await paymaster.maxGasCostCap();
    const minTokenBalance = await paymaster.minTokenBalance();
    const paused = await paymaster.paused();
    const entryPoint = await paymaster.entryPoint();
    const isSBTSupported = await paymaster.isSBTSupported(CONTRACTS.SBT);
    const isGasTokenSupported = await paymaster.isGasTokenSupported(CONTRACTS.PNT_TOKEN);

    console.log(`   - owner: ${owner}`);
    console.log(
      `     ${owner === CONTRACTS.OWNER ? "✅" : "❌"} ${owner === CONTRACTS.OWNER ? "正确" : "配置错误!"}`,
    );

    console.log(`   - treasury: ${treasury}`);
    console.log(
      `     ${treasury === CONTRACTS.OWNER ? "✅" : "⚠️"} ${treasury === CONTRACTS.OWNER ? "正确 (与owner相同)" : "treasury地址不同"}`,
    );

    console.log(`   - gasToUSDRate: $${ethers.formatUnits(gasToUSDRate, 18)}/ETH`);
    console.log(
      `     ${gasToUSDRate === ethers.parseUnits("4500", 18) ? "✅" : "⚠️"} ${gasToUSDRate === ethers.parseUnits("4500", 18) ? "正确 ($4500/ETH)" : "非预期值"}`,
    );

    console.log(`   - pntPriceUSD: $${ethers.formatUnits(pntPriceUSD, 18)}/PNT`);
    console.log(
      `     ${pntPriceUSD === ethers.parseUnits("0.02", 18) ? "✅" : "⚠️"} ${pntPriceUSD === ethers.parseUnits("0.02", 18) ? "正确 ($0.02/PNT)" : "非预期值"}`,
    );

    console.log(`   - serviceFeeRate: ${serviceFeeRate} bps (${Number(serviceFeeRate) / 100}%)`);
    console.log(
      `     ${serviceFeeRate === 200n ? "✅" : "⚠️"} ${serviceFeeRate === 200n ? "正确 (2%)" : "非预期值"}`,
    );

    console.log(`   - maxGasCostCap: ${ethers.formatEther(maxGasCostCap)} ETH`);
    console.log(
      `     ${maxGasCostCap === ethers.parseEther("1") ? "✅" : "⚠️"} ${maxGasCostCap === ethers.parseEther("1") ? "正确 (1 ETH)" : "非预期值"}`,
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

    console.log(`   - SBT 支持: ${isSBTSupported}`);
    console.log(
      `     ${isSBTSupported ? "✅" : "❌"} ${isSBTSupported ? "已添加" : "未添加!"}`,
    );

    console.log(`   - GasToken 支持: ${isGasTokenSupported}`);
    console.log(
      `     ${isGasTokenSupported ? "✅" : "❌"} ${isGasTokenSupported ? "已添加" : "未添加!"}`,
    );
  } catch (error) {
    console.log(`   ❌ 读取配置失败: ${error.message}`);
  }

  // 2. 检查 EntryPoint deposit/stake
  console.log("\n2. PaymasterV4 EntryPoint 存款/质押:");
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
      CONTRACTS.PAYMASTER_V4,
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

    if (depositInfo.staked && depositInfo.stake >= ethers.parseEther("0.01")) {
      console.log(`   ✅ Stake 充足 (>= 0.01 ETH)`);
    } else {
      console.log(`   ⚠️  Stake 不足或未质押`);
    }
  } catch (error) {
    console.log(`   ❌ 读取失败: ${error.message}`);
  }

  // 3. 检查 Registry 注册状态
  console.log("\n3. Registry 注册状态:");
  console.log(`   Registry: ${CONTRACTS.REGISTRY}`);

  const registryABI = [
    "function paymasters(address) external view returns (address owner, uint256 feeRate, bool isRegistered, string memory name)",
  ];

  const registry = new ethers.Contract(
    CONTRACTS.REGISTRY,
    registryABI,
    provider,
  );

  try {
    const paymasterInfo = await registry.paymasters(CONTRACTS.PAYMASTER_V4);
    console.log(`   - 注册状态: ${paymasterInfo.isRegistered}`);
    console.log(
      `     ${paymasterInfo.isRegistered ? "✅" : "❌"} ${paymasterInfo.isRegistered ? "已注册" : "未注册!"}`,
    );

    if (paymasterInfo.isRegistered) {
      console.log(`   - 名称: ${paymasterInfo.name}`);
      console.log(`   - Fee Rate: ${paymasterInfo.feeRate} bps (${Number(paymasterInfo.feeRate) / 100}%)`);
      console.log(`   - Owner: ${paymasterInfo.owner}`);
    }
  } catch (error) {
    console.log(`   ❌ 读取注册状态失败: ${error.message}`);
  }

  // 4. 检查 SimpleAccount 余额
  console.log("\n4. SimpleAccount 测试账户:");
  console.log(`   地址: ${CONTRACTS.SIMPLE_ACCOUNT}`);

  const erc20ABI = [
    "function balanceOf(address) external view returns (uint256)",
    "function allowance(address owner, address spender) external view returns (uint256)",
  ];
  const pntContract = new ethers.Contract(
    CONTRACTS.PNT_TOKEN,
    erc20ABI,
    provider,
  );
  const sbtContract = new ethers.Contract(CONTRACTS.SBT, erc20ABI, provider);

  try {
    const pntBalance = await pntContract.balanceOf(CONTRACTS.SIMPLE_ACCOUNT);
    const pntAllowance = await pntContract.allowance(CONTRACTS.SIMPLE_ACCOUNT, CONTRACTS.PAYMASTER_V4);
    console.log(`   - PNT 余额: ${ethers.formatUnits(pntBalance, 18)} PNT`);
    console.log(
      `     ${pntBalance >= ethers.parseUnits("10", 18) ? "✅" : "❌"} ${pntBalance >= ethers.parseUnits("10", 18) ? "满足最低要求 (>= 10 PNT)" : "不足 10 PNT!"}`,
    );
    console.log(`   - PNT Allowance: ${ethers.formatUnits(pntAllowance, 18)} PNT`);
    console.log(
      `     ${pntAllowance >= ethers.parseUnits("10", 18) ? "✅" : "⚠️"} ${pntAllowance >= ethers.parseUnits("10", 18) ? "授权充足" : "需要授权!"}`,
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

  // 5. 检查合约部署状态
  console.log("\n5. 合约部署状态:");
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
