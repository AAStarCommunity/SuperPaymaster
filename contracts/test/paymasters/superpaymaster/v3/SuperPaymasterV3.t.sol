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
        mockFactory.setToken(operator, address(apnts));


        // Fix: Update Price Cache (Warp to prevent underflow allowed check)
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Grant Roles
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);

        // Fund Operator
        apnts.mint(operator, 1000 ether);
        apnts.mint(user, 1000 ether); // User holds xPNTs (technically same logic for aPNTs here)
        vm.stopPrank();
        
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
        paymaster.configureOperator(address(apnts), treasury);
        (,,, address token,,,,,) = paymaster.operators(operator); 
        assertEq(token, address(apnts));
        vm.stopPrank();
    }
    
    function testSlashAndPause() public {
        vm.startPrank(owner);
        paymaster.updateReputation(operator, 100);

        // Slash Minor
        paymaster.slashOperator(operator, ISuperPaymaster.SlashLevel.MINOR, 0, "Test Minor");
        (,,,, uint32 repMinor,,,,) = paymaster.operators(operator);
        assertEq(repMinor, 80);

        // P0-14: advance past 24h cooldown before second slash
        vm.warp(block.timestamp + 24 hours + 1);

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
    
    function testProtocolRevenueFlow() public {
        // 1. Setup Operator (Need significant balance for 1 ETH gas * 2000 price)
        vm.startPrank(owner);
        apnts.mint(operator, 200000 ether);
        apnts.mint(user, 200000 ether); // FIX: Mint user enough tokens to pay for the op
        vm.stopPrank();
        // AUDIT H-1: credit is now enforced in validation regardless of balance, so a
        // sponsored user needs a non-zero credit ceiling (this test exercises revenue
        // flow, not the credit gate). Give ample credit so the op passes validation.
        registry.setCreditForUser(user, 200000 ether);

        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury);
        
        apnts.approve(address(paymaster), 200000 ether);
        // Split deposit to respect 5000 ether limit (40 * 5000 = 200,000)
        for(uint i=0; i<40; i++) {
            paymaster.depositFor(operator, 5000 ether);
        }
        vm.stopPrank();

        // 2. Mock Validation Call
        vm.startPrank(address(entryPoint));
        
        PackedUserOperation memory op = _createOp(user);
        
        // Use 1 ether prefund to guarantee > 0 revenue
        try paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether) {
             // Success
        } catch Error(string memory reason) {
             console.log("Val Failed:", reason);
             fail(); 
        } catch (bytes memory) {
             console.log("Val Failed (Bytes)");
             fail();
        }
        
        // 3. Verify Revenue
        // Spent is v7 (index 7, item 8?) 
        // Struct: 6=Balance, 7=TotalSpent. 
        // Tuple: (v1..v9).
        // If v6 is Balance, then v7 is TotalSpent.
        (,,,,,,, uint256 spent,) = paymaster.operators(operator); 
        
        uint256 revenue = paymaster.protocolRevenue();
        console.log("Revenue detected:", revenue);
        
        assertEq(spent, revenue);
        assertTrue(revenue > 0);
        
        vm.stopPrank();
        
        // 4. Withdraw Revenue — must leave PROTOCOL_REVENUE_BUFFER (0.1 ether) in place
        vm.startPrank(owner);
        uint256 buffer = 0.1 ether;
        uint256 withdrawable = revenue > buffer ? revenue - buffer : 0;
        uint256 treasuryBalBefore = apnts.balanceOf(treasury);
        if (withdrawable > 0) {
            paymaster.withdrawProtocolRevenue(treasury, withdrawable);
            assertEq(apnts.balanceOf(treasury), treasuryBalBefore + withdrawable);
        }
        // Verify buffer prevents full drain
        if (revenue > buffer) {
            vm.expectRevert(abi.encodeWithSelector(SuperPaymaster.InsufficientRevenue.selector));
            paymaster.withdrawProtocolRevenue(treasury, revenue);
        }
        vm.stopPrank();
    }


    // ====================================
    // V3.1 Refactor Tests
    // ====================================

    function _setupV3Env() internal {
        vm.startPrank(user);
        vm.stopPrank();

        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury);
        apnts.approve(address(paymaster), 200 ether);
        paymaster.depositFor(operator, 200 ether);
        vm.stopPrank();
    }

    function test_V31_CreditPayment_Success() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        
        PackedUserOperation memory op = _createOp(user);
        bytes32 opHash = keccak256("test_hash");

        vm.startPrank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, opHash, 0.001 ether);
        vm.stopPrank();

        assertEq(uint160(validationData), 0, "Validation should pass via Credit");
        (address token, address u, uint256 aAmount, bytes32 h, address opAddr) = abi.decode(context, (address, address, uint256, bytes32, address));
        assertEq(token, address(apnts));
        assertEq(opAddr, operator);
        assertEq(u, user);
        assertGt(aAmount, 0);
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
        
        // paymasterAndData: [PM][Limit][Post][Op][Rate] (104 bytes)
        bytes memory pmData = abi.encodePacked(
            address(paymaster),
            uint128(100000), 
            uint128(200000),      
            operator,
            type(uint256).max // MaxRate
        );
        
        bytes32 hash = keccak256(abi.encode(
            op.sender,
            op.nonce,
            keccak256(op.initCode),
            keccak256(op.callData),
            op.accountGasLimits,
            op.preVerificationGas,
            op.gasFees,
            keccak256(pmData)
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, MessageHashUtils.toEthSignedMessageHash(hash));
        op.paymasterAndData = abi.encodePacked(pmData, r, s, v);
        
        return op;
    }

    function test_V31_DebtRecording_OnBurnFail() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);

        // Zero out user's xPNTs so burnFromWithOpHash fails and falls back to recordDebt.
        deal(address(apnts), user, 0);

        PackedUserOperation memory op = _createOp(user);
        bytes32 opHash = keccak256("test_hash");

        vm.startPrank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, opHash, 0.001 ether);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, 1 gwei);
        vm.stopPrank();

        uint256 debt = apnts.getDebt(user);
        assertGt(debt, 0, "Debt should be recorded when burn fails due to zero balance");
    }

    function test_V31_BurnSuccess_WhenUserHasBalance() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);

        uint256 balBefore = apnts.balanceOf(user); // 1000 ether from setUp
        require(balBefore > 0, "Precondition: user needs xPNTs");

        PackedUserOperation memory op = _createOp(user);
        bytes32 opHash = keccak256("test_burn_hash");

        vm.startPrank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, opHash, 0.001 ether);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, 1 gwei);
        vm.stopPrank();

        assertLt(apnts.balanceOf(user), balBefore, "User xPNTs must decrease after burn");
        assertEq(apnts.getDebt(user), 0, "No debt should be recorded when burn succeeds");
    }

    /*
    function test_V31_InsufficientCredit_Revert() public {
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        
        deal(address(apnts), user, 0);

        PackedUserOperation memory op = _createOp(user);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, keccak256("h"), 0.001 ether);
        
        // Assert: Returns SIG_VALIDATION_FAILED (1) instead of reverting
        assertEq(validationData, 1, "Should return SIG_VALIDATION_FAILED");
    }
    */

    function test_V31_ReputationEvent() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        PackedUserOperation memory op = _createOp(user);

        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, keccak256("h"), 0.001 ether);
    }

    // ─── C-01 Negative Tests (audit §6 T-H) ──────────────────────────────────────
    // The credit gate (`_creditExceeded`) is a soft validation failure: it does
    // NOT revert, it returns SIG_VALIDATION_FAILED so the EntryPoint drops the op.
    // Per ERC-4337 v0.7 the failure is encoded in the low 160 bits (authorizer ==
    // address(1)), with validUntil/validAfter in the upper bits — so the correct
    // assertion is `uint160(validationData) == 1`, NOT `validationData == 1`
    // (the latter only holds when validUntil/validAfter are both zero, which is
    // why the historical inline test was commented out).

    /// @notice C-01a: a user with ZERO credit AND zero xPNTs balance (so the
    ///         charge must fall to debt) is rejected at validation.
    function test_C01_ZeroCredit_NoBalance_Rejected() public {
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        deal(address(apnts), user, 0); // cannot settle from balance → debt path

        PackedUserOperation memory op = _createOp(user);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, keccak256("c01a"), 0.001 ether);

        assertEq(uint160(validationData), 1, "C-01a: zero-credit user must fail validation");
        assertEq(context.length, 0, "C-01a: no context emitted on credit failure");
    }

    /// @notice C-01b: a user whose existing debt already sits at their credit
    ///         ceiling (and who has no xPNTs to pay) is rejected — the new charge
    ///         would push debt PAST the ceiling.
    function test_C01_DebtAtCeiling_Rejected() public {
        _setupV3Env();
        uint256 creditLimit = 1 ether; // tiny ceiling
        registry.setCreditForUser(user, creditLimit);
        deal(address(apnts), user, 0);

        // Pre-load debt right up to the ceiling via the SuperPaymaster path.
        vm.prank(address(paymaster));
        apnts.recordDebt(user, creditLimit);
        assertEq(apnts.getDebt(user), creditLimit);

        PackedUserOperation memory op = _createOp(user);

        vm.prank(address(entryPoint));
        (, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, keccak256("c01b"), 0.001 ether);

        assertEq(uint160(validationData), 1, "C-01b: over-ceiling charge must fail validation");
    }

    /// @notice C-01c (positive control): a user WITH ample credit but zero balance
    ///         is allowed — the charge falls to debt but stays within the ceiling.
    ///         Guards against the gate being so strict it rejects legitimate ops.
    function test_C01_AmpleCredit_NoBalance_Allowed() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        deal(address(apnts), user, 0);

        PackedUserOperation memory op = _createOp(user);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, keccak256("c01c"), 0.001 ether);

        assertEq(uint160(validationData), 0, "C-01c: in-credit user must pass validation");
        assertGt(context.length, 0, "C-01c: context must be emitted on success");
    }

    /// @notice C-01d (positive control): a user with NO credit but enough xPNTs
    ///         to settle the charge from balance is allowed — credit only governs
    ///         the overdraft/debt path, never balance-backed payment.
    function test_C01_NoCredit_WithBalance_Rejected() public {
        // AUDIT H-1: the credit ceiling is now enforced in validation regardless of
        // xPNTs balance. A zero-credit user is rejected even with sufficient balance,
        // because a balance-backed op could empty its balance between validate and
        // postOp (plain transfer bypasses the autoApprovedSpenders firewall) and
        // force the debt path with unbounded recorded debt.
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        // setUp already minted the user 1000 ether xPNTs; ensure it's intact.
        require(apnts.balanceOf(user) > 0, "precondition: user holds xPNTs");

        PackedUserOperation memory op = _createOp(user);

        vm.prank(address(entryPoint));
        (, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, keccak256("c01d"), 0.001 ether);

        assertEq(uint160(validationData), 1, "C-01d (H-1): zero-credit op rejected even with balance");
    }
}
