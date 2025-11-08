const FAUCET_API = "https://faucet.aastar.io/api";
const NEW_ACCOUNT = "0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce";

async function main() {
  console.log("=== Minting tokens to new SimpleAccount V1 ===\n");
  console.log("Account:", NEW_ACCOUNT);
  console.log();
  
  // Mint PNT
  console.log("1. Minting 100 PNT...");
  const pntResponse = await fetch(`${FAUCET_API}/mint`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      address: NEW_ACCOUNT,
      type: "pnt",
    }),
  });
  
  const pntData = await pntResponse.json();
  if (pntResponse.ok) {
    console.log("   ✅ PNT minted, tx:", pntData.txHash);
  } else {
    console.log("   ❌ Failed:", pntData.error);
  }
  
  // Mint SBT
  console.log("\n2. Minting 1 SBT...");
  const sbtResponse = await fetch(`${FAUCET_API}/mint`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      address: NEW_ACCOUNT,
      type: "sbt",
    }),
  });
  
  const sbtData = await sbtResponse.json();
  if (sbtResponse.ok) {
    console.log("   ✅ SBT minted, tx:", sbtData.txHash);
  } else {
    console.log("   ❌ Failed:", sbtData.error);
  }
  
  console.log("\n✅ Token minting complete!");
  console.log("\nWait 10 seconds for confirmation, then check balances...");
  
  await new Promise(resolve => setTimeout(resolve, 10000));
}

main().catch(console.error);
