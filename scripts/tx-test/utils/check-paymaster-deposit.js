/**
 * Check Paymaster deposit in EntryPoint
 */
const { ethers } = require("ethers");
const { getProvider, CONTRACTS } = require("./config");

async function main() {
  const provider = getProvider();

  const entryPoint = new ethers.Contract(
    CONTRACTS.ENTRYPOINT,
    [
      "function balanceOf(address account) view returns (uint256)",
      "function getDepositInfo(address account) view returns (uint256 deposit, bool staked, uint112 stake, uint32 unstakeDelaySec, uint48 withdrawTime)",
    ],
    provider
  );

  console.log("EntryPoint:", CONTRACTS.ENTRYPOINT);
  console.log();

  // Check PaymasterV4.1
  const paymasterV4Balance = await entryPoint.balanceOf(CONTRACTS.PAYMASTER_V4_1);
  console.log("PaymasterV4.1:", CONTRACTS.PAYMASTER_V4_1);
  console.log("  Balance:", ethers.formatEther(paymasterV4Balance), "ETH");

  const paymasterV4DepositInfo = await entryPoint.getDepositInfo(CONTRACTS.PAYMASTER_V4_1);
  console.log("  Deposit:", ethers.formatEther(paymasterV4DepositInfo.deposit), "ETH");
  console.log("  Staked:", paymasterV4DepositInfo.staked);
  console.log();

  // Check SuperPaymasterV2
  const superPaymasterBalance = await entryPoint.balanceOf(CONTRACTS.SUPER_PAYMASTER_V2);
  console.log("SuperPaymasterV2:", CONTRACTS.SUPER_PAYMASTER_V2);
  console.log("  Balance:", ethers.formatEther(superPaymasterBalance), "ETH");

  const superPaymasterDepositInfo = await entryPoint.getDepositInfo(CONTRACTS.SUPER_PAYMASTER_V2);
  console.log("  Deposit:", ethers.formatEther(superPaymasterDepositInfo.deposit), "ETH");
  console.log("  Staked:", superPaymasterDepositInfo.staked);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
