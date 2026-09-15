// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

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
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../../../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "../../../../src/tokens/v2/xPNTsTokenV2.sol";
import {Math} from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";

// Reusing Mocks from SuperPaymasterV3.t.sol logic but localized for clarity
contract MockRegistryV2 is IRegistry {
    
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }
    
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    // Stub implementations
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false, 0,"stub",address(0),0); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
    
    function setCreditTier(uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
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
    xPNTsToken apnts;           // aPNTs deposit token (3.x; SP only uses it through IERC20)
    xPNTsTokenV2 xtok;          // operator's community gas token (xPNTs v2, SP 5.5.0)
    V2TokenDeployer.Stack stack;
    MockRegistryV2 registry;
    MockAggregatorV3Spy priceFeed;
    MockEntryPointV2 entryPoint;
    MockXPNTsFactory mockFactory;

    address owner = address(1);
    address operator = vm.addr(0xBEEF);
    address user = address(3);
    address treasury = address(4);

    uint256 constant INITIAL_PRICE = 2000 * 1e8; // $2000
    uint256 constant MAX_COST = 0.01 ether;      // a0 = 1000 aPNTs * 1.2 (fits v2 caps)

    function setUp() public {
        vm.warp(10 hours); // Start at a safe timestamp to avoid underflow
        vm.startPrank(owner);

        entryPoint = new MockEntryPointV2();
        registry = new MockRegistryV2();
        priceFeed = new MockAggregatorV3Spy(int256(INITIAL_PRICE), 8);

        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        ); // 1 hour staleness
        apnts.setSuperPaymasterAddress(address(paymaster));

        // Grant Roles
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(keccak256("COMMUNITY"), operator);
        registry.grantRole(keccak256("ENDUSER"), user);

        // Deploy mock factory (P1-4 factory binding)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));

        // Fund Operator (aPNTs)
        apnts.mint(operator, 100000 ether);
        vm.stopPrank();

        // Operator's xPNTs v2 community token; the user holds it to pay for gas.
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xtok = V2TokenDeployer.newToken(stack, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xtok));
        IxPNTsV2Admin(address(xtok)).mint(user, 100000 ether);

        // Sync SBT Status
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(operator, true);

        // Setup Operator
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 10000 ether);
        paymaster.configureOperator(address(xtok), treasury);
        paymaster.depositFor(operator, 5000 ether);
        paymaster.depositFor(operator, 5000 ether);
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
            // 5.5.0: [PM 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
            paymasterAndData: V2TokenDeployer.pmd(
                address(paymaster), uint128(100000), uint128(200000), operator, type(uint256).max, address(xtok), 0
            ),
            signature: bytes("")
        });
    }

    /// @dev 5.5.0: postOp only accepts a context produced by a real validation (the token's
    ///      escrow record + transient live marker must exist), so every postOp scenario below
    ///      validates first, in the same transaction, instead of fabricating a context.
    function _validate(bytes32 h) internal returns (bytes memory ctx, uint256 vd) {
        PackedUserOperation memory op = _createOp();
        vm.prank(address(entryPoint));
        (ctx, vd) = paymaster.validatePaymasterUserOp(op, h, MAX_COST);
    }

    function _validateAndPostOp(bytes32 h) internal {
        (bytes memory ctx, uint256 vd) = _validate(h);
        assertEq(uint160(vd), 0, "precondition: validation passes");
        uint256 balBefore = xtok.balanceOf(user);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.001 ether, 1 gwei);
        assertLt(xtok.balanceOf(user), balBefore, "precondition: postOp actually settled");
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

        _validateAndPostOp(keccak256("fresh"));

        // Assert:
        // 1. Cache timestamp should NOT change (no update triggered by validate or postOp)
        (, uint256 newUpdatedAt, , ) = paymaster.cachedPrice();
        assertEq(newUpdatedAt, initialUpdatedAt, "Cache should not update when fresh");

        // 2. Cache price should remain OLD value
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, int256(INITIAL_PRICE), "Should use cached price");
    }

    // 2. Stale Cache Scenario (Passive Update Removed)
    function test_StaleCache_DoesNotUpdatePrice() public {
        paymaster.updatePrice();
        (, uint256 initialUpdatedAt, , ) = paymaster.cachedPrice();

        // Advance time by 2 hours (Stale)
        vm.warp(block.timestamp + 2 hours);

        // Oracle returns new price
        int256 NEW_PRICE = 3000 * 1e8;
        priceFeed.setPrice(NEW_PRICE);

        _validateAndPostOp(keccak256("stale"));

        // Assert: Cache timestamp SHOULD NOT Update (Passive update removed)
        (, uint256 newUpdatedAt, , ) = paymaster.cachedPrice();
        assertEq(newUpdatedAt, initialUpdatedAt, "Cache should NOT update in validate/postOp");

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

        (, uint256 validationData) = _validate(keccak256("expired"));

        // ERC-4337 v0.7 validationData: [0..159] authorizer / sigFail, [160..207] validUntil,
        // [208..255] validAfter. Staleness is enforced through validUntil (EntryPoint rejects),
        // not by a sigFail, so the authorizer part must be 0 here (i.e. not an early rejection).
        assertEq(uint160(validationData), 0, "not a sigFail: staleness is expressed via validUntil");
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
        paymaster.updatePriceDVT(4000 * 1e8, block.timestamp, "", 0);

        // Restore Chainlink
        priceFeed.setRevert(false);

        // 3. User op happens immediately
        // Change Oracle to something else to prove we ignored it
        priceFeed.setPrice(5000 * 1e8);

        _validateAndPostOp(keccak256("dvt"));

        // Assert:
        // 1. Cache should still be DVT price ($4000), not Oracle ($5000)
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, 4000 * 1e8);
    }

    // 5. R10-M3 (new in 5.5.0): postOp prices the charge at the VALIDATION-time snapshot carried
    //    in the context, not at the cache value current at postOp time.
    function test_PostOp_ChargesAtValidationSnapshot() public {
        paymaster.updatePrice(); // $2000
        (bytes memory ctx, uint256 vd) = _validate(keccak256("snapshot"));
        assertEq(uint160(vd), 0);

        // Price moves between validation and postOp (DVT path; Chainlink down).
        vm.warp(block.timestamp + 1 minutes);
        priceFeed.setRevert(true);
        vm.prank(owner);
        paymaster.updatePriceDVT(2200 * 1e8, block.timestamp, "", 0);
        (int256 p, , , ) = paymaster.cachedPrice();
        assertEq(p, 2200 * 1e8, "cache moved");

        uint256 actualGasCost = 0.001 ether;
        uint256 feePerGas = 1 gwei;
        uint256 revBefore = paymaster.protocolRevenue();
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actualGasCost, feePerGas);
        uint256 charge = paymaster.protocolRevenue() - revBefore;

        assertEq(charge, _expectedCharge(INITIAL_PRICE, actualGasCost, feePerGas), "charge at the $2000 snapshot");
        assertTrue(charge != _expectedCharge(2200 * 1e8, actualGasCost, feePerGas), "control: current cache would differ");
    }

    /// @dev Mirrors SP postOp (R10-M3, exp/buffer): bufWei = (C_POSTOP 175k (exp/params default) + ceil((callGas+postOpGas)*10%)
    ///      + C_WRAP 5k) * feePerGas; charge = ceil(ceil(aGas) * (1 + 10% fee)). callGas = 0 here.
    function _expectedCharge(uint256 price, uint256 actualGasCost, uint256 feePerGas) internal pure returns (uint256) {
        uint256 postOpGas = 200000;
        uint256 bufWei = (175_000 + Math.ceilDiv(postOpGas * 10, 100) + 5_000) * feePerGas;
        uint256 aGas = Math.mulDiv((actualGasCost + bufWei) * price, 1e18, 1e8 * 0.02 ether, Math.Rounding.Ceil);
        return Math.mulDiv(aGas, 11000, 10000, Math.Rounding.Ceil);
    }
}
