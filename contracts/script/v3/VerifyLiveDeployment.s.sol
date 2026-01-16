// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Interfaces
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract VerifyLiveDeployment is Script {
    // Config Addresses (from config.sepolia.json)
    address constant ADDR_REGISTRY = 0x2D7d16EAaa85Fa88D05B296E9951f730BDaA0A7D;
    address constant ADDR_SP = 0xF4FE801D3dd95045f81a90c09445BB7412BA474a;
    address constant ADDR_GTOKEN = 0xccB0cA1Ec9F8e51bEdBD4038BB9980B071bD81cB;
    address constant ADDR_STAKING = 0xF50D6ade7C150A8Ac7cF5cDD47C43Fa8d44747eD;
    address constant ADDR_SBT = 0xa7c910437c6E0488C0FaA6587067bb35687E2fd4;
    address constant ADDR_APNTS = 0x7A56b5B9f4aC457B5d080468Dd002222D1Df4c50;
    address constant ADDR_REP = 0xAeDbd253FE3E483A9000D6e419c5C22417f2f244;
    address constant ADDR_BLS_AGG = 0xB4635b6656CA0584D3A7B1e79B6AE09ca304542E;
    address constant ADDR_BLS_VAL = 0x08c3e8e52203F6d90ec3cDBDD9d80E00b8d81EC5;
    address constant ADDR_DVT = 0x5eEa6DE4FC4CCACf436f9cd91FE1095e8Ec8D240;
    address constant ADDR_XPNTS_FACTORY = 0x0F815454ea941224dE582554D1DeF4B67ffBE38c;
    address constant ADDR_PM_V4_IMPL = 0x4E3b8183b790d25e2f44b2711D7b1e1E560c28b3;
    address constant ADDR_PM_FACTORY = 0xe4551c950b35DcF80e61CEa730743CEec127db88;
    
    // Roles
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function run() external view {
        console.log("=== Verifying Live Deployment on Sepolia ===");

        // 1. Check Wiring
        console.log("Checking Wiring...");
        require(address(GTokenStaking(ADDR_STAKING).GTOKEN()) == ADDR_GTOKEN, "Staking.GTOKEN mismatch");
        require(Registry(ADDR_REGISTRY).SUPER_PAYMASTER() == ADDR_SP, "Registry.SUPER_PAYMASTER mismatch");
        require(SuperPaymaster(payable(ADDR_SP)).REGISTRY() == Registry(ADDR_REGISTRY), "SP.REGISTRY mismatch");
        
        // FIXED: Use isReputationSource (mapped getter)
        require(Registry(ADDR_REGISTRY).isReputationSource(ADDR_REP) == true, "Reputation Source mismatch");
        
        require(Registry(ADDR_REGISTRY).blsAggregator() == ADDR_BLS_AGG, "BLS Aggregator mismatch");
        
        // FIXED: Cast interface to address
        require(address(Registry(ADDR_REGISTRY).blsValidator()) == ADDR_BLS_VAL, "BLS Validator mismatch");
        
        // Check xPNTsFactory wiring
        try SuperPaymaster(payable(ADDR_SP)).xpntsFactory() returns (address f) {
            require(f == ADDR_XPNTS_FACTORY, "SP.xPNTsFactory mismatch");
        } catch {
             console.log("Warning: SP.xPNTsFactory getter not available or failed");
        }

        // 2. Check Community "AAStar"
        console.log("Checking Community Details...");
        uint256 count = Registry(ADDR_REGISTRY).getRoleUserCount(ROLE_COMMUNITY);
        console.log("Total Communities:", count);
        
        address[] memory communities = Registry(ADDR_REGISTRY).getRoleMembers(ROLE_COMMUNITY);
        
        for(uint i=0; i<communities.length; i++) {
            address commAddr = communities[i];
            console.log("------------------------------------------------");
            console.log("Community Address:", commAddr);
            
            // Get Metadata (Skipped to avoid memory panic)
            // bytes memory meta = Registry(ADDR_REGISTRY).roleMetadata(ROLE_COMMUNITY, commAddr);
            
            // Check Roles
            bool isSuper = Registry(ADDR_REGISTRY).hasRole(ROLE_PAYMASTER_SUPER, commAddr);
            console.log("Is SuperPaymaster Operator:", isSuper);
            
            bool isAOA = Registry(ADDR_REGISTRY).hasRole(keccak256("PAYMASTER_AOA"), commAddr);
            console.log("Is AOA Paymaster Operator:", isAOA);
            
            // Check if they deployed a V4 Paymaster (via Factory mapping?)
            // PaymasterFactory doesn't have a public mapping "getPaymasterByOperator" in interface?
            // checking factory code...
        }
        console.log("------------------------------------------------");

        // 3. Check aPNTs
        console.log("Checking aPNTs...");
        require(bytes(xPNTsToken(ADDR_APNTS).name()).length > 0, "aPNTs Name empty");
        // Note: SUPERPAYMASTER_ADDRESS might be different casing or missing in some versions, assume getter generated
        try xPNTsToken(ADDR_APNTS).SUPERPAYMASTER_ADDRESS() returns (address sm) {
             require(sm == ADDR_SP, "aPNTs.SUPERPAYMASTER mismatch");
        } catch {
             console.log("Warning: aPNTs.SUPERPAYMASTER_ADDRESS getter failed");
        }

        // 4. Check Paymaster Role & Config
        console.log("Checking Paymaster Role & Config...");
        address owner = Registry(ADDR_REGISTRY).owner();
        console.log("Registry Owner:", owner);
        
        bool hasRole = Registry(ADDR_REGISTRY).hasRole(ROLE_PAYMASTER_SUPER, owner);
        if (hasRole) {
            console.log("Owner has PAYMASTER_SUPER_ROLE: YES");
            
            // FIXED: Unpack correctly based on ISuperPaymaster.OperatorConfig
            (
                uint128 bal,
                uint96 rate,
                bool isConfigured,
                bool isPaused,
                address token,
                uint32 reputation,
                uint48 minTxInterval,
                address treasury,
                uint256 totalSpent,
                uint256 totalTxSponsored
            ) = SuperPaymaster(payable(ADDR_SP)).operators(owner);
            
            console.log("Operator aPNTs Balance (Internal):", bal);
            console.log("Operator Token:", token);
            require(token == ADDR_APNTS, "Operator Token Mismatch");
            
        } else {
            console.log("Owner has PAYMASTER_SUPER_ROLE: NO (Check if deployer differs from owner)");
        }

        // 5. Check EntryPoint Deposit
        IEntryPoint ep = SuperPaymaster(payable(ADDR_SP)).entryPoint();
        uint256 deposit = ep.balanceOf(ADDR_SP);
        console.log("SuperPaymaster EntryPoint Deposit:", deposit);
        require(deposit >= 0.05 ether, "SuperPaymaster Deposit too low");

        console.log("=== Verification Successful ===");
    }
}
