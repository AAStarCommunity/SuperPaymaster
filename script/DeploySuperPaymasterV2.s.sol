// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/Registry.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";
import "../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../src/paymasters/v2/tokens/MySBT.sol";
import "../src/paymasters/v2/monitoring/DVTValidator.sol";
import "../src/paymasters/v2/monitoring/BLSAggregator.sol";

/**
 * @title DeploySuperPaymasterV2
 * @notice Complete deployment script for SuperPaymaster v2.0 system
 * @dev Deploys all contracts in correct order with proper initialization
 *
 * Deployment Order:
 * 1. Mock GToken (if not exists)
 * 2. GTokenStaking
 * 3. Registry
 * 4. SuperPaymasterV2
 * 5. xPNTsFactory
 * 6. MySBT
 * 7. DVTValidator
 * 8. BLSAggregator
 *
 * Usage:
 * forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
 *   --rpc-url $RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify
 */
contract DeploySuperPaymasterV2 is Script {

    // ====================================
    // Configuration
    // ====================================

    /// @notice EntryPoint v0.7 address (Sepolia)
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice Mock GToken address (deploy if not exists)
    address public GTOKEN;

    // ====================================
    // Deployment State
    // ====================================

    GTokenStaking public gtokenStaking;
    Registry public registry;
    SuperPaymasterV2 public superPaymaster;
    xPNTsFactory public xpntsFactory;
    MySBT public mysbt;
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== SuperPaymaster v2.0 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy or use existing GToken
        _deployGToken();

        // Step 2: Deploy GTokenStaking
        _deployGTokenStaking();

        // Step 3: Deploy Registry
        _deployRegistry();

        // Step 4: Deploy SuperPaymasterV2
        _deploySuperPaymaster();

        // Step 5: Deploy xPNTsFactory
        _deployXPNTsFactory();

        // Step 6: Deploy MySBT
        _deployMySBT();

        // Step 7: Deploy DVTValidator
        _deployDVTValidator();

        // Step 8: Deploy BLSAggregator
        _deployBLSAggregator();

        // Step 9: Initialize connections
        _initializeConnections();

        vm.stopBroadcast();

        // Print summary
        _printDeploymentSummary();
    }

    // ====================================
    // Deployment Functions
    // ====================================

    function _deployGToken() internal {
        console.log("Step 1: Deploying GToken (Mock)...");

        // Check if GToken exists from environment
        try vm.envAddress("GTOKEN_ADDRESS") returns (address existingGToken) {
            GTOKEN = existingGToken;
            console.log("Using existing GToken:", GTOKEN);
        } catch {
            // Deploy mock GToken for testing
            GTOKEN = address(new MockERC20("GToken", "GT", 18));
            console.log("Deployed Mock GToken:", GTOKEN);

            // Mint initial supply for testing (1,000,000 GT)
            MockERC20(GTOKEN).mint(msg.sender, 1_000_000 ether);
            console.log("Minted 1,000,000 GT to deployer");
        }

        console.log("");
    }

    function _deployGTokenStaking() internal {
        console.log("Step 2: Deploying GTokenStaking...");

        gtokenStaking = new GTokenStaking(GTOKEN);

        console.log("GTokenStaking deployed:", address(gtokenStaking));
        console.log("MIN_STAKE:", gtokenStaking.MIN_STAKE() / 1e18, "GT");
        console.log("UNSTAKE_DELAY:", gtokenStaking.UNSTAKE_DELAY() / 1 days, "days");
        console.log("Treasury:", gtokenStaking.treasury());
        console.log("");
    }

    function _deployRegistry() internal {
        console.log("Step 3: Deploying Registry...");

        registry = new Registry();

        console.log("Registry deployed:", address(registry));
        console.log("");
    }

    function _deploySuperPaymaster() internal {
        console.log("Step 4: Deploying SuperPaymasterV2...");

        superPaymaster = new SuperPaymasterV2(
            address(gtokenStaking),
            address(registry)
        );

        console.log("SuperPaymasterV2 deployed:", address(superPaymaster));
        console.log("minOperatorStake:", superPaymaster.minOperatorStake() / 1e18, "sGT");
        console.log("minAPNTsBalance:", superPaymaster.minAPNTsBalance() / 1e18, "aPNTs");
        console.log("");
    }

    function _deployXPNTsFactory() internal {
        console.log("Step 5: Deploying xPNTsFactory...");

        xpntsFactory = new xPNTsFactory(
            address(superPaymaster),
            address(registry)
        );

        console.log("xPNTsFactory deployed:", address(xpntsFactory));
        console.log("DEFAULT_SAFETY_FACTOR:", xpntsFactory.DEFAULT_SAFETY_FACTOR() / 1e18);
        console.log("MIN_SUGGESTED_AMOUNT:", xpntsFactory.MIN_SUGGESTED_AMOUNT() / 1e18, "aPNTs");
        console.log("");
    }

    function _deployMySBT() internal {
        console.log("Step 6: Deploying MySBT...");

        mysbt = new MySBT(
            GTOKEN,
            address(gtokenStaking)
        );

        console.log("MySBT deployed:", address(mysbt));
        console.log("minLockAmount:", mysbt.minLockAmount() / 1e18, "sGT");
        console.log("mintFee:", mysbt.mintFee() / 1e18, "GT");
        console.log("creator:", mysbt.creator());
        console.log("");
    }

    function _deployDVTValidator() internal {
        console.log("Step 7: Deploying DVTValidator...");

        dvtValidator = new DVTValidator(address(superPaymaster));

        console.log("DVTValidator deployed:", address(dvtValidator));
        console.log("MIN_VALIDATORS:", dvtValidator.MIN_VALIDATORS());
        console.log("PROPOSAL_EXPIRATION:", dvtValidator.PROPOSAL_EXPIRATION() / 1 hours, "hours");
        console.log("");
    }

    function _deployBLSAggregator() internal {
        console.log("Step 8: Deploying BLSAggregator...");

        blsAggregator = new BLSAggregator(
            address(superPaymaster),
            address(dvtValidator)
        );

        console.log("BLSAggregator deployed:", address(blsAggregator));
        console.log("THRESHOLD:", blsAggregator.THRESHOLD());
        console.log("MAX_VALIDATORS:", blsAggregator.MAX_VALIDATORS());
        console.log("");
    }

    function _initializeConnections() internal {
        console.log("Step 9: Initializing connections...");

        // Set MySBT in SuperPaymaster
        mysbt.setSuperPaymaster(address(superPaymaster));
        console.log("MySBT.setSuperPaymaster:", address(superPaymaster));

        // Set DVT Aggregator in SuperPaymaster
        superPaymaster.setDVTAggregator(address(blsAggregator));
        console.log("SuperPaymaster.setDVTAggregator:", address(blsAggregator));

        // Set EntryPoint in SuperPaymaster
        superPaymaster.setEntryPoint(ENTRYPOINT_V07);
        console.log("SuperPaymaster.setEntryPoint:", ENTRYPOINT_V07);

        // Set BLS Aggregator in DVT Validator
        dvtValidator.setBLSAggregator(address(blsAggregator));
        console.log("DVTValidator.setBLSAggregator:", address(blsAggregator));

        // ====================================
        // Configure Lock System and Exit Fees
        // ====================================

        // Set treasury for exit fees (use deployer for now, transfer to multisig later)
        gtokenStaking.setTreasury(msg.sender);
        console.log("GTokenStaking.setTreasury:", msg.sender);

        // Configure MySBT locker (flat 0.1 sGT exit fee)
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);

        gtokenStaking.configureLocker(
            address(mysbt),
            true,                    // authorized
            0.1 ether,              // baseExitFee: 0.1 sGT
            emptyTiers,             // no time tiers
            emptyFees,              // no tiered fees
            address(0)              // use default treasury
        );
        console.log("Configured MySBT locker: flat 0.1 sGT exit fee");

        // Configure SuperPaymaster locker (tiered exit fees based on operating time)
        uint256[] memory spTiers = new uint256[](3);
        spTiers[0] = 90 days;
        spTiers[1] = 180 days;
        spTiers[2] = 365 days;

        uint256[] memory spFees = new uint256[](4);
        spFees[0] = 15 ether;   // < 90 days: 15 sGT
        spFees[1] = 10 ether;   // 90-180 days: 10 sGT
        spFees[2] = 7 ether;    // 180-365 days: 7 sGT
        spFees[3] = 5 ether;    // >= 365 days: 5 sGT

        gtokenStaking.configureLocker(
            address(superPaymaster),
            true,                    // authorized
            0,                       // baseExitFee not used
            spTiers,                // time tiers
            spFees,                 // tiered fees
            address(0)              // use default treasury
        );
        console.log("Configured SuperPaymaster locker: tiered exit fees (5-15 sGT)");

        // Set SuperPaymaster in GTokenStaking (for slash operations)
        gtokenStaking.setSuperPaymaster(address(superPaymaster));
        console.log("GTokenStaking.setSuperPaymaster:", address(superPaymaster));

        console.log("");
    }

    // ====================================
    // Summary
    // ====================================

    function _printDeploymentSummary() internal view {
        console.log("=== Deployment Summary ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  GToken:", GTOKEN);
        console.log("  GTokenStaking:", address(gtokenStaking));
        console.log("  Registry:", address(registry));
        console.log("  SuperPaymasterV2:", address(superPaymaster));
        console.log("");
        console.log("Token System:");
        console.log("  xPNTsFactory:", address(xpntsFactory));
        console.log("  MySBT:", address(mysbt));
        console.log("");
        console.log("Monitoring System:");
        console.log("  DVTValidator:", address(dvtValidator));
        console.log("  BLSAggregator:", address(blsAggregator));
        console.log("");
        console.log("EntryPoint:");
        console.log("  EntryPoint v0.7:", ENTRYPOINT_V07);
        console.log("");
        console.log("Deployment complete!");
        console.log("");
        console.log("Next steps:");
        console.log("1. Register DVT validators (dvtValidator.registerValidator)");
        console.log("2. Register BLS public keys (blsAggregator.registerBLSPublicKey)");
        console.log("3. Register communities (registry.registerCommunity)");
        console.log("4. Test operator registration (superPaymaster.registerOperator)");
    }
}

// ====================================
// Mock Contracts for Testing
// ====================================

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
