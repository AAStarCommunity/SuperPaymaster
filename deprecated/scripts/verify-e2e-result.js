require("dotenv").config({ path: ".env.v3" });
const { ethers } = require("ethers");

const SETTLEMENT = "0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5";
const PNT_TOKEN = "0xf2996D81b264d071f99FD13d76D15A9258f4cFa9";
const SIMPLE_ACCOUNT = "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";
const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";
const TX_HASH = "0x5bcea0df573e1f1c02c60af5ed69404649b5039b17a3d3db61028193d607ad83";
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;

const SettlementABI = [
  "function getUserDebt(address user) external view returns (uint256)",
  "event GasConsumed(address indexed user, uint256 gasUsedInGwei)",
];

const ERC20ABI = [
  "function balanceOf(address account) external view returns (uint256)",
];

async function main() {
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);

  console.log("=== Verify E2E Test Result ===\n");

  // 1. Check transaction receipt
  console.log("Transaction:", TX_HASH);
  const receipt = await provider.getTransactionReceipt(TX_HASH);
  console.log("Block:", receipt.blockNumber);
  console.log("Status:", receipt.status === 1 ? "✅ Success" : "❌ Failed");
  console.log("Gas used:", receipt.gasUsed.toString());

  // 2. Parse logs for GasConsumed event
  const settlement = new ethers.Contract(SETTLEMENT, SettlementABI, provider);
  const gasConsumedEvents = receipt.logs
    .filter((log) => log.address.toLowerCase() === SETTLEMENT.toLowerCase())
    .map((log) => {
      try {
        return settlement.interface.parseLog({
          topics: log.topics,
          data: log.data,
        });
      } catch (e) {
        return null;
      }
    })
    .filter((event) => event && event.name === "GasConsumed");

  console.log("\nGasConsumed Events:");
  if (gasConsumedEvents.length > 0) {
    gasConsumedEvents.forEach((event) => {
      console.log(
        `  User: ${event.args.user}, Gas (Gwei): ${event.args.gasUsedInGwei}`,
      );
    });
  } else {
    console.log("  ⚠️  No GasConsumed events found");
  }

  // 3. Check Settlement debt
  console.log("\nSettlement Contract:");
  const debt = await settlement.getUserDebt(SIMPLE_ACCOUNT);
  console.log(`  User debt: ${debt} Gwei`);

  // 4. Check PNT balances
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);
  const simpleAccountBalance = await pntContract.balanceOf(SIMPLE_ACCOUNT);
  const recipientBalance = await pntContract.balanceOf(RECIPIENT);

  console.log("\nPNT Balances:");
  console.log(
    `  SimpleAccount: ${ethers.formatUnits(simpleAccountBalance, 18)} PNT`,
  );
  console.log(
    `  Recipient: ${ethers.formatUnits(recipientBalance, 18)} PNT`,
  );

  // 5. Expected results
  console.log("\n=== Expected Results ===");
  console.log("✅ Transaction successful");
  console.log("✅ GasConsumed event emitted with gas cost in Gwei");
  console.log("✅ Settlement contract recorded user debt");
  console.log("✅ SimpleAccount PNT balance decreased by 0.5 PNT");
  console.log("✅ Recipient received 0.5 PNT");
  console.log(
    "\n📝 Next: Run Keeper script to settle gas fees from PNT balance",
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
