import { ethers } from 'ethers';
import * as dotenv from 'dotenv';
import * as path from 'path';
dotenv.config({ path: path.join(__dirname, 'env/.env') });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const REGISTRY_ADDRESS = process.env.SuperPaymasterRegistryV1_2;

const REGISTRY_ABI = [
  'function getActivePaymasters() external view returns (address[])',
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const registry = new ethers.Contract(REGISTRY_ADDRESS!, REGISTRY_ABI, provider);
  
  const paymasters = await registry.getActivePaymasters();
  
  console.log(`Found ${paymasters.length} active Paymasters:\n`);
  paymasters.forEach((pm: string, i: number) => {
    console.log(`#${i}: ${pm}`);
  });
}

main();
