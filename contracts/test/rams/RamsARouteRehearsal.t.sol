// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import "src/tokens/v2/AOAProtocolRegistry.sol";
import "src/tokens/v2/GlobalTierSource.sol";
import "src/tokens/v2/xPNTsTokenV2.sol";
import "src/tokens/v2/xPNTsTokenV2Ext.sol";
import "src/tokens/v2/xPNTsFactoryV2.sol";
import "./RamsAHelpers.sol";

/// @notice OFFLINE-authored Route A rehearsal; every test skips without SEPOLIA_FORK_RPC.
/// @dev Required: FORK_BLOCK and OPERATORS (comma-separated, no omitted configured operator).
/// The orchestrator MUST obtain the complete list from an archive scan of the proxy's
/// OperatorConfigured(address indexed operator,address xPNTsToken,address treasury) events
/// from deployment through FORK_BLOCK (v5.4.2 tag, configureOperator). Deduplicate addresses,
/// then read isConfigured at FORK_BLOCK. On-chain fork tests cannot prove log-scan completeness.
/// Known OWNER and ANNI are mandatory, but they are NOT asserted to be the complete inventory.
///
/// Fixtures: fresh SimpleAccounts, local ETH/ERC20 funding, Registry-authorized SBT updates,
/// getCreditLimit mocks scoped ONLY to synthetic accounts, and a fresh $2000 Chainlink response.
/// No pause, role-membership, factory-binding, validation, settlement or upgrade calls are mocked.
/// A3/A5 explicitly migrate OWNER to a freshly deployed real V2 token/factory on the fork.
/// These are controlled route/settlement tests, not evidence of live balances or oracle health.
/// No broadcast, FFI, RPC log scan, or remote transaction submission is used.
contract RamsARouteRehearsalTest is Test {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    using stdStorage for StdStorage;

    address constant SP = 0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9;
    address constant REGISTRY = 0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71;
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant OWNER = 0xb5600060e6de5E11D3636731964218E53caadf0E;
    address constant ANNI = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
    address constant SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    address constant FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant NEW_OPERATOR = address(0xA522523);
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant COMMUNITY = keccak256("COMMUNITY");
    bytes32 constant USER_EVENT = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant POST_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
    uint256 constant DELAY = 172800;
    uint256 constant USER_KEY = 0xA522;
    uint256 constant OWNER_KEY = 0xA523;
    uint128 constant PM_VERIFICATION_GAS = 1_150_000;
    uint256 constant FIXTURE_BALANCE = 100_000 ether;

    SuperPaymaster sp = SuperPaymaster(payable(SP));
    IEntryPoint ep = IEntryPoint(EP);
    address[] operators;
    address user;
    address ownerAccount;
    address newImpl;
    bytes32 newHash;
    RamsTarget target;
    uint256 gpSlot;
    uint256 pendingSlot;
    uint256 pauseSlot;
    uint256 opSlot;
    bool forkEnabled;
    bytes32 inventoryHash;
    uint256 sigFailureProbes;

    modifier forkOnly() {
        if (!forkEnabled) vm.skip(true);
        _;
    }

    function setUp() public {
        if (bytes(vm.envOr("SEPOLIA_FORK_RPC", string(""))).length == 0) {
            return;
        }
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        require(forkBlock != 0, "RAMS: FORK_BLOCK must be explicit and nonzero");
        vm.createSelectFork(vm.envString("SEPOLIA_FORK_RPC"), forkBlock);
        forkEnabled = true;
        assertEq(block.chainid, 11155111, "RAMS: Sepolia only");
        assertEq(vm.getBlockNumber(), forkBlock, "RAMS: wrong fork block");
        assertEq(sp.version(), "SuperPaymaster-5.4.2", "RAMS: expected live 5.4.2");
        assertEq(sp.owner(), OWNER, "RAMS: live owner drift");
        assertEq(OWNER.code.length, 0, "RAMS: live owner must be an undelegated EOA");
        assertEq(address(sp.entryPoint()), EP, "RAMS: EP immutable drift");
        assertEq(address(sp.REGISTRY()), REGISTRY, "RAMS: Registry immutable drift");
        assertEq(address(sp.ETH_USD_PRICE_FEED()), FEED, "RAMS: feed immutable drift");
        assertGt(EP.code.length, 0, "RAMS: missing EntryPoint");
        assertEq(RamsSafe(SAFE).getThreshold(), 2, "RAMS: Safe threshold drift");
        assertEq(RamsSafe(SAFE).getOwners().length, 3, "RAMS: Safe owners drift");
        operators = vm.envAddress("OPERATORS", ",");
        inventoryHash = keccak256(abi.encode(operators));
        require(operators.length != 0, "RAMS: archive operator inventory missing");
        bool ownerSeen;
        bool anniSeen;
        for (uint256 i; i < operators.length; ++i) {
            address op = operators[i];
            require(op != address(0), "RAMS: zero operator");
            for (uint256 j; j < i; ++j) {
                require(op != operators[j], "RAMS: duplicate operator");
            }
            (, bool configured,, address token,,,,,) = sp.operators(op);
            require(configured && token.code.length != 0, "RAMS: unconfigured operator or missing token");
            ownerSeen = ownerSeen || op == OWNER;
            anniSeen = anniSeen || op == ANNI;
        }
        require(ownerSeen && anniSeen, "RAMS: known operators absent from inventory");
        emit log_named_string("Registry source version (must match inspected tag)", RamsRegistry(REGISTRY).version());
        // Live Sepolia Registry reports Registry-5.8.0 (introduced bb2610e8, replaced at dfdbf742). configureRole,
        // registerRole's isActive gate and RoleConfig are identical at both ends of that range.
        assertEq(RamsRegistry(REGISTRY).version(), "Registry-5.8.0", "RAMS: inspect Registry source on version drift");
        emit log_named_uint("EVM block gas limit (not transaction cap)", block.gaslimit);
        emit log_named_uint("R0 comparison 2^24", 1 << 24);
        emit log("Transaction gas limit, Amsterdam cap switch and reservoir are not introspectable here; R0 is a runner assumption.");
        emit log_named_uint("Pinned fork block", forkBlock);
        emit log_named_uint("Archive inventory entries (completeness externally attested)", operators.length);
        newImpl = address(new SuperPaymaster(ep, sp.REGISTRY(), address(sp.ETH_USD_PRICE_FEED())));
        newHash = newImpl.codehash;
        RamsStorageSlots layout = new RamsStorageSlots(ep, sp.REGISTRY(), FEED);
        (gpSlot, pendingSlot, pauseSlot, opSlot) = layout.slots();
        assertEq(vm.load(SP, bytes32(gpSlot)), bytes32(0), "RAMS: legacy gas slot not zero");
        assertEq(vm.load(SP, bytes32(pendingSlot)), bytes32(0), "RAMS: legacy pending slot not zero");
        assertEq(vm.load(SP, bytes32(pauseSlot)), bytes32(0), "RAMS: legacy guardian/pause slot not zero");
        SimpleAccountFactory af = new SimpleAccountFactory(ep);
        user = address(af.createAccount(vm.addr(USER_KEY), 0));
        ownerAccount = address(af.createAccount(vm.addr(OWNER_KEY), 0));
        target = new RamsTarget();
        vm.deal(address(this), 100 ether);
        ep.depositTo{value: 20 ether}(SP);
        ep.depositTo{value: 5 ether}(ownerAccount);
        vm.prank(REGISTRY);
        sp.updateSBTStatus(user, true);
        assertTrue(sp.sbtHolders(user), "RAMS: synthetic account SBT fixture");
        vm.mockCall(REGISTRY, abi.encodeCall(IRegistry.getCreditLimit, (user)), abi.encode(uint256(1e30)));
        _freshPrice();
    }

    function _freshPrice() internal {
        vm.mockCall(
            FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(2000e8), vm.getBlockTimestamp(), vm.getBlockTimestamp(), uint80(1))
        );
        sp.updatePrice();
        (int256 p, uint256 t,,) = sp.cachedPrice();
        assertEq(p, 2000e8, "RAMS: oracle fixture price");
        assertEq(t, vm.getBlockTimestamp(), "RAMS: oracle fixture freshness");
    }

    function _token(address op) internal view returns (address token) {
        (,,, token,,,,,) = sp.operators(op);
        require(token.code.length != 0, "RAMS: missing operator token");
    }

    function _fundOperator(address op) internal {
        address apnts = sp.APNTS_TOKEN();
        RamsTokenLimits token = RamsTokenLimits(apnts);
        // v1 transferFrom called by SP with recipient SP is exempt from daily-cap and credit
        // gates. Require that identity explicitly; do not disable any live token guard.
        assertEq(token.SUPERPAYMASTER_ADDRESS(), SP, "RAMS: deposit SP identity; daily-cap exemption unavailable");
        uint256 limit = token.maxSingleTxLimit();
        uint256 rate = token.exchangeRate();
        uint256 chunk = RamsBudget.depositChunk(limit, rate);
        emit log_named_address("Deposit token", apnts);
        emit log_named_uint("Live deposit single-tx limit (aPNTs)", limit);
        emit log_named_uint("Deposit chunk (token units)", chunk);
        (uint128 beforeBalance,,,,,,,,) = sp.operators(op);
        uint256 beforeSP = IERC20(apnts).balanceOf(SP);
        uint256 funded = IERC20(apnts).balanceOf(op) + FIXTURE_BALANCE;
        deal(apnts, op, funded);
        vm.startPrank(op);
        assertTrue(IERC20(apnts).approve(SP, FIXTURE_BALANCE), "RAMS: deposit approval failed");
        assertGe(IERC20(apnts).allowance(op, SP), FIXTURE_BALANCE, "RAMS: insufficient deposit allowance");
        uint256 remaining = FIXTURE_BALANCE;
        while (remaining != 0) {
            uint256 amount = Math.min(remaining, chunk);
            assertLe(Math.mulDiv(amount, 1 ether, rate), limit, "RAMS: deposit exceeds converted limit");
            sp.deposit(amount);
            remaining -= amount;
        }
        sp.setOperatorLimits(0); // Synthetic accounts can submit independent controls without a rate-limit wait.
        vm.stopPrank();
        (uint128 b,,,,,,,,) = sp.operators(op);
        assertEq(uint256(b), uint256(beforeBalance) + FIXTURE_BALANCE, "RAMS: operator fixture deposit");
        assertEq(IERC20(apnts).balanceOf(SP), beforeSP + FIXTURE_BALANCE, "RAMS: deposit token receipt");
        assertEq(IERC20(apnts).balanceOf(op), funded - FIXTURE_BALANCE, "RAMS: deposit token debit");
    }

    function _legacyReady(address op) internal {
        _fundOperator(op);
        _fundLegacyUser(_token(op));
        vm.prank(sp.owner());
        sp.setOperatorPaused(op, false); // Explicit positive-control fixture, not a live-state claim.
        _assertOperatorPause(op, false);
    }

    function _fundLegacyUser(address token) internal {
        assertEq(RamsTokenLimits(token).SUPERPAYMASTER_ADDRESS(), SP, "RAMS: legacy burn SP identity");
        assertFalse(RamsTokenLimits(token).emergencyDisabled(), "RAMS: legacy control impossible: emergency stop");
        deal(token, user, FIXTURE_BALANCE, true);
        // v1 settlement uses burnFromWithOpHash, not ERC20 allowance. The identity,
        // emergency flag, aPNTs single-tx limit and Registry credit gate still apply.
        assertEq(IERC20(token).balanceOf(user), FIXTURE_BALANCE, "RAMS: legacy user funding");
    }

    function _reservation(uint256 cost) internal view returns (uint256) {
        (int256 price,,, uint8 decimals) = sp.cachedPrice();
        require(price > 0, "RAMS: nonpositive cached price");
        return RamsBudget.reservation(cost, uint256(price), decimals, sp.aPNTsPriceUSD(), sp.protocolFeeBPS());
    }

    function _capacity(address operator, bool v2) internal view returns (uint256 capacity) {
        address token = _token(operator);
        uint256 rate = RamsTokenLimits(token).exchangeRate();
        require(rate != 0, "RAMS: zero user-token rate");
        capacity = RamsTokenLimits(token).maxSingleTxLimit();
        (uint128 balance,,,,,,,,) = sp.operators(operator);
        capacity = Math.min(capacity, balance);
        uint256 available = IERC20(token).balanceOf(user);
        if (v2) {
            xPNTsTokenV2 t = xPNTsTokenV2(token);
            available -= t.lockedOf(user);
            (uint256 cap, uint256 used) = t.autoAllowance(user, SP);
            capacity = Math.min(capacity, cap > used ? cap - used : 0);
            (cap, used) = t.userTotal(user);
            capacity = Math.min(capacity, cap > used ? cap - used : 0);
        } else {
            uint256 credit = sp.REGISTRY().getCreditLimit(user);
            uint256 used = RamsTokenLimits(token).getDebt(user) + RamsLegacyDebt(SP).pendingDebts(token, user);
            capacity = Math.min(capacity, credit > used ? credit - used : 0);
        }
        // floor(balance / rate) ensures ceil(reservation * rate) fits the funded xPNTs.
        return Math.min(capacity, Math.mulDiv(available, 1 ether, rate));
    }

    function _fitFees(PackedUserOperation memory op, address operator, bool v2) internal view {
        uint256 gas = RamsBudget.requiredGas(op);
        // Recompute remaining capacity for each op; never allow a zero-price success.
        uint256 budget = _capacity(operator, v2);
        require(_reservation(gas) <= budget, "RAMS: token/credit/balance limits cannot fund a 1-wei gas price");
        uint256 low = 1;
        uint256 high = 1 gwei;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_reservation(gas * mid) <= budget) low = mid;
            else high = mid - 1;
        }
        op.gasFees = bytes32(abi.encodePacked(uint128(low), uint128(low)));
    }

    function _assertBudget(PackedUserOperation memory op) internal view {
        bytes memory pmd = op.paymasterAndData;
        address operator;
        assembly { operator := shr(96, mload(add(pmd, 84))) }
        bool v2 = pmd.length == 125;
        uint256 reserve = _reservation(RamsBudget.maxCost(op));
        assertGt(reserve, 0, "RAMS: zero reservation");
        assertLe(reserve, _capacity(operator, v2), "RAMS: control exceeds token/credit/balance capacity");
        if (v2) {
            (IxPNTsTokenV2.LockResult result,) =
                xPNTsTokenV2(_token(operator)).previewLock(SP, user, ep.getUserOpHash(op), reserve, false);
            assertEq(uint256(result), uint256(IxPNTsTokenV2.LockResult.OK), "RAMS: V2 escrow control impossible");
        }
    }

    function _assertOperatorPause(address op, bool want) internal view {
        (, bool configured, bool stopped,,,,,,) = sp.operators(op);
        require(configured, "RAMS: operator no longer configured");
        assertEq(stopped, want, "RAMS: operator pause read-back");
    }

    function _pauseAll(bool stopped) internal {
        address authority = sp.owner();
        for (uint256 i; i < operators.length; ++i) {
            vm.prank(authority);
            sp.setOperatorPaused(operators[i], stopped);
            _assertOperatorPause(operators[i], stopped);
        }
    }

    function _sign(PackedUserOperation memory op, uint256 key) internal view returns (PackedUserOperation memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(ep.getUserOpHash(op)));
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function _op(address operator, uint128 postGas, bool v2) internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.nonce = ep.getNonce(user, 0);
        op.callData = abi.encodeCall(SimpleAccount.execute, (address(target), 0, abi.encodeCall(RamsTarget.hit, ())));
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(600_000), uint128(300_000)));
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(SP, PM_VERIFICATION_GAS, postGas, operator, type(uint256).max);
        if (v2) op.paymasterAndData = abi.encodePacked(op.paymasterAndData, _token(operator), uint8(0));
        // Legacy-format ops after upgrade are deliberately invalid pause controls,
        // including uint128.max postGas; they must reach the global pause gate as-is.
        if (v2 || keccak256(bytes(sp.version())) == keccak256("SuperPaymaster-5.4.2")) {
            _fitFees(op, operator, v2);
        }
        return _sign(op, USER_KEY);
    }

    /// @dev Roll back both the optimistic debit (5.4.2) and reservation (5.5.0).
    function _probe(PackedUserOperation memory op, bool success, uint256 contextLength) internal {
        if (success) _assertBudget(op);
        uint256 beforeFailures = sigFailureProbes;
        uint256 snapshot = vm.snapshot();
        bytes32 h = ep.getUserOpHash(op);
        uint256 maxCost = RamsBudget.maxCost(op);
        if (success) {
            emit log_named_uint("Positive control maxCost (wei)", maxCost);
            emit log_named_uint("Positive control reservation (aPNTs)", _reservation(maxCost));
        }
        vm.prank(EP);
        (bytes memory context, uint256 vd) = sp.validatePaymasterUserOp(op, h, maxCost);
        if (success) {
            assertEq(uint160(vd), 0, "RAMS: positive control SIG_FAILURE");
            uint48 until = uint48(vd >> 160);
            assertTrue(until == 0 || until >= vm.getBlockTimestamp(), "RAMS: positive control expired");
            assertLe(uint48(vd >> 208), vm.getBlockTimestamp(), "RAMS: positive control not yet valid");
            assertEq(context.length, contextLength, "RAMS: positive control context length");
        } else {
            assertEq(vd, 1, "RAMS: exact SIG_FAILURE required");
            assertEq(context.length, 0, "RAMS: rejected op must have no context");
        }
        bool rejected = vd == 1 && context.length == 0;
        assertTrue(vm.revertTo(snapshot), "RAMS: probe rollback");
        sigFailureProbes = beforeFailures + (rejected ? 1 : 0);
    }

    function _upgrade(bool atomicPause) internal {
        vm.prank(sp.owner());
        sp.upgradeToAndCall(newImpl, atomicPause ? abi.encodeWithSignature("setGlobalPaused(bool)", true) : bytes(""));
        _assertUpgrade(atomicPause);
    }

    function _assertUpgrade(bool stopped) internal view {
        assertEq(address(uint160(uint256(vm.load(SP, IMPL_SLOT)))), newImpl, "RAMS: implementation");
        assertEq(newImpl.codehash, newHash, "RAMS: runtime identity");
        assertEq(sp.version(), "SuperPaymaster-5.5.0", "RAMS: version");
        assertEq(sp.paused(), stopped, "RAMS: atomic global pause");
        assertEq(address(sp.entryPoint()), EP, "RAMS: new EP immutable");
        assertEq(address(sp.REGISTRY()), REGISTRY, "RAMS: new Registry immutable");
        assertEq(address(sp.ETH_USD_PRICE_FEED()), FEED, "RAMS: new feed immutable");
    }

    function _assertGas(bool activated) internal view {
        (SuperPaymasterStorage.GasParams memory p, SuperPaymasterStorage.PendingGasParams memory q) = sp.gasParams();
        assertEq(p.minPostOpGas, activated ? 440_000 : 200_000, "RAMS: MIN read-back");
        assertEq(p.settleGasBound, activated ? 420_000 : 160_000, "RAMS: SETTLE read-back");
        assertEq(p.cWrap, 5000, "RAMS: C_WRAP read-back");
        assertEq(p.cPostop, activated ? 340_000 : 175_000, "RAMS: C_POSTOP read-back");
        if (activated) {
            assertEq(
                keccak256(abi.encode(q)),
                keccak256(abi.encode(SuperPaymasterStorage.PendingGasParams(0, 0, 0, 0, 0))),
                "RAMS: pending must clear"
            );
        } else {
            assertEq(vm.load(SP, bytes32(gpSlot)), bytes32(0), "RAMS: defaults must come from zero slot");
        }
    }

    function _queue() internal returns (uint256 eta) {
        vm.prank(sp.owner());
        sp.queueGasParams(440_000, 420_000, 5000, 340_000);
        return _queuedReadback();
    }

    function _queuedReadback() internal view returns (uint256 eta) {
        (, SuperPaymasterStorage.PendingGasParams memory q) = sp.gasParams();
        assertEq(q.minPostOpGas, 440_000, "RAMS: queued MIN");
        assertEq(q.settleGasBound, 420_000, "RAMS: queued SETTLE");
        assertEq(q.cWrap, 5000, "RAMS: queued WRAP");
        assertEq(q.cPostop, 340_000, "RAMS: queued POSTOP");
        assertEq(q.eta, vm.getBlockTimestamp() + DELAY, "RAMS: internal eta exactly 48h");
        return q.eta;
    }

    /// @dev Real V2 stack; all protocol-registry identities are sealed before mint/validation.
    function _v2Ready() internal returns (xPNTsTokenV2 token) {
        return _v2ReadyFor(OWNER);
    }

    function _v2ReadyFor(address operator) internal returns (xPNTsTokenV2 token) {
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(address(this));
        GlobalTierSource tier = new GlobalTierSource(REGISTRY);
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(SP));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory =
            new xPNTsFactoryV2(SP, REGISTRY, address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier));
        vm.prank(sp.owner());
        sp.setXPNTsFactory(address(factory));
        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("RAMS", "rPNT", "RAMS", "", 1 ether, address(0)));
        sp.configureOperator(address(token), operator);
        RamsMint(address(token)).mint(user, FIXTURE_BALANCE);
        vm.stopPrank();
        // SP escrow uses bounded auto-allowance and a user-total cap. ERC20 approve
        // cannot authorize SP transferFrom on V2 (allowance is deliberately zero).
        vm.startPrank(user);
        xPNTsTokenV2Ext(address(token)).setAutoAllowance(SP, token.maxSingleTxLimit());
        xPNTsTokenV2Ext(address(token)).setUserTotalCap(token.maxSingleTxLimit());
        vm.stopPrank();
        assertEq(token.balanceOf(user), FIXTURE_BALANCE, "RAMS: V2 user funding");
        assertEq(token.allowance(user, SP), 0, "RAMS: V2 SP must use escrow");
        assertEq(_token(operator), address(token), "RAMS: V2 operator binding");
        assertEq(token.BALANCE_MODE_VERSION(), 1, "RAMS: V2 token required");
        _fundOperator(operator);
    }

    function _mustReject(address destination, bytes memory data, bytes memory expected, string memory message)
        internal
    {
        (bool ok, bytes memory reason) = destination.call(data);
        require(!ok, message);
        assertEq(reason, expected, message);
    }

    function test_A1_oldPausePath_blocksAllOperators() public forkOnly {
        PackedUserOperation[] memory signed = new PackedUserOperation[](operators.length);
        for (uint256 i; i < operators.length; ++i) {
            _legacyReady(operators[i]);
            signed[i] = _op(operators[i], 440_000, false);
            _probe(signed[i], true, 160);
        }
        _pauseAll(true);
        for (uint256 i; i < operators.length; ++i) {
            _probe(signed[i], false, 0);
        }
        assertEq(sp.version(), "SuperPaymaster-5.4.2", "RAMS: old pause path only");
    }

    function _registerNewOperator() internal {
        RamsRegistry reg = RamsRegistry(REGISTRY);
        address ownerToken = _token(OWNER);
        address registryOwner = reg.owner();
        require(registryOwner != address(0), "RAMS: missing Registry owner");
        emit log_named_address("Registry configuration authority", registryOwner);
        emit log_named_address("COMMUNITY role configuration owner", reg.getRoleConfig(COMMUNITY).owner);
        emit log_named_address("PAYMASTER_SUPER role configuration owner", reg.getRoleConfig(SUPER).owner);
        emit log("Role acquisition: self registerRole; existing communities may sponsor safeMintForRole. Stake/ticket and active-role gates apply.");
        (, bool configured,,,,,,,) = sp.operators(NEW_OPERATOR);
        assertFalse(configured, "RAMS: new operator already exists");
        assertFalse(sp.REGISTRY().hasRole(COMMUNITY, NEW_OPERATOR), "RAMS: unexpected community role");
        assertFalse(sp.REGISTRY().hasRole(SUPER, NEW_OPERATOR), "RAMS: unexpected super role");
        vm.prank(NEW_OPERATOR);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.configureOperator(ownerToken, NEW_OPERATOR);
        address staking = reg.GTOKEN_STAKING();
        address gtoken = RamsStaking(staking).GTOKEN();
        IRegistry.RoleConfig memory community = reg.getRoleConfig(COMMUNITY);
        IRegistry.RoleConfig memory superRole = reg.getRoleConfig(SUPER);
        require(community.isActive && superRole.isActive, "RAMS: registration disabled at fork; reassess window");
        deal(
            gtoken,
            NEW_OPERATOR,
            community.minStake + community.ticketPrice + superRole.minStake + superRole.ticketPrice
        );
        vm.startPrank(NEW_OPERATOR);
        IERC20(gtoken).approve(staking, type(uint256).max);
        reg.registerRole(
            COMMUNITY, NEW_OPERATOR, abi.encode(RamsRegistry.CommunityData("RAMS-new-522-523", "", community.minStake))
        );
        vm.stopPrank();
        assertTrue(sp.REGISTRY().hasRole(COMMUNITY, NEW_OPERATOR), "RAMS: self-granted community");
        vm.prank(NEW_OPERATOR);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.configureOperator(ownerToken, NEW_OPERATOR);
        vm.prank(NEW_OPERATOR);
        reg.registerRole(SUPER, NEW_OPERATOR, abi.encode(superRole.minStake));
        assertTrue(sp.REGISTRY().hasRole(SUPER, NEW_OPERATOR), "RAMS: self-granted super operator");
        vm.startPrank(NEW_OPERATOR);
        address tok =
            RamsFactory(sp.xpntsFactory()).deployxPNTsToken("RAMS old", "rOLD", "RAMS", "", 1 ether, address(0));
        sp.configureOperator(tok, NEW_OPERATOR);
        vm.stopPrank();
        _assertOperatorPause(NEW_OPERATOR, false); // No pause setter was ever called for this address.
        assertEq(_token(NEW_OPERATOR), tok, "RAMS: new token binding");
        _fundOperator(NEW_OPERATOR);
        _fundLegacyUser(tok);
        _probe(_op(NEW_OPERATOR, 440_000, false), true, 160);
    }

    function test_A2_newOperatorRisk_window() public forkOnly {
        _pauseAll(true);
        _registerNewOperator();
        for (uint256 i; i < operators.length; ++i) {
            _assertOperatorPause(operators[i], true);
        }
        _upgrade(true);
        _probe(_op(NEW_OPERATOR, 440_000, false), false, 0);
        _assertOperatorPause(NEW_OPERATOR, false);
        // Isolate the global stop from 5.5.0's new token/layout requirements.
        _v2ReadyFor(NEW_OPERATOR);
        PackedUserOperation memory migrated = _op(NEW_OPERATOR, 440_000, true);
        _probe(migrated, false, 0);
        uint256 snapshot = vm.snapshot();
        vm.prank(OWNER);
        sp.setGlobalPaused(false);
        _probe(migrated, true, 384);
        assertTrue(vm.revertTo(snapshot), "RAMS: restore global stop after control");
        assertTrue(sp.paused(), "RAMS: new operator globally stopped");
        _assertOperatorPause(NEW_OPERATOR, false);
    }

    function test_A3_atomicUpgradeWithGlobalPause() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        assertEq(sp.owner(), OWNER, "RAMS: owner preserved by atomic delegatecall");
        _assertGas(false);
        uint128[5] memory limits = [uint128(0), 200_000, 300_000, 440_000, type(uint128).max];
        uint256 beforeProbes = sigFailureProbes;
        for (uint256 i; i < operators.length; ++i) {
            for (uint256 j; j < limits.length; ++j) {
                _probe(_op(operators[i], limits[j], false), false, 0);
            }
        }
        assertEq(sigFailureProbes - beforeProbes, operators.length * limits.length, "RAMS: all operator classes probed");
        PackedUserOperation memory unknown = _op(OWNER, 300_000, false);
        unknown.paymasterAndData =
            abi.encodePacked(SP, uint128(1_150_000), uint128(300_000), NEW_OPERATOR, type(uint256).max);
        _probe(unknown, false, 0);
        unknown.paymasterAndData = hex"01";
        _probe(unknown, false, 0); // Pause before parsing, even malformed input.
        _v2Ready();
        vm.prank(OWNER);
        sp.setOperatorPaused(OWNER, false);
        _probe(_op(OWNER, 440_000, true), false, 0);
    }

    function test_A3_emptyUpgradeData_admitsUnsafeLimit() public forkOnly {
        _upgrade(false);
        _assertGas(false);
        _v2Ready();
        vm.prank(OWNER);
        sp.setOperatorPaused(OWNER, false);
        // Hazard prevented by atomic pause: 300k is inside [200k,365k).
        // Admission alone is asserted here; this is NOT a claim that Amsterdam settlement succeeds.
        _probe(_op(OWNER, 300_000, true), true, 384);
    }

    struct BundleResult {
        uint256 events;
        uint256 sponsored;
        uint256 invalidContexts;
        uint256 cost;
    }

    function _run(PackedUserOperation[] memory ops, bool[] memory wanted) internal returns (BundleResult memory r) {
        bytes32[] memory hashes = new bytes32[](ops.length);
        bool[] memory seen = new bool[](ops.length);
        for (uint256 i; i < ops.length; ++i) {
            hashes[i] = ep.getUserOpHash(ops[i]);
        }
        vm.recordLogs();
        ep.handleOps(ops, payable(address(0xBEEF)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == EP && logs[i].topics[0] == USER_EVENT) {
                bool matched;
                for (uint256 j; j < hashes.length; ++j) {
                    if (logs[i].topics[1] == hashes[j]) {
                        require(!seen[j], "RAMS: duplicate UserOperationEvent");
                        seen[j] = true;
                        matched = true;
                        (, bool ok, uint256 cost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                        assertEq(ok, wanted[j], "RAMS: bundle success mismatch");
                        assertGt(cost, 0, "RAMS: no gas charged");
                        r.cost += cost;
                        ++r.events;
                    }
                }
                require(matched, "RAMS: unexpected UserOperationEvent");
            } else if (logs[i].emitter == EP && logs[i].topics[0] == POST_REVERT) {
                (, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IEntryPoint.PostOpReverted.selector,
                        abi.encodeWithSelector(SuperPaymasterStorage.InvalidContextLength.selector)
                    ),
                    "RAMS: exact legacy postOp failure"
                );
                ++r.invalidContexts;
            } else if (logs[i].emitter == SP && logs[i].topics[0] == SPONSORED) {
                (, uint256 charged) = abi.decode(logs[i].data, (uint256, uint256));
                assertGt(charged, 0, "RAMS: zero settlement");
                ++r.sponsored;
            }
        }
        assertEq(r.events, ops.length, "RAMS: missing bundle result");
    }

    function _settleOne(PackedUserOperation memory op) internal {
        _assertBudget(op);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        bool[] memory wanted = new bool[](1);
        wanted[0] = true;
        uint256 beforeHits = target.hits();
        BundleResult memory r = _run(ops, wanted);
        assertEq(r.invalidContexts, 0, "RAMS: settlement reverted");
        assertEq(r.sponsored, 1, "RAMS: missing settlement");
        assertEq(target.hits(), beforeHits + 1, "RAMS: execution rolled back");
    }

    function test_A4_legacyContexts() public forkOnly {
        _legacyReady(OWNER);
        PackedUserOperation memory op = _op(OWNER, 440_000, false);
        _probe(op, true, 160);
        uint256 beforeBalance = IERC20(_token(OWNER)).balanceOf(user);
        _settleOne(op); // handleOps validates, executes AND settles before returning.
        assertLt(IERC20(_token(OWNER)).balanceOf(user), beforeBalance, "RAMS: legacy user charged");
        assertEq(sp.version(), "SuperPaymaster-5.4.2", "RAMS: settled on old implementation");
        PackedUserOperation memory signedBeforePause = _op(OWNER, 440_000, false);
        _probe(signedBeforePause, true, 160);
        _pauseAll(true);
        _probe(signedBeforePause, false, 0);
        PackedUserOperation[] memory rejected = new PackedUserOperation[](1);
        rejected[0] = signedBeforePause;
        _mustReject(
            EP,
            abi.encodeCall(ep.handleOps, (rejected, payable(address(0xBEEF)))),
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA34 signature error"),
            "RAMS A4: pre-signed operation escaped pause"
        );
        vm.roll(vm.getBlockNumber() + 1);
        _upgrade(true); // Models the subsequent top-level upgrade; no suspended EntryPoint call exists.
        emit log("Separate handleOps transactions cannot straddle an upgrade: validation and postOp share one call tree.");
    }

    function test_A4_hypotheticalSmartAccountOwner_midBundle() public forkOnly {
        _legacyReady(OWNER);
        PackedUserOperation memory victim = _op(OWNER, 440_000, false);
        _probe(victim, true, 160);
        vm.prank(OWNER);
        sp.transferOwnership(ownerAccount); // 5.4.2 Ownable is SINGLE step.
        assertEq(sp.owner(), ownerAccount, "RAMS: hypothetical account owner");
        PackedUserOperation memory admin;
        admin.sender = ownerAccount;
        admin.nonce = ep.getNonce(ownerAccount, 0);
        admin.callData = abi.encodeCall(
            SimpleAccount.execute,
            (
                SP,
                0,
                abi.encodeWithSignature(
                    "upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("setGlobalPaused(bool)", true)
                )
            )
        );
        admin.accountGasLimits = bytes32(abi.encodePacked(uint128(600_000), uint128(1_500_000)));
        admin.preVerificationGas = 60_000;
        admin.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        admin = _sign(admin, OWNER_KEY);
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = admin;
        ops[1] = victim;
        bool[] memory wanted = new bool[](2);
        wanted[0] = true;
        uint256 initialBalance = IERC20(_token(OWNER)).balanceOf(user);
        (uint128 operatorBefore,,,,,,,,) = sp.operators(OWNER);
        uint256 revenueBefore = sp.protocolRevenue();
        uint256 stranded = _reservation(RamsBudget.maxCost(victim));
        BundleResult memory r = _run(ops, wanted);
        (uint128 operatorAfter,,,,,,,,) = sp.operators(OWNER);
        assertEq(uint256(operatorBefore) - operatorAfter, stranded, "RAMS: legacy validation debit stranded");
        assertEq(sp.protocolRevenue() - revenueBefore, stranded, "RAMS: legacy validation revenue stranded");
        emit log_named_uint("Stranded operator aPNTs (token wei)", stranded);
        emit log_named_uint("Protocol revenue delta (token wei)", sp.protocolRevenue() - revenueBefore);
        _assertUpgrade(true);
        assertEq(r.invalidContexts, 1, "RAMS: 160B context must fail after upgrade");
        assertEq(r.sponsored, 0, "RAMS: no legacy settlement on new implementation");
        assertEq(target.hits(), 0, "RAMS: victim execution rolled back");
        assertEq(IERC20(_token(OWNER)).balanceOf(user), initialBalance, "RAMS: victim not charged");
        emit log("Counterfactual ownership only. EOA cannot be this account; Safe-only executor blocks arbitrary account calls (A6). Safe AA modules/delegation must remain excluded operationally.");
    }

    function test_A5_governanceTimeline_EOAowner() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        uint256 eta = _queue();
        vm.prank(OWNER);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams();
        vm.warp(eta - 1);
        vm.prank(OWNER);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams();
        assertTrue(sp.paused(), "RAMS: pause holds through internal timelock");
        _assertGas(false);
        vm.warp(eta);
        vm.prank(OWNER);
        (bool activated,) = SP.call(abi.encodeWithSignature("executeGasParams()"));
        require(activated, "RAMS A5: activation not mature");
        _assertGas(true);
        _freshPrice();
        xPNTsTokenV2 token = _v2Ready();
        _pauseAll(false);
        vm.prank(OWNER);
        sp.setGlobalPaused(false);
        assertFalse(sp.paused(), "RAMS: resumed only after gas read-back");
        PackedUserOperation memory op = _op(OWNER, 440_000, true);
        _probe(op, true, 384);
        bytes32 hash = ep.getUserOpHash(op);
        _settleOne(op); // The orchestrator must run under nightly --hardfork amsterdam.
        assertTrue(token.usedOpHashes(hash), "RAMS: V2 token settlement read-back");
        _probe(_op(OWNER, 300_000, true), false, 0);
    }

    /// @dev Threshold analysis for this real V2 fixture, not a universal token gas bound.
    function test_A5b_settleBindingAnalysis() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        _v2Ready();
        uint32[2] memory bounds = [uint32(420_000), uint32(160_000)];
        for (uint256 i; i < bounds.length; ++i) {
            uint256 branch = vm.snapshot();
            vm.prank(OWNER);
            sp.queueGasParams(440_000, bounds[i], 5000, 340_000);
            (, SuperPaymasterStorage.PendingGasParams memory q) = sp.gasParams();
            vm.warp(q.eta);
            vm.prank(OWNER);
            sp.executeGasParams();
            (SuperPaymasterStorage.GasParams memory active,) = sp.gasParams();
            assertEq(active.settleGasBound, bounds[i], "RAMS: analysis SETTLE activated");
            _freshPrice();
            _pauseAll(false);
            vm.prank(OWNER);
            sp.setGlobalPaused(false);
            PackedUserOperation memory op = _op(OWNER, 440_000, true);
            uint256 validationSnapshot = vm.snapshot();
            bytes32 opHash = ep.getUserOpHash(op);
            vm.prank(EP);
            (bytes memory context, uint256 vd) = sp.validatePaymasterUserOp(op, opHash, RamsBudget.maxCost(op));
            assertEq(uint160(vd), 0, "RAMS: analysis minimum admitted");
            // Binary-search callback success threshold with the same reserved context.
            // Each attempt rolls back settlement; gas is the only varied input.
            uint256 low;
            uint256 high = 600_000;
            assertTrue(_postOpAtGas(context, high), "RAMS: analysis upper control");
            while (high - low > 1) {
                uint256 mid = (high + low) / 2;
                if (_postOpAtGas(context, mid)) high = mid;
                else low = mid;
            }
            emit log_named_uint("Analysis SETTLE", bounds[i]);
            emit log_named_uint("Synthetic callback guard crossing (not settlement exhaustion)", high);
            emit log_named_uint("Synthetic guard overhead including call/EIP-150", high - bounds[i]);
            assertTrue(vm.revertTo(validationSnapshot), "RAMS: restore before minimum handleOps control");
            _settleOne(op); // Real EntryPoint forwarding at the smallest admissible limit, for BOTH tuples.
            assertTrue(vm.revertTo(branch), "RAMS: analysis branch rollback");
        }
    }

    function test_A5c_handleOps_minBoundaries() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        _v2Ready();
        uint256 eta = _queue();
        vm.warp(eta);
        vm.prank(OWNER);
        sp.executeGasParams();
        _freshPrice();
        _pauseAll(false);
        vm.prank(OWNER);
        sp.setGlobalPaused(false);
        PackedUserOperation[] memory rejected = new PackedUserOperation[](1);
        rejected[0] = _op(OWNER, 439_999, true);
        _mustReject(
            EP,
            abi.encodeCall(ep.handleOps, (rejected, payable(address(0xBEEF)))),
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA34 signature error"),
            "RAMS A5c: MIN-1 admitted"
        );
        emit log("RAMS A5c: 439,999 rejected with AA34 signature error");
        _settleOne(_op(OWNER, 440_000, true));
        emit log("RAMS A5c: 440,000 executed and settled");
        _settleOne(_op(OWNER, 440_001, true));
        emit log("RAMS A5c: 440,001 executed and settled");
    }

    function test_A3b_probeOnly_globalPause() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        _v2Ready();
        vm.prank(OWNER);
        sp.setOperatorPaused(OWNER, false);
        _probe(_op(OWNER, 440_000, true), false, 0);
    }

    function _postOpAtGas(bytes memory context, uint256 gasLimit) internal returns (bool ok) {
        uint256 snapshot = vm.snapshot();
        vm.prank(EP);
        (ok,) = SP.call{gas: gasLimit}(
            abi.encodeCall(sp.postOp, (IPaymaster.PostOpMode.opSucceeded, context, uint256(100_000), uint256(1)))
        );
        assertTrue(vm.revertTo(snapshot), "RAMS: callback measurement rollback");
    }

    function _timelock() internal returns (TimelockController tl) {
        address[] memory safeOnly = new address[](1);
        safeOnly[0] = SAFE;
        tl = new TimelockController(DELAY, safeOnly, safeOnly, address(0));
        assertEq(tl.getMinDelay(), DELAY, "RAMS: external delay");
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), SAFE), "RAMS: Safe proposer");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), SAFE), "RAMS: Safe executor");
        assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "RAMS: executor must NOT be open");
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), address(0)), "RAMS: no zero proposer");
        address[4] memory excluded = [OWNER, address(this), ownerAccount, address(tl)];
        for (uint256 i; i < excluded.length; ++i) {
            assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), excluded[i]), "RAMS: extra proposer");
            assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), excluded[i]), "RAMS: extra executor");
        }
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), SAFE), "RAMS: no external role admin");
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "RAMS: self-admin only");
    }

    function _transferToTimelock(TimelockController tl) internal {
        vm.prank(sp.owner());
        sp.transferOwnership(address(tl));
        if (sp.owner() != address(tl)) {
            // GOV-2 applies only when transfer happens AFTER the 5.5.0 upgrade.
            assertEq(sp.pendingOwner(), address(tl), "RAMS: two-step pending owner");
            vm.prank(address(tl));
            sp.acceptOwnership();
        }
        assertEq(sp.owner(), address(tl), "RAMS: timelock ownership read-back");
    }

    function _logSafe() internal {
        address cursor = address(1);
        do {
            (address[] memory modules, address next) = RamsSafe(SAFE).getModulesPaginated(cursor, 32);
            for (uint256 i; i < modules.length; ++i) {
                emit log_named_address("Live Safe module", modules[i]);
            }
            emit log_named_uint("Live Safe module page count", modules.length);
            cursor = next;
        } while (cursor != address(1));
        emit log_named_bytes32(
            "Live Safe guard slot", vm.load(SAFE, 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8)
        );
    }

    function test_A6b_safeRoute_preUpgradeGap() public forkOnly {
        _pauseAll(true);
        TimelockController tl = _timelock();
        _transferToTimelock(tl);
        uint256 began = vm.getBlockTimestamp();
        bytes memory upgrade = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("setGlobalPaused(bool)", true)
        );
        bytes32 upgradeSalt = keccak256("RAMS gap upgrade");
        vm.prank(SAFE);
        tl.schedule(SP, 0, upgrade, bytes32(0), upgradeSalt, DELAY);
        vm.warp(began + 1 hours);
        _freshPrice();
        _registerNewOperator(); // Includes real role grants, configureOperator and valid sponsorship probe.
        _settleOne(_op(NEW_OPERATOR, 440_000, false));
        bytes memory pause = abi.encodeWithSignature("setOperatorPaused(address,bool)", NEW_OPERATOR, true);
        bytes32 salt = keccak256("RAMS gap pause");
        vm.prank(SAFE);
        tl.schedule(SP, 0, pause, bytes32(0), salt, DELAY);
        vm.warp(began + DELAY); // The earliest modeled upgrade time, one hour before this pause matures.
        bytes32 pauseId = tl.hashOperation(SP, 0, pause, bytes32(0), salt);
        vm.prank(SAFE);
        _mustReject(
            address(tl),
            abi.encodeCall(tl.execute, (SP, 0, pause, bytes32(0), salt)),
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                pauseId,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            ),
            "RAMS A6b: new operator pause unexpectedly ready"
        );
        _freshPrice();
        uint256 gapSnapshot = vm.snapshot();
        PackedUserOperation memory gapOp = _op(NEW_OPERATOR, 440_000, false);
        bytes32 gapHash = ep.getUserOpHash(gapOp);
        vm.prank(EP);
        (bytes memory gapContext, uint256 gapValidation) =
            sp.validatePaymasterUserOp(gapOp, gapHash, RamsBudget.maxCost(gapOp));
        require(uint160(gapValidation) == 0 && gapContext.length == 160, "RAMS A6b: new operator sponsored in gap");
        assertTrue(vm.revertTo(gapSnapshot), "RAMS A6b: gap probe rollback");
        vm.prank(SAFE);
        tl.execute(SP, 0, upgrade, bytes32(0), upgradeSalt);
        _assertUpgrade(true);
        _probe(_op(NEW_OPERATOR, 440_000, false), false, 0);
        emit log_named_uint("Safe route pre-upgrade hours", (vm.getBlockTimestamp() - began) / 1 hours);
    }

    function test_A6c_registryRegistrationStop() public forkOnly {
        _pauseAll(true);
        TimelockController tl = _timelock();
        _transferToTimelock(tl);
        RamsRegistry reg = RamsRegistry(REGISTRY);
        IRegistry.RoleConfig memory config = reg.getRoleConfig(SUPER);
        emit log_named_address("Live Registry owner", reg.owner());
        emit log_named_address("Live PAYMASTER_SUPER config owner", config.owner);
        bytes memory registration = abi.encodeCall(reg.registerRole, (SUPER, NEW_OPERATOR, abi.encode(config.minStake)));
        uint256 controlSnapshot = vm.snapshot();
        vm.prank(NEW_OPERATOR);
        (bool controlOk, bytes memory controlData) = REGISTRY.call(registration);
        if (controlOk) {
            assertTrue(sp.REGISTRY().hasRole(SUPER, NEW_OPERATOR), "RAMS A6c: control grant missing");
            emit log("RAMS A6c: pre-freeze registerRole succeeded");
        } else {
            bytes4 selector;
            if (controlData.length >= 4) {
                assembly { selector := mload(add(controlData, 32)) }
            }
            assertTrue(
                selector != bytes4(keccak256("RoleNotConfigured(bytes32,bool)")), "RAMS A6c: control role inactive"
            );
            emit log_named_bytes("RAMS A6c: pre-freeze registerRole revert", controlData);
        }
        assertTrue(vm.revertTo(controlSnapshot), "RAMS A6c: control rollback");
        config.isActive = false;
        vm.prank(reg.owner());
        reg.configureRole(SUPER, config);
        assertFalse(reg.getRoleConfig(SUPER).isActive, "RAMS: role stop read-back");
        vm.prank(NEW_OPERATOR);
        _mustReject(
            REGISTRY,
            registration,
            abi.encodeWithSignature("RoleNotConfigured(bytes32,bool)", SUPER, false),
            "RAMS A6c: post-freeze RoleNotConfigured required"
        );
        assertTrue(sp.REGISTRY().hasRole(SUPER, OWNER), "RAMS: stop does not revoke existing grants");
    }

    function test_A6d_EOAfirst_thenTimelock() public forkOnly {
        uint256 pausedAt = vm.getBlockTimestamp();
        _pauseAll(true);
        _upgrade(true);
        emit log_named_uint("EOA-first modeled pre-upgrade seconds", vm.getBlockTimestamp() - pausedAt);
        uint256 eta = _queue(); // EOA queues while still owner, immediately after upgrade.
        TimelockController tl = _timelock();
        vm.prank(OWNER);
        sp.transferOwnership(address(tl));
        assertEq(sp.pendingOwner(), address(tl), "RAMS: pending timelock");
        uint256 snapshot = vm.snapshot();
        _acceptAndActivate(tl, eta, pausedAt, false);
        assertTrue(vm.revertTo(snapshot), "RAMS: EOA-first branch rollback");
        _acceptAndActivate(tl, eta, pausedAt, true);
    }

    function _acceptAndActivate(TimelockController tl, uint256 eta, uint256 pausedAt, bool sequential) internal {
        if (sequential) vm.warp(eta);
        address[] memory targets = new address[](2);
        targets[0] = SP;
        targets[1] = SP;
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature("acceptOwnership()");
        data[1] = abi.encodeWithSignature("executeGasParams()");
        bytes32 salt = keccak256(abi.encode("RAMS EOA handover", sequential));
        vm.prank(SAFE);
        tl.scheduleBatch(targets, values, data, bytes32(0), salt, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(SAFE);
        tl.executeBatch(targets, values, data, bytes32(0), salt);
        assertEq(sp.owner(), address(tl), "RAMS: accepted timelock owner");
        _assertGas(true);
        assertTrue(sp.paused(), "RAMS: handover preserves pause");
        assertEq(vm.getBlockTimestamp() - pausedAt, sequential ? 96 hours : 48 hours, "RAMS: EOA-first downtime");
        emit log_named_uint(
            "EOA-first total downtime hours (through gas activation)", (vm.getBlockTimestamp() - pausedAt) / 1 hours
        );
    }

    function test_A6_governanceTimeline_SafeTimelock() public forkOnly {
        _logSafe();
        _pauseAll(true);
        TimelockController tl = _timelock();
        _transferToTimelock(tl); // Live 5.4.2 transfer completes in one step.
        address[] memory targets = new address[](2);
        targets[0] = SP;
        targets[1] = SP;
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("setGlobalPaused(bool)", true)
        );
        data[1] = abi.encodeWithSignature(
            "queueGasParams(uint32,uint32,uint32,uint32)",
            uint32(440_000),
            uint32(420_000),
            uint32(5000),
            uint32(340_000)
        );
        bytes32 salt = keccak256("RAMS A6 upgrade and queue");
        bytes32 batchId = tl.hashOperationBatch(targets, values, data, bytes32(0), salt);
        uint256 scheduled = vm.getBlockTimestamp();
        vm.prank(SAFE);
        tl.scheduleBatch(targets, values, data, bytes32(0), salt, DELAY);
        assertEq(tl.getTimestamp(batchId), scheduled + DELAY, "RAMS: batch ETA");
        assertTrue(tl.isOperationPending(batchId), "RAMS: batch pending");
        vm.warp(scheduled + DELAY - 1);
        vm.prank(SAFE);
        _mustReject(
            address(tl),
            abi.encodeCall(tl.executeBatch, (targets, values, data, bytes32(0), salt)),
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                batchId,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            ),
            "RAMS A6: upgrade batch executed before delay"
        );
        vm.warp(scheduled + DELAY);
        vm.prank(ownerAccount);
        _mustReject(
            address(tl),
            abi.encodeCall(tl.executeBatch, (targets, values, data, bytes32(0), salt)),
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", ownerAccount, keccak256("EXECUTOR_ROLE")
            ),
            "RAMS A6: non-Safe executor accepted"
        );
        vm.prank(SAFE);
        tl.executeBatch(targets, values, data, bytes32(0), salt);
        assertTrue(tl.isOperationDone(batchId), "RAMS: upgrade batch done");
        _assertUpgrade(true);
        assertEq(sp.owner(), address(tl), "RAMS: governance owner preserved");
        assertEq(sp.pendingOwner(), address(0), "RAMS: no pending governance owner");
        uint256 upgradedAt = vm.getBlockTimestamp();
        uint256 eta = _queuedReadback();
        _assertGas(false);
        uint256 snapshot = vm.snapshot();
        // Already on 5.5.0: queue from the completed preparation batch is live.
        // A second real upgrade/queue batch is pending, so selector readiness cannot mask its dependency.
        bytes32 replaySalt = keccak256("RAMS predecessor batch");
        bytes32 requiredBatch = tl.hashOperationBatch(targets, values, data, bytes32(0), replaySalt);
        vm.prank(SAFE);
        tl.scheduleBatch(targets, values, data, bytes32(0), replaySalt, DELAY);
        bytes memory activation = abi.encodeWithSignature("executeGasParams()");
        bytes32 activationSalt = keccak256("RAMS predecessor negative");
        bytes32 requiredPredecessor = requiredBatch;
        vm.prank(SAFE);
        tl.schedule(SP, 0, activation, requiredPredecessor, activationSalt, DELAY);
        vm.warp(eta);
        vm.prank(SAFE);
        (bool premature, bytes memory predecessorReason) =
            address(tl).call(abi.encodeCall(tl.execute, (SP, 0, activation, requiredPredecessor, activationSalt)));
        assertFalse(premature, "RAMS: TimelockUnexecutedPredecessor required");
        assertEq(
            predecessorReason,
            abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, requiredBatch),
            "RAMS: exact TimelockUnexecutedPredecessor"
        );
        vm.prank(SAFE);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, requiredBatch)
        );
        tl.execute(SP, 0, activation, requiredPredecessor, activationSalt);
        assertTrue(vm.revertTo(snapshot), "RAMS: predecessor branch rollback");
        snapshot = vm.snapshot();
        _activateViaTimelock(tl, batchId, eta, upgradedAt, false);
        emit log_named_uint("Safe total downtime hours", (vm.getBlockTimestamp() - scheduled) / 1 hours);
        assertTrue(vm.revertTo(snapshot), "RAMS: timeline branch rollback");
        _activateViaTimelock(tl, batchId, eta, upgradedAt, true);
        emit log_named_uint("Safe total downtime hours", (vm.getBlockTimestamp() - scheduled) / 1 hours);
    }

    function _activateViaTimelock(
        TimelockController tl,
        bytes32 predecessor,
        uint256 eta,
        uint256 upgradedAt,
        bool sequential
    ) internal {
        if (sequential) vm.warp(eta); // Waste the internal wait before scheduling the external wait.
        uint256 scheduled = vm.getBlockTimestamp();
        bytes memory data = abi.encodeWithSignature("executeGasParams()");
        bytes32 salt = keccak256(abi.encode("RAMS activation", sequential));
        bytes32 id = tl.hashOperation(SP, 0, data, predecessor, salt);
        vm.prank(SAFE);
        tl.schedule(SP, 0, data, predecessor, salt, DELAY);
        uint256 earliest = scheduled + DELAY > eta ? scheduled + DELAY : eta;
        assertEq(tl.getTimestamp(id), scheduled + DELAY, "RAMS: activation external ETA");
        assertEq(earliest - upgradedAt, sequential ? 96 hours : 48 hours, "RAMS: parallel vs sequential delay");
        vm.warp(earliest - 1);
        vm.prank(SAFE);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            )
        );
        tl.execute(SP, 0, data, predecessor, salt);
        vm.warp(earliest);
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", OWNER, keccak256("EXECUTOR_ROLE")
            )
        );
        tl.execute(SP, 0, data, predecessor, salt);
        vm.prank(SAFE);
        tl.execute(SP, 0, data, predecessor, salt);
        assertTrue(tl.isOperationDone(id), "RAMS: activation done");
        _assertGas(true);
        assertTrue(sp.paused(), "RAMS: activation does not implicitly resume");
        emit log_named_uint(
            sequential ? "Sequential hours AFTER upgrade" : "Parallel hours AFTER upgrade",
            (vm.getBlockTimestamp() - upgradedAt) / 1 hours
        );
    }

    struct Gate {
        address implementation;
        bytes32 runtimeHash;
        address owner;
        address guardian;
        bool paused;
        bytes32 gasHash;
        bytes32 pendingHash;
        address[] inventory;
        bool[] operatorPauses;
        TimelockController timelock;
        bytes32 operation;
        TimelockController.OperationState state;
        uint256 timestamp;
    }

    /// @notice Fail-closed read-back gate: explicit zero guardian is valid; omitted identity/inventory is not.
    function readbackGate(Gate calldata g) external view {
        require(
            g.implementation != address(0) && g.runtimeHash != bytes32(0), "RAMS gate: missing implementation identity"
        );
        address actual = address(uint160(uint256(vm.load(SP, IMPL_SLOT))));
        require(actual == g.implementation, "RAMS gate: implementation");
        require(actual.code.length != 0 && actual.codehash == g.runtimeHash, "RAMS gate: runtime codehash");
        require(keccak256(bytes(sp.version())) == keccak256("SuperPaymaster-5.5.0"), "RAMS gate: version");
        require(g.owner != address(0) && sp.owner() == g.owner, "RAMS gate: owner");
        require(sp.guardian() == g.guardian, "RAMS gate: guardian");
        require(sp.paused() == g.paused, "RAMS gate: global pause");
        (SuperPaymasterStorage.GasParams memory p, SuperPaymasterStorage.PendingGasParams memory q) = sp.gasParams();
        require(g.gasHash != bytes32(0) && keccak256(abi.encode(p)) == g.gasHash, "RAMS gate: gas parameters");
        require(
            g.pendingHash != bytes32(0) && keccak256(abi.encode(q)) == g.pendingHash, "RAMS gate: pending parameters"
        );
        require(g.inventory.length != 0 && g.operatorPauses.length == g.inventory.length, "RAMS gate: inventory length");
        require(keccak256(abi.encode(g.inventory)) == inventoryHash, "RAMS gate: inventory commitment");
        for (uint256 i; i < g.inventory.length; ++i) {
            (, bool configured, bool stopped,,,,,,) = sp.operators(g.inventory[i]);
            require(configured, "RAMS gate: operator missing");
            require(stopped == g.operatorPauses[i], "RAMS gate: operator pause");
        }
        require(
            address(g.timelock).code.length != 0 && g.operation != bytes32(0) && g.timestamp != 0
                && g.state != TimelockController.OperationState.Unset,
            "RAMS gate: missing timelock operation"
        );
        require(
            g.timelock.getOperationState(g.operation) == g.state && g.timelock.getTimestamp(g.operation) == g.timestamp,
            "RAMS gate: timelock operation"
        );
    }

    function _tamper(Gate memory g, address account, bytes32 slot, bytes32 bad, string memory reason) internal {
        bytes32 original = vm.load(account, slot);
        require(original != bad, "RAMS: negative control did not change storage");
        vm.store(account, slot, bad);
        _mustReject(
            address(this),
            abi.encodeCall(this.readbackGate, (g)),
            abi.encodeWithSignature("Error(string)", reason),
            string.concat("RAMS gate negative: ", reason)
        );
        vm.store(account, slot, original);
        this.readbackGate(g);
    }

    function test_A7_readbackGate() public forkOnly {
        _pauseAll(true);
        _upgrade(true);
        uint256 eta = _queue();
        vm.warp(eta);
        vm.prank(OWNER);
        sp.executeGasParams();
        _assertGas(true);
        TimelockController tl = _timelock();
        _transferToTimelock(tl); // Also rehearses the NEW two-step ownership transfer.
        bytes memory data = abi.encodeWithSignature("setGlobalPaused(bool)", false);
        bytes32 salt = keccak256("RAMS gate operation");
        bytes32 id = tl.hashOperation(SP, 0, data, bytes32(0), salt);
        vm.prank(SAFE);
        tl.schedule(SP, 0, data, bytes32(0), salt, DELAY);
        Gate memory g;
        g.implementation = newImpl;
        g.runtimeHash = newHash;
        g.owner = address(tl);
        g.guardian = address(0);
        g.paused = true;
        g.gasHash = keccak256(abi.encode(SuperPaymasterStorage.GasParams(440_000, 420_000, 5000, 340_000)));
        g.pendingHash = keccak256(abi.encode(SuperPaymasterStorage.PendingGasParams(0, 0, 0, 0, 0)));
        g.inventory = vm.envAddress("OPERATORS", ",");
        g.operatorPauses = new bool[](operators.length);
        for (uint256 i; i < operators.length; ++i) {
            g.operatorPauses[i] = true;
        }
        g.timelock = tl;
        g.operation = id;
        g.state = TimelockController.OperationState.Waiting;
        g.timestamp = vm.getBlockTimestamp() + DELAY;
        this.readbackGate(g);
        for (uint256 i; i < 4; ++i) {
            _tamper(
                g,
                SP,
                bytes32(gpSlot),
                vm.load(SP, bytes32(gpSlot)) ^ bytes32(uint256(1) << (32 * i)),
                "RAMS gate: gas parameters"
            );
        }
        _tamper(g, SP, bytes32(pendingSlot), bytes32(uint256(1)), "RAMS gate: pending parameters");
        uint256 ownerSlot = stdstore.target(SP).sig("owner()").find();
        _tamper(g, SP, bytes32(ownerSlot), bytes32(uint256(uint160(OWNER))), "RAMS gate: owner");
        _tamper(g, SP, bytes32(pauseSlot), vm.load(SP, bytes32(pauseSlot)) | bytes32(uint256(1)), "RAMS gate: guardian");
        _tamper(
            g,
            SP,
            bytes32(pauseSlot),
            vm.load(SP, bytes32(pauseSlot)) ^ bytes32(uint256(1) << 160),
            "RAMS gate: global pause"
        );
        _tamper(g, SP, IMPL_SLOT, bytes32(uint256(uint160(address(target)))), "RAMS gate: implementation");
        for (uint256 i; i < operators.length; ++i) {
            bytes32 slot = keccak256(abi.encode(operators[i], opSlot));
            _tamper(g, SP, slot, vm.load(SP, slot) ^ bytes32(uint256(1) << 136), "RAMS gate: operator pause");
            _tamper(g, SP, slot, vm.load(SP, slot) ^ bytes32(uint256(1) << 128), "RAMS gate: operator missing");
        }
        uint256 timestampSlot = stdstore.target(address(tl)).sig("getTimestamp(bytes32)").with_key(id).find();
        _tamper(g, address(tl), bytes32(timestampSlot), bytes32(0), "RAMS gate: timelock operation");
        // Code is not storage: vm.etch is required for this negative control, not vm.store.
        bytes memory originalCode = newImpl.code;
        vm.etch(newImpl, hex"00");
        vm.expectRevert(bytes("RAMS gate: runtime codehash"));
        this.readbackGate(g);
        vm.etch(newImpl, originalCode);
        this.readbackGate(g);
        g.runtimeHash = bytes32(0);
        vm.expectRevert(bytes("RAMS gate: missing implementation identity"));
        this.readbackGate(g);
        g.runtimeHash = newHash;
        g.inventory = new address[](0);
        vm.expectRevert(bytes("RAMS gate: inventory length"));
        this.readbackGate(g);
        g.inventory = vm.envAddress("OPERATORS", ",");
        g.operation = bytes32(0);
        vm.expectRevert(bytes("RAMS gate: missing timelock operation"));
        this.readbackGate(g);
    }
}
