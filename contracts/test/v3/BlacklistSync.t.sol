// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/core/Registry.sol";
import "../../src/interfaces/v3/IRegistry.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/tokens/MySBT.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import "../../src/mocks/MockBLSAggregator.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {PostOpMode} from "singleton-paymaster/src/interfaces/PostOpMode.sol";

contract MockAggregator is AggregatorV3Interface {
    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "Mock"; }
    function version() external pure returns (uint256) { return 1; }
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
}

contract MockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function balanceOf(address) external view returns (uint256) { return 0; }
    function getDepositInfo(address) external view returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external {} 
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {} 
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function getUserOpHash(PackedUserOperation calldata) external view returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view returns (uint256) { return 0; }
    function incrementNonce(uint192) external {}
    function delegateAndRevert(address, bytes calldata) external {}
}

contract BlacklistSyncTest is Test {
    using Clones for address;
    Registry registry;
    SuperPaymaster paymaster;
    xPNTsToken apnts;
    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    MockEntryPoint entryPoint;
    MockAggregator priceFeed;
    MockBLSAggregator mockAggregator;
    MockXPNTsFactory mockFactory;
    /// @dev SP 5.5.0: the operator's community token must be an xPNTs v2 (balance-mode) token;
    ///      the 3.x `apnts` clone above only plays the aPNTs (operator deposit) role.
    xPNTsTokenV2 xpnts;

    address owner = address(1);
    address dvtNode = address(2); // Legacy: kept for now, no longer privileged for blacklist
    address operator = address(3);
    address maliciousUser = address(4);
    address treasury = address(5);

    /// @dev P0-3: caller must be the wired BLS aggregator.
    function _aggregator() internal view returns (address) { return address(mockAggregator); }

    /// @dev Build a non-empty proof matching the aggregator's expected ABI.
    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(0x7F), new bytes(256));
    }

    function setUp() public {
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(owner);

        // 1. Deploy Core Dependencies (Scheme B)
        gtoken = new GToken(1_000_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), owner, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), owner);
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));

        // 2. Deploy Paymaster Dependencies
        entryPoint = new MockEntryPoint();
        priceFeed = new MockAggregator();
        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("APNTS", "APNTS", owner, "Comm", "ens", 1e18);
        
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(entryPoint, IRegistry(address(registry)), address(priceFeed), owner, address(apnts), treasury, 3600);

        // 3. Connect Registry & Paymaster
        registry.setSuperPaymaster(address(paymaster));
        apnts.setSuperPaymasterAddress(address(paymaster));

        // 4. Wire a permissive mock BLS aggregator. P0-3 restricts the
        //    blacklist endpoint to msg.sender == blsAggregator, so we route
        //    every test call through this address.
        mockAggregator = new MockBLSAggregator();
        registry.setBLSAggregator(address(mockAggregator));

        // 5. Setup Roles (kept for backward-compat with other suites; no
        //    longer required for blacklist auth post-P0-3).
        registry.setReputationSource(dvtNode, true);

        // Deploy mock factory and wire it (owner context)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));

        // Register Operator (Community + Paymaster)
        gtoken.mint(operator, 10000 ether);
        vm.stopPrank();

        // SP 5.5.0: configureOperator only accepts BALANCE_MODE_VERSION()==1 tokens (xPNTs v2).
        // The test contract becomes the token FACTORY (can mint) and owns the protocol registry.
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xpnts));

        vm.startPrank(operator);
        gtoken.approve(address(staking), 10000 ether);
        Registry.CommunityRoleData memory commData = Registry.CommunityRoleData("OpComm", "op.eth", 100 ether);
        registry.registerRole(keccak256("COMMUNITY"), operator, abi.encode(commData));
        registry.registerRole(keccak256("PAYMASTER_SUPER"), operator, abi.encode(uint256(100 ether)));

        // Configure Operator
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.updatePrice();
        
        // Fund Operator
        vm.stopPrank();
        vm.prank(owner);
        apnts.mint(operator, 2000 ether);
        // 5.5.0 balance mode: the user pays from escrowed xPNTs v2 (a0 ~= 1,200 aPNTs for the
        // 0.01 ETH maxCost used below at rate 1:1), so the user needs an xPNTs balance.
        IxPNTsV2Admin(address(xpnts)).mint(maliciousUser, 2000 ether);
        
        vm.prank(operator);
        apnts.approve(address(paymaster), 2000 ether);
        vm.prank(operator);
        paymaster.depositFor(operator, 2000 ether);

        // --- 5. Sync SBT Status for Malicious User ---
        vm.prank(address(registry));
        paymaster.updateSBTStatus(maliciousUser, true);
    }

    function test_BlacklistFlow() public {
        // 1. Verify User NOT blocked initially
        (, bool blocked) = paymaster.userOpState(operator, maliciousUser);
        assertFalse(blocked, "Should not be blocked initially");

        // 1b. Positive control: the very same op validates while the user is NOT blocked, so the
        //     sigFail asserted in step 4 can only come from the blacklist (not from a malformed
        //     5.5.0 paymasterAndData, a missing xPNTs balance, or operator solvency).
        uint256 snap = vm.snapshot();
        vm.prank(address(entryPoint));
        (, uint256 vdOk) = paymaster.validatePaymasterUserOp(_createOp(maliciousUser), bytes32(0), 0.01 ether);
        assertEq(vdOk & uint256(type(uint160).max), 0, "control: unblocked user validates");
        assertTrue(vm.revertTo(snap), "snapshot restored");
        assertEq(xpnts.lockedOf(maliciousUser), 0, "control left no escrow behind");

        // 2. DVT triggers blacklist via Registry
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        
        vm.prank(_aggregator());
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());

        // 3. Verify Blocked in Paymaster
        // 3. Verify Blocked in Paymaster
        (, blocked) = paymaster.userOpState(operator, maliciousUser);
        assertTrue(blocked, "Should be blocked after sync");

        // 4. Try to validate UserOp (Should Fail)
        PackedUserOperation memory op = _createOp(maliciousUser);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        
        // ValidationData != 0 means failure (SIG_VALIDATION_FAILED)
        // Actually BasePaymaster packs it. 
        // 0 = Success. 
        // 1 = SIG_VALIDATION_FAILED (Signature mismatch, but here we return packed data)
        // _packValidationData(true, ...) returns a large number (authorizer=1 => failure)
        
        // Let's decode validationData
        // validationData: [authorizer(20 bytes)][validUntil(6 bytes)][validAfter(6 bytes)]
        // If authorizer != 0, it failed.
        uint256 authorizer = validationData & uint256(type(uint160).max);
        assertEq(authorizer, 1, "Should fail validation");
    }

    function test_UnblockFlow() public {
        // 5.5.0: the legacy H-1 validation-time credit ceiling (`_creditExceeded`) is removed.
        // A user holding enough xPNTs is sponsored in BALANCE mode (escrow via tryLockForGas)
        // and the Registry credit tier is never consulted, so the old `setCreditTier` top-up
        // is no longer part of the precondition. The validation at the end is asserted to go
        // through the escrow path explicitly.

        // Block first
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        
        vm.prank(_aggregator());
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());


        (, bool blocked1) = paymaster.userOpState(operator, maliciousUser);
        assertTrue(blocked1);

        // Unblock
        statuses[0] = false;
        vm.prank(_aggregator());
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
        
        
        (, bool blocked2) = paymaster.userOpState(operator, maliciousUser);
        assertFalse(blocked2);
        
        // Validation should pass now
        PackedUserOperation memory op = _createOp(maliciousUser);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        assertEq(uint160(validationData), 0, "Should pass validation");
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(c.mode, 1, "BALANCE mode (escrow), not credit");
        assertEq(xpnts.lockedOf(maliciousUser), c.a0, "user xPNTs escrowed at validation (rate 1:1)");
        assertEq(xpnts.creditReservedOf(maliciousUser), 0, "no credit reservation");
    }

    /// @notice T-R14-03 (spec 03 §10.6): a stale blacklist -- `isBlocked` written by the Registry
    ///         AFTER validation and BEFORE postOp. The already-admitted op still settles (I8/I9:
    ///         no unbacked sponsorship), while a new op from the now-blocked user is rejected.
    function test_TR1403_StaleBlacklist_AdmittedOpStillSettles() public {
        bytes32 h = keccak256("tr1403");
        uint256 userBefore = xpnts.balanceOf(maliciousUser);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(_createOp(maliciousUser), h, 0.01 ether);
        assertEq(uint160(vd), 0, "admitted before the blacklist lands");
        assertGt(xpnts.lockedOf(maliciousUser), 0);

        // Blacklist lands between validation and postOp.
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        vm.prank(_aggregator());
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
        (, bool blocked) = paymaster.userOpState(operator, maliciousUser);
        assertTrue(blocked, "blacklist landed mid-flight");

        // The admitted op settles normally (no try/catch around settlement, B-1).
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opSucceeded)), ctx, 1e14, 1 gwei);
        assertLt(xpnts.balanceOf(maliciousUser), userBefore, "admitted op was paid for");
        assertEq(xpnts.lockedOf(maliciousUser), 0, "escrow consumed");
        (address f, uint256 a0) = paymaster.inflightOf(h);
        assertEq(f, address(0), "in-flight cleared");
        assertEq(a0, 0);

        // A new op from the blocked user is rejected.
        vm.prank(address(entryPoint));
        (, uint256 vd2) = paymaster.validatePaymasterUserOp(_createOp(maliciousUser), keccak256("tr1403-2"), 0.01 ether);
        assertEq(vd2 & uint256(type(uint160).max), 1, "new op after blacklist rejected");
    }

    function test_Revert_UnauthorizedSource() public {
        // Anonymous-ish caller (still happens to be a reputation source under
        // pre-P0-3 code; under the new caller gate ANY non-aggregator address
        // must revert).
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        // Try the legacy reputation-source caller — must now revert because
        // P0-3 narrowed the gate to `msg.sender == blsAggregator` only.
        vm.prank(dvtNode);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());

        // And an arbitrary attacker also reverts.
        address hacker = address(0xdead);
        vm.prank(hacker);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
    }

    function _createOp(address sender) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(100000))),
            preVerificationGas: 21000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei))),
            // SP 5.5.0 layout: [pm 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
            paymasterAndData: V2TokenDeployer.pmd(
                address(paymaster), uint128(100000), uint128(200000), operator, type(uint256).max, address(xpnts), 0
            ),
            signature: ""
        });
    }
}
