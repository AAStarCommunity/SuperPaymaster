// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/xPNTsToken.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

contract C04OOGRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function getCreditLimit(address) external pure returns (uint256) {
        return 1_000_000 ether;
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

contract PoC_C04_ForcedPostOpOOG_Test is Test {
    using Clones for address;

    EntryPoint public entryPoint;
    SimpleAccountFactory public accountFactory;
    SuperPaymaster public paymaster;
    C04OOGRegistry public registry;
    C04OOGAPNTs public apnts;
    xPNTsToken public xpnts;
    MockXPNTsFactory public mockFactory;

    uint256 internal constant ACCOUNT_OWNER_PK = 0xC0400A;
    uint256 internal constant NORMAL_POST_OP_GAS = 1_000_000;
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

    bytes32 public constant C04_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant C04_ROLE_COMMUNITY = keccak256("COMMUNITY");

    bytes32 internal constant POST_OP_REVERT_REASON_TOPIC =
        keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");

    struct Snapshot {
        uint128 operatorBalance;
        uint256 protocolRevenue;
        uint256 userDebt;
        uint256 spDeposit;
    }

    struct ScenarioResult {
        bool handleOpsReverted;
        bool postOpFailed;
        uint256 postOpGasLimit;
        uint256 operatorLoss;
        uint256 protocolRevenueIncrease;
        uint256 userDebtIncrease;
        uint256 spDepositLoss;
        Snapshot beforeState;
        Snapshot afterState;
    }

    function setUp() public {
        vm.deal(owner, 10 ether);

        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        user = address(accountFactory.createAccount(accountOwner, 0));

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

        address xImpl = address(new xPNTsToken());
        xpnts = xPNTsToken(xImpl.clone());
        xpnts.initialize("Community Points", "xPNT", owner, "Community", "community.eth", 1e18);
        xpnts.setSuperPaymasterAddress(address(paymaster));

        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();
        paymaster.deposit{value: 1 ether}();

        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.deposit(100_000 ether);
        vm.stopPrank();
    }

    function test_baseline_normalPostOp() public {
        ScenarioResult memory result = _runScenario(0, NORMAL_POST_OP_GAS);

        assertFalse(result.handleOpsReverted, "baseline handleOps must not revert");
        assertFalse(result.postOpFailed, "baseline postOp unexpectedly failed");
        assertGt(result.operatorLoss, 0, "baseline should charge operator for actual gas");
        assertGt(result.protocolRevenueIncrease, 0, "baseline should leave final protocol revenue");
        assertGt(result.userDebtIncrease, 0, "baseline should record user debt");
        assertGt(result.spDepositLoss, 0, "baseline should spend SP EntryPoint deposit");

        console.log("baseline operator aPNTs loss", result.operatorLoss);
        console.log("baseline protocolRevenue increase", result.protocolRevenueIncrease);
        console.log("baseline user debt increase", result.userDebtIncrease);
        console.log("baseline SP ETH deposit loss", result.spDepositLoss);
    }

    // REGRESSION GUARD (post-fix): an op whose paymasterPostOpGasLimit is below
    // MIN_POST_OP_GAS must be rejected at validation, so it never executes and the
    // operator is never debited. Pre-fix this same op forced postOp OOG and drained
    // the operator (C-04). This test PASSES on fixed code, FAILS on vulnerable code.
    function test_fix_lowPostOpGasRejected() public {
        ScenarioResult memory result = _runScenario(0, 5_000);

        assertTrue(result.handleOpsReverted, "fix: low paymasterPostOpGasLimit must be rejected at validation");
        assertEq(result.operatorLoss, 0, "fix: rejected op must not debit the operator");
        assertEq(result.protocolRevenueIncrease, 0, "fix: rejected op must not inflate protocolRevenue");

        console.log("C-04 FIX VERIFIED: low postOpGasLimit op rejected, operator protected");
    }

    // A sufficient postOpGasLimit still settles normally (the fix doesn't break the happy path),
    // while the forced-OOG attempt is now blocked — together this is the C-04 fix verdict.
    function test_fix_verdict() public {
        ScenarioResult memory baseline = _runScenario(0, NORMAL_POST_OP_GAS);
        assertFalse(baseline.handleOpsReverted, "baseline handleOps must not revert");
        assertFalse(baseline.postOpFailed, "baseline postOp must succeed");
        assertGt(baseline.operatorLoss, 0, "baseline charges operator for actual gas");
        assertGt(baseline.userDebtIncrease, 0, "baseline records user debt");

        ScenarioResult memory oog = _runScenario(1, 5_000);
        assertTrue(oog.handleOpsReverted, "C-04 fix: forced-OOG op must be rejected at validation");
        assertEq(oog.operatorLoss, 0, "C-04 fix: no operator aPNTs lost");
        assertEq(oog.protocolRevenueIncrease, 0, "C-04 fix: no protocolRevenue inflation");

        console.log("C-04 FIX VERIFIED: forced-OOG rejected; baseline operator loss", baseline.operatorLoss);
    }

    // MIN_POST_OP_GAS must be high enough that an op allocating EXACTLY the floor does
    // not OOG in postOp — otherwise the floor is too low and C-04 is only half-fixed.
    function test_fix_minGasFloorIsSufficient() public {
        ScenarioResult memory result = _runScenario(0, 200_000); // == MIN_POST_OP_GAS
        assertFalse(result.handleOpsReverted, "op at the MIN floor must pass validation and execute");
        assertFalse(result.postOpFailed, "postOp must NOT OOG when given exactly MIN_POST_OP_GAS");
        console.log("C-04 FIX VERIFIED: postOp completes at the MIN_POST_OP_GAS floor");
    }

    function _runScenario(uint256 nonce, uint256 postOpGasLimit) internal returns (ScenarioResult memory result) {
        PackedUserOperation memory op = _buildUserOp(nonce, postOpGasLimit);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        result.postOpGasLimit = postOpGasLimit;
        result.beforeState = _snapshot();

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

        result.afterState = _snapshot();
        result.postOpFailed = _sawPostOpRevertReason();
        result.operatorLoss = _loss(result.beforeState.operatorBalance, result.afterState.operatorBalance);
        result.protocolRevenueIncrease = _increase(result.beforeState.protocolRevenue, result.afterState.protocolRevenue);
        result.userDebtIncrease = _increase(result.beforeState.userDebt, result.afterState.userDebt);
        result.spDepositLoss = _loss(result.beforeState.spDeposit, result.afterState.spDeposit);
    }

    function _buildUserOp(uint256 nonce, uint256 postOpGasLimit)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = user;
        op.nonce = nonce;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(ACCOUNT_VERIFICATION_GAS), uint128(CALL_GAS_LIMIT)));
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32(abi.encodePacked(uint128(1), uint128(1)));
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(PM_VERIFICATION_GAS),
            uint128(postOpGasLimit),
            operator,
            type(uint256).max
        );

        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            ACCOUNT_OWNER_PK,
            MessageHashUtils.toEthSignedMessageHash(userOpHash)
        );
        op.signature = abi.encodePacked(r, s, v);
    }

    function _snapshot() internal view returns (Snapshot memory snap) {
        (uint128 balance,,,,,,,,) = paymaster.operators(operator);
        snap.operatorBalance = balance;
        snap.protocolRevenue = paymaster.protocolRevenue();
        snap.userDebt = xpnts.getDebt(user);
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
