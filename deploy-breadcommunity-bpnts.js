const { ethers } = require("ethers");

const FACTORY_ADDRESS = "0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd";
const RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N";

// Read OWNER2 private key from env
const fs = require('fs');
const envContent = fs.readFileSync('env/.env', 'utf8');
const lines = envContent.split('\n');
let OWNER2_PRIVATE_KEY = '';
for (const line of lines) {
  if (line.startsWith('OWNER2_PRIVATE_KEY=')) {
    OWNER2_PRIVATE_KEY = line.split('=')[1].trim();
    break;
  }
}

const FACTORY_ABI = [
  "function deployxPNTsToken(string memory name, string memory symbol, string memory communityName, string memory communityENS, uint256 exchangeRate, address paymasterAOA) external returns (address token)",
  "event xPNTsTokenDeployed(address indexed community, address indexed tokenAddress, string name, string symbol)"
];

async function deployBreadBPNTs() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);
  
  console.log("=== Deploying bPNTs for BreadCommunity ===");
  console.log("Deployer (OWNER2):", signer.address);
  console.log("Factory:", FACTORY_ADDRESS);
  console.log("");
  
  const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);
  
  // Deploy bPNTs for BreadCommunity
  const tx = await factory.deployxPNTsToken(
    "Bread Points",           // name
    "bPNTs",                  // symbol
    "BreadCommunity",         // communityName
    "bread.eth",              // communityENS
    ethers.parseUnits("0.03", 18), // exchangeRate (0.03 = 3 cents per bPNT)
    ethers.ZeroAddress        // paymasterAOA (no specific AOA paymaster)
  );
  
  console.log("Transaction sent:", tx.hash);
  const receipt = await tx.wait();
  console.log("Transaction confirmed in block:", receipt.blockNumber);
  console.log("");
  
  // Parse event to get deployed token address
  const event = receipt.logs.find(log => {
    try {
      return factory.interface.parseLog(log)?.name === 'xPNTsTokenDeployed';
    } catch {
      return false;
    }
  });
  
  if (event) {
    const parsedEvent = factory.interface.parseLog(event);
    console.log("✅ bPNTs deployed successfully!");
    console.log("Token Address:", parsedEvent.args.tokenAddress);
    console.log("Community:", parsedEvent.args.community);
    console.log("Name:", parsedEvent.args.name);
    console.log("Symbol:", parsedEvent.args.symbol);
    console.log("");
    console.log("Update this address in shared-config:");
    console.log("bPNTs:", parsedEvent.args.tokenAddress);
  }
}

deployBreadBPNTs().catch(console.error);
