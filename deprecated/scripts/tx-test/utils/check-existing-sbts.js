const { ethers } = require("ethers");
const { getProvider, ACCOUNT_A, ACCOUNT_B, CONTRACTS } = require("./config");

async function main() {
  const provider = getProvider();

  // PaymasterV4.1 已支持的 SBT
  const sbt1 = "0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8";
  const sbt2 = "0xC6456910ECE42384C0F31Ab453bC598Eb09CEF1d";

  console.log("检查 Account A 和 B 的 SBT 余额");
  console.log("Account A:", ACCOUNT_A);
  console.log("Account B:", ACCOUNT_B);
  console.log();

  for (const sbtAddr of [sbt1, sbt2]) {
    console.log("SBT:", sbtAddr);
    const sbt = new ethers.Contract(
      sbtAddr,
      ["function balanceOf(address) view returns (uint256)"],
      provider
    );

    const balanceA = await sbt.balanceOf(ACCOUNT_A);
    const balanceB = await sbt.balanceOf(ACCOUNT_B);

    console.log("  Account A 余额:", balanceA.toString());
    console.log("  Account B 余额:", balanceB.toString());
    console.log();
  }
}

main();
