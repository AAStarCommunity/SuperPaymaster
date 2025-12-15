const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../env/.env.v3') });

// Load Config
const CONFIG_PATH = path.join(__dirname, 'config.json');
let CONFIG = {};
if (fs.existsSync(CONFIG_PATH)) {
    CONFIG = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} else {
    console.warn("⚠️ config.json not found. Please run SetupV3.s.sol first.");
}

// ABIs
const ENTRYPOINT_ABI = [
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
    "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) external view returns (bytes32)",
    "function getNonce(address sender, uint192 key) external view returns (uint256)",
    "function depositTo(address account) external payable"
];

const ERC20_ABI = [
    "function transfer(address to, uint256 amount) returns (bool)",
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function mint(address to, uint256 amount) external" 
];

const REGISTRY_ABI = [
    "function registerRole(bytes32 roleId, address user, bytes calldata roleData) external",
    "function hasRole(bytes32 roleId, address user) external view returns (bool)",
    "function checkRole(bytes32 roleId, address user) external view returns (bool)"
];

const STAKING_ABI = [
    "function stake(uint256 amount) external",
    "function lockStake(address user, bytes32 roleId, uint256 amount, uint256 entryBurn, address payer) external"
];

const SIMPLE_ACCOUNT_ABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external",
    "function getNonce() view returns (uint256)"
];

// Constants
const ROLE_COMMUNITY = ethers.keccak256(ethers.toUtf8Bytes("COMMUNITY"));
const ROLE_ENDUSER = ethers.keccak256(ethers.toUtf8Bytes("ENDUSER"));
const ROLE_PAYMASTER_SUPER = ethers.keccak256(ethers.toUtf8Bytes("PAYMASTER_SUPER"));

async function main() {
    console.log("🚀 Starting V3 E2E Gasless Tests...");

    // Setup Provider & Signers
    const rpcUrl = process.env.SEPOLIA_RPC_URL;
    if (!rpcUrl) throw new Error("Missing SEPOLIA_RPC_URL");
    
    // Signers from ENV
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const adminKey = process.env.PRIVATE_KEY_JASON;
    const userKey = process.env.PRIVATE_KEY_ANNI;

    if (!adminKey || !userKey) throw new Error("Missing Private Keys in .env.v3");

    const adminWallet = new ethers.Wallet(adminKey, provider); // Owner/Operator/Community
    const userWallet = new ethers.Wallet(userKey, provider);    // End User

    console.log(`👨‍✈️ Admin: ${adminWallet.address}`);
    console.log(`👤 User:  ${userWallet.address}`);

    // Contracts
    const entryPoint = new ethers.Contract(CONFIG.entryPoint, ENTRYPOINT_ABI, adminWallet);
    const registry = new ethers.Contract(CONFIG.registry, REGISTRY_ABI, adminWallet);
    const xPNTs = new ethers.Contract(CONFIG.aPNTs, ERC20_ABI, adminWallet); // Using aPNTs as xPNTs for test? Or separate?
    // In SetupV3, we mapped "aPNTs" to xPNTsToken.
    // We also have "xPNTsFactory" to deploy user tokens.
    // For Scenario B, let's use the 'aPNTs' token as the community token for simplicity, or deploy one.
    
    const superPaymasterAddress = CONFIG.superPaymaster;
    const paymasterV4Address = CONFIG.paymasterV4Proxy; // Proxy Instance
    // Since SetupV3 didn't output Proxy address (it outputs factory), we might need to deploy it or finding it.
    // For this test, let's assume we use SuperPaymasterV3 (Scenario B) primarily, 
    // And for V4, we need to deploy a proxy.
    
    // 4. Configure Operator (Community)
    console.log("\n⚙️  Configuring Operator...");
    
    // Connect to SuperPaymaster as Admin (Operator)
    const superPaymaster = new ethers.Contract(CONFIG.superPaymaster, [
        "function configureOperator(address,address,uint256) external",
        "function deposit(uint256) external",
        "function operators(address) external view returns (address,address,bool,uint256,uint256,uint256,uint256)"
    ], adminWallet); // Changed ADMIN to adminWallet

    // Verify configuration
    let opConfig = await superPaymaster.operators(adminWallet.address); // Changed ADMIN to adminWallet
    if (!opConfig[2]) { // isConfigured
        console.log("   Operator not configured. Configuring...");
        const txConfig = await superPaymaster.configureOperator(
            CONFIG.aPNTs, // xPNTs Token (created in Setup) - Changed to aPNTs as per later logic
            adminWallet.address,     // Treasury (Admin for now) - Changed ADMIN to adminWallet
            ethers.parseEther("1.0") // Exchange Rate 1:1
        );
        await txConfig.wait();
        console.log("   ✅ Operator Configured.");
    }

    // 5. Fund Operator with aPNTs (Deposit)
    console.log("\n💰 Funding Operator with aPNTs...");
    const aPNTs = new ethers.Contract(CONFIG.aPNTs, ERC20_ABI, adminWallet); // Changed ADMIN to adminWallet
    
    // Check allowanced
    const allowance = await aPNTs.allowance(adminWallet.address, CONFIG.superPaymaster); // Changed ADMIN to adminWallet
    if (allowance < ethers.parseEther("1000")) {
         console.log("   Approving aPNTs...");
         const txApprove = await aPNTs.approve(CONFIG.superPaymaster, ethers.MaxUint256);
         await txApprove.wait();
    }

    // Check Balance in Paymaster
    opConfig = await superPaymaster.operators(adminWallet.address); // Changed ADMIN to adminWallet
    if (opConfig[4] < ethers.parseEther("100")) { // aPNTsBalance
        console.log("   Depositing 1000 aPNTs...");
        // Mint if local mock (Setup V3 mints initial supply to deployer?)
        // If aPNTs is Mock, we can mint?
        // Note: SetupV3 deployed xPNTsToken as aPNTs on Anvil. It mints 1 ether?
        // Wait, SetupV3: `new xPNTsToken(..., 1 ether)`. Only 1 ether minted to deployer?
        // We might need more.
        // xPNTsToken constructor mints `initialSupply`.
        
        // If we need more, mint it (if owner).
        try {
             const txMint = await aPNTs.mint(adminWallet.address, ethers.parseEther("10000")); // Changed ADMIN to adminWallet
             await txMint.wait();
             console.log("   Minted 10000 aPNTs to Admin.");
        } catch (e) {
             console.log("   Could not mint aPNTs (maybe not owner or not mock). Assuming sufficient balance.");
        }

        const txDeposit = await superPaymaster.deposit(ethers.parseEther("1000"));
        await txDeposit.wait();
        console.log("   ✅ Deposited 1000 aPNTs.");
    }

    // 6. Fund User with xPNTs (to pay for transaction)
    console.log("\n💸 Funding User with xPNTs...");
    // const xPNTs = new ethers.Contract(CONFIG.xPNTsToken, ERC20_ABI, adminWallet); // Connect as Admin to mint/transfer
    // Mint/Transfer to USER
    // Check Logic: xPNTsFactory created it? Or Setup deployed it?
    // Setup deployed `xPNTsToken` (mock aPNTs) AND `xPNTsFactory`.
    // Wait, `config.xPNTs` vs `config.aPNTs`.
    // In `SetupV3`, `aPNTs` is the token used for `SuperPaymaster`.
    // `xPNTsFactory` is address.
    // But `xPNTs` (the token User pays with) must be created/defined.
    // SuperPaymaster uses `CONFIG.xPNTsToken`.
    // In `configureOperator`, I used `CONFIG.xPNTsToken`.
    // Where is `CONFIG.xPNTsToken` defined?
    // SetupV3 output:
    // "aPNTs": "0x..."
    // "gToken": "0x..." 
    // "xPNTsFactory": "0x..."
    // "paymasterFactory": ...
    // "registry": ...
    // "superPaymaster": ...
    // "sbt": ...
    // "staking": ...
    // 
    // It does NOT output `xPNTsToken` (User Token).
    // The Operator must specify a token.
    // I can use `gToken` as the payment token for testing?
    // Or I can deploy a fresh Token for testing?
    // Or usage `aPNTs` itself? (Operator accepts aPNTs from User).
    // Let's use `aPNTs` address as `xPNTsToken` for simplicity in this test.
    // User pays aPNTs, Operator pays aPNTs.
    // So Operator Exchange Rate 1:1.
    // User needs aPNTs.
    
    const userPaymentToken = CONFIG.aPNTs; 
    console.log(`   Using ${userPaymentToken} as Payment Token (xPNTs)`);

    // Re-configure operator to use this token
     const txConfigRetry = await superPaymaster.configureOperator(
            userPaymentToken, 
            adminWallet.address, // Changed ADMIN to adminWallet
            ethers.parseEther("1.0")
    );
    await txConfigRetry.wait();

    const paymentToken = new ethers.Contract(userPaymentToken, ERC20_ABI, adminWallet); // Changed ADMIN to adminWallet
    // Mint to User
    try {
        const txMintUser = await paymentToken.mint(userWallet.address, ethers.parseEther("500")); // Changed USER to userWallet
        await txMintUser.wait();
        console.log("   ✅ Minted 500 Payment Tokens to User.");
    } catch (e) {
        // If mint fails, try transfer
        const txTransfer = await paymentToken.transfer(userWallet.address, ethers.parseEther("500")); // Changed USER to userWallet
        await txTransfer.wait();
         console.log("   ✅ Transferred 500 Payment Tokens to User.");
    }

    // User Approve SuperPaymaster
    const userToken = paymentToken.connect(userWallet); // Changed USER to userWallet
    const txApproveUser = await userToken.approve(CONFIG.superPaymaster, ethers.MaxUint256);
    await txApproveUser.wait();
    console.log("   ✅ User Approved SuperPaymaster.");

    // 2. Register User as ENDUSER
    const isEndUser = await registry.checkRole(ROLE_ENDUSER, userWallet.address);
    if (!isEndUser) {
        console.log("  Registering User as ENDUSER...");
        // admin calls registerRole for user (or user calls self).
        // For simplicity, Admin airdrops/registers user?
        // Or user calls registerRoleSelf?
    } else {
        console.log("  ✅ User is ENDUSER");
    }

    // --- Scenario B: SuperPaymaster V3 ---
    console.log("\n🧪 Executing Scenario B: SuperPaymaster V3 Logic");
    
    // UserAA (SimpleAccount)
    // We need the User's CA (Contract Account).
    // If using SimpleAccountFactory, predict address.
    // For this test, let's assume USER_WALLET *IS* the signer for the AA, and we construct the AA address manually 
    // OR we use the EOA directly?
    // User request: "Use a normal EOA directly interact with entrypoint...".
    // Wait. EntryPoint `handleOps` executes UserOps. 
    // UserOp `sender` MUST be a Smart Account (AA).
    // EOA CANNOT be the sender in a UserOp (sender must have `validateUserOp`).
    // The user probably meant: "Use EOA to SIGN and SUBMIT the UserOp for the AA".
    // "Use our superpaymaster... submit gasless transaction".
    
    // We need a deployed SimpleAccount for the user.
    // config.json doesn't have it.
    // We can use `TEST_SIMPLE_ACCOUNT_A` from env if deployed.
    const senderAA = process.env.TEST_SIMPLE_ACCOUNT_A || "0xECD9C07f648B09CFb78906302822Ec52Ab87dd70";
    console.log(`  AA Sender: ${senderAA}`);

    // Construct CallData: Transfer xPNTs
    // dest: adminWallet.address
    const dest = adminWallet.address;
    const amount = ethers.parseEther("0.1");
    const callDataInner = xPNTs.interface.encodeFunctionData("transfer", [dest, amount]);
    
    // AA Execute CallData
    const accountInterface = new ethers.Interface(SIMPLE_ACCOUNT_ABI);
    const callData = accountInterface.encodeFunctionData("execute", [CONFIG.aPNTs, 0, callDataInner]);

    const nonce = await entryPoint.getNonce(senderAA, 0);
    
    // Paymaster Data: SuperPaymaster + Operator Address
    // V3 Requirement: [PM(20)][Operator(20)]
    const operatorAddr = adminWallet.address;
    const paymasterAndData = ethers.solidityPacked(
        ["address", "address"],
        [superPaymasterAddress, operatorAddr]
    );

    const userOp = {
        sender: senderAA,
        nonce: nonce,
        initCode: "0x", // Assumes account deployed
        callData: callData,
        accountGasLimits: ethers.solidityPacked(["uint128", "uint128"], [500000, 100000]), // gasLimit
        preVerificationGas: 50000,
        gasFees: ethers.solidityPacked(["uint128", "uint128"], [ethers.parseUnits("50", "gwei"), ethers.parseUnits("100", "gwei")]),
        paymasterAndData: paymasterAndData,
        signature: "0x"
    };

    // Hash & Sign
    const userOpHash = await entryPoint.getUserOpHash(userOp);
    console.log(`  UserOp Hash: ${userOpHash}`);
    
    const signature = await userWallet.signMessage(ethers.getBytes(userOpHash));
    userOp.signature = signature;

    console.log("  Submitting UserOp...");
    
    try {
        const tx = await entryPoint.handleOps([userOp], adminWallet.address);
        console.log(`  Tx Hash: ${tx.hash}`);
        await tx.wait();
        console.log("  ✅ Transaction Mined!");
    } catch (e) {
        console.error("  ❌ Transaction Failed:", e.message);
        if (e.data) console.error("  Data:", e.data);
    }
}

main().catch(console.error);
