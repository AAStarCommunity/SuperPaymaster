// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../../../src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "../../../../src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

// Reusing Mocks from SuperPaymasterV3.t.sol logic but localized for clarity
contract MockRegistryV2 is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }
    
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    // Stub implementations
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function setRoleLockDuration(bytes32, uint256) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false,0,"stub",address(0),0); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
    
    function roleOwners(bytes32) external view override returns (address) { return address(0); }
    function setRoleOwner(bytes32, address) external override {}
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
}

contract MockAggregatorV3Spy is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;
    bool public shouldRevert;

    constructor(int256 _price, uint8 _dec) {
        price = _price;
        _decimals = _dec;
    }
    
    function setPrice(int256 _p) external { price = _p; }
    function setRevert(bool _r) external { shouldRevert = _r; }
    
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return "Mock"; }
    function version() external view override returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("Oracle Error");
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockEntryPointV2 is IEntryPoint {
    function depositTo(address) external payable override {}
    function addStake(uint32) external payable override {}
    function unlockStake() external override {}
    function withdrawStake(address payable) external override {}
    function balanceOf(address) external view override returns (uint256) { return 0; }
    function getDepositInfo(address) external view override returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external override {} 
    
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external override {} 
    function handleOps(PackedUserOperation[] calldata, address payable) external override {}
    function getSenderAddress(bytes memory) external override {}
    function getUserOpHash(PackedUserOperation calldata) external view override returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view override returns (uint256) { return 0; }
    function incrementNonce(uint192) external override {}
    function delegateAndRevert(address, bytes calldata) external override {}
}

contract SuperPaymasterPricingV2Test is Test {
    using Clones for address;
    SuperPaymaster paymaster;
    xPNTsToken apnts;
    MockRegistryV2 registry;
    MockAggregatorV3Spy priceFeed;
    MockEntryPointV2 entryPoint;
    
    address owner = address(1);
    address operator = vm.addr(0xBEEF);
    address user = address(3);
    address treasury = address(4);

    uint256 constant INITIAL_PRICE = 2000 * 1e8; // $2000

    function setUp() public {
        vm.warp(10 hours); // Start at a safe timestamp to avoid underflow
        vm.startPrank(owner);
        
        entryPoint = new MockEntryPointV2();
        registry = new MockRegistryV2();
        priceFeed = new MockAggregatorV3Spy(int256(INITIAL_PRICE), 8);
        
        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);
        paymaster = new SuperPaymaster(entryPoint, owner, registry, address(apnts), address(priceFeed), treasury, 3600); // 1 hour staleness
        apnts.setSuperPaymasterAddress(address(paymaster));

        // Grant Roles
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(keccak256("COMMUNITY"), operator);
        registry.grantRole(keccak256("ENDUSER"), user);

        // Fund Operator & Config
        apnts.mint(operator, 100000 ether);
        apnts.mint(user, 100000 ether);
        vm.stopPrank();
        
        // Sync SBT Status
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(operator, true);

        // Setup Operator
        vm.startPrank(operator);
        apnts.setPaymasterLimit(address(paymaster), 100000 ether); // Increase limit for test
        apnts.approve(address(paymaster), 10000 ether);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        paymaster.depositFor(operator, 10000 ether);
        vm.stopPrank();
    }

    function _createOp() internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: user,
            nonce: 0,
            initCode: bytes(""),
            callData: bytes(""),
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: abi.encodePacked(address(paymaster), uint128(100000), uint128(100000), operator),
            signature: bytes("")
        });
    }

    function _getContext() internal view returns (bytes memory) {
        // Mock context returned by validation
        return abi.encode(address(apnts), uint256(0), user, uint256(1 ether), bytes32(0), operator);
    }

    // 1. Fresh Cache Scenario
    function test_FreshCache_DoesNotCallOracle() public {
        // Initialize cache
        paymaster.updatePrice();
        (, uint256 initialUpdatedAt, , ) = paymaster.cachedPrice();
        
        // Advance time by 30 mins (Fresh)
        vm.warp(block.timestamp + 30 minutes);
        
        // Change Oracle Price to verify it's NOT picked up
        priceFeed.setPrice(9999 * 1e8);
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, _getContext(), 0.01 ether, 1 gwei);
        
        // Assert: 
        // 1. Cache timestamp should NOT change (no update triggered)
        (, uint256 newUpdatedAt, , ) = paymaster.cachedPrice();
        assertEq(newUpdatedAt, initialUpdatedAt, "Cache should not update when fresh");
        
        // 2. Cache price should remain OLD value
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, int256(INITIAL_PRICE), "Should use cached price");
    }

    // 2. Stale Cache + Successful Update Scenario
    // 2. Stale Cache Scenario (Passive Update Removed)
    function test_StaleCache_DoesNotUpdatePrice() public {
        paymaster.updatePrice();
        (, uint256 initialUpdatedAt, , ) = paymaster.cachedPrice();
        
        // Advance time by 2 hours (Stale)
        vm.warp(block.timestamp + 2 hours);
        
        // Oracle returns new price
        int256 NEW_PRICE = 3000 * 1e8;
        priceFeed.setPrice(NEW_PRICE); 
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, _getContext(), 0.01 ether, 1 gwei);
        
        // Assert: Cache timestamp SHOULD NOT Update (Passive update removed)
        (, uint256 newUpdatedAt, , ) = paymaster.cachedPrice();
        assertEq(newUpdatedAt, initialUpdatedAt, "Cache should NOT update in postOp");
        
        // Verify Cache is still old price
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, int256(INITIAL_PRICE));
    }

    // 3. Stale Cache + Failed Update (Expired ValidUntil) Scenario
    function test_StaleCache_ReturnsExpiredValidUntil() public {
        paymaster.updatePrice();
        (, uint256 initialUpdatedAt, , ) = paymaster.cachedPrice();
        
        // Advance time by 2 hours (7200s). Threshold is 1 hour (3600s).
        vm.warp(block.timestamp + 2 hours);
        
        priceFeed.setRevert(true);
        
        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(_createOp(), bytes32(0), 0);
        
        // Validation Data format: [aggregator(20 logic/0 main)][validAfter(6)][validUntil(6)] (packed uint256)
        // Wait, Paymaster returns _packValidationData(sigFail, validUntil, validAfter)
        // Format: (sigFailed ? 1 : 0) << 160 | (validUntil << 112) | (validAfter << 64) ??
        // Standard ERC-4337: validationData is uint256.
        // If sigFailed is boolean (1 bit), then 6-byte validUntil, 6-byte validAfter.
        // Actually BasePaymaster uses: (authorizer 0..159), (validUntil 160..207), (validAfter 208..255).
        // Let's check BasePaymaster or helpers. 
        // _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter)
        // returns: (uint256(sigFailed ? 1 : 0) * 0 + validAfter) << ...?
        // No, standard is:
        // [authorizer(160 bits)] [validUntil(48 bits)] [validAfter(48 bits)]
        // NOTE: validUntil=0 means "forever".
        
        uint48 validUntil = uint48(validationData >> 48); // Wait, standard order?
        // Let's look at BasePaymaster or just infer from standard.
        // ERC-4337 v0.7: validationData: authorizer(20 bytes) + validUntil(6 bytes) + validAfter(6 bytes)
        // No, standard is: params are packed.
        // But the return value for Paymaster is `context` and `validationData`.
        // `validationData` bit layout:
        // bits 0-159: aggregator/sig (0 = success)
        // bits 160-207: validAfter (48 bits) -- WAIT
        // bits 208-255: validUntil (48 bits) -- WAIT
        
        // Actually, check _packValidationData in BasePaymaster usually follows:
        // (sigFailed, validUntil, validAfter)
        // Usually returns: (uint256(validAfter) << 160) | (uint256(validUntil) << 160 + 48)? No.
        
        // Let's decode assuming `_packValidationData(false, validUntil, validAfter)`:
        // Usually: validAfter is HIGH ORDER? validUntil is MIDDLE?
        // Let's assume standard logic:
        // validUntil is bytes 20..26?
        
        // Simplest Verification:
        // Just assert validationData != 0.
        // And check behavior.
        
        // But better constraint:
        // validUntil should be roughly initialUpdatedAt + 3600.
        // block.timestamp is initialUpdatedAt + 7200.
        // So validUntil < block.timestamp.
        
        // If I can't easily decode, I'll rely on the property that it's NOT 0 (forever) and represents a past time.
        
        // ValidationData decoding from BasePaymaster:
        // return (uint256(validAfter) << 208) | (uint256(validUntil) << 160) | (sigFail);
        // Correct? Let's assume standard from standard repo.
        // 0-159: 0 (success)
        // 160-207: validUntil
        // 208-255: validAfter
        
        // So validUntil = uint48(validationData >> 160);
        uint48 extractedValidUntil = uint48(validationData >> 160);
        
        assertEq(extractedValidUntil, initialUpdatedAt + 3600, "ValidUntil should be updatedAt + threshold");
        assertTrue(extractedValidUntil < block.timestamp, "ValidUntil should be in the past (expired)");
    }

    // 4. DVT Intervention Scenario
    function test_DVT_Update_RespectsCache() public {
        // 1. Initial State
        paymaster.updatePrice(); // $2000
        
        // 2. DVT Updates Price to $4000 (with fresh timestamp)
        vm.warp(block.timestamp + 10 minutes); // Some time passed
        
        // Simulate Chainlink DOWN so DVT can bypass deviation check
        priceFeed.setRevert(true);
        
        vm.prank(owner);
        paymaster.updatePriceDVT(4000 * 1e8, block.timestamp, "");
        
        // Restore Chainlink
        priceFeed.setRevert(false);
        
        // 3. User op happens immediately
        // Change Oracle to something else to prove we ignored it
        priceFeed.setPrice(5000 * 1e8);
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, _getContext(), 0.01 ether, 1 gwei);
        
        // Assert: 
        // 1. Cache should still be DVT price ($4000), not Oracle ($5000)
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, 4000 * 1e8);
    }
}
