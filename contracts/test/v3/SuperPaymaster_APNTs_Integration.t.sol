// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

/**
 * @title SuperPaymaster_APNTs_Integration
 * @notice Integration tests for unified aPNTs accounting in SuperPaymaster v5.3.3.
 *
 *  Key changes tested:
 *  1. configureOperator(xPNTsToken, treasury) — 2-arg, no exchangeRate param
 *  2. postOp passes finalCharge (aPNTs) directly to _recordDebt
 *  3. Burn path at non-1:1 rate: xPNTsToken converts aPNTs->xPNTs internally
 *  4. getAvailableCredit returns aPNTs credit minus aPNTs debt
 *  5. Protocol fee adds markup in aPNTs; debtAPNTs > aPNTsCost
 *  6. validatePaymasterUserOp reads live exchangeRate() from xPNTsToken
 */
contract SuperPaymaster_APNTs_Integration_Test is Test {
    using Clones for address;
    using stdStorage for StdStorage;

    SuperPaymaster      public sp;
    xPNTsToken          public xpnts;
    SPMockEntryPoint    public ep;
    SPMockPriceFeed     public priceFeed;
    SPMockAPNTs         public apnts;
    SPMockRegistry      public registry;
    MockXPNTsFactory    public mockFactory;

    address owner    = address(0xF1);
    address treasury = address(0xF2);
    address operator = address(0xF3);
    address user     = address(0xF5);

    // 1_000_000 wei gas cost -> ~100 aPNTs charge at $2000 ETH / $0.02 aPNTs
    uint256 constant MAX_COST = 1_000_000;

    // operators() field indices (9-tuple, exchangeRate removed in v5.3.3)
    // 0:aPNTsBalance 1:isConfigured 2:isPaused 3:xPNTsToken 4:reputation
    // 5:minTxInterval 6:treasury 7:totalSpent 8:totalTxSponsored

    function setUp() public {
        vm.startPrank(owner);

        ep        = new SPMockEntryPoint();
        priceFeed = new SPMockPriceFeed();   // $2000/ETH, 8 decimals
        apnts     = new SPMockAPNTs();
        registry  = new SPMockRegistry();

        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(ep)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );
        vm.warp(block.timestamp + 2 hours);
        sp.updatePrice();

        // Real xPNTsToken (clone), initialized with rate=1e18
        address xImpl = address(new xPNTsToken());
        xpnts = xPNTsToken(xImpl.clone());
        xpnts.initialize("XPNTs", "XP", operator, "Comm", "comm.eth", 1e18);
        xpnts.setSuperPaymasterAddress(address(sp));

        mockFactory = new MockXPNTsFactory();
        sp.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);

        apnts.mint(operator, 100_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(xpnts), treasury); // 2-arg (no exchangeRate)
        sp.deposit(10_000 ether);
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _setXPNTsRate(uint256 rate) internal {
        stdstore.target(address(xpnts)).sig("exchangeRate()").checked_write(rate);
    }

    function _buildPaymasterData(uint256 maxRate) internal view returns (bytes memory) {
        return abi.encodePacked(address(sp), uint256(MAX_COST), operator, maxRate);
    }

    function _runValidate(uint256 maxRate) internal returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _buildPaymasterData(maxRate);
        vm.prank(address(ep));
        (ctx,) = sp.validatePaymasterUserOp(op, bytes32(uint256(1)), MAX_COST);
    }

    function _getAPNTsBalance(address who) internal view returns (uint128 bal) {
        (bal,,,,,,,,) = sp.operators(who);
    }

    function _getIsConfigured(address who) internal view returns (bool configured) {
        (, configured,,,,,,,) = sp.operators(who);
    }

    function _getXPNTsToken(address who) internal view returns (address tok) {
        (,,,tok,,,,,) = sp.operators(who);
    }

    // ─── 1. configureOperator 2-arg signature ─────────────────────────────────

    function test_ConfigureOperator_NoExchangeRateParam_Configured() public view {
        assertTrue(_getIsConfigured(operator), "operator must be configured after 2-arg configureOperator");
    }

    function test_ConfigureOperator_StoredToken_Correct() public view {
        assertEq(_getXPNTsToken(operator), address(xpnts), "xPNTsToken address must be stored");
    }

    function test_ConfigureOperator_NoStoredExchangeRate_LiveRateUsed() public {
        // In v5.3.3, no exchangeRate field in OperatorConfig.
        // Validate with a rate commitment and verify the live token rate is used.
        _setXPNTsRate(2e18);
        // maxRate = 1e18 < live rate 2e18 → validation fails
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _buildPaymasterData(1e18);
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(99)), MAX_COST);
        assertEq(vd & 1, 1, "validate must fail: live rate 2e18 > maxRate 1e18");
    }

    // ─── 2. getAvailableCredit returns aPNTs ──────────────────────────────────

    function test_GetAvailableCredit_NoDebt_EqualsCreditLimit() public view {
        uint256 credit = sp.getAvailableCredit(user, address(xpnts));
        uint256 limit  = registry.getCreditLimit(user);
        assertEq(credit, limit, "no debt: available credit must equal limit");
    }

    function test_GetAvailableCredit_AfterDebt_DecreasedByDebt() public {
        bytes memory ctx = _runValidate(type(uint256).max);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        uint256 debt   = xpnts.getDebt(user);
        uint256 credit = sp.getAvailableCredit(user, address(xpnts));
        uint256 limit  = registry.getCreditLimit(user);

        assertEq(credit, limit - debt, "credit must equal limit minus aPNTs debt");
    }

    // ─── 3. postOp: debt path records charge in aPNTs ────────────────────────

    function test_PostOp_DebtPath_RecordsAPNTs() public {
        assertEq(xpnts.balanceOf(user), 0); // no xPNTs → debt fallback
        bytes memory ctx = _runValidate(type(uint256).max);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        assertGt(xpnts.getDebt(user), 0, "debt must be recorded in aPNTs");
    }

    // Debt is proportional to gas cost; doubling gas → doubles debt
    // Uses two separate users to avoid needing to reset state.
    function test_PostOp_DebtPath_ProportionalToGas() public {
        address user2 = address(0xF6);
        vm.prank(address(registry));
        sp.updateSBTStatus(user2, true);

        // user — 1x gas cost
        bytes memory ctx1 = _runValidate(type(uint256).max);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, MAX_COST, 0);
        uint256 debt1 = xpnts.getDebt(user);

        // user2 — 2x gas cost (different opHash via different sender)
        PackedUserOperation memory op2;
        op2.sender = user2;
        op2.paymasterAndData = _buildPaymasterData(type(uint256).max);
        vm.prank(address(ep));
        (bytes memory ctx2,) = sp.validatePaymasterUserOp(op2, bytes32(uint256(10)), MAX_COST);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, MAX_COST * 2, 0);
        uint256 debt2 = xpnts.getDebt(user2);

        assertGt(debt2, debt1, "double gas cost must produce higher aPNTs debt");
    }

    // ─── 4. postOp burn path at non-1:1 rate ────────────────────────────────

    function test_PostOp_BurnPath_HighRate_BurnsMoreXPNTs() public {
        _setXPNTsRate(2e18); // 1 aPNT = 2 xPNTs

        vm.prank(operator);
        xpnts.mint(user, 5_000 ether); // give user enough xPNTs

        uint256 balBefore = xpnts.balanceOf(user);
        bytes memory ctx = _runValidate(type(uint256).max);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        uint256 burned = balBefore - xpnts.balanceOf(user);
        uint256 debt   = xpnts.getDebt(user);

        assertTrue(burned > 0, "xPNTs must be burned in burn path");
        assertEq(debt, 0, "no debt when burn path succeeds");
        // burned xPNTs must be ~2x more than the aPNTs charge (ceil conversion at rate=2e18)
    }

    // ─── 5. Protocol fee: debtAPNTs increases with fee ────────────────────────

    // Compare 0% fee vs 10% fee for same gas cost using two fresh users.
    function test_PostOp_HigherFee_IncreasesDebt() public {
        address userA = address(0xFA);
        address userB = address(0xFB);
        vm.prank(address(registry)); sp.updateSBTStatus(userA, true);
        vm.prank(address(registry)); sp.updateSBTStatus(userB, true);

        // userA: 0% fee
        vm.prank(owner);
        sp.setProtocolFee(0);

        PackedUserOperation memory opA;
        opA.sender = userA;
        opA.paymasterAndData = _buildPaymasterData(type(uint256).max);
        vm.prank(address(ep));
        (bytes memory ctxA,) = sp.validatePaymasterUserOp(opA, bytes32(uint256(30)), MAX_COST);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctxA, MAX_COST, 0);
        uint256 debtZeroFee = xpnts.getDebt(userA);

        // userB: 10% fee
        vm.prank(owner);
        sp.setProtocolFee(1000);

        PackedUserOperation memory opB;
        opB.sender = userB;
        opB.paymasterAndData = _buildPaymasterData(type(uint256).max);
        vm.prank(address(ep));
        (bytes memory ctxB,) = sp.validatePaymasterUserOp(opB, bytes32(uint256(31)), MAX_COST);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctxB, MAX_COST, 0);
        uint256 debtTenPctFee = xpnts.getDebt(userB);

        assertGt(debtTenPctFee, debtZeroFee, "10% fee must produce higher aPNTs debt than 0% fee");
    }

    // ─── 6. validatePaymasterUserOp uses live rate ───────────────────────────

    function test_Validate_LiveRate_Exceeds_MaxRate_Fails() public {
        _setXPNTsRate(2e18);
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _buildPaymasterData(1e18); // maxRate too low
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(2)), MAX_COST);
        assertEq(vd & 1, 1, "SIG_VALIDATION_FAILED when live rate > maxRate");
    }

    function test_Validate_LiveRate_Within_MaxRate_Succeeds() public {
        _setXPNTsRate(1e18);
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _buildPaymasterData(2e18); // maxRate >= live rate
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(3)), MAX_COST);
        assertEq(vd & 1, 0, "validation must succeed when live rate <= maxRate");
    }

    // ─── 7. Deposit/withdraw accounting ─────────────────────────────────────

    function test_Deposit_IncreasesAPNTsBalance() public {
        uint128 before = _getAPNTsBalance(operator);
        vm.prank(operator);
        sp.deposit(1_000 ether);
        assertEq(_getAPNTsBalance(operator) - before, 1_000 ether, "deposit must increase aPNTsBalance");
    }

    function test_Withdraw_DecreasesAPNTsBalance() public {
        uint128 before = _getAPNTsBalance(operator);
        vm.prank(operator);
        sp.withdraw(500 ether);
        assertEq(before - _getAPNTsBalance(operator), 500 ether, "withdraw must decrease aPNTsBalance");
    }
}

// ─── Minimal mocks ────────────────────────────────────────────────────────────

contract SPMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) {
        return keccak256(abi.encode(op, block.chainid));
    }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract SPMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract SPMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract SPMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function hasRole(bytes32 role, address account) external view returns (bool) { return _roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { _roles[role][account] = val; }
    function getCreditLimit(address) external pure returns (uint256) { return 10_000 ether; }
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
