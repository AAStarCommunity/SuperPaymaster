require("dotenv").config({ path: ".env.v3" });

const FAUCET_API = "https://faucet.aastar.io/api";
const owner = "0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d";

async function main() {
  console.log("=== Creating SimpleAccount via Faucet API ===\n");
  console.log("Owner:", owner);
  
  // Use random salt
  const salt = Math.floor(Math.random() * 1000000) + Date.now();
  console.log("Salt:", salt);
  
  const response = await fetch(`${FAUCET_API}/create-account`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      owner,
      salt,
    }),
  });
  
  const data = await response.json();
  
  if (!response.ok) {
    console.error("❌ Failed:", data.error || data);
    return;
  }
  
  console.log("\n✅ Account created!");
  console.log("Address:", data.accountAddress);
  console.log("Transaction:", data.txHash);
  
  console.log("\nAdd to .env.v3:");
  console.log(`SIMPLE_ACCOUNT_V1_TEST="${data.accountAddress}"`);
}

main().catch(console.error);
