// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

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
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external override {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function queueBLSAggregator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }
    function version() external pure returns (string memory) { return "Mock"; }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("A", "A") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Oracle passive fallback in postOp, migrated to SuperPaymaster 5.5.0.
/// @dev    5.5.0 postOp never touches the oracle NOR the price cache: it prices the charge with
///         the validation-time snapshot carried in the context (spec R10-M3). The legacy tests fed
///         postOp a hand-made 6-field context for a non-existent escrow; 5.5.0 settles only a real
///         validation-time escrow (L-3), so each test now runs validate -> (oracle fails) -> postOp.
contract SuperPaymaster_PassiveFallback_Test is Test {
    SuperPaymaster paymaster;
    MockRegistryStub registry;
    MockFailingPriceFeed priceFeed;
    MockEntryPointV3 entryPoint;
    xPNTsTokenV2 xpnts;
    MockXPNTsFactory mockFactory;
    MockERC20 apnts;

    address user = address(0xA11CE);

    event OracleFallbackTriggered(uint256 timestamp);

    function setUp() public {
        vm.warp(2 hours);
        registry = new MockRegistryStub();
        priceFeed = new MockFailingPriceFeed();
        entryPoint = new MockEntryPointV3();

        apnts = new MockERC20();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint,
            IRegistry(address(registry)),
            address(priceFeed),
            address(this),
            address(apnts),
            address(this),
            1 hours // Staleness Threshold
        );

        // Setup initial cache
        paymaster.updatePrice();

        // Valid v2 token for postOp settlement (test contract = operator, community owner, FACTORY)
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, address(this), address(this), address(paymaster), 1e18);
        IxPNTsV2Admin(address(xpnts)).mint(user, 1_000 ether);

        // Deploy mock factory and register operator token (owner = address(this))
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(address(this), address(xpnts));

        // Test contract is the operator (RegistryStub grants every role).
        paymaster.configureOperator(address(xpnts), address(this));

        // Fund operator (Deposit)
        apnts.mint(address(this), 1000e18);
        apnts.approve(address(paymaster), 1000e18);
        paymaster.deposit(100e18);

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
    }

    function _validate(bytes32 opHash) internal returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster), uint128(100000), uint128(200000), address(this), type(uint256).max, address(xpnts), 0
        );
        vm.prank(address(entryPoint));
        uint256 vd;
        (ctx, vd) = paymaster.validatePaymasterUserOp(op, opHash, 100000);
        assertEq(uint160(vd), 0, "setup: op admitted");
    }

    function test_FreshCache_DoesNotCallOracle() public {
        // 1. Initial State: Cache Fresh (Updated in setUp); escrow created at validation
        bytes memory context = _validate(bytes32(uint256(1)));
        uint256 balBefore = xpnts.balanceOf(user);
        uint256 revBefore = paymaster.protocolRevenue();

        // 2. Make Oracle "Fail" if Called, and assert it is never called
        priceFeed.setFail(true);
        vm.expectCall(address(priceFeed), abi.encodeWithSelector(MockFailingPriceFeed.latestRoundData.selector), 0);

        // 3. Call PostOp (Should succeed using the validation-time snapshot)
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 1000, 1000);

        assertLt(xpnts.balanceOf(user), balBefore, "settlement actually happened");
        assertGt(paymaster.protocolRevenue(), revBefore, "revenue booked");
        assertEq(xpnts.lockedOf(user), 0, "escrow cleared");
    }

    function test_StaleCache_SucceedsInPostOp() public {
        bytes memory context = _validate(bytes32(uint256(2)));
        uint256 balBefore = xpnts.balanceOf(user);

        // 1. Warp to make Cache Stale (1 hour + 1 sec)
        vm.warp(block.timestamp + 3601);

        // 2. Make Oracle Fail (Simulate Denial of Service)
        priceFeed.setFail(true);

        // 3. Expect Success: postOp prices with the context snapshot (R10-M3), not the cache.
        // In reality, this tx would fail validation at EntryPoint due to validUntil.
        // But if it reaches postOp (e.g. miner bypass or time edge case), it should process.
        vm.expectCall(address(priceFeed), abi.encodeWithSelector(MockFailingPriceFeed.latestRoundData.selector), 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 1000, 1000);

        assertLt(xpnts.balanceOf(user), balBefore, "settled despite stale cache + dead oracle");
        assertEq(xpnts.lockedOf(user), 0, "escrow cleared");
    }

    /// @notice R10-M3: the charge is computed from the VALIDATION-time price snapshot. Moving the
    ///         cached price between validation and postOp must not change what the user pays.
    function test_PostOp_UsesValidationSnapshot_NotCurrentCache() public {
        bytes memory ctxA = _validate(bytes32(uint256(3)));
        bytes memory ctxB = _validate(bytes32(uint256(4)));

        uint256 b0 = xpnts.balanceOf(user);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctxA, 1000, 1000);
        uint256 paidA = b0 - xpnts.balanceOf(user);

        // Double the ETH price in the cache (Chainlink moved) before the second postOp.
        priceFeed.setPrice(4000 * 1e8);
        paymaster.updatePrice();
        (int256 p,,,) = paymaster.cachedPrice();
        assertEq(p, 4000 * 1e8, "cache really moved");

        uint256 b1 = xpnts.balanceOf(user);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctxB, 1000, 1000);
        uint256 paidB = b1 - xpnts.balanceOf(user);

        assertGt(paidA, 0);
        assertEq(paidB, paidA, "same actual cost, same snapshot -> same charge despite the cache move");
    }
}
