#!/usr/bin/env node
/**
 * Approve Settlement contract to spend PNT from SimpleAccount
 */

const { ethers } = require('ethers');
const dotenv = require('dotenv');
const path = require('path');

dotenv.config({ path: path.join(__dirname, '../.env.v3') });

const RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SIMPLE_ACCOUNT = '0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D';
const PNT_TOKEN = '0xf2996D81b264d071f99FD13d76D15A9258f4cFa9';
const SETTLEMENT = '0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5';

const provider = new ethers.JsonRpcProvider(RPC_URL);
const ownerWallet = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

const SimpleAccountABI = [
  'function execute(address dest, uint256 value, bytes calldata func) external'
];

const ERC20ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)'
];

async function main() {
  console.log('=== Approve Settlement to spend PNT ===\n');

  const accountContract = new ethers.Contract(SIMPLE_ACCOUNT, SimpleAccountABI, ownerWallet);
  const pntContract = new ethers.Contract(PNT_TOKEN, ERC20ABI, provider);

  // Check current allowance
  const currentAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, SETTLEMENT);
  console.log(`Current allowance: ${ethers.formatEther(currentAllowance)} PNT`);

  if (currentAllowance >= ethers.MaxUint256 / 2n) {
    console.log('✅ Already approved!');
    return;
  }

  // Encode approve calldata
  const approveCalldata = pntContract.interface.encodeFunctionData('approve', [
    SETTLEMENT,
    ethers.MaxUint256
  ]);

  console.log('\nSending approve transaction via SimpleAccount.execute()...');
  const tx = await accountContract.execute(PNT_TOKEN, 0, approveCalldata);
  console.log(`Transaction hash: ${tx.hash}`);

  console.log('Waiting for confirmation...');
  const receipt = await tx.wait();
  console.log(`✅ Approved! Block: ${receipt.blockNumber}`);

  // Verify
  const newAllowance = await pntContract.allowance(SIMPLE_ACCOUNT, SETTLEMENT);
  console.log(`\nNew allowance: ${newAllowance === ethers.MaxUint256 ? 'MAX_UINT256' : ethers.formatEther(newAllowance)} PNT`);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
