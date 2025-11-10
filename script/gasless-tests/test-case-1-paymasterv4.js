#!/usr/bin/env node

/**
 * Gasless Transfer Test Case 1
 *
 * Tests gasless ERC20 token transfer using:
 * - PaymasterV4: 0x0cf072952047bC42F43694631ca60508B3fF7f5e
 * - xPNTs Token: 0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215
 * - EntryPoint v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
 *
 * Reads RPC URL and private keys from /Volumes/UltraDisk/Dev2/aastar/env/.env
 */

const { ethers } = require('ethers');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../../env/.env') });

// Contract addresses
const PAYMASTER_ADDRESS = '0x0cf072952047bC42F43694631ca60508B3fF7f5e';
const XPNTS_TOKEN_ADDRESS = '0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215';
const ENTRYPOINT_ADDRESS = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const SIMPLE_ACCOUNT_FACTORY_ADDRESS = process.env.SIMPLE_ACCOUNT_FACTORY_ADDRESS_V2;

// ABIs (minimal for testing)
const ERC20_ABI = [
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)"
];

const ENTRYPOINT_ABI = [
  "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external"
];

const SIMPLE_ACCOUNT_ABI = [
  "function execute(address dest, uint256 value, bytes calldata func) external",
  "function getNonce() view returns (uint256)",
  "function entryPoint() view returns (address)"
];

async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Gasless Transfer Test Case 1 - PaymasterV4           ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  // Load config from env
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  const senderPrivateKey = process.env.OWNER_PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  const recipientAddress = process.env.OWNER2_ADDRESS || process.env.TEST_EOA_ADDRESS;

  if (!rpcUrl) {
    throw new Error('SEPOLIA_RPC_URL not found in /Volumes/UltraDisk/Dev2/aastar/env/.env');
  }
  if (!senderPrivateKey) {
    throw new Error('OWNER_PRIVATE_KEY not found in /Volumes/UltraDisk/Dev2/aastar/env/.env');
  }
  if (!recipientAddress) {
    throw new Error('OWNER2_ADDRESS not found in /Volumes/UltraDisk/Dev2/aastar/env/.env');
  }

  console.log('📌 Configuration:');
  console.log(`  RPC: ${rpcUrl.substring(0, 50)}...`);
  console.log(`  Paymaster: ${PAYMASTER_ADDRESS}`);
  console.log(`  xPNTs Token: ${XPNTS_TOKEN_ADDRESS}`);
  console.log(`  EntryPoint: ${ENTRYPOINT_ADDRESS}\n`);

  // Setup provider and signer
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(senderPrivateKey, provider);

  // Get sender's AA account address (SimpleAccountV2)
  const senderAAAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || process.env.SIMPLE_ACCOUNT_A;
  if (!senderAAAccount) {
    throw new Error('TEST_AA_ACCOUNT_ADDRESS_A not found in env');
  }

  console.log(`  Sender AA Account: ${senderAAAccount}`);
  console.log(`  Sender EOA: ${wallet.address}`);
  console.log(`  Recipient: ${recipientAddress}\n`);

  // Connect to contracts
  const xPNTsToken = new ethers.Contract(XPNTS_TOKEN_ADDRESS, ERC20_ABI, provider);
  const simpleAccount = new ethers.Contract(senderAAAccount, SIMPLE_ACCOUNT_ABI, provider);
  const entryPoint = new ethers.Contract(ENTRYPOINT_ADDRESS, ENTRYPOINT_ABI, wallet);

  try {
    // Step 1: Check token balance
    console.log('📊 Step 1: Check xPNTs Balance');
    const balance = await xPNTsToken.balanceOf(senderAAAccount);
    const symbol = await xPNTsToken.symbol();
    const decimals = await xPNTsToken.decimals();
    const formattedBalance = ethers.formatUnits(balance, decimals);

    console.log(`  Balance: ${formattedBalance} ${symbol}`);

    if (balance === 0n) {
      console.log('  ⚠️  Warning: Zero balance, cannot test transfer\n');
      return;
    }

    // Step 2: Prepare transfer calldata
    console.log('\n📝 Step 2: Prepare Transfer CallData');
    const transferAmount = ethers.parseUnits('1', decimals); // Transfer 1 token
    const transferCalldata = xPNTsToken.interface.encodeFunctionData('transfer', [
      recipientAddress,
      transferAmount
    ]);

    // AA account execute() calldata
    const executeCalldata = simpleAccount.interface.encodeFunctionData('execute', [
      XPNTS_TOKEN_ADDRESS,
      0, // value
      transferCalldata
    ]);

    console.log(`  Transfer Amount: 1 ${symbol}`);
    console.log(`  Calldata length: ${executeCalldata.length} bytes`);

    // Step 3: Build UserOperation
    console.log('\n🔨 Step 3: Build UserOperation');
    const nonce = await simpleAccount.getNonce();
    console.log(`  Nonce: ${nonce}`);

    // UserOperation structure (v0.7)
    const userOp = {
      sender: senderAAAccount,
      nonce: nonce,
      initCode: '0x', // Account already deployed
      callData: executeCalldata,
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [150000, 150000]), // verificationGasLimit, callGasLimit
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [1000000000, 1000000000]), // maxPriorityFeePerGas, maxFeePerGas
      paymasterAndData: PAYMASTER_ADDRESS, // Simple paymaster, no extra data
      signature: '0x' // Will be filled after signing
    };

    console.log('  UserOp prepared');

    // Step 4: Sign UserOperation
    console.log('\n✍️  Step 4: Sign UserOperation');

    // Get chain ID
    const network = await provider.getNetwork();
    const chainId = network.chainId;
    console.log(`  Chain ID: ${chainId}`);

    // Create UserOp hash (simplified - actual implementation requires proper EIP-4337 hash)
    const userOpHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ['address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256', 'bytes32', 'bytes32'],
        [
          userOp.sender,
          userOp.nonce,
          ethers.keccak256(userOp.initCode),
          ethers.keccak256(userOp.callData),
          userOp.accountGasLimits,
          userOp.preVerificationGas,
          userOp.gasFees,
          ethers.keccak256(userOp.paymasterAndData)
        ]
      )
    );

    // Sign with EOA
    const signature = await wallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log(`  Signature: ${signature.substring(0, 20)}...`);

    // Step 5: Submit to EntryPoint
    console.log('\n🚀 Step 5: Submit UserOp to EntryPoint');
    console.log('  ⚠️  Note: This is a simplified test and may fail due to signature format');
    console.log('  For production, use proper EIP-4337 libraries like @account-abstraction/sdk');

    // Beneficiary (receives gas payment)
    const beneficiary = wallet.address;

    // Estimate gas first
    try {
      const gasEstimate = await entryPoint.handleOps.estimateGas([userOp], beneficiary);
      console.log(`  Estimated gas: ${gasEstimate}`);
    } catch (error) {
      console.log(`  Gas estimation failed: ${error.message}`);
      console.log('  Proceeding anyway...');
    }

    // Send transaction
    console.log('  Sending transaction...');
    const tx = await entryPoint.handleOps([userOp], beneficiary);
    console.log(`  TX Hash: ${tx.hash}`);
    console.log(`  Etherscan: https://sepolia.etherscan.io/tx/${tx.hash}`);

    console.log('  Waiting for confirmation...');
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log('  ✅ Transaction confirmed!\n');

      // Check new balances
      console.log('📊 Final Balances:');
      const newBalance = await xPNTsToken.balanceOf(senderAAAccount);
      const recipientBalance = await xPNTsToken.balanceOf(recipientAddress);
      console.log(`  Sender: ${ethers.formatUnits(newBalance, decimals)} ${symbol}`);
      console.log(`  Recipient: ${ethers.formatUnits(recipientBalance, decimals)} ${symbol}`);
    } else {
      console.log('  ❌ Transaction failed\n');
    }

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    if (error.data) {
      console.error('  Error data:', error.data);
    }
    process.exit(1);
  }

  console.log('\n╔═══════════════════════════════════════════════════════════╗');
  console.log('║                    Test Completed                         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
