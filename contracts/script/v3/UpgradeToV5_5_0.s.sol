// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// NOTE: deliberately does NOT import src/core/Registry.sol. foundry.toml's Registry
// compilation_restriction compiles every file that imports Registry.sol — and that file's whole
// closure — under the runs=200 "registry-size" profile, so `new SuperPaymaster(...)` here would
// ship different bytes from the profile.default artifact that the 5.5.0 size/ABI evidence was
// measured on. Step 5 asserts which artifact the new implementation matches.
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {IStakeManager} from "@account-abstraction-v7/interfaces/IStakeManager.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {V55Bootstrap, IxPNTsV2Script} from "./V55Bootstrap.sol";

/// @dev 5.4.2 surface that 5.5.0 removed (runbook steps 0 and 2 run BEFORE the upgrade).
interface ISP542Legacy {
    function pendingDebts(address token, address user) external view returns (uint256);
    function clearPendingDebt(address token, address user) external;
}

interface IBLSPtr {
    function blsAggregator() external view returns (address);
    function BLS_AGGREGATOR() external view returns (address);
}

/**
 * @title UpgradeToV5_5_0
 * @notice SuperPaymaster 5.4.2 -> 5.5.0 (AOA balance mode) + xPNTs v2 stack, for an EXISTING
 *         deployment (the Sepolia layout: SP proxy at 5.4.2). Implements runbook
 *         docs/design/aoa-balance-mode/03-final-spec.md §6 steps 4–7c; steps 0–3 are exposed as
 *         separate operational entry points (rehearsed in D5.3).
 *
 * Entry points (all read back and `require` the state they claim; all idempotent):
 *   inventory(address[] operators)                     step 0 (view)
 *   inventoryDebts(address[] tokens, address[] users)  step 0 (view, pendingDebts on 5.4.2)
 *   executePendingAPNTs()   step 1, branch A  ── AUTHOR DECISION REQUIRED
 *   cancelPendingAPNTs()    step 1, branch B  ── AUTHOR DECISION REQUIRED
 *                           Both refuse to run unless V55_APNTS_DECISION=execute|cancel matches.
 *   clearPendingDebts(address[] tokens, address[] users)  step 2 (D-21 write-off, 5.4.2 only)
 *   pauseOperators(address[] ops)                      step 3
 *   run()                   steps 4 → 5 → 5b → 6 (SP owner broadcasts)
 *   ensureStake()           step 5b alone: SP EntryPoint stake >= V55_MIN_STAKE_WEI (default
 *                           1 ether), unstakeDelaySec >= V55_MIN_UNSTAKE_DELAY (default 86400),
 *                           not unlocking (bundler staked-paymaster threshold; DSR D-9 adjustment)
 *   issueCommunityToken(name, symbol, communityName, ens, rate)   step 7a (community broadcasts)
 *   configureOperatorV2(token, treasury)               step 7c-1 (operator broadcasts;
 *                                                      updatePrice + read-back FIRST)
 *   unpauseOperator(address op)                        step 7c-2 (SP owner broadcasts)
 *
 * Preconditions checked by run() (runbook 1 and 3): pendingAPNTsToken == 0 and every operator
 * listed in V55_OPERATORS (comma-separated) paused. V55_REHEARSAL_SKIP_PRECONDITIONS=true lets a
 * FORK rehearsal proceed without having taken the step-1 decision; it is logged loudly and must
 * never be set for a real network.
 *
 * Config: reads deployments/config.<ENV>.json (ENV default "sepolia"). New keys
 * (aoaProtocolRegistry, globalTierSource, xPNTsTokenV2Ext, xPNTsTokenV2Impl, xPNTsFactoryV2,
 * superPaymasterLens, spImpl) are written ONLY when V55_OUT_CONFIG names a file (path relative
 * to the project root; it is created from the input config if missing). Nothing is ever deleted.
 *
 * Fork rehearsal (never the public RPC):
 *   anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com --port 28546
 *   cast rpc anvil_impersonateAccount <SP owner> --rpc-url http://127.0.0.1:28546
 *   ENV=sepolia V55_OUT_CONFIG=cache/d5-rehearsal/config.sepolia-fork.json \
 *   forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 \
 *     --rpc-url http://127.0.0.1:28546 --unlocked --sender <SP owner> --broadcast
 */
contract UpgradeToV5_5_0 is V55Bootstrap {
    string internal constant FROM_VERSION = "SuperPaymaster-5.4.2";
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev SP layout (5.5.0 storageLayout): slots 0..37 used, __gap[27] = 38..64. Snapshot well
    ///      past the end; an impl swap with empty call data must leave every one of them untouched.
    uint256 internal constant SNAPSHOT_SLOTS = 96;

    struct Addrs {
        address sp;
        address registry;
        address entryPoint;
        address priceFeed;
        address dvt;
        address blsAggregatorCfg;
    }

    struct PreState {
        string version;
        address impl;
        address owner;
        address registryImm;
        address feedImm;
        address entryPointImm;
        address apnts;
        address xpntsFactory;
        address treasury;
        address blsSP;
        address blsRegistry;
        address blsDVT;
        uint256 fee;
        uint256 aPriceUSD;
        uint256 staleness;
        uint256 tracked;
        uint256 revenue;
        address pendingAPNTs;
        uint256 epDeposit;
        uint112 epStake;
        bool epStaked;
        bytes32[] slots;
        // mapping samples (values live at hashed slots the raw scan does not cover)
        address[] sampleUsers;
        address sampleOp;
        bool[] sampleSbt;
        bool[] sampleBlocked;
        uint48[] sampleLast;
    }

    // =====================================================================
    // Config
    // =====================================================================

    function _network() internal view returns (string memory) {
        return vm.envOr("ENV", string("sepolia"));
    }

    function _configJson() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", _network(), ".json"));
    }

    function _addrs() internal view returns (Addrs memory a) {
        string memory j = _configJson();
        a.sp = vm.parseJsonAddress(j, ".superPaymaster");
        a.registry = vm.parseJsonAddress(j, ".registry");
        a.entryPoint = vm.parseJsonAddress(j, ".entryPoint");
        a.priceFeed = vm.parseJsonAddress(j, ".priceFeed");
        a.dvt = _optAddrV55(j, ".dvtValidator");
        a.blsAggregatorCfg = _optAddrV55(j, ".blsAggregator");
    }

    function _outPath() internal view returns (string memory) {
        string memory rel = vm.envOr("V55_OUT_CONFIG", string(""));
        if (bytes(rel).length == 0) return "";
        return string.concat(vm.projectRoot(), "/", rel);
    }

    /// @dev Resume source: the output config if it already has v2 keys, else the input config.
    function _prevStack() internal view returns (V55Stack memory st) {
        string memory out = _outPath();
        if (bytes(out).length != 0) {
            try vm.readFile(out) returns (string memory j) {
                st = _stackFromConfig(j);
                if (st.factory != address(0)) return st;
            } catch {}
        }
        st = _stackFromConfig(_configJson());
    }

    function _factoryV2() internal view returns (address f) {
        f = _prevStack().factory;
        require(f != address(0), "V55: no xPNTsFactoryV2 in config (run() first, with V55_OUT_CONFIG)");
    }

    // =====================================================================
    // Step 0 — inventory (view)
    // =====================================================================

    function inventory(address[] calldata ops) external view {
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        console.log("=== Step 0: inventory ===");
        console.log("  SP proxy          :", a.sp);
        console.log("  version           :", sp.version());
        console.log("  impl              :", address(uint160(uint256(vm.load(a.sp, ERC1967_IMPL_SLOT)))));
        console.log("  owner             :", sp.owner());
        console.log("  APNTS_TOKEN       :", sp.APNTS_TOKEN());
        console.log("  pendingAPNTsToken :", sp.pendingAPNTsToken());
        console.log("  pendingAPNTsEta   :", sp.pendingAPNTsTokenEta());
        console.log("  xpntsFactory      :", sp.xpntsFactory());
        (int256 price, uint256 updatedAt,,) = sp.cachedPrice();
        console.log("  cachedPrice       :", uint256(price));
        console.log("  cachedUpdatedAt   :", updatedAt);
        console.log("  staleness (s)     :", sp.priceStalenessThreshold());
        console.log("  block.timestamp   :", block.timestamp);
        console.log("  totalTracked      :", sp.totalTrackedBalance());
        console.log("  protocolRevenue   :", sp.protocolRevenue());
        IStakeManager.DepositInfo memory d = IEntryPoint(a.entryPoint).getDepositInfo(a.sp);
        console.log("  EP deposit / stake:", d.deposit, uint256(d.stake));
        console.log("  EP staked / delay :", d.staked, uint256(d.unstakeDelaySec));
        for (uint256 i; i < ops.length; ++i) {
            (uint128 bal, bool cfg, bool paused, address tok,,,,,) = sp.operators(ops[i]);
            console.log("  operator", ops[i]);
            console.log("    configured/paused:", cfg, paused);
            console.log("    aPNTsBalance     :", uint256(bal));
            console.log("    token            :", tok);
            (bool ok, bytes memory ret) = tok.staticcall(abi.encodeWithSignature("BALANCE_MODE_VERSION()"));
            console.log("    token is v2      :", ok && ret.length == 32 && abi.decode(ret, (uint16)) == 1);
        }
    }

    /// @notice Step 0/2: pendingDebts for (token, user) pairs found by the D5.3 log scan
    ///         (DebtRecordFailed events). Only meaningful on 5.4.2 (the getter is gone in 5.5.0).
    function inventoryDebts(address[] calldata tokens, address[] calldata users) external view {
        require(tokens.length == users.length, "V55: length mismatch");
        Addrs memory a = _addrs();
        require(_strEq(SuperPaymaster(payable(a.sp)).version(), FROM_VERSION), "V55: pendingDebts getter only on 5.4.2");
        uint256 total;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 d = ISP542Legacy(a.sp).pendingDebts(tokens[i], users[i]);
            total += d;
            console.log("  pendingDebts", tokens[i], users[i], d);
        }
        console.log("  total pendingDebts:", total);
    }

    // =====================================================================
    // Step 1 — pending aPNTs switch: AUTHOR DECISION REQUIRED (do not pick a branch here)
    // =====================================================================

    /// @notice Branch A. AUTHOR DECISION REQUIRED — refuses unless V55_APNTS_DECISION=execute.
    ///         5.4.2 executeAPNTsTokenChange requires the timelock elapsed AND
    ///         totalTrackedBalance == protocolRevenue <= 0.1 ether (every operator drained).
    function executePendingAPNTs() external {
        require(_strEq(vm.envOr("V55_APNTS_DECISION", string("")), "execute"), "V55: AUTHOR DECISION REQUIRED (V55_APNTS_DECISION=execute)");
        SuperPaymaster sp = SuperPaymaster(payable(_addrs().sp));
        address pending = sp.pendingAPNTsToken();
        if (pending == address(0)) {
            console.log("  step 1: nothing pending (idempotent no-op)");
            return;
        }
        vm.startBroadcast(sp.owner());
        sp.executeAPNTsTokenChange();
        vm.stopBroadcast();
        require(sp.pendingAPNTsToken() == address(0), "V55 step1 read-back: pendingAPNTsToken != 0");
        require(sp.APNTS_TOKEN() == pending, "V55 step1 read-back: APNTS_TOKEN != executed token");
        console.log("  step 1 (execute): APNTS_TOKEN ->", pending);
    }

    /// @notice Branch B. AUTHOR DECISION REQUIRED — refuses unless V55_APNTS_DECISION=cancel.
    function cancelPendingAPNTs() external {
        require(_strEq(vm.envOr("V55_APNTS_DECISION", string("")), "cancel"), "V55: AUTHOR DECISION REQUIRED (V55_APNTS_DECISION=cancel)");
        SuperPaymaster sp = SuperPaymaster(payable(_addrs().sp));
        address apntsBefore = sp.APNTS_TOKEN();
        vm.startBroadcast(sp.owner());
        sp.cancelAPNTsTokenChange(); // idempotent on the contract side
        vm.stopBroadcast();
        require(sp.pendingAPNTsToken() == address(0), "V55 step1 read-back: pendingAPNTsToken != 0");
        require(sp.pendingAPNTsTokenEta() == 0, "V55 step1 read-back: pendingAPNTsTokenEta != 0");
        require(sp.APNTS_TOKEN() == apntsBefore, "V55 step1 read-back: APNTS_TOKEN moved on cancel");
        console.log("  step 1 (cancel): pendingAPNTsToken cleared, APNTS_TOKEN unchanged:", apntsBefore);
    }

    // =====================================================================
    // Step 2 — pendingDebts write-off (D-21: legacy debt is test data, not migrated)
    // =====================================================================

    function clearPendingDebts(address[] calldata tokens, address[] calldata users) external {
        require(tokens.length == users.length, "V55: length mismatch");
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        require(_strEq(sp.version(), FROM_VERSION), "V55: clearPendingDebt exists only on 5.4.2");
        vm.startBroadcast(sp.owner());
        for (uint256 i; i < tokens.length; ++i) {
            uint256 d = ISP542Legacy(a.sp).pendingDebts(tokens[i], users[i]);
            if (d != 0) {
                ISP542Legacy(a.sp).clearPendingDebt(tokens[i], users[i]);
                console.log("  step 2: written off", tokens[i], users[i], d);
            }
        }
        vm.stopBroadcast();
        for (uint256 i; i < tokens.length; ++i) {
            require(ISP542Legacy(a.sp).pendingDebts(tokens[i], users[i]) == 0, "V55 step2 read-back: pendingDebts != 0");
        }
    }

    // =====================================================================
    // Step 3 — pause every legacy operator
    // =====================================================================

    function pauseOperators(address[] calldata ops) external {
        SuperPaymaster sp = SuperPaymaster(payable(_addrs().sp));
        vm.startBroadcast(sp.owner());
        for (uint256 i; i < ops.length; ++i) {
            (, , bool paused, , , , , ,) = sp.operators(ops[i]);
            if (!paused) sp.setOperatorPaused(ops[i], true);
        }
        vm.stopBroadcast();
        for (uint256 i; i < ops.length; ++i) {
            (, , bool paused, , , , , ,) = sp.operators(ops[i]);
            require(paused, "V55 step3 read-back: operator not paused");
            console.log("  step 3: paused", ops[i]);
        }
    }

    // =====================================================================
    // Steps 4 → 5 → 6
    // =====================================================================

    function run() external {
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        address owner = sp.owner();
        console.log("=== UpgradeToV5_5_0 on", _network(), "===");
        console.log("  SP proxy:", a.sp);
        console.log("  SP owner:", owner);

        _checkPreconditions(sp);
        PreState memory pre = _snapshot(a);
        console.log("  pre version:", pre.version);
        console.log("  pre impl   :", pre.impl);

        // ---------------- Step 4: xPNTs v2 stack ----------------
        console.log("--- Step 4: GlobalTierSource -> AOAProtocolRegistry (bootstrap+seal) -> ext -> template -> factoryV2 -> lens ---");
        vm.startBroadcast(owner);
        V55Stack memory st = _ensureV55Stack(_prevStack(), a.sp, a.registry, owner);
        vm.stopBroadcast();
        _verifyV55Stack(st, a.sp, a.registry);
        require(Ownable(st.aoaRegistry).owner() == owner, "V55 step4 read-back: AOA registry owner");
        require(Ownable(st.factory).owner() == owner, "V55 step4 read-back: factoryV2 owner");

        // ---------------- Step 5: SP impl swap ----------------
        console.log("--- Step 5: new SP impl with the LIVE immutables, upgradeToAndCall ---");
        address newImpl = _step5(a, pre, owner);

        // ---------------- Step 5b: EntryPoint stake for bundler admission ----------------
        console.log("--- Step 5b: SP EntryPoint stake >= target, unstakeDelay >= 86400, locked ---");
        _step5bStake(a.sp, pre.entryPointImm, owner);

        // ---------------- Step 6: SP -> factoryV2 ----------------
        console.log("--- Step 6: setXPNTsFactory(factoryV2) ---");
        vm.startBroadcast(owner);
        _wireSPFactory(a.sp, st.factory);
        vm.stopBroadcast();
        _verifySPFactory(a.sp, st.factory);
        require(_lensAcceptsSP(st.lens, a.sp), "V55 step6 read-back: lens rejects this SP version");

        _writeOut(st, newImpl);
        console.log("=== Steps 4-5b-6 complete; SP version:", sp.version(), "===");
        console.log("NEXT (per community): issueCommunityToken -> configureOperatorV2 -> unpauseOperator (step 7a/7c)");
        console.log("REMINDER: hand AOAProtocolRegistry + xPNTsFactoryV2 ownership to governance;");
        console.log("          notify repo:sdk / repo:dvt (new paymasterAndData, lens, v2 token ABI).");
    }

    function _checkPreconditions(SuperPaymaster sp) internal view {
        bool skip = vm.envOr("V55_REHEARSAL_SKIP_PRECONDITIONS", false);
        address pending = sp.pendingAPNTsToken();
        if (pending != address(0)) {
            if (!skip) revert("V55 precondition (runbook 1): pendingAPNTsToken != 0 - execute or cancel first (author decision)");
            console.log("  !!! REHEARSAL: runbook step 1 NOT done - pendingAPNTsToken =", pending);
            console.log("  !!! its ETA survives the upgrade and stays executable (spec 03 section 3.1)");
        }
        string memory opsCsv = vm.envOr("V55_OPERATORS", string(""));
        if (bytes(opsCsv).length != 0) {
            address[] memory ops = vm.envAddress("V55_OPERATORS", ",");
            for (uint256 i; i < ops.length; ++i) {
                (, bool cfg, bool paused, , , , , ,) = sp.operators(ops[i]);
                if (cfg && !paused) {
                    if (!skip) revert("V55 precondition (runbook 3): a legacy operator is not paused");
                    console.log("  !!! REHEARSAL: operator not paused:", ops[i]);
                }
            }
        } else {
            console.log("  WARN: V55_OPERATORS not set - runbook step 3 (all operators paused) NOT checked");
        }
    }

    function _snapshot(Addrs memory a) internal view returns (PreState memory p) {
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        p.version = sp.version();
        p.impl = address(uint160(uint256(vm.load(a.sp, ERC1967_IMPL_SLOT))));
        p.owner = sp.owner();
        p.registryImm = address(sp.REGISTRY());
        p.feedImm = address(sp.ETH_USD_PRICE_FEED());
        p.entryPointImm = address(sp.entryPoint());
        p.apnts = sp.APNTS_TOKEN();
        p.xpntsFactory = sp.xpntsFactory();
        p.treasury = sp.treasury();
        p.blsSP = sp.BLS_AGGREGATOR();
        p.blsRegistry = IBLSPtr(a.registry).blsAggregator();
        p.blsDVT = a.dvt == address(0) ? address(0) : IBLSPtr(a.dvt).BLS_AGGREGATOR();
        p.fee = sp.protocolFeeBPS();
        p.aPriceUSD = sp.aPNTsPriceUSD();
        p.staleness = sp.priceStalenessThreshold();
        p.tracked = sp.totalTrackedBalance();
        p.revenue = sp.protocolRevenue();
        p.pendingAPNTs = sp.pendingAPNTsToken();
        IStakeManager.DepositInfo memory d = IEntryPoint(p.entryPointImm).getDepositInfo(a.sp);
        p.epDeposit = d.deposit;
        p.epStake = d.stake;
        p.epStaked = d.staked;
        p.slots = new bytes32[](SNAPSHOT_SLOTS);
        for (uint256 i; i < SNAPSHOT_SLOTS; ++i) {
            p.slots[i] = vm.load(a.sp, bytes32(i));
        }
        if (bytes(vm.envOr("V55_SAMPLE_USERS", string(""))).length != 0) {
            p.sampleUsers = vm.envAddress("V55_SAMPLE_USERS", ",");
        } else {
            p.sampleUsers = new address[](0);
        }
        p.sampleOp = vm.envOr("V55_SAMPLE_OPERATOR", address(0));
        uint256 n = p.sampleUsers.length;
        p.sampleSbt = new bool[](n);
        p.sampleBlocked = new bool[](n);
        p.sampleLast = new uint48[](n);
        for (uint256 i; i < n; ++i) {
            p.sampleSbt[i] = sp.sbtHolders(p.sampleUsers[i]);
            (p.sampleLast[i], p.sampleBlocked[i]) = sp.userOpState(p.sampleOp, p.sampleUsers[i]);
        }
        // The immutables that go into the new impl are the LIVE ones, cross-checked with config.
        require(p.registryImm == a.registry, "V55 pre: SP.REGISTRY != config.registry");
        require(p.entryPointImm == a.entryPoint, "V55 pre: SP.entryPoint != config.entryPoint");
        if (p.feedImm != a.priceFeed) console.log("  WARN: SP.ETH_USD_PRICE_FEED != config.priceFeed; using the LIVE value", p.feedImm);
    }

    function _step5(Addrs memory a, PreState memory pre, address owner) internal returns (address newImpl) {
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        if (_strEq(pre.version, SP_V55_VERSION)) {
            newImpl = pre.impl;
            console.log("  SP already at 5.5.0 - impl swap skipped:", newImpl);
        } else {
            require(_strEq(pre.version, FROM_VERSION), "V55 step5: SP is neither 5.4.2 nor 5.5.0");
            vm.startBroadcast(owner);
            SuperPaymaster impl = new SuperPaymaster(IEntryPoint(pre.entryPointImm), IRegistry(pre.registryImm), pre.feedImm);
            vm.stopBroadcast();
            newImpl = address(impl);
            // Pre-swap: the new impl must carry EXACTLY the live immutables and be the right build.
            require(address(impl.REGISTRY()) == pre.registryImm, "V55 step5 pre-swap: impl REGISTRY");
            require(address(impl.ETH_USD_PRICE_FEED()) == pre.feedImm, "V55 step5 pre-swap: impl price feed");
            require(address(impl.entryPoint()) == pre.entryPointImm, "V55 step5 pre-swap: impl entryPoint");
            require(_strEq(impl.version(), SP_V55_VERSION), "V55 step5 pre-swap: impl version");
            require(newImpl.code.length <= 24_576, "V55 step5 pre-swap: impl exceeds EIP-170");
            uint8 art = _artifactMatch(newImpl, "SuperPaymaster");
            require(art == 1, "V55 step5 pre-swap: impl code != profile.default SuperPaymaster artifact");
            console.log("  new impl:", newImpl);
            console.log("  new impl runtime bytes:", newImpl.code.length);
            vm.startBroadcast(owner);
            UUPSUpgradeable(a.sp).upgradeToAndCall(newImpl, ""); // zero new storage: no reinitializer
            vm.stopBroadcast();
        }
        _verifyStep5(a, pre, newImpl, sp);
    }

    function _verifyStep5(Addrs memory a, PreState memory pre, address newImpl, SuperPaymaster sp) internal view {
        require(_strEq(sp.version(), SP_V55_VERSION), "V55 step5 read-back: version != SuperPaymaster-5.5.0");
        require(address(uint160(uint256(vm.load(a.sp, ERC1967_IMPL_SLOT)))) == newImpl, "V55 step5 read-back: ERC1967 impl slot");
        // three immutables equal to 5.4.2's
        require(address(sp.REGISTRY()) == pre.registryImm, "V55 step5 read-back: REGISTRY changed");
        require(address(sp.ETH_USD_PRICE_FEED()) == pre.feedImm, "V55 step5 read-back: ETH_USD_PRICE_FEED changed");
        require(address(sp.entryPoint()) == pre.entryPointImm, "V55 step5 read-back: entryPoint changed");
        // BLS three legs unchanged
        require(sp.BLS_AGGREGATOR() == pre.blsSP, "V55 step5 read-back: SP.BLS_AGGREGATOR changed");
        require(IBLSPtr(a.registry).blsAggregator() == pre.blsRegistry, "V55 step5 read-back: Registry.blsAggregator changed");
        if (a.dvt != address(0)) require(IBLSPtr(a.dvt).BLS_AGGREGATOR() == pre.blsDVT, "V55 step5 read-back: DVT.BLS_AGGREGATOR changed");
        if (a.blsAggregatorCfg != address(0) && pre.blsSP != a.blsAggregatorCfg) {
            console.log("  NOTE: SP.BLS_AGGREGATOR != config.blsAggregator (unchanged by this upgrade):", pre.blsSP);
        }
        // named state
        require(sp.owner() == pre.owner, "V55 step5 read-back: owner drifted");
        require(sp.APNTS_TOKEN() == pre.apnts, "V55 step5 read-back: APNTS_TOKEN drifted");
        require(sp.xpntsFactory() == pre.xpntsFactory, "V55 step5 read-back: xpntsFactory drifted");
        require(sp.treasury() == pre.treasury, "V55 step5 read-back: treasury drifted");
        require(sp.protocolFeeBPS() == pre.fee, "V55 step5 read-back: protocolFeeBPS drifted");
        require(sp.aPNTsPriceUSD() == pre.aPriceUSD, "V55 step5 read-back: aPNTsPriceUSD drifted");
        require(sp.priceStalenessThreshold() == pre.staleness, "V55 step5 read-back: staleness drifted");
        require(sp.totalTrackedBalance() == pre.tracked, "V55 step5 read-back: totalTrackedBalance drifted");
        require(sp.protocolRevenue() == pre.revenue, "V55 step5 read-back: protocolRevenue drifted");
        require(sp.pendingAPNTsToken() == pre.pendingAPNTs, "V55 step5 read-back: pendingAPNTsToken drifted");
        IStakeManager.DepositInfo memory d = IEntryPoint(pre.entryPointImm).getDepositInfo(a.sp);
        require(d.deposit == pre.epDeposit && d.stake == pre.epStake && d.staked == pre.epStaked, "V55 step5 read-back: EntryPoint deposit/stake drifted");
        // raw storage: every slot 0..SNAPSHOT_SLOTS-1 byte-identical (layout-agnostic; covers
        // operators/userOpState/sbtHolders roots, pendingDebts root, gap)
        uint256 diffs;
        for (uint256 i; i < SNAPSHOT_SLOTS; ++i) {
            if (vm.load(a.sp, bytes32(i)) != pre.slots[i]) {
                console.log("  slot drifted:", i);
                diffs++;
            }
        }
        require(diffs == 0, "V55 step5 read-back: raw storage drifted");
        // D5-plan §4 step 5: sbtHolders / userOpState samples (V55_SAMPLE_USERS, V55_SAMPLE_OPERATOR),
        // read through the 5.5.0 getters and compared with the 5.4.2 reads taken before the swap.
        for (uint256 i; i < pre.sampleUsers.length; ++i) {
            (uint48 last, bool blocked) = sp.userOpState(pre.sampleOp, pre.sampleUsers[i]);
            require(sp.sbtHolders(pre.sampleUsers[i]) == pre.sampleSbt[i], "V55 step5 read-back: sbtHolders sample drifted");
            require(blocked == pre.sampleBlocked[i] && last == pre.sampleLast[i], "V55 step5 read-back: userOpState sample drifted");
            console.log("  sample ok", pre.sampleUsers[i], pre.sampleSbt[i]);
        }
        console.log("  step-5 read-back OK: 5.5.0, immutables, BLS legs, named state, EP stake; raw slots:", SNAPSHOT_SLOTS);
    }

    // =====================================================================
    // Step 5b — EntryPoint stake (DSR, D-9 adjustment)
    // =====================================================================

    /// @notice Standalone entry point for step 5b (SP owner broadcasts). run() calls the same code.
    function ensureStake() external {
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        _step5bStake(a.sp, address(sp.entryPoint()), sp.owner());
    }

    /// @dev Bundlers only let a paymaster read global storage in validation (ERC-7562 STO-033 —
    ///      SP's token calls and price cache depend on it) when it is STAKED at or above their
    ///      threshold: Rundler v0.11.0 defaults to 1 ETH and MIN_UNSTAKE_DELAY = 86400 s. Targets:
    ///      V55_MIN_STAKE_WEI (default 1 ether), V55_MIN_UNSTAKE_DELAY (default 86400).
    ///      EntryPoint.addStake adds msg.value to the stake, forbids lowering the delay, and
    ///      re-locks (withdrawTime = 0) — so one call with the shortfall and
    ///      max(target, current) delay fixes all three conditions. Idempotent.
    function _step5bStake(address sp, address ep, address owner) internal {
        uint256 minStake = vm.envOr("V55_MIN_STAKE_WEI", uint256(1 ether));
        uint256 minDelay = vm.envOr("V55_MIN_UNSTAKE_DELAY", uint256(86_400));
        IStakeManager.DepositInfo memory d = IEntryPoint(ep).getDepositInfo(sp);
        console.log("  before: staked / stake / unstakeDelay / withdrawTime:", d.staked, uint256(d.stake), uint256(d.unstakeDelaySec));
        console.log("          withdrawTime:", uint256(d.withdrawTime));
        bool needs = !d.staked || d.stake < minStake || d.unstakeDelaySec < minDelay || d.withdrawTime != 0;
        if (needs) {
            uint256 shortfall = d.stake < minStake ? minStake - d.stake : 0;
            uint256 delay = d.unstakeDelaySec > minDelay ? d.unstakeDelaySec : minDelay;
            require(delay <= type(uint32).max, "V55 step5b: delay overflow");
            require(owner.balance >= shortfall, "V55 step5b: SP owner lacks ETH for the stake shortfall");
            vm.startBroadcast(owner);
            SuperPaymaster(payable(sp)).addStake{value: shortfall}(uint32(delay));
            vm.stopBroadcast();
            console.log("  addStake shortfall (wei) / delay:", shortfall, delay);
        } else {
            console.log("  stake already sufficient - skipped");
        }
        IStakeManager.DepositInfo memory a = IEntryPoint(ep).getDepositInfo(sp);
        require(a.staked, "V55 step5b read-back: SP not staked");
        require(a.stake >= minStake, "V55 step5b read-back: stake below target");
        require(a.unstakeDelaySec >= minDelay, "V55 step5b read-back: unstakeDelaySec below target");
        require(a.withdrawTime == 0, "V55 step5b read-back: stake is unlocking (withdrawTime != 0)");
        require(a.deposit == d.deposit, "V55 step5b read-back: gas deposit moved");
        console.log("  step-5b read-back OK: stake (wei) / delay:", uint256(a.stake), uint256(a.unstakeDelaySec));
    }

    function _lensAcceptsSP(address lens, address sp) internal view returns (bool) {
        // The lens answers VERSION_MISMATCH on any SP that is not 5.5.0 — use it as a live probe.
        (bool ok, bytes memory ret) = lens.staticcall(abi.encodeWithSignature("EXPECTED_SP_VERSION()"));
        return ok && abi.decode(ret, (bytes32)) == keccak256(bytes(SuperPaymaster(payable(sp)).version()));
    }

    function _writeOut(V55Stack memory st, address newImpl) internal {
        string memory out = _outPath();
        if (bytes(out).length == 0) {
            console.log("  (V55_OUT_CONFIG unset: config NOT written; new addresses are in the log above)");
            return;
        }
        try vm.readFile(out) returns (string memory) {} catch {
            vm.writeFile(out, _configJson());
        }
        _writeStackKeys(out, st);
        vm.writeJson(vm.toString(newImpl), out, ".spImpl");
        console.log("  config written:", out);
    }

    // =====================================================================
    // Step 7a — issue a v2 token (broadcast as the COMMUNITY: --sender <community>)
    // =====================================================================

    function issueCommunityToken(
        string calldata name_,
        string calldata symbol_,
        string calldata communityName,
        string calldata ens,
        uint256 rate
    ) external {
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        require(_strEq(sp.version(), SP_V55_VERSION), "V55 step7a: SP is not 5.5.0 (run() first)");
        address factory = _factoryV2();
        address community = msg.sender;
        vm.startBroadcast(community);
        address token = _issueV2Token(factory, community, name_, symbol_, communityName, ens, rate);
        vm.stopBroadcast();
        _verifyV2Token(token, factory, community, a.sp);
        (, bool cfg, bool paused, , , , , ,) = sp.operators(community);
        if (cfg) require(paused, "V55 step7a read-back: operator must stay PAUSED until 7c");
        console.log("  step 7a: v2 token", token);
        string memory out = _outPath();
        if (bytes(out).length != 0) {
            vm.writeJson(vm.toString(token), out, string.concat(".xPNTsV2Tokens.", vm.toString(community)));
        }
    }

    // =====================================================================
    // Step 7c — price first, then configure (operator), then unpause (SP owner)
    // =====================================================================

    /// @notice 7c-1, broadcast as the OPERATOR. DSR D3 §8(a): refresh + read back the price
    ///         cache BEFORE the operator is configured.
    function configureOperatorV2(address token, address treasury) external {
        Addrs memory a = _addrs();
        require(_strEq(SuperPaymaster(payable(a.sp)).version(), SP_V55_VERSION), "V55 step7c: SP is not 5.5.0");
        address operator = msg.sender;
        vm.startBroadcast(operator);
        _refreshAndCheckPrice(a.sp);
        vm.stopBroadcast();
        _verifyPriceFresh(a.sp);
        vm.startBroadcast(operator);
        _configureOperatorV2(a.sp, token, treasury, operator);
        vm.stopBroadcast();
        _verifyOperatorV2(a.sp, operator, token, treasury);
        _verifyV2Token(token, _factoryV2(), operator, a.sp);
        console.log("  step 7c-1: operator configured on v2 token", operator, token);
    }

    /// @notice 7c-2, broadcast as the SP OWNER. Unpause only a v2-backed operator, only on a
    ///         fresh price cache.
    function unpauseOperator(address operator) external {
        Addrs memory a = _addrs();
        SuperPaymaster sp = SuperPaymaster(payable(a.sp));
        require(_strEq(sp.version(), SP_V55_VERSION), "V55 step7c: SP is not 5.5.0");
        (, bool cfg, , address tok, , , , ,) = sp.operators(operator);
        require(cfg, "V55 step7c: operator not configured");
        require(IxPNTsV2Script(tok).BALANCE_MODE_VERSION() == 1, "V55 step7c: operator still on a legacy token");
        vm.startBroadcast(sp.owner());
        _refreshAndCheckPrice(a.sp);
        vm.stopBroadcast();
        _verifyPriceFresh(a.sp);
        vm.startBroadcast(sp.owner());
        sp.setOperatorPaused(operator, false);
        vm.stopBroadcast();
        (, , bool paused, , , , , ,) = sp.operators(operator);
        require(!paused, "V55 step7c read-back: operator still paused");
        console.log("  step 7c-2: operator unpaused (balance mode only; credit stays OFF)", operator);
    }
}
