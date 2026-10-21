// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccount.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { V55Registry, V55PriceFeed, V55APNTs } from "../helpers/V55TestFixtures.sol";
import { V55FuzzTarget } from "../helpers/V55FuzzFixtures.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

/// @dev Minimal 5.4.2-era xPNTs token: exactly the calls 5.4.2's validate / postOp make
///      (IxPNTsToken: exchangeRate, getDebt, burnFromWithOpHash, recordDebtWithOpHash, recordDebt). Rate 1:1.
contract V542Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public debt;
    uint256 public totalSupply;
    uint256 public burnCalls;

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address u) external view returns (uint256) { return debt[u]; }
    function burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32) external {
        require(balanceOf[from] >= amountAPNTs, "balance");
        balanceOf[from] -= amountAPNTs;
        totalSupply -= amountAPNTs;
        burnCalls++;
    }
    function recordDebtWithOpHash(address u, uint256 a, bytes32) external { debt[u] += a; }
    function recordDebt(address u, uint256 a) external { debt[u] += a; }
}

contract V542Factory {
    address public token;
    function setToken(address t) external { token = t; }
    function getTokenAddress(address) external view returns (address) { return token; }
}

/**
 * @title SuperPaymasterV542ToRc2MidBundleTest — DSR CC-124 e96d0111: 5.4.2 → rc.2 FORWARD same-bundle
 * @notice The live Sepolia proxy runs SuperPaymaster-5.4.2 (impl 0xe25f88db…), so 5.4.2 is the "previous
 *         release" for the A3b upgrade. This suite deploys 5.4.2 and rc.2 from creation fixtures built from
 *         tags v5.4.2 and v5.5.0-rc.2 (provenance: contracts/test/fixtures/sp-5.5.0-rc1-rc2.PROVENANCE.md),
 *         puts victim ops through 5.4.2's validation and lets an owner op in the SAME bundle upgrade the
 *         proxy to rc.2 before the victims' postOp runs.
 *
 *         What the sources say happens (and what is asserted):
 *           - 5.4.2 validation debits the operator optimistically (aPNTsBalance -= a0, protocolRevenue += a0)
 *             and returns a 160-byte context abi.encode(token, user, a0, opHash, operator).
 *           - rc.2 postOp rejects any context length other than 352 / 384: `revert InvalidContextLength()`.
 *           - EntryPoint v0.7 wraps that as PostOpReverted(bytes), reverts innerHandleOp (the victim's own
 *             execution is rolled back), emits PostOpRevertReason, and charges the paymaster's EntryPoint
 *             deposit for the gas without calling postOp again (mode postOpReverted).
 *           => FAILURE MODE: each in-flight 5.4.2 op is lost. The user gets nothing done and is not charged.
 *              SP's ETH deposit pays the gas. The operator's validation debit (a0) is NEVER refunded; it stays
 *              in protocolRevenue.
 *         This is NOT a pass. The spec avoids the window operationally (03 §10.7b C2 last bullet: the
 *         5.4.2 → 5.5.0 upgrade is a separate EOA transaction, so no bundle can straddle it; runbook step
 *         3 pauses the operators and drains the mempool first). Here the owner is made a 4337 account only
 *         to construct the window. There is deliberately NO rollback direction (spec P2: 5.5.0 is not
 *         rolled back to 5.4.2).
 *         Control: the same bundle without the upgrade settles normally under 5.4.2.
 */
contract SuperPaymasterV542ToRc2MidBundleTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");

    string constant V542_FIXTURE = "contracts/test/fixtures/superpaymaster-5.4.2-78364b12-impl.creation.hex";
    string constant RC2_FIXTURE = "contracts/test/fixtures/superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex";
    bytes32 constant V542_CREATION_KECCAK = 0x1650ed800e099aeafe4353be14e7b4a4074c0cefdc2f14cdc0a0e8dc75f88033;
    bytes32 constant RC2_CREATION_KECCAK = 0x4edff578ddfb3875aa057f690fb68b85df24332aa0023a115aadad07107a0e4e; // attestation
    uint256 constant V542_RUNTIME = 23_569;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp; // typed with the rc.2 ABI; every selector used here is identical in 5.4.2
    address v542;
    address rc2;
    V542Token token;
    V55Registry registry;
    V55FuzzTarget target;
    address deployer = address(0x0A11);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    uint256[3] pk = [uint256(0xC001), 0xC002, 0xC003]; // owner account, victim 1, victim 2
    address[3] acct;

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();
        for (uint256 i; i < 3; i++) acct[i] = address(accountFactory.createAccount(vm.addr(pk[i]), 0));
    }

    function _deployFixture(string memory path, bytes32 expectedKeccak, address feed) internal returns (address impl) {
        bytes memory creation = vm.parseBytes(vm.readFile(path));
        assertEq(keccak256(creation), expectedKeccak, string.concat("fixture identity: ", path));
        bytes memory init = abi.encodePacked(creation, abi.encode(EP, address(registry), feed));
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "fixture impl deploy");
    }

    function _boot() internal {
        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        v542 = _deployFixture(V542_FIXTURE, V542_CREATION_KECCAK, feed);
        rc2 = _deployFixture(RC2_FIXTURE, RC2_CREATION_KECCAK, feed);
        assertEq(v542.code.length, V542_RUNTIME, "5.4.2 runtime size");
        assertEq(keccak256(bytes(SuperPaymaster(payable(v542)).version())), keccak256("SuperPaymaster-5.4.2"), "5.4.2 version()");
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            v542, abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 3600))
        ))));
        assertTrue(_implIs(v542), "precondition: proxy starts on 5.4.2");
        token = new V542Token();
        V542Factory factory = new V542Factory();
        factory.setToken(address(token));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 5 ether}();
        apnts.mint(operator, 1_000_000 ether);
        sp.transferOwnership(acct[0]); // 5.4.2: single-step Ownable
        vm.stopPrank();
        assertEq(sp.owner(), acct[0], "owner account owns SP (constructs the in-bundle window)");

        vm.startPrank(operator);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), deployer);
        sp.deposit(100_000 ether);
        vm.stopPrank();
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(address(registry));
            sp.updateSBTStatus(acct[i], true);
            registry.setCreditLimit(acct[i], 1e30); // 5.4.2 C-01 credit gate
            token.mint(acct[i], 10_000 ether);
        }
        vm.deal(address(this), 1 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]);
    }

    function _implIs(address impl) internal view returns (bool) {
        return address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))) == impl;
    }

    function _op(uint256 i, bytes memory callData, bool sponsored) internal view returns (PackedUserOperation memory op) {
        op.sender = acct[i];
        op.nonce = 1 << 64;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        if (sponsored) {
            // 5.4.2 layout: [paymaster 20][verif 16][postOp 16][operator 20][maxRate 32]
            op.paymasterAndData = abi.encodePacked(address(sp), uint128(700_000), uint128(200_000), operator, type(uint256).max);
        }
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk[i], MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _victimOp(uint256 i, string memory tag) internal view returns (PackedUserOperation memory) {
        return _op(i, abi.encodeCall(SimpleAccount.execute, (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (keccak256(bytes(tag)))))), true);
    }

    function _ownerOp(bytes memory call) internal view returns (PackedUserOperation memory) {
        return _op(0, abi.encodeCall(SimpleAccount.execute, (address(sp), 0, call)), false);
    }

    /// @dev 5.4.2 context + a0 for a victim op at the EntryPoint's maxCost (state rolled back).
    function _probe(uint256 i, string memory tag) internal returns (uint256 ctxLen, uint256 a0) {
        PackedUserOperation memory op = _victimOp(i, tag);
        uint256 maxCost = uint256(400_000 + 300_000 + 700_000 + 200_000 + 50_000) * 1 gwei;
        bytes32 oh = entryPoint.getUserOpHash(op); // before the prank: it is itself a call
        uint256 s = vm.snapshot();
        vm.prank(EP);
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, oh, maxCost);
        vm.revertTo(s);
        assertEq(vd & 1, 0, "probe: validation passes (sigFail bit clear)");
        ctxLen = ctx.length;
        assembly { a0 := mload(add(ctx, 96)) } // word 2
    }

    struct Res {
        uint256 nPostRevert;
        uint256 nInvalidLen;
        uint256 nUserOpEvents;
        bool[3] success;
        uint256[3] G;
        uint256[3] charge;
        uint256 nTS;
    }

    function _run(PackedUserOperation[] memory ops) internal returns (Res memory r) {
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory wantInner = abi.encodeWithSelector(SuperPaymasterStorage.InvalidContextLength.selector);
        for (uint256 i; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (logs[i].emitter == EP && t0 == T_POSTOP_REVERT) {
                r.nPostRevert++;
                (, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                // EntryPoint v0.7: PostOpReverted(bytes returnData)
                if (reason.length >= 4 && bytes4(reason) == IEntryPoint.PostOpReverted.selector) {
                    bytes memory payload = new bytes(reason.length - 4);
                    for (uint256 b; b < payload.length; b++) payload[b] = reason[b + 4];
                    bytes memory decoded = abi.decode(payload, (bytes));
                    if (keccak256(decoded) == keccak256(wantInner)) r.nInvalidLen++;
                }
            } else if (logs[i].emitter == EP && t0 == T_USEROP) {
                r.nUserOpEvents++;
                (, bool success, uint256 cost, ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                for (uint256 k; k < 3; k++) {
                    if (logs[i].topics[2] == bytes32(uint256(uint160(acct[k])))) { r.success[k] = success; r.G[k] = cost; }
                }
            } else if (logs[i].emitter == address(sp) && t0 == T_TX_SPONSORED) {
                address u = address(uint160(uint256(logs[i].topics[2])));
                for (uint256 k; k < 3; k++) if (u == acct[k]) (, r.charge[k]) = abi.decode(logs[i].data, (uint256, uint256));
                r.nTS++;
            }
        }
    }

    struct Snap {
        uint128 opBal;
        uint256 rev;
        uint256 supply;
        uint256 epDeposit;
    }

    function _snap() internal view returns (Snap memory s) {
        (s.opBal, , , , , , , , ) = sp.operators(operator);
        s.rev = sp.protocolRevenue();
        s.supply = token.totalSupply();
        s.epDeposit = entryPoint.balanceOf(address(sp));
    }

    // =====================================================================

    /// @dev FORWARD 5.4.2 → rc.2 inside one bundle: the asserted outcome is the FAILURE MODE described above.
    function test_v542_to_rc2_forward_mid_bundle_inflightOpsFail() public {
        _boot();
        (uint256 ctxLen, uint256 a0) = _probe(1, "v1");
        assertEq(ctxLen, 160, "5.4.2 emits a 160-byte context (5 words), not 352/384");
        assertGt(a0, 0, "positive control: a0 > 0");
        Snap memory s0 = _snap();

        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", rc2, bytes("")));
        ops[1] = _victimOp(1, "v1"); // validated by 5.4.2
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        Snap memory s1 = _snap();

        assertTrue(_implIs(rc2), "precondition: upgraded to rc.2 mid-bundle");
        assertEq(r.nUserOpEvents, 3, "3 UserOperationEvents");
        assertTrue(r.success[0], "the upgrade op itself succeeded");
        // the failure mode, asserted exactly
        assertEq(r.nPostRevert, 2, "5.4.2->rc.2: both victims' postOp reverts (PostOpRevertReason x2)");
        assertEq(r.nInvalidLen, 2, "5.4.2->rc.2: revert reason is PostOpReverted(InvalidContextLength())");
        assertFalse(r.success[1], "victim 1 UserOperationEvent.success == false");
        assertFalse(r.success[2], "victim 2 UserOperationEvent.success == false");
        assertEq(target.hits(keccak256("v1")), 0, "victim 1 execution rolled back");
        assertEq(target.hits(keccak256("v2")), 0, "victim 2 execution rolled back");
        assertEq(r.nTS, 0, "no TransactionSponsored (no settlement ran)");
        // money: operator debited a0 per op at validation, never refunded; it all sits in protocolRevenue
        assertEq(uint256(s0.opBal) - s1.opBal, 2 * a0, "operator lost the full validation debit a0 per op (no refund)");
        assertEq(s1.rev - s0.rev, 2 * a0, "protocolRevenue kept the full a0 per op");
        assertEq(s0.supply, s1.supply, "user xPNTs not burned");
        assertEq(token.debt(acct[1]) + token.debt(acct[2]), 0, "no user debt recorded");
        assertEq(s0.epDeposit - s1.epDeposit, r.G[1] + r.G[2], "SP's EntryPoint deposit paid the victims' gas");
        assertGt(r.G[1], 0, "positive control: gas was charged");
    }

    /// @dev CONTROL: same bundle, the owner op does NOT upgrade (calls version()); 5.4.2 settles normally.
    function test_control_v542_stays_settlesNormally() public {
        _boot();
        (, uint256 a0) = _probe(1, "v1");
        Snap memory s0 = _snap();
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(abi.encodeWithSignature("version()"));
        ops[1] = _victimOp(1, "v1");
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        Snap memory s1 = _snap();

        assertTrue(_implIs(v542), "precondition: still 5.4.2");
        assertEq(r.nPostRevert, 0, "control: no postOp revert");
        assertTrue(r.success[1] && r.success[2], "control: both victims succeeded");
        assertEq(target.hits(keccak256("v1")), 1, "control: victim 1 execution kept");
        assertEq(target.hits(keccak256("v2")), 1, "control: victim 2 execution kept");
        assertEq(r.nTS, 2, "control: TransactionSponsored x2");
        uint256 sumC = r.charge[1] + r.charge[2];
        assertGt(sumC, 0, "positive control: charged");
        assertLt(sumC, 2 * a0, "control: refund happened (charge < a0)");
        assertEq(uint256(s0.opBal) - s1.opBal, sumC, "control: operator paid exactly the charges");
        assertEq(s1.rev - s0.rev, sumC, "control: revenue == sum(charge)");
        assertEq(s0.supply - s1.supply, sumC, "control: user xPNTs burned == charges (rate 1:1)");
    }
}
