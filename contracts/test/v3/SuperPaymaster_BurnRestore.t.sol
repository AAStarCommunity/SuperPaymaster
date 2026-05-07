// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract BurnMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) { return keccak256(abi.encode(op, block.chainid)); }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract BurnMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract BurnMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// Tracking mock: records burn vs recordDebt calls to verify fallback logic.
contract TrackingXPNTs is ERC20 {
    address public FACTORY;
    uint256 public exchangeRateVal = 1e18;
    bool public shouldRecordDebtFail;

    uint256 public burnSuccesses;
    uint256 public recordDebtCalls;
    mapping(bytes32 => bool) public usedOpHashes;

    constructor() ERC20("xPNTs", "xPNT") { FACTORY = address(this); }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setRecordDebtFail(bool v) external { shouldRecordDebtFail = v; }

    // ── IxPNTsToken ──
    function exchangeRate() external view returns (uint256) { return exchangeRateVal; }
    function getDebt(address) external pure returns (uint256) { return 0; }

    function burnFromWithOpHash(address from, uint256 amount, bytes32 opHash) external {
        require(!usedOpHashes[opHash], "AlreadyProcessed");
        usedOpHashes[opHash] = true;
        _burn(from, amount); // reverts naturally on insufficient balance
        burnSuccesses++;
    }

    function recordDebt(address, uint256) external {
        if (shouldRecordDebtFail) revert("RecordDebtFailed");
        recordDebtCalls++;
    }

    // P1-17: SuperPaymaster now calls recordDebtWithOpHash (opHash-protected) instead
    // of recordDebt. The mock increments the same counter so existing test assertions
    // ("recordDebt must be called as fallback") continue to verify fallback behavior.
    mapping(bytes32 => bool) public usedDebtHashes;
    function recordDebtWithOpHash(address, uint256, bytes32 opHash) external {
        if (shouldRecordDebtFail) revert("RecordDebtFailed");
        require(!usedDebtHashes[opHash], "DebtAlreadyRecorded");
        usedDebtHashes[opHash] = true;
        recordDebtCalls++;
    }
}

contract BurnMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view returns (bool) { return roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { roles[role][account] = val; }
    function getCreditLimit(address) external pure returns (uint256) { return 1000 ether; }

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

    function version() external pure returns (string memory) { return "MockBurn"; }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

// ─── Test Contract ─────────────────────────────────────────────────────────────

contract SuperPaymaster_BurnRestore_Test is Test {
    SuperPaymaster public paymaster;
    BurnMockRegistry public registry;
    BurnMockEntryPoint public entryPoint;
    BurnMockPriceFeed public priceFeed;
    BurnMockAPNTs public apnts;
    TrackingXPNTs public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner     = address(0x1);
    address public treasury  = address(0x2);
    address public operator1 = address(0x3);
    address public user1     = address(0x5);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY       = keccak256("COMMUNITY");

    uint256 constant MAX_COST = 1000; // wei — gives small but non-zero aPNTs charge

    function setUp() public {
        vm.startPrank(owner);

        entryPoint = new BurnMockEntryPoint();
        priceFeed  = new BurnMockPriceFeed();
        apnts      = new BurnMockAPNTs();
        xpnts      = new TrackingXPNTs();
        registry   = new BurnMockRegistry();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        registry.setRole(ROLE_PAYMASTER_SUPER, operator1, true);
        registry.setRole(ROLE_COMMUNITY, operator1, true);

        // Deploy mock factory and register operator token (P1-4 fix)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator1, address(xpnts));

        apnts.mint(operator1, 10_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true);

        vm.startPrank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), address(0x999), 1 ether);
        paymaster.deposit(5_000 ether);
        vm.stopPrank();
    }

    // Build a minimal paymasterAndData for operator1.
    function _buildPaymasterData() internal view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster),
            uint256(MAX_COST),
            operator1,
            type(uint256).max  // maxRate
        );
    }

    // Run validate → postOp and return context.
    function _runValidate() internal returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = _buildPaymasterData();

        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(uint256(1)), MAX_COST);
    }

    // ── Test 1: User has xPNTs → burn succeeds, no debt ──────────────────────

    function test_PostOp_Burns_WhenUserHasBalance() public {
        // Pre-fund user with enough xPNTs to cover the gas charge
        xpnts.mint(user1, 1_000 ether);
        uint256 balBefore = xpnts.balanceOf(user1);

        bytes memory ctx = _runValidate();

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 1, "burnFromWithOpHash must be called exactly once");
        assertEq(xpnts.recordDebtCalls(), 0, "recordDebt must NOT be called when burn succeeds");
        assertLt(xpnts.balanceOf(user1), balBefore, "User xPNTs balance must decrease after burn");
        assertEq(paymaster.pendingDebts(address(xpnts), user1), 0, "No pending debts expected");
    }

    // ── Test 2: User has no xPNTs → falls back to recordDebt ──────────────────

    function test_PostOp_FallsBack_ToRecordDebt_WhenNoBalance() public {
        // user1 has 0 xPNTs; burnFromWithOpHash will revert inside _burn
        assertEq(xpnts.balanceOf(user1), 0);

        bytes memory ctx = _runValidate();

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 0, "burnFromWithOpHash must NOT succeed (no balance)");
        assertEq(xpnts.recordDebtCalls(), 1, "recordDebt must be called as fallback");
        assertEq(paymaster.pendingDebts(address(xpnts), user1), 0, "No pending debts (recordDebt succeeded)");
    }

    // ── Test 3: Both burn and recordDebt fail → pendingDebts ──────────────────

    function test_PostOp_PendingDebts_WhenBothFail() public {
        // No xPNTs balance + recordDebt will fail
        xpnts.setRecordDebtFail(true);

        bytes memory ctx = _runValidate();

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 0, "Burn should not succeed");
        assertEq(xpnts.recordDebtCalls(), 0, "recordDebt should revert");
        assertGt(paymaster.pendingDebts(address(xpnts), user1), 0, "pendingDebts must be non-zero");
    }

    // ── Test 4: Two consecutive ops → different burns (not replay) ────────────

    function test_PostOp_TwoOps_NoDuplicateReplay() public {
        xpnts.mint(user1, 1_000 ether);

        // Op 1
        PackedUserOperation memory op1;
        op1.sender = user1;
        op1.nonce  = 0;
        op1.paymasterAndData = _buildPaymasterData();

        vm.prank(address(entryPoint));
        (bytes memory ctx1,) = paymaster.validatePaymasterUserOp(op1, bytes32(uint256(1)), MAX_COST);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 1, "First op must burn");

        // Op 2 — different nonce → different userOpHash
        xpnts.mint(user1, 1_000 ether);

        PackedUserOperation memory op2;
        op2.sender = user1;
        op2.nonce  = 1;
        op2.paymasterAndData = _buildPaymasterData();

        vm.prank(address(entryPoint));
        (bytes memory ctx2,) = paymaster.validatePaymasterUserOp(op2, bytes32(uint256(2)), MAX_COST);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 2, "Second op must also burn (no replay collision)");
        assertEq(xpnts.recordDebtCalls(), 0, "No debt when balance sufficient");
    }

    // ── Test 5: Overflow path (actual > initialAPNTs) also uses burn ──────────

    function test_PostOp_OverflowPath_BurnsXPNTs() public {
        xpnts.mint(user1, 1_000 ether);

        // Craft context with tiny initialAPNTs so finalCharge > initialAPNTs (overflow path)
        bytes memory ctx = abi.encode(
            address(xpnts),  // token
            user1,           // user
            uint256(1),      // initialAPNTs (tiny)
            bytes32(uint256(9999)), // userOpHash (unique)
            operator1        // operator
        );

        // actualGasCost drives finalCharge > 1 → overflow branch
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 1, "Overflow path must also call burnFromWithOpHash");
        assertEq(xpnts.recordDebtCalls(), 0, "No debt when burn succeeds");
    }

    // ── Test 6: Overflow path + no balance → recordDebt ──────────────────────

    function test_PostOp_OverflowPath_FallsBackToRecordDebt() public {
        // No xPNTs → burn fails → recordDebt
        bytes memory ctx = abi.encode(
            address(xpnts),
            user1,
            uint256(1),
            bytes32(uint256(8888)),
            operator1
        );

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        assertEq(xpnts.burnSuccesses(), 0, "Burn must fail when no balance");
        assertEq(xpnts.recordDebtCalls(), 1, "recordDebt must be called as fallback");
    }

    // ── Test 7: Cross-path — burn succeeds, same opHash postOp called again ──
    // P1-17: _settledDebtOps SP-level guard must prevent the second postOp from
    // falling through to recordDebtWithOpHash after burnFromWithOpHash rejects.

    function test_CrossPath_BurnSucceeds_SecondPostOpIdempotent() public {
        xpnts.mint(user1, 1_000 ether);

        bytes32 opHash = bytes32(uint256(9999));
        bytes memory ctx = abi.encode(address(xpnts), user1, MAX_COST, opHash, operator1);

        // First postOp: burn succeeds
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        assertEq(xpnts.burnSuccesses(), 1, "First call must burn");
        assertEq(xpnts.recordDebtCalls(), 0, "No debt on first call");

        // Second postOp (same ctx/opHash): SP-level _settledDebtOps returns early
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        // Counts must not increase — idempotent
        assertEq(xpnts.burnSuccesses(), 1, "Burn count must not increase on replay");
        assertEq(xpnts.recordDebtCalls(), 0, "Debt count must stay 0 on replay");
    }

    // ── Test 8: Cross-path — debt recorded, same opHash would double-charge ──
    // P1-17: after recordDebtWithOpHash succeeds (no balance), a second postOp
    // must not record debt or burn again.

    function test_CrossPath_DebtRecorded_SecondPostOpIdempotent() public {
        // No xPNTs: burn fails → recordDebtWithOpHash records debt
        bytes32 opHash = bytes32(uint256(7777));
        bytes memory ctx = abi.encode(address(xpnts), user1, MAX_COST, opHash, operator1);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        assertEq(xpnts.recordDebtCalls(), 1, "First call must record debt");

        // Now give user balance — second postOp must still be a no-op
        xpnts.mint(user1, 1_000 ether);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        // SP-level guard fires — no burn, no additional debt
        assertEq(xpnts.burnSuccesses(), 0, "Must not burn on replay");
        assertEq(xpnts.recordDebtCalls(), 1, "Debt count must stay 1 on replay");
    }
}
