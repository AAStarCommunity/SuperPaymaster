const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../../env/.env.v3') });

const CONFIG_PATH = path.join(__dirname, 'config.json');
let CONFIG = {};
if (fs.existsSync(CONFIG_PATH)) {
    CONFIG = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} else {
    console.warn("⚠️ config.json not found.");
}

const ENTRYPOINT_ABI = [
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] calldata ops, address payable beneficiary) external",
    "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) calldata userOp) external view returns (bytes32)",
    "function getNonce(address sender, uint192 key) external view returns (uint256)",
    "function depositTo(address account) external payable"
];

const SIMPLE_ACCOUNT_FACTORY_ABI = [
    "function createAccount(address owner, uint256 salt) external returns (address)",
    "function getAddress(address owner, uint256 salt) external view returns (address)"
];

const ERC20_ABI = [
    "function transfer(address to, uint256 amount) returns (bool)",
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function mint(address to, uint256 amount) external",
    "function allowance(address owner, address spender) view returns (uint256)"
];

const REGISTRY_ABI = [
    "function registerRole(bytes32 roleId, address user, bytes calldata roleData) external",
    "function hasRole(bytes32 roleId, address user) external view returns (bool)"
];

const SUPER_PAYMASTER_ABI = [
    "function configureOperator(address,address,uint256) external",
    "function deposit(uint256) external",
    "function operators(address) external view returns (address,address,bool,uint256,uint256,uint256,uint256)"
];

const SIMPLE_ACCOUNT_ABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external"
];

const ROLE_COMMUNITY = ethers.keccak256(ethers.toUtf8Bytes("COMMUNITY"));
const ROLE_ENDUSER = ethers.keccak256(ethers.toUtf8Bytes("ENDUSER"));

async function main() {
    console.log("🚀 Starting V3 E2E Tests...");
    const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
    const adminWallet = new ethers.Wallet(process.env.PRIVATE_KEY_JASON, provider);
    const userWallet = new ethers.Wallet(process.env.PRIVATE_KEY_ANNI, provider);

    console.log(`👨‍✈️ Admin: ${adminWallet.address}`);
    console.log(`👤 User Signer: ${userWallet.address}`);

    const registry = new ethers.Contract(CONFIG.registry, REGISTRY_ABI, adminWallet);
    const superPaymaster = new ethers.Contract(CONFIG.superPaymaster, SUPER_PAYMASTER_ABI, adminWallet);
    const token = new ethers.Contract(CONFIG.aPNTs, ERC20_ABI, adminWallet);
    const factory = new ethers.Contract(CONFIG.simpleAccountFactory, SIMPLE_ACCOUNT_FACTORY_ABI, adminWallet);
    const entryPoint = new ethers.Contract(CONFIG.entryPoint, ENTRYPOINT_ABI, adminWallet);

    // 1. Calculate Sender AA
    const salt = 0;
    const sender = await factory.getAddress(userWallet.address, salt);
    const initCode = ethers.concat([
        CONFIG.simpleAccountFactory,
        factory.interface.encodeFunctionData("createAccount", [userWallet.address, salt])
    ]);
    console.log(`📦 Sender AA: ${sender}`);

    // Check deployment code
    const code = await provider.getCode(sender);
    const isDeployed = code !== "0x";
    console.log(`   Deployed: ${isDeployed}`);

    // 2. Register Roles
    console.log("\n🔑 Registering Roles...");
    
    // Approve Staking (GToken)
    const gToken = new ethers.Contract(CONFIG.gToken, ERC20_ABI, adminWallet);
    const stakingAddr = CONFIG.staking;
    console.log(`   Approving Staking (${stakingAddr}) for GToken...`);
    let nonce = await provider.getTransactionCount(adminWallet.address);
    // Use pending to be safe? Or latest? latest usually fine.
    // If we rely on counter, we must ensure we don't refetch stale.
    await (await gToken.approve(stakingAddr, ethers.MaxUint256, { nonce: nonce++ })).wait();

    if (!(await registry.hasRole(ROLE_COMMUNITY, adminWallet.address))) {
        // Do NOT refetch nonce. Trust increment.
        await (await registry.connect(adminWallet).registerRole(ROLE_COMMUNITY, adminWallet.address, 
            ethers.AbiCoder.defaultAbiCoder().encode(["tuple(string,string,string,string,string,uint256)"], [["Comm","","","","",0]]),
            { nonce: nonce++ }
        )).wait();
        console.log("   Admin Registered as COMMUNITY.");
    }
    
    // Register EndUser (AA)
    if (!(await registry.hasRole(ROLE_ENDUSER, sender))) {
        // Do NOT refetch nonce. Trust increment.
        await (await registry.connect(adminWallet).registerRole(ROLE_ENDUSER, sender, 
            ethers.AbiCoder.defaultAbiCoder().encode(["tuple(address,address,string,string,uint256)"], [[sender, adminWallet.address, "","" ,0]]),
            { nonce: nonce++ }
        )).wait();
         console.log("   Sender AA Registered as ENDUSER.");
    }

    // 3. Configure Operator
    console.log("\n⚙️  Configuring Paymaster Operator...");
    let op = await superPaymaster.operators(adminWallet.address);
    if (!op[2]) {
        await (await superPaymaster.configureOperator(token.target, adminWallet.address, ethers.parseEther("1.0"))).wait();
    }
    await (await token.mint(adminWallet.address, ethers.parseEther("1000"))).wait();
    await (await token.approve(superPaymaster.target, ethers.MaxUint256)).wait();
    // Check balance
    op = await superPaymaster.operators(adminWallet.address);
    if (op[4] < ethers.parseEther("100")) {
        await (await superPaymaster.deposit(ethers.parseEther("500"))).wait();
        console.log("   Deposited 500 aPNTs.");
    }

    // 4. Fund Sender with ETH and xPNTs
    console.log("\n💰 Funding Sender AA...");
    const balance = await provider.getBalance(sender);
    if (balance < ethers.parseEther("0.1")) {
        await (await adminWallet.sendTransaction({ to: sender, value: ethers.parseEther("0.1") })).wait();
        console.log("   Sent 0.1 ETH to Sender.");
    }
    const tokenBal = await token.balanceOf(sender);
    if (tokenBal < ethers.parseEther("100")) {
        await (await token.mint(sender, ethers.parseEther("500"))).wait();
        console.log("   Minted 500 aPNTs to Sender.");
    }

    // 5. Initial Op: Approve Paymaster (Pay with ETH)
    console.log("\n📝 Step A: Approving Paymaster (ETH payment)...");
    const approveData = token.interface.encodeFunctionData("approve", [superPaymaster.target, ethers.MaxUint256]);
    const executeApprove = new ethers.Interface(SIMPLE_ACCOUNT_ABI).encodeFunctionData("execute", [token.target, 0, approveData]);
    
    // Check current allowance
    const allowance = await token.allowance(sender, superPaymaster.target);
    if (allowance == 0n) {
        await submitUserOp(entryPoint, sender, userWallet, executeApprove, initCode, "0x"); // "0x" paymaster = ETH
        // After first op, contract is deployed, initCode not needed for next, but safe to keep or remove.
    } else {
        console.log("   Already Approved.");
    }

    // 6. Gasless Op: Execution (Pay with Paymaster)
    console.log("\n✨ Step B: Gasless Transaction (Paymaster)...");
    const paymasterAndData = ethers.solidityPacked(
        ["address", "address"],
        [CONFIG.superPaymaster, adminWallet.address] // PM + Operator
    );
    // Arbitrary action: Self-transfer 0 ETH
    const actionData = new ethers.Interface(SIMPLE_ACCOUNT_ABI).encodeFunctionData("execute", [adminWallet.address, 0, "0x"]);
    
    await submitUserOp(entryPoint, sender, userWallet, actionData, "0x", paymasterAndData); // initCode empty if deployed
}

async function submitUserOp(entryPoint, sender, signer, callData, initCodeOrEmpty, paymasterAndData) {
    const nonce = await entryPoint.getNonce(sender, 0);
    const code = await sender.provider.getCode(sender);
    const initCode = (code === "0x") ? initCodeOrEmpty : "0x";

    const userOp = {
        sender,
        nonce,
        initCode,
        callData,
        accountGasLimits: ethers.solidityPacked(["uint128", "uint128"], [500000, 100000]),
        preVerificationGas: 50000,
        gasFees: ethers.solidityPacked(["uint128", "uint128"], [ethers.parseUnits("50", "gwei"), ethers.parseUnits("50", "gwei")]),
        paymasterAndData,
        signature: "0x"
    };

    const hash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await signer.signMessage(ethers.getBytes(hash));

    console.log(`   Submitting Op (Nonce ${nonce})...`);
    try {
        const tx = await entryPoint.handleOps([userOp], signer.address);
        console.log(`   Tx: ${tx.hash}`);
        await tx.wait();
        console.log("   ✅ Success!");
    } catch(e) {
        console.error("   ❌ Failed:", e.message);
        if (e.data) console.error("   Data:", e.data);
    }
}

main().catch(console.error);
