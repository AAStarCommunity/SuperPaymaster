// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

contract C04OOGRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimit;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function setCreditLimit(address user, uint256 limit) external {
        creditLimit[user] = limit;
    }

    /// @dev Read by GlobalTierSource (the v2 token's default credit tier source).
    function getCreditLimit(address user) external view returns (uint256) {
        return creditLimit[user];
    }
}

contract C04OOGPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C04OOGAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice C-04 (forced postOp OOG) regression, migrated to SuperPaymaster 5.5.0 + xPNTs v2.
/// @dev    Runs through a REAL EntryPoint v0.7. In 5.5.0 the user is escrowed at validation
///         (BALANCE) or holds a validation-time credit reservation (CREDIT); postOp settles WITHOUT
///         try/catch (spec §10.1 B-1), so the legacy pendingDebts fallback no longer exists and the
///         worst postOp path is now the settlement itself plus the cold rate-limit write.
contract PoC_C04_ForcedPostOpOOG_Test is Test {
    EntryPoint public entryPoint;
    SimpleAccountFactory public accountFactory;
    SuperPaymaster public paymaster;
    C04OOGRegistry public registry;
    C04OOGAPNTs public apnts;
    xPNTsTokenV2 public xpnts;
    MockXPNTsFactory public mockFactory;

    uint256 internal constant ACCOUNT_OWNER_PK = 0xC0400A;
    uint256 internal constant POOR_OWNER_PK = 0xC0400B;
    uint256 internal constant NORMAL_POST_OP_GAS = 1_000_000;
    uint256 internal constant MIN_POST_OP_GAS = 200_000; // SuperPaymaster.MIN_POST_OP_GAS (internal)
    uint256 internal constant PM_VERIFICATION_GAS = 700_000;
    uint256 internal constant ACCOUNT_VERIFICATION_GAS = 350_000;
    uint256 internal constant CALL_GAS_LIMIT = 0;
    uint256 internal constant PRE_VERIFICATION_GAS = 50_000;

    address public owner = address(0xC0401);
    address public treasury = address(0xC0402);
    address public operator = address(0xC0403);
    address public beneficiary = address(0xC0404);
    address public accountOwner = vm.addr(ACCOUNT_OWNER_PK);
    address public user;
    address public poorUser; // SBT holder with NO xPNTs -> can only be sponsored on credit

    bytes32 public constant C04_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant C04_ROLE_COMMUNITY = keccak256("COMMUNITY");

    bytes32 internal constant POST_OP_REVERT_REASON_TOPIC =
        keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");

    struct Snapshot {
        uint128 operatorBalance;
        uint256 protocolRevenue;
        uint256 userDebt;
        uint256 userBalance;
        uint256 userLocked;
        uint256 userReserved;
        uint256 spDeposit;
    }

    struct ScenarioResult {
        bool handleOpsReverted;
        bool postOpFailed;
        uint256 postOpGasLimit;
        bytes32 opHash;
        uint256 operatorLoss;
        uint256 protocolRevenueIncrease;
        uint256 userDebtIncrease;
        uint256 userBurned;
        uint256 spDepositLoss;
        Snapshot beforeState;
        Snapshot afterState;
    }

    function setUp() public {
        vm.deal(owner, 10 ether);

        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        user = address(accountFactory.createAccount(accountOwner, 0));
        poorUser = address(accountFactory.createAccount(vm.addr(POOR_OWNER_PK), 0));

        vm.startPrank(owner);
        registry = new C04OOGRegistry();
        registry.setRole(C04_ROLE_PAYMASTER_SUPER, operator, true);
        registry.setRole(C04_ROLE_COMMUNITY, operator, true);

        C04OOGPriceFeed priceFeed = new C04OOGPriceFeed();
        apnts = new C04OOGAPNTs();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );
        vm.stopPrank();

        // xPNTs v2 stack (this test contract is the protocol-registry owner and the token FACTORY).
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, owner, operator, address(paymaster), 1e18);
        IxPNTsV2Admin(address(xpnts)).mint(user, 1_000_000 ether);

        vm.startPrank(owner);
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();
        paymaster.deposit{value: 1 ether}();

        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.startPrank(address(registry));
        paymaster.updateSBTStatus(user, true);
        paymaster.updateSBTStatus(poorUser, true);
        vm.stopPrank();

        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.deposit(100_000 ether);
        vm.stopPrank();
    }

    function test_baseline_normalPostOp() public {
        ScenarioResult memory result = _runScenario(user, ACCOUNT_OWNER_PK, 0, NORMAL_POST_OP_GAS);

        assertFalse(result.handleOpsReverted, "baseline handleOps must not revert");
        assertFalse(result.postOpFailed, "baseline postOp unexpectedly failed");
        assertGt(result.operatorLoss, 0, "baseline should charge operator for actual gas");
        assertGt(result.protocolRevenueIncrease, 0, "baseline should leave final protocol revenue");
        // 5.5.0: the user pays from the validation-time escrow (burn), NOT via debt (I3).
        assertGt(result.userBurned, 0, "baseline should burn the user's escrowed xPNTs");
        assertEq(result.userDebtIncrease, 0, "balance mode never creates debt (I3)");
        assertEq(result.afterState.userLocked, 0, "escrow fully cleared after settlement");
        assertEq(result.operatorLoss, result.protocolRevenueIncrease, "operator net loss == revenue (R10-M1b, no clamp)");
        assertGt(result.spDepositLoss, 0, "baseline should spend SP EntryPoint deposit");
        (address f, uint256 a0) = paymaster.inflightOf(result.opHash);
        assertEq(f, address(0), "in-flight sponsorship cleared");
        assertEq(a0, 0, "in-flight a0 cleared");

        console.log("baseline operator aPNTs loss", result.operatorLoss);
        console.log("baseline protocolRevenue increase", result.protocolRevenueIncrease);
        console.log("baseline user xPNTs burned", result.userBurned);
        console.log("baseline SP ETH deposit loss", result.spDepositLoss);
    }

    // REGRESSION GUARD (post-fix): an op whose paymasterPostOpGasLimit is below
    // MIN_POST_OP_GAS must be rejected at validation, so it never executes and the
    // operator is never debited. Pre-fix this same op forced postOp OOG and drained
    // the operator (C-04). This test PASSES on fixed code, FAILS on vulnerable code.
    function test_fix_lowPostOpGasRejected() public {
        ScenarioResult memory result = _runScenario(user, ACCOUNT_OWNER_PK, 0, 5_000);

        assertTrue(result.handleOpsReverted, "fix: low paymasterPostOpGasLimit must be rejected at validation");
        assertEq(result.operatorLoss, 0, "fix: rejected op must not debit the operator");
        assertEq(result.protocolRevenueIncrease, 0, "fix: rejected op must not inflate protocolRevenue");
        assertEq(result.userBurned, 0, "fix: rejected op must not charge the user");
        assertEq(result.afterState.userLocked, 0, "fix: rejected op leaves no escrow behind (L-1)");

        console.log("C-04 FIX VERIFIED: low postOpGasLimit op rejected, operator protected");
    }

    /// @notice Positive control for the floor itself: exactly one gas unit below MIN_POST_OP_GAS is
    ///         rejected, so the floor test below cannot pass because the check is dead.
    function test_fix_oneBelowFloorRejected() public {
        ScenarioResult memory result = _runScenario(user, ACCOUNT_OWNER_PK, 0, MIN_POST_OP_GAS - 1);
        assertTrue(result.handleOpsReverted, "MIN_POST_OP_GAS - 1 must be rejected at validation");
        assertEq(result.operatorLoss, 0, "rejected op must not debit the operator");
        assertEq(result.afterState.userLocked, 0, "rejected op leaves no escrow behind");
    }

    // A sufficient postOpGasLimit still settles normally (the fix doesn't break the happy path),
    // while the forced-OOG attempt is now blocked — together this is the C-04 fix verdict.
    function test_fix_verdict() public {
        ScenarioResult memory baseline = _runScenario(user, ACCOUNT_OWNER_PK, 0, NORMAL_POST_OP_GAS);
        assertFalse(baseline.handleOpsReverted, "baseline handleOps must not revert");
        assertFalse(baseline.postOpFailed, "baseline postOp must succeed");
        assertGt(baseline.operatorLoss, 0, "baseline charges operator for actual gas");
        assertGt(baseline.userBurned, 0, "baseline charges the user (escrow burn)");

        ScenarioResult memory oog = _runScenario(user, ACCOUNT_OWNER_PK, 1, 5_000);
        assertTrue(oog.handleOpsReverted, "C-04 fix: forced-OOG op must be rejected at validation");
        assertEq(oog.operatorLoss, 0, "C-04 fix: no operator aPNTs lost");
        assertEq(oog.protocolRevenueIncrease, 0, "C-04 fix: no protocolRevenue inflation");
        assertEq(oog.userBurned, 0, "C-04 fix: no user charge for a rejected op");

        console.log("C-04 FIX VERIFIED: forced-OOG rejected; baseline operator loss", baseline.operatorLoss);
    }

    // MIN_POST_OP_GAS must be enough that an op allocating EXACTLY the floor does not
    // fail in postOp on its WORST path (T-R14-09 / R10-H1). 5.5.0 worst BALANCE path:
    //   - minTxInterval > 0  → cold lastTimestamp write in postOp
    //   - first settlement   → cold _settledDebtOps / usedOpHashes writes, lock delete,
    //                          allowance refund writes and the burn, behind the SP->token
    //                          call's second 63/64 forwarding.
    // (The legacy pendingDebts fallback branch no longer exists: settlement has no try/catch.)
    function test_fix_minGasFloorIsSufficient() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        ScenarioResult memory result = _runScenario(user, ACCOUNT_OWNER_PK, 0, MIN_POST_OP_GAS);

        assertFalse(result.handleOpsReverted, "op at the MIN floor must pass validation and execute");
        assertFalse(result.postOpFailed, "postOp must NOT fail at MIN_POST_OP_GAS on the worst BALANCE path");
        assertGt(result.userBurned, 0, "worst path must be exercised (escrow actually settled, not skipped)");
        assertEq(result.afterState.userLocked, 0, "escrow cleared by settlement");
        (uint48 lastTs,) = paymaster.userOpState(operator, user);
        assertEq(uint256(lastTs), block.timestamp, "cold rate-limit write happened in postOp");
        console.log("C-04 FIX VERIFIED: postOp completes at MIN_POST_OP_GAS on the worst BALANCE path");
    }

    /// @notice Same floor gate on the CREDIT settlement path (settleCredit writes a fresh debt
    ///         slot), so neither settlement mode can be starved at exactly MIN_POST_OP_GAS.
    function test_fix_minGasFloorIsSufficient_creditPath() public {
        _enableAutoCredit(poorUser, 1_000 ether);
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        ScenarioResult memory result = _runScenario(poorUser, POOR_OWNER_PK, 0, MIN_POST_OP_GAS);

        assertFalse(result.handleOpsReverted, "credit op at the MIN floor must pass validation and execute");
        assertFalse(result.postOpFailed, "postOp must NOT fail at MIN_POST_OP_GAS on the CREDIT path");
        assertGt(result.userDebtIncrease, 0, "credit path must be exercised (debt recorded by settleCredit)");
        assertEq(result.afterState.userReserved, 0, "credit reservation consumed by settlement");
        assertEq(result.userBurned, 0, "credit path burns nothing");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _enableAutoCredit(address who, uint256 tier) internal {
        registry.setCreditLimit(who, tier);
        vm.prank(owner); // communityOwner
        IxPNTsV2Admin(address(xpnts)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(xpnts)).executeCreditPolicy();
        paymaster.updatePrice(); // refresh the cache after the 48 h warp
        vm.prank(who);
        IxPNTsV2Admin(address(xpnts)).requestCredit(tier);
    }

    function _runScenario(address sender, uint256 pk, uint256 nonce, uint256 postOpGasLimit)
        internal
        returns (ScenarioResult memory result)
    {
        PackedUserOperation memory op = _buildUserOp(sender, pk, nonce, postOpGasLimit);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        result.postOpGasLimit = postOpGasLimit;
        result.opHash = entryPoint.getUserOpHash(op);
        result.beforeState = _snapshot(sender);

        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) {
            result.handleOpsReverted = false;
        } catch Error(string memory reason) {
            result.handleOpsReverted = true;
            console.log("handleOps reverted", reason);
        } catch (bytes memory reason) {
            result.handleOpsReverted = true;
            console.logBytes(reason);
        }

        result.afterState = _snapshot(sender);
        result.postOpFailed = _sawPostOpRevertReason();
        result.operatorLoss = _loss(result.beforeState.operatorBalance, result.afterState.operatorBalance);
        result.protocolRevenueIncrease = _increase(result.beforeState.protocolRevenue, result.afterState.protocolRevenue);
        result.userDebtIncrease = _increase(result.beforeState.userDebt, result.afterState.userDebt);
        result.userBurned = _loss(result.beforeState.userBalance, result.afterState.userBalance);
        result.spDepositLoss = _loss(result.beforeState.spDeposit, result.afterState.spDeposit);
    }

    function _buildUserOp(address sender, uint256 pk, uint256 nonce, uint256 postOpGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = nonce;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(ACCOUNT_VERIFICATION_GAS), uint128(CALL_GAS_LIMIT)));
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32(abi.encodePacked(uint128(1), uint128(1)));
        op.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster),
            uint128(PM_VERIFICATION_GAS),
            uint128(postOpGasLimit),
            operator,
            type(uint256).max,
            address(xpnts),
            0
        );

        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(userOpHash));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _snapshot(address who) internal view returns (Snapshot memory snap) {
        (uint128 balance,,,,,,,,) = paymaster.operators(operator);
        snap.operatorBalance = balance;
        snap.protocolRevenue = paymaster.protocolRevenue();
        snap.userDebt = xpnts.debts(who);
        snap.userBalance = xpnts.balanceOf(who);
        snap.userLocked = xpnts.lockedOf(who);
        snap.userReserved = xpnts.creditReservedOf(who);
        snap.spDeposit = entryPoint.balanceOf(address(paymaster));
    }

    function _sawPostOpRevertReason() internal returns (bool) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == POST_OP_REVERT_REASON_TOPIC) {
                return true;
            }
        }
        return false;
    }

    function _loss(uint256 beforeValue, uint256 afterValue) internal pure returns (uint256) {
        return beforeValue > afterValue ? beforeValue - afterValue : 0;
    }

    function _increase(uint256 beforeValue, uint256 afterValue) internal pure returns (uint256) {
        return afterValue > beforeValue ? afterValue - beforeValue : 0;
    }
}
