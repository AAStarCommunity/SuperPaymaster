// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";

import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";

contract xPNTsTokenV2Test is Test {
    using stdStorage for StdStorage;
    AOAProtocolRegistry reg;
    MockRegistryV2 registry;
    GlobalTierSource tier;
    xPNTsTokenV2Ext ext;
    xPNTsTokenV2 impl;
    xPNTsFactoryV2 factory;
    xPNTsTokenV2 t;

    address governance = address(0xA11CE);
    address community = address(0xC0);
    address sp = address(0x5B);
    address sp2 = address(0x5B2);
    address user = address(0xB0B);
    uint256 userPk = 0xB0B0;
    address signer;
    DummySpender spender;

    bytes32 constant OP1 = keccak256("op1");
    bytes32 constant OP2 = keccak256("op2");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        reg = new AOAProtocolRegistry(governance);
        registry = new MockRegistryV2();
        tier = new GlobalTierSource(address(registry));
        ext = new xPNTsTokenV2Ext(address(reg));
        impl = new xPNTsTokenV2(address(reg), address(ext));
        spender = new DummySpender();

        vm.startPrank(governance);
        reg.bootstrapApprove(reg.KIND_SP(), reg.spKey(sp));
        reg.bootstrapApprove(reg.KIND_SP(), reg.spKey(sp2));
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(tier).codehash);
        reg.bootstrapApprove(reg.KIND_SPENDER(), address(spender).codehash);
        reg.seal();
        vm.stopPrank();

        factory = new xPNTsFactoryV2(sp, address(registry), address(impl), address(tier));
        vm.prank(community);
        t = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "comm.eth", 1 ether, address(0)));

        signer = vm.addr(userPk);
        vm.prank(community);
        IExt(address(t)).mint(user, 10_000 ether);
    }

    function _ext() internal view returns (IExt) { return IExt(address(t)); }

    // ------------------------------------------------------------------
    // Construction, A-9, S-0
    // ------------------------------------------------------------------

    function test_version_and_genesis() public view {
        assertEq(t.version(), "XPNTs-4.0.3");
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp);
        assertTrue(t.historicalSP(sp), "S-0 marks genesis SP historical");
        assertFalse(t.autoApprovedSpenders(sp), "A-3: SP is never a spender");
        assertFalse(t.autoApprovedSpenders(address(factory)), "A-9: factory is never a spender");
        assertEq(t.community(), community);
        assertEq(t.creditTierSource(), address(tier), "R4-H5 default tier source");
    }

    function _domain(string memory domainName, uint256 chainId, address verifyingContract)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(domainName)),
            keccak256("1"),
            chainId,
            verifyingContract
        ));
    }

    function test_C2_02_domain_uses_clone_name_chain_and_address() public view {
        (bytes1 fields, string memory domainName, string memory domainVersion, uint256 chainId,
            address verifyingContract, bytes32 salt, uint256[] memory extensions) = t.eip712Domain();
        assertEq(uint8(fields), 15);
        assertEq(domainName, t.name());
        assertEq(domainVersion, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(t));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(t.DOMAIN_SEPARATOR(), _domain(t.name(), block.chainid, address(t)));
    }

    /// @dev Discriminating C2-02 evidence: the pre-fix clone accepts the empty-name signature.
    function test_C2_02_permit_uses_named_domain_and_rejects_empty_name() public {
        uint256 value = 7 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signer, address(spender), value, 0, deadline));
        bytes32 emptyDigest = MessageHashUtils.toTypedDataHash(_domain("", block.chainid, address(t)), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, emptyDigest);
        vm.expectRevert();
        t.permit(signer, address(spender), value, deadline, v, r, s);
        assertEq(t.nonces(signer), 0, "failed permit keeps nonce");

        bytes32 namedDigest = MessageHashUtils.toTypedDataHash(t.DOMAIN_SEPARATOR(), structHash);
        (v, r, s) = vm.sign(userPk, namedDigest);
        t.permit(signer, address(spender), value, deadline, v, r, s);
        assertEq(t.allowance(signer, address(spender)), value);
        assertEq(t.nonces(signer), 1);
    }

    /// @dev Regression control, NOT C2-02 evidence: this test also passes on the pre-fix code (name ""),
    ///      because OZ already bound the domain to the clone address and chain id before C2-02.
    function test_regression_permit_rejects_cross_chain_and_cross_clone_replay() public {
        uint256 value = 7 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signer, address(spender), value, 0, deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(t.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        (, , , uint256 originalChainId, , , ) = t.eip712Domain();
        vm.chainId(originalChainId + 1);
        vm.expectRevert();
        t.permit(signer, address(spender), value, deadline, v, r, s);
        vm.chainId(originalChainId);

        address community2 = address(0xC2);
        vm.prank(community2);
        xPNTsTokenV2 t2 = xPNTsTokenV2(
            factory.deployxPNTsToken("Comm", "xC2", "Comm2", "comm2.eth", 1 ether, address(0))
        );
        vm.expectRevert();
        t2.permit(signer, address(spender), value, deadline, v, r, s);
        t.permit(signer, address(spender), value, deadline, v, r, s);
    }

    function test_C2_02_action_digest_uses_same_named_domain() public view {
        bytes memory params = abi.encode(sp);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            _ext().ACTION_TYPEHASH(), signer, uint8(1), keccak256(params), uint256(0), deadline
        ));
        assertEq(
            _ext().actionDigest(signer, 1, params, 0, deadline),
            MessageHashUtils.toTypedDataHash(_domain(t.name(), block.chainid, address(t)), structHash)
        );
    }

    function test_I_01_issuance_cap_exact_boundary_and_burn_reopens_room() public {
        uint256 cap = t.totalSupply() + 10 ether;
        vm.prank(community);
        _ext().setIssuanceCap(cap);
        vm.prank(community);
        _ext().mint(user, 10 ether);
        assertEq(t.totalSupply(), cap);
        vm.mockCall(
            sp,
            abi.encodeWithSelector(bytes4(keccak256("operators(address)")), community),
            abi.encode(uint128(0), false, false, address(t), uint32(0), uint48(0), address(0), uint256(0), uint256(0))
        );
        assertFalse(_ext().isOverIssued());

        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(
            xPNTsV2Base.IssuanceCapExceeded.selector, cap, uint256(1), cap
        ));
        _ext().mint(user, 1);
        vm.prank(user);
        t.burn(1);
        vm.prank(community);
        _ext().mint(user, 1);
        assertEq(t.totalSupply(), cap);
    }

    function test_I_01_zero_cap_is_unlimited_and_lowered_cap_blocks_mint() public {
        uint256 supply = t.totalSupply();
        vm.prank(community);
        _ext().setIssuanceCap(supply - 1);
        assertTrue(_ext().isOverIssued());
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(
            xPNTsV2Base.IssuanceCapExceeded.selector, supply, uint256(1), supply - 1
        ));
        _ext().mint(user, 1);

        vm.prank(community);
        _ext().setIssuanceCap(0);
        vm.prank(community);
        _ext().mint(user, 1);
        assertEq(t.totalSupply(), supply + 1);
    }

    function test_I_01_debt_repayment_enforces_cap_on_net_issuance() public {
        uint256 supply = t.totalSupply();
        stdstore.target(address(t)).sig("debts(address)").with_key(user).checked_write(5 ether);
        vm.prank(community);
        _ext().setIssuanceCap(supply + 5 ether);
        vm.prank(community);
        _ext().mint(user, 10 ether);
        assertEq(t.debts(user), 0);
        assertEq(t.totalSupply(), supply + 5 ether);

        stdstore.target(address(t)).sig("debts(address)").with_key(user).checked_write(1 ether);
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(
            xPNTsV2Base.IssuanceCapExceeded.selector, supply + 5 ether, uint256(1 ether), supply + 5 ether
        ));
        _ext().mint(user, 2 ether);
    }

    function test_I_01_debt_repayment_non_unit_rate_checks_exact_net_issuance() public {
        uint256 rate = 1.5 ether;
        vm.prank(address(0xC2));
        xPNTsTokenV2 token = xPNTsTokenV2(
            factory.deployxPNTsToken("Rated", "xR", "Rated", "rated.eth", rate, address(0))
        );
        IExt tokenExt = IExt(address(token));
        vm.prank(address(0xC2));
        tokenExt.mint(user, 100);
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(user);
        uint256 value = 10;
        uint256 repayAPNTs = 3;
        uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18;
        uint256 net = value - repayXPNTs;
        assertEq(repayXPNTs, 5, "fractional repayment rounds up");
        assertEq(net, 5);
        stdstore.target(address(token)).sig("debts(address)").with_key(user).checked_write(repayAPNTs);

        vm.prank(address(0xC2));
        tokenExt.setIssuanceCap(supply + net - 1);
        vm.expectRevert(abi.encodeWithSelector(
            xPNTsV2Base.IssuanceCapExceeded.selector, supply, net, supply + net - 1
        ));
        vm.prank(address(0xC2));
        tokenExt.mint(user, value);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(user), balance);
        assertEq(token.debts(user), repayAPNTs);

        vm.prank(address(0xC2));
        tokenExt.setIssuanceCap(supply + net);
        assertGt(supply + value, token.issuanceCap(), "gross mint would exceed cap");
        vm.prank(address(0xC2));
        tokenExt.mint(user, value);
        assertEq(token.totalSupply() - supply, net, "supply delta equals checked amount");
        assertEq(token.balanceOf(user) - balance, net);
        assertEq(token.totalSupply(), token.issuanceCap());
        assertEq(token.debts(user), 0);
    }

    /// @dev Regression control, NOT C2-02 evidence: this test also passes on the pre-fix code (name ""),
    ///      because OZ already bound the domain to the clone address and chain id before C2-02.
    function test_regression_executeBySig_rejects_cross_clone_and_cross_chain_replay() public {
        vm.prank(address(0xC2));
        xPNTsTokenV2 other = xPNTsTokenV2(
            factory.deployxPNTsToken("Comm", "xC2", "Comm2", "comm2.eth", 1 ether, address(0))
        );
        assertEq(other.name(), t.name());
        bytes memory params = abi.encode(sp);
        uint256 deadline = block.timestamp + 1 hours;
        (, , , uint256 originalChainId, , , ) = t.eip712Domain();
        bytes32 digest = _ext().actionDigest(signer, 1, params, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertNotEq(IExt(address(other)).actionDigest(signer, 1, params, 0, deadline), digest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        IExt(address(other)).executeBySig(signer, 1, params, deadline, signature);
        assertEq(other.actionNonce(signer), 0);

        vm.chainId(originalChainId + 1);
        assertNotEq(_ext().actionDigest(signer, 1, params, 0, deadline), digest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        _ext().executeBySig(signer, 1, params, deadline, signature);
        assertEq(t.actionNonce(signer), 0, "rejection is not caused by a consumed nonce");

        vm.chainId(originalChainId);
        assertEq(_ext().actionDigest(signer, 1, params, 0, deadline), digest);
        _ext().executeBySig(signer, 1, params, deadline, signature);
        assertEq(t.actionNonce(signer), 1, "same signature succeeds on its original domain");
    }

    function test_I_01_lowered_cap_allows_transfers_and_burns_but_blocks_positive_net_mint() public {
        uint256 supply = t.totalSupply();
        uint256 cap = supply - 100 ether;
        vm.prank(community);
        _ext().setIssuanceCap(cap);
        vm.prank(user);
        assertTrue(t.transfer(signer, 10 ether));
        assertEq(t.balanceOf(signer), 10 ether);
        assertEq(t.balanceOf(user), supply - 10 ether);
        assertEq(t.totalSupply(), supply);
        vm.prank(signer);
        t.burn(1 ether);
        supply -= 1 ether;
        assertEq(t.balanceOf(signer), 9 ether);
        assertEq(t.totalSupply(), supply);
        assertGt(supply, cap, "supply remains above lowered cap after burn");

        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.IssuanceCapExceeded.selector, supply, 1, cap));
        vm.prank(community);
        _ext().mint(user, 1);
        stdstore.target(address(t)).sig("debts(address)").with_key(user).checked_write(5 ether);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.IssuanceCapExceeded.selector, supply, 1, cap));
        vm.prank(community);
        _ext().mint(user, 5 ether + 1);
        assertEq(t.debts(user), 5 ether);
        assertEq(t.totalSupply(), supply);
    }

    function test_factory_rejects_empty_token_name() public {
        vm.prank(address(0xC2));
        vm.expectRevert(xPNTsFactoryV2.InvalidParameters.selector);
        factory.deployxPNTsToken("", "xC2", "Comm2", "comm2.eth", 1 ether, address(0));
        assertEq(factory.communityToToken(address(0xC2)), address(0));
    }

    function test_initialize_rejects_empty_token_name_outside_the_factory() public {
        xPNTsTokenV2 c = xPNTsTokenV2(Clones.clone(address(impl)));
        vm.expectRevert(xPNTsV2Base.InvalidParam.selector);
        c.initialize(xPNTsTokenV2.InitConfig("", "s", address(this), address(this), "c", "e", 1 ether, sp, address(0), address(0)));
        assertEq(c.FACTORY(), address(0), "clone stays uninitialized");
        c.initialize(xPNTsTokenV2.InitConfig("n", "s", address(this), address(this), "c", "e", 1 ether, sp, address(0), address(0)));
        assertEq(c.name(), "n");
    }

    function test_implementation_domain_is_empty_and_differs_from_clone() public view {
        (bytes1 fields, string memory domainName, string memory domainVersion, uint256 chainId,
            address verifyingContract, bytes32 salt, uint256[] memory extensions) = impl.eip712Domain();
        assertEq(uint8(fields), 15);
        assertEq(domainName, "");
        assertEq(domainVersion, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(impl));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(impl.DOMAIN_SEPARATOR(), _domain("", block.chainid, address(impl)));
        assertNotEq(impl.DOMAIN_SEPARATOR(), t.DOMAIN_SEPARATOR());
    }

    /// @dev Discriminating C2-02 evidence: the pre-fix clone accepts this old empty-name domain.
    function test_C2_02_executeBySig_rejects_old_empty_name_domain() public {
        bytes memory params = abi.encode(sp);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            _ext().ACTION_TYPEHASH(), signer, uint8(1), keccak256(params), uint256(0), deadline
        ));
        bytes32 oldDigest = MessageHashUtils.toTypedDataHash(_domain("", block.chainid, address(t)), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, oldDigest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        _ext().executeBySig(signer, 1, params, deadline, abi.encodePacked(r, s, v));
        assertEq(t.actionNonce(signer), 0);
        (v, r, s) = vm.sign(userPk, _ext().actionDigest(signer, 1, params, 0, deadline));
        _ext().executeBySig(signer, 1, params, deadline, abi.encodePacked(r, s, v));
        assertEq(t.actionNonce(signer), 1);
    }

    function test_I_01_above_cap_zero_net_mint_repays_debt() public {
        uint256 supply = t.totalSupply();
        uint256 balance = t.balanceOf(user);
        stdstore.target(address(t)).sig("debts(address)").with_key(user).checked_write(5 ether);
        vm.prank(community);
        _ext().setIssuanceCap(supply - 1);
        vm.prank(community);
        _ext().mint(user, 5 ether);
        assertEq(t.debts(user), 0);
        assertEq(t.totalSupply(), supply);
        assertEq(t.balanceOf(user), balance);
        assertGt(t.totalSupply(), t.issuanceCap());
    }

    function test_I_01_above_cap_settlement_repayment_and_burn_work() public {
        registry.setCreditLimit(user, 300 ether);
        _enableAuto();
        vm.prank(user);
        _ext().requestCredit(300 ether);
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult result,) = t.tryLockForGas(user, OP1, 100 ether, false);
        assertEq(uint8(result), uint8(IxPNTsTokenV2.LockResult.OK));
        vm.prank(sp);
        assertEq(uint8(t.tryReserveCredit(user, OP2, 200 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        vm.prank(community);
        _ext().setIssuanceCap(1 ether);
        uint256 supply = t.totalSupply();
        vm.prank(sp);
        assertEq(t.settleLocked(user, OP1, 30 ether), 30 ether);
        assertEq(t.lockedOf(user), 0);
        assertEq(t.totalSupply(), supply - 30 ether);
        assertGt(t.totalSupply(), t.issuanceCap());
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP2, 150 ether), 150 ether);
        assertEq(t.debts(user), 150 ether);
        assertEq(t.creditReservedOf(user), 0);
        assertEq(t.totalSupply(), supply - 30 ether);
        vm.prank(user);
        _ext().repayDebt(150 ether);
        assertEq(t.debts(user), 0);
        assertEq(t.totalSupply(), supply - 180 ether);
        assertGt(t.totalSupply(), t.issuanceCap());
        vm.prank(user);
        t.burn(1 ether);
        assertEq(t.totalSupply(), supply - 181 ether);
        assertGt(t.totalSupply(), t.issuanceCap());
    }

    function test_A9_factory_cannot_pull() public {
        vm.prank(address(factory));
        vm.expectRevert(xPNTsV2Base.BurnExceedsAllowance.selector);
        t.transferFrom(user, address(factory), 1 ether);
        vm.prank(address(factory));
        vm.expectRevert(xPNTsV2Base.BurnExceedsAllowance.selector);
        t.burn(user, 1 ether);
    }

    function test_A3_sp_cannot_pull_even_with_explicit_approve() public {
        vm.prank(user);
        t.approve(sp, type(uint256).max);
        assertEq(t.allowance(user, sp), 0, "SP allowance always reads 0");
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        t.transferFrom(user, sp, 1 ether);
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        t.burn(user, 1 ether);
    }

    function test_deleted_selectors_do_not_exist() public {
        // C3-1: 3.x direct debt/burn entry points are gone (fallback → extension → no match).
        bytes[3] memory calls = [
            abi.encodeWithSignature("burnFromWithOpHash(address,uint256,bytes32)", user, 1 ether, OP1),
            abi.encodeWithSignature("recordDebt(address,uint256)", user, 1 ether),
            abi.encodeWithSignature("recordDebtWithOpHash(address,uint256,bytes32)", user, 1 ether, OP1)
        ];
        for (uint256 i; i < 3; i++) {
            vm.prank(sp);
            (bool ok, ) = address(t).call(calls[i]);
            assertFalse(ok, "deleted selector must not execute");
        }
        assertEq(t.debts(user), 0);
        assertEq(t.balanceOf(user), 10_000 ether);
    }

    // ------------------------------------------------------------------
    // Lock / settle (X3, L-*, A-1, B-6)
    // ------------------------------------------------------------------

    function test_lock_settle_happy_path() public {
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, uint256 x) = t.tryLockForGas(user, OP1, 100 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));
        assertEq(x, 100 ether);
        assertEq(t.lockedOf(user), 100 ether);
        (uint256 cap, uint256 used) = t.autoAllowance(user, sp);
        assertEq(cap, 5_000 ether);
        assertEq(used, 100 ether);

        vm.prank(sp);
        uint256 burned = t.settleLocked(user, OP1, 30 ether);
        assertEq(burned, 30 ether);
        assertEq(t.lockedOf(user), 0);
        assertEq(t.balanceOf(user), 10_000 ether - 30 ether);
        (, used) = t.autoAllowance(user, sp);
        assertEq(used, 30 ether, "unused reservation refunded (A-4)");
        assertTrue(t.usedOpHashes(OP1));
    }

    function test_settle_charge_capped_at_reservation() public {
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false);
        vm.prank(sp);
        uint256 burned = t.settleLocked(user, OP1, 1_000 ether);
        assertEq(burned, 100 ether, "never more than locked");
    }

    function test_A1_locked_balance_cannot_move() public {
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP1, 4_000 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK), "precondition: the lock exists");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.BalanceLocked.selector, user, 4_000 ether));
        t.transfer(address(1), 6_001 ether);
        vm.prank(user);
        t.transfer(address(1), 6_000 ether); // exactly the free part is fine
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.BalanceLocked.selector, user, 4_000 ether));
        t.burn(1);
    }

    function test_lock_results_typed_and_write_free_on_failure() public {
        // SINGLE_TX_LIMIT (B-6: no truncation)
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP1, 5_001 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT));
        // INSUFFICIENT balance
        address poor = address(0xDEAD);
        vm.prank(sp);
        (r, ) = t.tryLockForGas(poor, OP1, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INSUFFICIENT));
        assertEq(t.lockedOf(poor), 0, "L-1: failure writes nothing");
        // CONFLICTING
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 1 ether, false);
        vm.prank(sp);
        (r, ) = t.tryLockForGas(user, OP1, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.CONFLICTING_LOCK));
        // DISABLED (E-1)
        vm.prank(user);
        _ext().disableSpenderForSelf(sp);
        vm.prank(sp);
        (r, ) = t.tryLockForGas(user, OP2, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.DISABLED));
    }

    function test_lock_insufficient_allowance_and_total() public {
        // 5 × 1,000 = the default 5,000 cap
        for (uint256 i; i < 5; i++) {
            vm.prank(sp);
            (IxPNTsTokenV2.LockResult r0, ) = t.tryLockForGas(user, keccak256(abi.encode(i)), 1_000 ether, false);
            assertEq(uint8(r0), uint8(IxPNTsTokenV2.LockResult.OK));
        }
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP2, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INSUFFICIENT), "cap exhausted");
    }

    function test_only_current_sp_can_lock() public {
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, sp2));
        t.tryLockForGas(user, OP1, 1 ether, false);
    }

    function test_emergency_blocks_new_locks_but_settles_existing() public {
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false);
        vm.prank(community);
        _ext().emergencyRevokePaymaster();
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP2, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.EMERGENCY));
        vm.prank(sp);
        assertEq(t.settleLocked(user, OP1, 10 ether), 10 ether, "E-2: existing lock still settles");
    }

    /// forge-config: default.isolate = true
    function test_L3_settle_only_within_original_tx_and_L4_release() public {
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false);
        // next top-level call = new transaction: the live marker is gone
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.NotLive.selector);
        t.settleLocked(user, OP1, 10 ether);
        t.releaseStaleLock(user, OP1);
        assertEq(t.lockedOf(user), 0);
        (, uint256 used) = t.autoAllowance(user, sp);
        assertEq(used, 0, "full refund on stale release");
    }

    function test_L4_release_refused_while_live() public {
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false);
        vm.expectRevert(xPNTsV2Base.StillLive.selector);
        t.releaseStaleLock(user, OP1); // same transaction as the lock
    }

    function test_settle_rate_uses_lock_time_ratio() public {
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false); // rate 1e18 → x = 100
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(community);
        (bool ok, ) = address(t).call(abi.encodeWithSignature("updateExchangeRate(uint256)", 1.2 ether));
        assertTrue(ok);
        vm.prank(sp);
        assertEq(t.settleLocked(user, OP1, 50 ether), 50 ether, "D-12: lock-time ratio, not live rate");
    }

    // ------------------------------------------------------------------
    // Renewal (A-5, A-6, D-13, D-18)
    // ------------------------------------------------------------------

    function _exhaust() internal {
        for (uint256 i; i < 5; i++) {
            bytes32 h = keccak256(abi.encode("x", i));
            vm.prank(sp);
            t.tryLockForGas(user, h, 1_000 ether, false);
            vm.prank(sp);
            t.settleLocked(user, h, 1_000 ether);
        }
    }

    function test_sp_renew_K1() public {
        _exhaust();
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP1, 100 ether, true);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK), "first SP renewal allowed");
        assertEq(t.autoRenewUsed(user), 1);
        vm.prank(sp);
        t.settleLocked(user, OP1, 5_000 ether); // burns the 100 locked
        _exhaustRemaining();
        vm.prank(sp);
        (r, ) = t.tryLockForGas(user, OP2, 100 ether, true);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INVALID_RENEWAL), "K = 1 reached");
    }

    function _exhaustRemaining() internal {
        (uint256 cap, uint256 used) = t.autoAllowance(user, sp);
        if (cap > used) {
            bytes32 h = keccak256("rest");
            vm.prank(sp);
            t.tryLockForGas(user, h, cap - used, false);
            vm.prank(sp);
            t.settleLocked(user, h, cap - used);
        }
    }

    function test_renew_insufficient_after_commit_writes_nothing() public {
        // user balance small: renewal would reset counters but balance is short → nothing committed
        address u2 = address(0xB2);
        vm.prank(community);
        IExt(address(t)).mint(u2, 10 ether);
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(u2, OP1, 100 ether, true);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INSUFFICIENT));
        assertEq(t.autoRenewUsed(u2), 0, "A-5/L-1: renewal not committed on failure");
    }

    function test_account_only_mode_blocks_sp_renew() public {
        vm.prank(user);
        _ext().setRenewalMode(1);
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP1, 1 ether, true);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INVALID_RENEWAL));
    }

    function test_renewForSelf_resets_and_is_blocked_by_outstanding_lock() public {
        _exhaust();
        vm.prank(user);
        t.renewForSelf(sp);
        (, uint256 used) = t.autoAllowance(user, sp);
        assertEq(used, 0);

        vm.prank(sp);
        t.tryLockForGas(user, OP2, 10 ether, false);
        vm.prank(user);
        vm.expectRevert(xPNTsV2Base.RenewBlocked.selector);
        t.renewForSelf(sp);
    }

    function test_A8_floor_and_ceiling() public {
        vm.prank(user);
        vm.expectRevert(xPNTsV2Base.BelowFloor.selector);
        _ext().setAutoAllowance(sp, 249 ether);
        vm.prank(user);
        vm.expectRevert(xPNTsV2Base.AboveCeiling.selector);
        _ext().setAutoAllowance(sp, 50_001 ether);
        vm.prank(user);
        _ext().setAutoAllowance(sp, 250 ether);
        (uint256 cap, ) = t.autoAllowance(user, sp);
        assertEq(cap, 250 ether);
    }

    // ------------------------------------------------------------------
    // Auto-allowance for non-SP spenders (A-2, B-7, Q5)
    // ------------------------------------------------------------------

    function test_other_spender_default_zero_and_user_opt_in() public {
        vm.startPrank(community);
        _ext().proposeSpender(address(spender));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSpender(address(spender));
        assertEq(t.allowance(user, address(spender)), 0, "Q5: non-SP default 0");
        vm.expectRevert(xPNTsV2Base.AutoAllowanceExceeded.selector);
        spender.pull(address(t), user, 1 ether);
        vm.prank(user);
        _ext().setAutoAllowance(address(spender), 100 ether);
        spender.pull(address(t), user, 60 ether);
        assertEq(t.balanceOf(address(spender)), 60 ether);
        assertEq(t.allowance(user, address(spender)), 40 ether);
    }

    function test_B7_saturating_allowance_with_explicit_max() public {
        vm.startPrank(community);
        _ext().proposeSpender(address(spender));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSpender(address(spender));
        vm.startPrank(user);
        _ext().setAutoAllowance(address(spender), 100 ether);
        t.approve(address(spender), type(uint256).max);
        vm.stopPrank();
        assertEq(t.allowance(user, address(spender)), type(uint256).max, "no overflow revert");
    }

    function test_B7_readd_spender_keeps_counters() public {
        vm.prank(community);
        _ext().proposeSpender(address(spender));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSpender(address(spender));
        vm.prank(user);
        _ext().setAutoAllowance(address(spender), 100 ether);
        spender.pull(address(t), user, 60 ether);
        vm.prank(community);
        _ext().removeAutoApprovedSpender(address(spender));
        vm.prank(community);
        _ext().proposeSpender(address(spender));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSpender(address(spender));
        (uint256 cap, uint256 used) = t.autoAllowance(user, address(spender));
        assertEq(cap, 100 ether);
        assertEq(used, 60 ether, "re-adding does not implicitly clear");
    }

    // ------------------------------------------------------------------
    // Credit (C-0 … C-5)
    // ------------------------------------------------------------------

    function _enableAuto() internal {
        vm.prank(community);
        _ext().queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().executeCreditPolicy();
    }

    function test_credit_off_by_default() public {
        registry.setCreditLimit(user, 300 ether);
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        assertEq(t.effectiveCreditCap(user), 0, "OFF");
        vm.prank(sp);
        assertEq(uint8(t.tryReserveCredit(user, OP1, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT));
    }

    function test_credit_auto_requires_current_epoch_request() public {
        registry.setCreditLimit(user, 300 ether);
        vm.prank(user);
        _ext().requestCredit(1_000 ether); // epoch 0
        _enableAuto();                     // epoch 1 → old request invalid
        assertEq(t.effectiveCreditCap(user), 0, "C-3 epoch invalidation");
        vm.prank(user);
        _ext().requestCredit(200 ether);
        assertEq(t.effectiveCreditCap(user), 200 ether, "min(request, tier)");
        registry.setCreditLimit(user, 100 ether);
        assertEq(t.effectiveCreditCap(user), 100 ether, "tier moves with reputation");
    }

    function test_credit_reserve_settle_and_cap() public {
        registry.setCreditLimit(user, 300 ether);
        _enableAuto();
        vm.prank(user);
        _ext().requestCredit(300 ether);
        vm.prank(sp);
        assertEq(uint8(t.tryReserveCredit(user, OP1, 200 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        vm.prank(sp);
        assertEq(uint8(t.tryReserveCredit(user, OP2, 200 ether)), uint8(IxPNTsTokenV2.CreditResult.EXCEEDS_CAP),
            "N-C1: second reservation sees the first");
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP1, 150 ether), 150 ether);
        assertEq(t.debts(user), 150 ether);
        assertEq(t.creditReservedOf(user), 0);
    }

    function test_manual_approval_is_a_ceiling() public {
        registry.setCreditLimit(user, 1_000 ether);
        vm.prank(community);
        _ext().queueCreditPolicy(1);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().executeCreditPolicy();
        vm.prank(user);
        _ext().requestCredit(500 ether);
        assertEq(t.effectiveCreditCap(user), 0, "MANUAL needs approval");
        vm.prank(community);
        _ext().approveCredit(user, 800 ether); // clipped to the request
        assertEq(t.effectiveCreditCap(user), 500 ether);
        registry.setCreditLimit(user, 300 ether);
        assertEq(t.effectiveCreditCap(user), 300 ether, "still follows reputation after approval");
    }

    function test_policy_noop_switch_rejected() public {
        vm.prank(community);
        vm.expectRevert(xPNTsV2Base.InvalidParam.selector);
        _ext().queueCreditPolicy(0);
    }

    // ------------------------------------------------------------------
    // SP state machine (§2.5)
    // ------------------------------------------------------------------

    function test_S1_S3_rotation_after_timelock() public {
        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.expectRevert();
        _ext().activateSP();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertTrue(t.historicalSP(sp2));
        assertTrue(t.historicalSP(sp), "old SP stays historical (transferFrom ban)");
    }

    function test_factory_proposal_cannot_override_community_and_is_cancelled_by_emergency() public {
        vm.prank(address(factory));
        _ext().proposeSP(sp2);
        assertTrue(t.pendingSPByFactory());
        vm.prank(community);
        _ext().emergencyRevokePaymaster();
        assertEq(t.pendingSP(), address(0), "S-4 cancels factory proposal");
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(factory)));
        _ext().proposeSP(sp2);
    }

    function test_RotationInvalidatesDesignatedStandby() public {
        vm.prank(community);
        _ext().proposeStandby(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateStandbyDesignation();
        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectEmit(true, false, false, true, address(t));
        emit xPNTsV2Base.StandbyInvalidated(sp2);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertEq(t.standbySP(), address(0));
    }

    /// DSR rc.8 (C2-01 end to end): a standby promoted to current SP, later compromised, must not
    /// brick the emergency switch. Before the fix standbySP stayed == the revoked SP and the switch reverted.
    function test_EmergencySwitchWorksAfterStandbyWasPromoted() public {
        vm.prank(community);
        _ext().proposeStandby(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateStandbyDesignation();
        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertEq(t.standbySP(), address(0));
        // designate the old SP as the new standby, then sp2 is compromised and revoked
        vm.prank(community);
        _ext().proposeStandby(sp);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateStandbyDesignation();
        vm.startPrank(community);
        _ext().emergencyRevokePaymaster();
        _ext().emergencySwitchToStandby();
        vm.stopPrank();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp);
        assertEq(t.standbySP(), address(0));
    }

    function test_RotationCancelsPendingStandbyAndEta() public {
        vm.startPrank(community);
        _ext().proposeStandby(sp2);
        _ext().proposeSP(sp2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectEmit(true, false, false, true, address(t));
        emit xPNTsV2Base.StandbyProposalCancelled(sp2);
        _ext().activateSP();
        assertEq(t.pendingStandby(), address(0));
        assertEq(t.pendingStandbyEta(), 0);
        vm.expectRevert(xPNTsV2Base.NothingPending.selector);
        _ext().activateStandbyDesignation();
    }

    function test_DesignationRejectsStaleCurrentCandidate() public {
        vm.prank(community);
        _ext().proposeStandby(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        // Seed a stale state to exercise the activation-time guard independently.
        stdstore.target(address(t)).sig("SUPERPAYMASTER_ADDRESS()").checked_write(sp2);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, sp2));
        _ext().activateStandbyDesignation();
        assertEq(t.standbySP(), address(0));
        assertEq(t.pendingStandby(), sp2);
    }

    function test_DesignationRejectsStaleRevokedCandidate() public {
        vm.prank(community);
        _ext().proposeStandby(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        // Seed a stale state; normal rotation now cancels this proposal first.
        stdstore.target(address(t)).sig("emergencyRevokedAddress()").checked_write(sp2);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, sp2));
        _ext().activateStandbyDesignation();
        assertEq(t.standbySP(), address(0));
        assertEq(t.pendingStandby(), sp2);
    }

    function test_S6_S7_standby_recovery() public {
        vm.prank(community);
        _ext().proposeStandby(sp2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _ext().activateStandbyDesignation();
        assertFalse(t.historicalSP(sp2), "designation grants nothing");
        vm.prank(community);
        _ext().emergencyRevokePaymaster();
        vm.prank(community);
        vm.expectRevert(xPNTsV2Base.RecoveryNotComplete.selector);
        _ext().unsetEmergencyDisabled();
        vm.prank(community);
        _ext().emergencySwitchToStandby();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        vm.prank(community);
        _ext().unsetEmergencyDisabled();
        assertFalse(t.emergencyDisabled());
    }

    /// forge-config: default.isolate = true
    function test_old_locker_settles_only_in_original_tx_after_rotation() public {
        // lock by sp, then rotate within the same tx is impossible (48 h); emulate by checking
        // that settle authority is tied to the record's locker, not to the current SP.
        vm.prank(sp);
        t.tryLockForGas(user, OP1, 100 ether, false);
        vm.prank(sp2);
        vm.expectRevert(); // not the locker (and not live either in isolate mode)
        t.settleLocked(user, OP1, 1 ether);
    }

    // ------------------------------------------------------------------
    // R2 relayed action (ECDSA path)
    // ------------------------------------------------------------------

    function test_executeBySig_renew_by_relayer() public {
        vm.prank(community);
        IExt(address(t)).mint(signer, 10_000 ether);
        bytes memory params = abi.encode(sp);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _ext().actionDigest(signer, 1, params, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        _ext().executeBySig(signer, 1, params, deadline, abi.encodePacked(r, s, v));
        assertEq(t.actionNonce(signer), 1);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        _ext().executeBySig(signer, 1, params, deadline, abi.encodePacked(r, s, v)); // replay → new nonce
    }

    // ------------------------------------------------------------------
    // Registry: EIP-1167 resolution (§9)
    // ------------------------------------------------------------------

    function test_registry_resolves_minimal_proxy_to_impl() public {
        address clone = Clones.clone(address(spender));
        assertEq(reg.implCodehash(clone), address(spender).codehash);
        assertTrue(reg.isApprovedImpl(reg.KIND_SPENDER(), clone));
        assertFalse(reg.isApprovedImpl(reg.KIND_SP(), sp), "SP never codehash-keyed");
    }

    // ------------------------------------------------------------------
    // Split safety (DSR D1 acceptance a/c): direct calls to the extension or the core
    // template never touch a clone and never grant authority.
    // ------------------------------------------------------------------

    function test_extension_direct_calls_are_inert() public {
        // the extension has no initializer of its own; its storage stays zero forever
        (bool ok, ) = address(ext).call(abi.encodeWithSignature("initialize((string,string,address,address,string,string,uint256,address,address,address))",
            xPNTsTokenV2.InitConfig("n","s",address(this),address(this),"c","e",1 ether,sp,address(0),address(0))));
        assertFalse(ok, "extension exposes no initializer");

        // privileged functions fail: owner/factory/SP in the extension's own storage are all zero
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(this)));
        IExt(address(ext)).mint(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(this)));
        IExt(address(ext)).proposeSP(sp2);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(this)));
        IExt(address(ext)).emergencyRevokePaymaster();

        // a user-level write on the extension lands in the extension's storage only
        (uint256 capBefore, ) = t.autoAllowance(user, sp);
        vm.prank(user);
        IExt(address(ext)).setAutoAllowance(sp, 300 ether); // SP_ADDRESS in ext storage is 0 → no floor check
        (uint256 capAfter, ) = t.autoAllowance(user, sp);
        assertEq(capAfter, capBefore, "clone state untouched by a direct extension call");
        assertEq(xPNTsTokenV2Ext(address(ext)).SUPERPAYMASTER_ADDRESS(), address(0));
    }

    function test_core_template_is_inert() public {
        assertEq(impl.SUPERPAYMASTER_ADDRESS(), address(0), "template never initialised");
        vm.expectRevert(); // initializers disabled on the template
        impl.initialize(xPNTsTokenV2.InitConfig("n","s",address(this),address(this),"c","e",1 ether,address(0),address(0),address(0)));
        vm.prank(address(0x5B));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(0x5B)));
        impl.tryLockForGas(user, OP1, 1 ether, false);
        assertEq(t.EXTENSION(), address(ext), "clones share the template's immutable extension");
    }
}
