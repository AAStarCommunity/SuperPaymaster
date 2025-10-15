#!/bin/bash
# Mint 10000 PNT for a specific account
# Usage: ./scripts/mint-pnt-10000.sh <account_address>

if [ -z "$1" ]; then
  echo "Usage: ./scripts/mint-pnt-10000.sh <account_address>"
  exit 1
fi

ACCOUNT=$1

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$PROJECT_DIR"

node -e "
require('dotenv').config({ path: '.env.v3' });
const { ethers } = require('ethers');

const ACCOUNT = '$ACCOUNT';
const PNT_TOKEN = process.env.GAS_TOKEN_ADDRESS || '0xD14E87d8D8B69016Fcc08728c33799bD3F66F180';
const OWNER2_PRIVATE_KEY = process.env.OWNER2_PRIVATE_KEY;

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
  const owner2 = new ethers.Wallet(OWNER2_PRIVATE_KEY, provider);
  
  const pntABI = [
    'function mint(address to, uint256 amount) public',
    'function balanceOf(address) external view returns (uint256)',
  ];
  
  const pntContract = new ethers.Contract(PNT_TOKEN, pntABI, owner2);
  
  console.log(\`\n🪙 Minting 10000 PNT for \${ACCOUNT}\n\`);
  
  const amount = ethers.parseUnits('10000', 18);
  
  try {
    const beforeBalance = await pntContract.balanceOf(ACCOUNT);
    console.log(\`Current balance: \${ethers.formatUnits(beforeBalance, 18)} PNT\`);
    
    const tx = await pntContract.mint(ACCOUNT, amount);
    console.log(\`Transaction: https://sepolia.etherscan.io/tx/\${tx.hash}\`);
    
    const receipt = await tx.wait();
    console.log(\`✅ Confirmed in block \${receipt.blockNumber}\`);
    
    const afterBalance = await pntContract.balanceOf(ACCOUNT);
    console.log(\`New balance: \${ethers.formatUnits(afterBalance, 18)} PNT\n\`);
  } catch (error) {
    console.log(\`❌ Failed: \${error.message}\n\`);
    process.exit(1);
  }
}

main().then(() => process.exit(0)).catch(error => {
  console.error(error);
  process.exit(1);
});
"
