// SPDX-License-Identifier: Apache-2.0
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
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../../../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "../../../../src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsV2Base} from "../../../../src/tokens/v2/xPNTsV2Base.sol";
import {IxPNTsTokenV2} from "../../../../src/tokens/v2/IxPNTsTokenV2.sol";
import {SuperPaymasterLens} from "../../../../src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";

// 5.5.0 migration notes (spec docs/design/aoa-balance-mode/03-final-spec.md):
// - `apnts` (3.x xPNTsToken) is kept ONLY as the operator-deposit aPNTs token: SP 5.5.0 still
//   talks to APNTS_TOKEN through IERC20 and the upgrade does not touch it (§6 step 1).
// - The operator's COMMUNITY gas token is now an xPNTs v2 token (`xtok`); SP 5.5.0 rejects 3.x
//   community tokens in configureOperator (§3.3).

// Mock Contracts
// Mock Contracts
contract MockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }

    function setCreditTier(uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}

    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    // Stub implementations for interface compliance
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false, 0,"stub",address(0),0); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    
    // V3.1 Mock Logic
    mapping(address => uint256) public creditLimits;
    
    function setCreditForUser(address user, uint256 limit) external {
        creditLimits[user] = limit;
    }

    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    
        function getCreditLimit(address user) external view override returns (uint256) { return creditLimits[user]; }
        function isReputationSource(address) external pure override returns (bool) { return true; }
        function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
        function version() external view override returns (string memory) { return "MockRegistryV3"; }
        function syncStakeFromStaking(address, bytes32, uint256) external override {}
        function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;

    constructor(int256 _price, uint8 _dec) {
        price = _price;
        _decimals = _dec;
    }
    
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return "Mock"; }
    function version() external view override returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockEntryPoint is IEntryPoint {
    function depositTo(address) external payable override {}
    function addStake(uint32) external payable override {}
    function unlockStake() external override {}
    function withdrawStake(address payable) external override {}
    function balanceOf(address) external view override returns (uint256) { return 0; }
    function getDepositInfo(address) external view override returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external override {} // IMPLEMENTED
    
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external override {} 
    function handleOps(PackedUserOperation[] calldata, address payable) external override {}
    function getSenderAddress(bytes memory) external override {}
    function getUserOpHash(PackedUserOperation calldata) external view override returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view override returns (uint256) { return 0; }
    function incrementNonce(uint192) external override {}
    function delegateAndRevert(address, bytes calldata) external override {}
}

contract SuperPaymasterTest is Test {
    using Clones for address;
    SuperPaymaster paymaster;
    xPNTsToken apnts;
    MockRegistry registry;
    MockAggregatorV3 priceFeed;
    MockEntryPoint entryPoint;
    MockXPNTsFactory mockFactory;
    V2TokenDeployer.Stack stack;
    xPNTsTokenV2 xtok; // operator's community gas token (xPNTs v2)
    SuperPaymasterLens lens; // 5.5.0 home of dryRunValidation (used to attribute sigFails)

    address owner = address(1);
    uint256 operatorPk = 0xA11CE;
    address operator = vm.addr(0xA11CE);
    address user = address(3);
    address treasury = address(4);

    bytes32 constant ENDUSER_ROLE = keccak256("ENDUSER");
    bytes32 constant COMMUNITY_ROLE = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);
        
        entryPoint = new MockEntryPoint();
        registry = new MockRegistry();
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);
        
        priceFeed = new MockAggregatorV3(2000 * 1e8, 8); // $2000 ETH
        
        // Deploy Token
        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);

        // Deploy Paymaster (UUPS Proxy)
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        // Setup Token Whitelist (CRITICAL FIX)
        apnts.setSuperPaymasterAddress(address(paymaster));

        // Deploy mock factory and register operator token (P1-4 fix)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));


        // Fix: Update Price Cache (Warp to prevent underflow allowed check)
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Grant Roles
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);

        // Fund Operator (aPNTs deposit token)
        apnts.mint(operator, 1000 ether);
        apnts.mint(user, 1000 ether);
        vm.stopPrank();

        // Operator's community gas token: xPNTs v2 (this test contract is its FACTORY, so it mints).
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xtok = V2TokenDeployer.newToken(stack, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xtok));
        IxPNTsV2Admin(address(xtok)).mint(user, 1000 ether);
        lens = new SuperPaymasterLens();

        // Sync SBT Status (Required for V3.3)
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(operator, true);
    }

    function testUnregisteredOperatorCannotDeposit() public {
        vm.startPrank(address(0xdead));
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testPushDeposit() public {
        vm.startPrank(operator);
        
        // Push Mode: Approve + DepositFor
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);
        
        assertEq(paymaster.totalTrackedBalance(), 100 ether, "Total Tracked Mismatch");

        (
            uint128 v1_bal,
            bool v3_conf,
            bool v4_pause,
            address v5_token,
            uint32 v6_rep,
            uint48 v6_minTx,
            address v7_treas,
            uint256 v8_spent,
            uint256 v9_count
        ) = paymaster.operators(operator);
        
        // v1 is aPNTsBalance (100 ether) in new packed layout.
        if (v1_bal != 100 ether) {
             console.log("v1:", v1_bal);
             fail();
        }
        assertEq(v1_bal, 100 ether);
        
        vm.stopPrank();
    }
    
    function testDepositFailsIfExceedLimit() public {
        vm.startPrank(operator);
        // Default limit is 5000 ether
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.SingleTxLimitExceeded.selector));
        paymaster.deposit(6000 ether);
        vm.stopPrank();
    }

    function testDepositWorksWithApproval() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        
        // Should succeed now
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testDestinationLockRevert() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        vm.stopPrank();

        // Simulate Paymaster trying to steal funds to a 3rd party (user)
        // We prank the Paymaster address itself
        vm.startPrank(address(paymaster));
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.UnauthorizedRecipient.selector));
        apnts.transferFrom(operator, user, 100 ether);
        vm.stopPrank();
    }

    function testWithdraw() public {
        // Setup Balance
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);

        paymaster.withdraw(50 ether);
        
        (uint128 bal,,,,,,,,) = paymaster.operators(operator); 
        assertEq(bal, 50 ether);
        assertEq(apnts.balanceOf(operator), 950 ether);
        vm.stopPrank();
    }
    
    function testConfigureOperator() public {
        vm.startPrank(operator);
        paymaster.configureOperator(address(xtok), treasury);
        (, bool configured,, address token,,, address treas,,) = paymaster.operators(operator);
        assertEq(token, address(xtok));
        assertTrue(configured);
        assertEq(treas, treasury);
        vm.stopPrank();
    }

    /// @notice 5.5.0 §3.3 / §8 migration: a 3.x community token is rejected even when the factory
    ///         binding matches (the BALANCE_MODE_VERSION probe fails), so a legacy operator can
    ///         never be (re)configured onto SP 5.5.0.
    function testConfigureOperator_RejectsLegacy3xToken() public {
        mockFactory.setToken(operator, address(apnts)); // factory binding satisfied
        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector);
        paymaster.configureOperator(address(apnts), treasury);
        (, bool configured,,,,,,,) = paymaster.operators(operator);
        assertFalse(configured, "legacy token must not configure the operator");
    }
    
    function testSlashAndPause() public {
        vm.startPrank(owner);
        paymaster.updateReputation(operator, 100);

        // HIGH-1: queue before each slash (two-step slash guard)
        paymaster.queueSlash(operator);
        // Slash Minor
        paymaster.slashOperator(operator, ISuperPaymaster.SlashLevel.MINOR, 0, "Test Minor");
        (,,,, uint32 repMinor,,,,) = paymaster.operators(operator);
        assertEq(repMinor, 80);

        // P0-14: advance past 24h cooldown before second slash
        vm.warp(block.timestamp + 24 hours + 1);

        // HIGH-1: re-queue for the second slash (flag was cleared by the first execution)
        paymaster.queueSlash(operator);
        // Slash Major (Pause)
        paymaster.slashOperator(operator, ISuperPaymaster.SlashLevel.MAJOR, 0, "Test Major");
        (,,,, uint32 repMajor,,,,) = paymaster.operators(operator);
        assertEq(repMajor, 30);

        vm.stopPrank();
    }

    // ====================================
    // M-5: pending-slash withdraw guard
    // ====================================

    /// @notice M-5: withdraw reverts when a slash has been queued for the caller.
    function testWithdrawBlockedWhenSlashPending() public {
        // Deposit so operator has a balance to attempt to withdraw
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);
        vm.stopPrank();

        // Owner queues a slash (phase 1 — sets the pending flag)
        vm.prank(owner);
        paymaster.queueSlash(operator);

        // Operator tries to front-run by withdrawing before slash executes
        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.SlashPending.selector);
        paymaster.withdraw(100 ether);
    }

    /// @notice M-5: withdraw succeeds again after slashOperator clears the flag.
    function testWithdrawAllowedAfterSlashExecuted() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);
        vm.stopPrank();

        // Owner queues then executes slash
        vm.startPrank(owner);
        paymaster.queueSlash(operator);
        paymaster.slashOperator(operator, ISuperPaymaster.SlashLevel.MINOR, 0, "Minor via queueSlash path");
        vm.stopPrank();

        // Withdraw should succeed now that flag is cleared
        vm.prank(operator);
        paymaster.withdraw(50 ether); // should not revert
        (uint128 bal,,,,,,,,) = paymaster.operators(operator);
        assertLt(bal, 100 ether, "balance should have decreased");
    }

    /// @notice M-5: withdraw succeeds after owner cancels a queued slash.
    function testWithdrawAllowedAfterSlashCancelled() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        paymaster.queueSlash(operator);
        paymaster.cancelSlash(operator);
        vm.stopPrank();

        // Withdraw should succeed now that flag is cleared
        vm.prank(operator);
        paymaster.withdraw(100 ether); // should not revert
        (uint128 bal,,,,,,,,) = paymaster.operators(operator);
        assertEq(bal, 0);
    }

    /// @notice M-5: queueSlash reverts for callers that are neither owner nor BLS aggregator.
    function testQueueSlashUnauthorizedReverts() public {
        vm.prank(user);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.queueSlash(operator);
    }

    /// @notice M-5: withdraw still works normally when no slash has been queued.
    function testWithdrawNoPendingSlash() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        paymaster.depositFor(operator, 100 ether);
        paymaster.withdraw(50 ether);
        vm.stopPrank();
        (uint128 bal,,,,,,,,) = paymaster.operators(operator);
        assertEq(bal, 50 ether);
    }
    

    /// @notice 5.5.0 (R10-M1b): validation moves a0 IN FLIGHT (not revenue); postOp turns the
    ///         charge into revenue and refunds (a0 - charge) to the operator. The pre-5.5.0
    ///         assertion `totalSpent == protocolRevenue` right after validation encoded the old
    ///         optimistic "a0 is revenue at validation" accounting and is replaced by the
    ///         in-flight / settle / withdraw-buffer flow below.
    function testProtocolRevenueFlow() public {
        // 1. Setup Operator
        vm.startPrank(owner);
        apnts.mint(operator, 200000 ether);
        vm.stopPrank();
        IxPNTsV2Admin(address(xtok)).mint(user, 200000 ether); // user pays gas in xPNTs v2

        vm.startPrank(operator);
        paymaster.configureOperator(address(xtok), treasury);

        apnts.approve(address(paymaster), 200000 ether);
        // Split deposit to respect the 3.x aPNTs 5000 ether single-tx limit (40 * 5000 = 200,000)
        for(uint i=0; i<40; i++) {
            paymaster.depositFor(operator, 5000 ether);
        }
        vm.stopPrank();

        // 2. Validation. maxCost 0.03 ETH -> a0 = 3000 aPNTs * 1.2 = 3600 aPNTs (full maxCost,
        //    + fee + validation buffer; spec §10.3), which fits the v2 single-tx/allowance caps.
        PackedUserOperation memory op = _createOp(user);
        bytes32 h = keccak256("revenue_flow");
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, h, 0.03 ether);
        assertEq(uint160(vd), 0, "validation must pass");
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        assertEq(a0, 3600 ether, "a0 = full maxCost at cached price + fee + buffer");

        (uint128 balMid,,,,,,, uint256 spent,) = paymaster.operators(operator);
        assertEq(spent, a0, "totalSpent records a0");
        assertEq(uint256(balMid), 200000 ether - a0, "a0 debited from operator at validation");
        assertEq(paymaster.protocolRevenue(), 0, "R10-M1b: a0 is in flight, NOT revenue, before postOp");
        (address inflOp, uint256 inflA0) = paymaster.inflightOf(h);
        assertEq(inflOp, operator, "in-flight operator");
        assertEq(inflA0, a0, "in-flight a0");

        // 3. Settlement
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.02 ether, 1 gwei);

        uint256 revenue = paymaster.protocolRevenue();
        (uint128 balFinal,,,,,,,,) = paymaster.operators(operator);
        assertGt(revenue, 0, "revenue after settlement");
        assertLt(revenue, a0, "charge < reservation (refund happened)");
        assertEq(uint256(balFinal), 200000 ether - revenue, "operator refunded exactly a0 - charge (no clamp)");
        (inflOp, inflA0) = paymaster.inflightOf(h);
        assertEq(inflOp, address(0), "in-flight cleared");
        assertEq(inflA0, 0, "in-flight cleared");

        // 4. Withdraw Revenue — must leave PROTOCOL_REVENUE_BUFFER (0.1 ether) in place
        vm.startPrank(owner);
        uint256 buffer = 0.1 ether;
        uint256 withdrawable = revenue > buffer ? revenue - buffer : 0;
        uint256 treasuryBalBefore = apnts.balanceOf(treasury);
        assertGt(withdrawable, 0, "revenue must exceed the buffer in this scenario");
        paymaster.withdrawProtocolRevenue(treasury, withdrawable);
        assertEq(apnts.balanceOf(treasury), treasuryBalBefore + withdrawable);
        // Verify buffer prevents full drain
        vm.expectRevert(abi.encodeWithSelector(SuperPaymaster.InsufficientRevenue.selector));
        paymaster.withdrawProtocolRevenue(treasury, revenue);
        vm.stopPrank();
    }


    // ====================================
    // V3.1 Refactor Tests (migrated to 5.5.0 balance mode + reservation credit)
    // ====================================

    function _setupV3Env() internal {
        vm.startPrank(operator);
        paymaster.configureOperator(address(xtok), treasury);
        apnts.approve(address(paymaster), 200 ether);
        paymaster.depositFor(operator, 200 ether);
        vm.stopPrank();
    }

    /// @dev Move the user's whole xPNTs balance away (the v2 token has lockedOf-aware storage,
    ///      so a real transfer is used instead of `deal`).
    function _drain(address who) internal {
        uint256 bal = xtok.balanceOf(who);
        if (bal > 0) {
            vm.prank(who);
            xtok.transfer(address(0xdead), bal);
        }
        assertEq(xtok.balanceOf(who), 0);
    }

    /// @dev Spec C-3: queue AUTO -> 48 h -> execute (anyone); then the user signs requestCredit.
    ///      The SP price cache is refreshed after the warp so validUntil stays in the future.
    function _enableAutoCredit(address who, uint256 requestedCap) internal {
        vm.prank(operator); // communityOwner of xtok
        IxPNTsV2Admin(address(xtok)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IxPNTsV2Admin(address(xtok)).executeCreditPolicy();
        paymaster.updatePrice();
        vm.prank(who);
        IxPNTsV2Admin(address(xtok)).requestCredit(requestedCap);
    }

    function _validate(bytes32 h, uint256 maxCost) internal returns (bytes memory ctx, uint256 vd) {
        PackedUserOperation memory op = _createOp(user);
        vm.prank(address(entryPoint));
        (ctx, vd) = paymaster.validatePaymasterUserOp(op, h, maxCost);
    }

    function _opBalance() internal view returns (uint128 b) {
        (b,,,,,,,,) = paymaster.operators(operator);
    }

    /// @notice Credit payment (5.5.0): a user with NO xPNTs balance, AUTO policy, a current-epoch
    ///         request and a non-zero tier is sponsored in CREDIT mode with a validation-time
    ///         reservation (spec §1, C-1).
    function test_V31_CreditPayment_Success() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        _drain(user);
        _enableAutoCredit(user, 1000 ether);

        bytes32 opHash = keccak256("test_hash");
        (bytes memory context, uint256 validationData) = _validate(opHash, 0.001 ether);

        assertEq(uint160(validationData), 0, "Validation should pass via Credit");
        SuperPaymaster.OpCtx memory c = abi.decode(context, (SuperPaymaster.OpCtx));
        assertEq(c.token, address(xtok));
        assertEq(c.operator, operator);
        assertEq(c.user, user);
        assertEq(c.opHash, opHash);
        assertEq(c.mode, 2, "CREDIT mode");
        assertGt(c.a0, 0);
        assertEq(xtok.creditReservedOf(user), c.a0, "validation-time reservation == a0");
        assertEq(xtok.lockedOf(user), 0, "no escrow in credit mode");
    }

    function _createOp(address sender) internal view returns (PackedUserOperation memory) {
        PackedUserOperation memory op;
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100000), uint128(100000)));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));

        // 5.5.0 paymasterAndData: [PM 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
        op.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster), uint128(100000), uint128(200000), operator, type(uint256).max, address(xtok), 0
        );
        return op;
    }

    /// @notice Replaces `test_V31_DebtRecording_OnBurnFail`. The 3.x "burn failed -> recordDebt
    ///         fallback in postOp" path no longer exists (spec §1: debt only via reservation ->
    ///         settleCredit, I3). The same risk — a user who cannot pay from balance — now becomes
    ///         debt only through an admitted credit reservation, and the debt equals the charge.
    function test_V31_DebtRecording_ViaCreditSettlement() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        _drain(user);
        _enableAutoCredit(user, 1000 ether);

        bytes32 opHash = keccak256("test_hash");
        (bytes memory context, uint256 vd) = _validate(opHash, 0.001 ether);
        assertEq(uint160(vd), 0);
        uint256 a0 = abi.decode(context, (SuperPaymaster.OpCtx)).a0;
        uint256 revBefore = paymaster.protocolRevenue();

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.0005 ether, 1 gwei);

        uint256 debt = xtok.debts(user);
        uint256 charge = paymaster.protocolRevenue() - revBefore;
        assertGt(debt, 0, "Debt recorded for a user who cannot pay from balance");
        assertEq(debt, charge, "debt == charge (settleCredit, C-2)");
        assertLe(debt, a0, "debt <= admitted reservation");
        assertEq(xtok.creditReservedOf(user), 0, "reservation consumed");
        assertEq(xtok.balanceOf(user), 0, "no balance touched");
    }

    function test_V31_BurnSuccess_WhenUserHasBalance() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);

        uint256 balBefore = xtok.balanceOf(user); // 1000 ether from setUp
        require(balBefore > 0, "Precondition: user needs xPNTs");

        bytes32 opHash = keccak256("test_burn_hash");
        (bytes memory context, uint256 vd) = _validate(opHash, 0.001 ether);
        assertEq(uint160(vd), 0);
        assertEq(abi.decode(context, (SuperPaymaster.OpCtx)).mode, 1, "BALANCE mode");
        assertGt(xtok.lockedOf(user), 0, "escrow taken at validation");
        uint256 revBefore = paymaster.protocolRevenue();

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, 1 gwei);

        uint256 burned = balBefore - xtok.balanceOf(user);
        assertGt(burned, 0, "User xPNTs must decrease after burn");
        assertEq(burned, paymaster.protocolRevenue() - revBefore, "rate 1:1: burned xPNTs == aPNTs charge");
        assertEq(xtok.lockedOf(user), 0, "escrow cleared");
        assertEq(xtok.debts(user), 0, "No debt should be recorded when burn succeeds");
    }

    /// @notice Migrated `test_V31_ReputationEvent` (it asserted nothing; `UserReputationAccrued`
    ///         is never emitted by SP). Asserts what the SP NatSpec actually promises for the
    ///         validation frame: it passes, and SuperPaymaster itself emits no event there.
    function test_V31_ValidationPasses_NoSPEventInValidation() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        PackedUserOperation memory op = _createOp(user);

        vm.recordLogs();
        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, keccak256("h"), 0.001 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint160(vd), 0, "validation passes");
        // Positive control for the recorder: the token's LockCreated IS captured.
        bool sawTokenLog;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(xtok)) sawTokenLog = true;
        }
        assertTrue(sawTokenLog, "recorder live: token escrow event captured");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(paymaster), "SP must not emit during validation");
        }
    }

    // ─── C-01 Negative Tests (audit §6 T-H), migrated to the token's canonical ceiling ────────
    // 5.5.0: the credit gate is the token's `effectiveCreditCap` (C-0) checked by
    // `tryReserveCredit` (C-1), and it is reached ONLY when the escrow lock is INSUFFICIENT
    // (R-2). A failure is still a soft SIG_VALIDATION_FAILED: `uint160(validationData) == 1`.

    /// @notice C-01a: a user with ZERO credit AND zero xPNTs balance is rejected at validation —
    ///         both under the default OFF policy and under AUTO with a request but a zero tier.
    ///         L-1: a failed validation writes nothing (no escrow, no reservation, no in-flight).
    function test_C01_ZeroCredit_NoBalance_Rejected() public {
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        _drain(user);
        uint128 opBefore = _opBalance();

        (bytes memory context, uint256 validationData) = _validate(keccak256("c01a"), 0.001 ether);
        assertEq(uint160(validationData), 1, "C-01a: zero-credit user must fail validation (policy OFF)");
        assertEq(context.length, 0, "C-01a: no context emitted on credit failure");
        _assertRejectedBy(_creditRejected(IxPNTsTokenV2.CreditResult.NO_CREDIT));

        _enableAutoCredit(user, 1000 ether); // request exists, but the tier is 0 -> cap 0
        assertEq(xtok.effectiveCreditCap(user), 0, "tier 0 -> effective cap 0");
        (context, validationData) = _validate(keccak256("c01a-auto"), 0.001 ether);
        assertEq(uint160(validationData), 1, "C-01a: zero-tier user must fail validation (policy AUTO)");
        assertEq(context.length, 0);
        _assertRejectedBy(_creditRejected(IxPNTsTokenV2.CreditResult.NO_CREDIT));

        assertEq(xtok.lockedOf(user), 0, "L-1: no escrow written");
        assertEq(xtok.creditReservedOf(user), 0, "L-1: no reservation written");
        assertEq(_opBalance(), opBefore, "operator not debited");
        (address f,) = paymaster.inflightOf(keccak256("c01a-auto"));
        assertEq(f, address(0), "nothing in flight");
    }

    /// @notice C-01b: once `debts + reserved + a0` would exceed the ceiling, validation fails.
    ///         Covers both the same-bundle case (an admitted reservation not yet settled, T-R14-08)
    ///         and debt that already sits at the ceiling. Replaces the 3.x `recordDebt` pre-load
    ///         (removed from v2): the debt is produced by a real reserve -> settle round.
    function test_C01_DebtAtCeiling_Rejected() public {
        _setupV3Env();
        // Keep the OPERATOR solvent for several ops so every rejection below is attributable to
        // the user's credit ceiling, not to the operator-balance check that runs first.
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 600 ether);
        paymaster.depositFor(operator, 600 ether);
        vm.stopPrank();
        registry.setCreditForUser(user, 1000 ether); // tier well above the request
        _drain(user);
        uint256 a0 = 120 ether; // maxCost 0.001 ETH -> 100 aPNTs * 1.2
        _enableAutoCredit(user, a0); // tiny ceiling: exactly one reservation fits

        (bytes memory ctx1, uint256 vd1) = _validate(keccak256("c01b-1"), 0.001 ether);
        assertEq(uint160(vd1), 0, "positive control: first op fits the ceiling exactly");
        assertEq(abi.decode(ctx1, (SuperPaymaster.OpCtx)).a0, a0);
        assertEq(paymaster.getAvailableCredit(user, address(xtok)), 0, "reservation consumes headroom");

        (, uint256 vd2) = _validate(keccak256("c01b-2"), 0.001 ether);
        assertEq(uint160(vd2), 1, "C-01b: same-bundle second reservation exceeds the ceiling");
        _assertRejectedBy(_creditRejected(IxPNTsTokenV2.CreditResult.EXCEEDS_CAP));

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.0005 ether, 1 gwei);
        uint256 debt = xtok.debts(user);
        assertGt(debt, 0);
        assertEq(paymaster.getAvailableCredit(user, address(xtok)), a0 - debt, "headroom = cap - debt");

        (, uint256 vd3) = _validate(keccak256("c01b-3"), 0.001 ether);
        assertEq(uint160(vd3), 1, "C-01b: over-ceiling charge must fail validation");
        _assertRejectedBy(_creditRejected(IxPNTsTokenV2.CreditResult.EXCEEDS_CAP));
        assertEq(xtok.creditReservedOf(user), 0, "rejected reservation writes nothing");
    }

    function _creditRejected(IxPNTsTokenV2.CreditResult r) internal view returns (bytes32) {
        return lens.DRYRUN_CREDIT_REJECTED() | bytes32(uint256(uint8(r)));
    }

    /// @dev Attribute a sigFail to its cause: the lens mirrors validation branch by branch.
    function _assertRejectedBy(bytes32 expected) internal view {
        (bool ok, bytes32 reason) = lens.dryRunValidation(address(paymaster), _createOp(user), 0.001 ether);
        assertFalse(ok, "lens agrees: rejected");
        assertEq(reason, expected, "rejection reason");
    }

    /// @notice C-01c (positive control): a user WITH ample credit but zero balance is allowed —
    ///         the op is reserved against credit and stays within the ceiling.
    function test_C01_AmpleCredit_NoBalance_Allowed() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        _drain(user);
        _enableAutoCredit(user, 1000 ether);
        uint256 availBefore = paymaster.getAvailableCredit(user, address(xtok));
        assertEq(availBefore, 1000 ether, "cap = min(request, ceiling, tier)");

        (bytes memory context, uint256 validationData) = _validate(keccak256("c01c"), 0.001 ether);

        assertEq(uint160(validationData), 0, "C-01c: in-credit user must pass validation");
        assertGt(context.length, 0, "C-01c: context must be emitted on success");
        uint256 a0 = abi.decode(context, (SuperPaymaster.OpCtx)).a0;
        assertEq(paymaster.getAvailableCredit(user, address(xtok)), availBefore - a0, "headroom drops by a0");
    }

    /// @notice C-01d — was `test_C01_NoCredit_WithBalance_Rejected` (AUDIT H-1). 5.5.0 behaviour
    ///         differs ON PURPOSE: a zero-credit user WITH balance is sponsored in BALANCE mode,
    ///         because the H-1 risk (emptying the balance between validation and postOp to force an
    ///         unbounded debt) is now structurally closed by the escrow: the locked xPNTs cannot be
    ///         moved (A-1), postOp burns from the escrow, and no debt can ever arise (I3).
    function test_C01_NoCredit_WithBalance_EscrowedNotDebt() public {
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        require(xtok.balanceOf(user) > 0, "precondition: user holds xPNTs");
        uint256 balBefore = xtok.balanceOf(user);

        (bytes memory ctx, uint256 validationData) = _validate(keccak256("c01d"), 0.001 ether);
        assertEq(uint160(validationData), 0, "C-01d: balance-backed op is sponsored");
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(c.mode, 1, "BALANCE mode, never credit");
        uint256 locked = xtok.lockedOf(user);
        assertEq(locked, c.a0, "rate 1:1: escrow == a0");

        // H-1 attack: empty the balance between validation and postOp -> blocked by the escrow.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.BalanceLocked.selector, user, locked));
        xtok.transfer(address(0xdead), balBefore);
        // Only the unlocked part can move.
        vm.prank(user);
        xtok.transfer(address(0xdead), balBefore - locked);

        uint256 revBefore = paymaster.protocolRevenue();
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.0005 ether, 1 gwei);
        uint256 charge = paymaster.protocolRevenue() - revBefore;
        assertEq(xtok.balanceOf(user), locked - charge, "settled from the escrow");
        assertEq(xtok.lockedOf(user), 0);
        assertEq(xtok.debts(user), 0, "no debt in balance mode (I3)");
    }
}
