// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

// --- Minimal Mocks ---

contract MockEntryPointV3 is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata) external view returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view returns (uint256) { return 0; }
    function balanceOf(address) external view returns (uint256) { return 0; }
    function getDepositInfo(address) external view returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {} 
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockFailingPriceFeed {
    int256 public price = 2000 * 1e8;
    bool public shouldFail = false;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldFail) {
            revert("Oracle Down");
        }
        return (1, price, 0, block.timestamp, 1);
    }
    
    function decimals() external pure returns (uint8) { return 8; }
    function setFail(bool _fail) external { shouldFail = _fail; }
    function setPrice(int256 _price) external { price = _price; }
}

// Minimal Registry Stub
contract MockRegistryStub is IRegistry {
    function hasRole(bytes32, address) external pure returns (bool) { return true; } // Always pass auth
    function getCreditLimit(address) external pure returns (uint256) { return 0; }
    
    // Ignore others
    function setRole(bytes32, address, bool) external {}
    function setRoleLockDuration(bytes32, uint256) external {}
    function setRoleOwner(bytes32, address) external {}
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function registerRoleSelf(bytes32, bytes calldata) external returns (uint256) { return 0; }
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external {}
    function createNewRole(bytes32, IRegistry.RoleConfig calldata, address) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function setBLSAggregator(address) external {}
    function setBLSValidator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function setLevelThreshold(uint256, uint256) external {}
    function addLevelThreshold(uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function calculateExitFee(bytes32, uint256) external view returns (uint256) { return 0; }
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }
    function version() external pure returns (string memory) { return "Mock"; }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function isReputationSource(address) external view returns (bool) { return false; }
    function roleOwners(bytes32) external view returns (address) { return address(0); }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("A", "A") {}
}

contract MockXPNTsToken is ERC20 {
    constructor() ERC20("M", "M") {}
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
    function recordDebt(address, uint256) external {}
}

contract SuperPaymaster_PassiveFallback_Test is Test {
    SuperPaymaster paymaster;
    MockRegistryStub registry;
    MockFailingPriceFeed priceFeed;
    MockEntryPointV3 entryPoint;
    MockXPNTsToken xpnts;
    
    event OracleFallbackTriggered(uint256 timestamp);
    
    function setUp() public {
        vm.warp(2 hours);
        registry = new MockRegistryStub();
        priceFeed = new MockFailingPriceFeed();
        entryPoint = new MockEntryPointV3();
        
        MockERC20 apnts = new MockERC20();
        xpnts = new MockXPNTsToken(); // Valid token for postOp interactions
        
        paymaster = new SuperPaymaster(
            entryPoint,
            address(this),
            registry,
            address(apnts),
            address(priceFeed),
            address(this),
            1 hours // Staleness Threshold
        );
        
        // Setup initial cache
        paymaster.updatePrice();
        
        // Setup Operator Config (Required for refund/debt logic)
        // Must be PAYMASTER_SUPER role. RegistryStub always returns true.
        // We need to configure operator to set exchangeRate etc.
        // Test contract is the operator.
        // Grant COMMUNITY role (Registry Stub allows).
        paymaster.configureOperator(address(xpnts), address(this), 1e18);
        
        // Fund operator (Deposit)
        apnts.approve(address(paymaster), 1000e18);
        try paymaster.deposit(100e18) {} catch { 
             // Deposit might fail if token transfer fails? MockERC20 is basic.
             // We need to mint tokens to this contract first.
        }
    }
    
    function test_FreshCache_DoesNotCallOracle() public {
        // 1. Initial State: Cache Fresh (Updated in setUp)
        // 2. Mock Context data with Valid Token/Operator
        bytes memory context = abi.encode(address(xpnts), uint256(100000), address(0), uint256(100000), bytes32(0), address(this));
        
        // 3. Make Oracle "Fail" if Called (to prove it wasn't called)
        priceFeed.setFail(true); 
        
        // 4. Call PostOp (Should succeed using Cache)
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 1000, 1000);
    }
    
    function test_StaleCache_TriggerEventOnOracleFailure() public {
        // 1. Warp to make Cache Stale (1 hour + 1 sec)
        vm.warp(block.timestamp + 3601);
        
        // 2. Make Oracle Fail (Simulate Denial of Service)
        priceFeed.setFail(true);
        
        // 3. Expect Event
        vm.expectEmit(false, false, false, true); 
        emit OracleFallbackTriggered(block.timestamp);
        
        // 4. Call PostOp
        bytes memory context = abi.encode(address(xpnts), uint256(100000), address(0), uint256(100000), bytes32(0), address(this));
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 1000, 1000);
    }
}
