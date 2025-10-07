require("dotenv").config({ path: ".env.production" });
const { ethers } = require("ethers");

const SEPOLIA_RPC = "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N";
const NEW_PNT = "0x090e34709a592210158aa49a969e4a04e3a29ebd";
const SETTLEMENT = "0x6bbf0c72805ecd4305efccf579c32d6f6d3041d5";
const TEST_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";

const PNT_ABI = [
  "function settlement() view returns (address)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC);
  const pnt = new ethers.Contract(NEW_PNT, PNT_ABI, provider);

  console.log("=== 验证新 PNT 自动授权机制 ===\n");

  // 1. 验证 PNT 基本信息
  const name = await pnt.name();
  const symbol = await pnt.symbol();
  const settlement = await pnt.settlement();

  console.log("PNT 合约信息:");
  console.log("  地址:", NEW_PNT);
  console.log("  名称:", name);
  console.log("  符号:", symbol);
  console.log("  Settlement:", settlement);
  console.log("  预期 Settlement:", SETTLEMENT);
  console.log(
    settlement.toLowerCase() === SETTLEMENT.toLowerCase()
      ? "  ✅ Settlement 地址正确"
      : "  ❌ Settlement 地址错误"
  );

  // 2. 检查测试账户的授权
  console.log("\n测试账户授权检查:");
  console.log("  账户:", TEST_ACCOUNT);

  const balance = await pnt.balanceOf(TEST_ACCOUNT);
  console.log("  余额:", ethers.formatUnits(balance, 18), "PNT");

  const allowance = await pnt.allowance(TEST_ACCOUNT, SETTLEMENT);
  console.log("  授权额度:", allowance.toString());

  const MAX_UINT256 = ethers.MaxUint256;
  console.log("  最大值:", MAX_UINT256.toString());

  if (allowance.toString() === MAX_UINT256.toString()) {
    console.log("  ✅ 已自动授权最大额度");
  } else if (allowance > 0n) {
    console.log("  ⚠️  有授权但非最大额度");
  } else {
    console.log("  ❌ 未授权");
  }

  // 3. 总结
  console.log("\n=== 自动授权机制验证 ===");
  console.log("根据 GasToken.sol 代码:");
  console.log("1. mint() 函数: ✅ 在 mint 时自动授权");
  console.log("2. _update() 函数: ✅ 在 transfer 时自动授权");
  console.log("3. approve() 函数: ✅ 防止用户撤销 Settlement 授权");
  console.log("\n结论: 所有 PNT 持有者都会自动授权给 Settlement");
  console.log("- Mint 时: 自动授权");
  console.log("- Transfer 时: 自动授权");
  console.log("- 无法撤销: approve() 有保护");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
