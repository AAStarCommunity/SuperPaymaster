// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { DefaultArtifacts } from "./DefaultArtifacts.sol";
import { SPReleaseVersion } from "./SPReleaseVersion.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";

/// @dev Minimal views/calls — deliberately NOT importing Registry.sol / SuperPaymaster.sol: the
///      implementations are deployed from their profile.default ARTIFACTS (DefaultArtifacts), never
///      from this script's own compile.
interface ID5bOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function version() external view returns (string memory);
    function acceptOwnership() external;
    function transferOwnership(address) external;
    function upgradeToAndCall(address, bytes calldata) external payable;
}

interface ID5bSP {
    function REGISTRY() external view returns (address);
    function entryPoint() external view returns (address);
    function ETH_USD_PRICE_FEED() external view returns (address);
    function EXTENSION() external view returns (address);
    function BLS_AGGREGATOR() external view returns (address);
    function guardian() external view returns (address);
    function paused() external view returns (bool);
    function setGuardian(address) external;
}

interface ID5bRegistryBls { function blsAggregator() external view returns (address); }
interface ID5bDvtBls { function BLS_AGGREGATOR() external view returns (address); }

/**
 * @title D5bUpgradeChecks
 * @notice Shared read-backs for the D5b upgrade paths (spec 03 §6 steps 5 / 5c / M1–M2, §10.7b C).
 */
abstract contract D5bUpgradeChecks is DefaultArtifacts {
    string internal constant REGISTRY_VERSION = "Registry-5.9.0";     // D5b Registry (GOV-2 two-step)
    string internal constant REGISTRY_FROM_VERSION = "Registry-5.8.0";
    uint256 internal constant SP_LAYOUT_END = 65;       // first slot after SP's __gap (unchanged by D5b)
    uint256 internal constant REGISTRY_LAYOUT_END = 74; // first slot after Registry's __gap
    /// @dev keccak256(abi.encode(uint256(keccak256("aastar.storage.Ownership2Step")) - 1)) & ~0xff
    bytes32 internal constant OWNERSHIP_2STEP_SLOT = 0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00;
    uint256 internal constant GOV1_MIN_DELAY = 48 hours;

    struct Cfg {
        address sp;
        address registry;
        address entryPoint;
        address priceFeed;
        address dvt;
        address timelock;
    }

    struct Bls3 {
        address sp;
        address registry;
        address dvt;
    }

    function _cfg() internal view returns (Cfg memory c) {
        string memory env = vm.envOr("ENV", string("anvil"));
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", env, ".json"));
        c.sp = vm.parseJsonAddress(j, ".superPaymaster");
        c.registry = vm.parseJsonAddress(j, ".registry");
        c.entryPoint = vm.parseJsonAddress(j, ".entryPoint");
        c.priceFeed = vm.parseJsonAddress(j, ".priceFeed");
        c.dvt = _opt(j, ".dvtValidator");
        c.timelock = vm.envOr("TIMELOCK", _opt(j, ".timelockController"));
    }

    function _opt(string memory j, string memory key) internal view returns (address a) {
        if (vm.keyExistsJson(j, key)) a = vm.parseJsonAddress(j, key);
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _slots(address a, uint256 n) internal view returns (bytes32[] memory s) {
        s = new bytes32[](n);
        for (uint256 i; i < n; ++i) s[i] = vm.load(a, bytes32(i));
    }

    function _requireSlotsEq(address a, bytes32[] memory before, string memory label) internal view {
        uint256 diffs;
        for (uint256 i; i < before.length; ++i) {
            if (vm.load(a, bytes32(i)) != before[i]) {
                console.log("  slot drifted:", i);
                diffs++;
            }
        }
        require(diffs == 0, string.concat(label, ": raw sequential storage drifted across the upgrade"));
        console.log(string.concat("  ", label, ": raw slots 0..N-1 byte-identical, N ="), before.length);
    }

    function _bls(Cfg memory c) internal view returns (Bls3 memory b) {
        b.sp = ID5bSP(c.sp).BLS_AGGREGATOR();
        b.registry = ID5bRegistryBls(c.registry).blsAggregator();
        if (c.dvt != address(0)) b.dvt = ID5bDvtBls(c.dvt).BLS_AGGREGATOR();
    }

    function _requireBlsEq(Cfg memory c, Bls3 memory before) internal view {
        Bls3 memory b = _bls(c);
        require(b.sp == before.sp, "read-back: SP.BLS_AGGREGATOR changed");
        require(b.registry == before.registry, "read-back: Registry.blsAggregator changed");
        require(b.dvt == before.dvt, "read-back: DVT.BLS_AGGREGATOR changed");
        console.log("  BLS three legs unchanged (SP / Registry / DVT):", b.sp, b.registry);
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Checks on a freshly deployed SP implementation BEFORE any proxy points at it.
    function _requireSPImplReady(address impl, Cfg memory c) internal view {
        _requireDefaultArtifact(impl, "SuperPaymaster"); // + extension binding (DefaultArtifacts)
        require(ID5bSP(impl).REGISTRY() == ID5bSP(c.sp).REGISTRY(), "SP impl: REGISTRY != live");
        require(ID5bSP(impl).entryPoint() == ID5bSP(c.sp).entryPoint(), "SP impl: entryPoint != live");
        require(ID5bSP(impl).ETH_USD_PRICE_FEED() == ID5bSP(c.sp).ETH_USD_PRICE_FEED(), "SP impl: price feed != live");
        require(_strEq(ID5bOwned(impl).version(), SPReleaseVersion.SP), "SP impl: version");
        require(impl.code.length + 1024 <= 24_576, "SP impl: core headroom < 1,024 B (release gate)");
        console.log("  SP impl ready (default build, immutables == live, headroom >= 1,024):", impl, impl.code.length);
    }

    function _requireRegistryImplReady(address impl) internal view {
        _requireDefaultArtifact(impl, "Registry");
        require(_strEq(ID5bOwned(impl).version(), REGISTRY_VERSION), "Registry impl: version");
        require(impl.code.length <= 24_576, "Registry impl: EIP-170");
        console.log("  Registry impl ready (default build, runs=200):", impl, impl.code.length);
    }

    /// @notice Post-upgrade read-back common to both proxies.
    function _requireProxyReadBack(address proxy, string memory name, address newImpl, address expectOwner,
        string memory expectVersion) internal view
    {
        require(_implOf(proxy) == newImpl, string.concat(name, " read-back: ERC-1967 implementation slot"));
        require(_strEq(ID5bOwned(proxy).version(), expectVersion), string.concat(name, " read-back: version"));
        require(ID5bOwned(proxy).owner() == expectOwner, string.concat(name, " read-back: owner changed"));
        require(ID5bOwned(proxy).pendingOwner() == address(0), string.concat(name, " read-back: pendingOwner != 0"));
        _requireDefaultProxy(proxy, name);
        console.log(string.concat("  ", name, " read-back OK: impl / version / owner / pendingOwner == 0; version ="), expectVersion);
    }
}

/**
 * @title UpgradeRegistryD5b — runbook 03 §6 step 5c (EOA owner, before M1)
 * @notice Registry `upgradeToAndCall` → the D5b Registry (GOV-2 two-step ownership, zero-owner
 *         initialize guard, `Registry-5.9.0`). Read-backs: version, ERC-1967 slot, owner unchanged,
 *         pendingOwner() == 0, BLS three legs unchanged, raw sequential slots 0..73 byte-identical.
 *         Storage gate beforehand: `python3 scripts/check_storage_layout.py` (Registry: no change allowed).
 * @dev    ENV=<config> forge script contracts/script/v3/UpgradeViaTimelock.s.sol:UpgradeRegistryD5b \
 *           --rpc-url $RPC --sender <registry owner> --broadcast   (plain `forge build` first)
 *         Refuses if the Registry owner is not the broadcaster (after M1 use UpgradeViaTimelock).
 */
contract UpgradeRegistryD5b is D5bUpgradeChecks {
    function run() external {
        Cfg memory c = _cfg();
        address owner = ID5bOwned(c.registry).owner();
        require(owner == msg.sender, "5c: Registry owner is not the broadcaster (after M1 use UpgradeViaTimelock)");
        string memory v = ID5bOwned(c.registry).version();
        if (_strEq(v, REGISTRY_VERSION) && _codeEqArtifact(_implOf(c.registry), _defaultArtifact("Registry"))) {
            console.log("  5c: Registry already at the D5b build - nothing to do");
            return;
        }
        require(_strEq(v, REGISTRY_FROM_VERSION), "5c: Registry is neither 5.8.0 nor the D5b build");
        require(vm.load(c.registry, OWNERSHIP_2STEP_SLOT) == bytes32(0), "5c pre: ERC-7201 pending slot not empty");
        Bls3 memory bls = _bls(c);
        bytes32[] memory before = _slots(c.registry, REGISTRY_LAYOUT_END);

        vm.startBroadcast();
        address impl = _deployDefault("Registry", "");
        vm.stopBroadcast();
        _requireRegistryImplReady(impl);
        vm.startBroadcast();
        ID5bOwned(c.registry).upgradeToAndCall(impl, "");
        vm.stopBroadcast();

        _requireProxyReadBack(c.registry, "Registry", impl, owner, REGISTRY_VERSION);
        _requireBlsEq(c, bls);
        _requireSlotsEq(c.registry, before, "Registry");
        console.log("  5c done. Registry impl:", impl);
    }
}

/**
 * @title UpgradeViaTimelock — GOV-1 aware upgrade flow (spec 03 §10.7b C) + the A5s batch (M1/M2)
 * @notice Once SP / Registry are owned by the 48h TimelockController, an upgrade is:
 *           deploy-impl → schedule(upgradeToAndCall) → ≥ minDelay → execute → read-backs.
 *         Modes (env TL_MODE):
 *           deploy-impl       TL_TARGET=SP|REGISTRY  deploy the profile.default impl (SP: with the LIVE
 *                                                    immutables) and run every pre-swap check
 *           schedule-upgrade  TL_TARGET, TL_NEW_IMPL schedule(proxy, 0, upgradeToAndCall(impl, ""), 0, salt, minDelay)
 *           direct-upgrade    TL_TARGET, TL_NEW_IMPL PRE-M1 only (owner == broadcaster): same checks, one EOA tx
 *           execute-upgrade   TL_TARGET, TL_NEW_IMPL execute + read-backs (impl slot, version, owner == timelock,
 *                                                    pendingOwner 0, default proxy/impl/extension, BLS legs,
 *                                                    raw sequential slots unchanged across the execute tx)
 *           schedule-accept   SAFE                   scheduleBatch[SP.acceptOwnership, Registry.acceptOwnership,
 *                                                    SP.setGuardian(SAFE)] — runbook M1 ② / M2
 *           execute-accept    SAFE                   executeBatch + read-backs (owner == timelock, pendingOwner 0,
 *                                                    guardian == SAFE, minDelay == 172800)
 *         TL_SALT (bytes32, default keccak256("d5b")). The proposer / executor is the broadcaster
 *         (`--sender`); when it lacks the role the script only PRINTS the calldata for the Safe.
 */
contract UpgradeViaTimelock is D5bUpgradeChecks {
    function run() external {
        string memory mode = vm.envString("TL_MODE");
        Cfg memory c = _cfg();
        bytes32 salt = vm.envOr("TL_SALT", keccak256("d5b"));
        bytes32 m = keccak256(bytes(mode));
        if (m == keccak256("deploy-impl")) { deployImpl(c, _target()); return; }
        if (m == keccak256("schedule-upgrade")) { scheduleUpgrade(c, _target(), vm.envAddress("TL_NEW_IMPL"), salt, msg.sender); return; }
        if (m == keccak256("execute-upgrade")) { executeUpgrade(c, _target(), vm.envAddress("TL_NEW_IMPL"), salt, msg.sender); return; }
        if (m == keccak256("direct-upgrade")) { directUpgrade(c, _target(), vm.envAddress("TL_NEW_IMPL"), msg.sender); return; }
        if (m == keccak256("schedule-accept")) { scheduleAccept(c, vm.envAddress("SAFE"), salt, msg.sender); return; }
        if (m == keccak256("execute-accept")) { executeAccept(c, vm.envAddress("SAFE"), salt, msg.sender); return; }
        revert("UpgradeViaTimelock: unknown TL_MODE");
    }

    function _target() internal view returns (bool isSP) {
        bytes32 t = keccak256(bytes(vm.envString("TL_TARGET")));
        require(t == keccak256("SP") || t == keccak256("REGISTRY"), "TL_TARGET must be SP or REGISTRY");
        return t == keccak256("SP");
    }

    function _timelock(Cfg memory c) internal view returns (TimelockController tl) {
        require(c.timelock != address(0) && c.timelock.code.length > 0, "timelock not configured (TIMELOCK / .timelockController)");
        tl = TimelockController(payable(c.timelock));
        uint256 d = tl.getMinDelay();
        require(d >= vm.envOr("TL_EXPECT_MIN_DELAY", GOV1_MIN_DELAY), "timelock minDelay below the GOV-1 48h");
    }

    function deployImpl(Cfg memory c, bool isSP) public returns (address impl) {
        vm.startBroadcast();
        impl = isSP
            ? _deployDefault("SuperPaymaster", abi.encode(ID5bSP(c.sp).entryPoint(), ID5bSP(c.sp).REGISTRY(), ID5bSP(c.sp).ETH_USD_PRICE_FEED()))
            : _deployDefault("Registry", "");
        vm.stopBroadcast();
        if (isSP) _requireSPImplReady(impl, c);
        else _requireRegistryImplReady(impl);
        console.log("  new implementation (pass as TL_NEW_IMPL):", impl);
    }

    function _upgradeCall(address impl) internal pure returns (bytes memory) {
        return abi.encodeCall(ID5bOwned.upgradeToAndCall, (impl, bytes("")));
    }

    function scheduleUpgrade(Cfg memory c, bool isSP, address impl, bytes32 salt, address proposer) public returns (bytes32 id) {
        TimelockController tl = _timelock(c);
        address proxy = isSP ? c.sp : c.registry;
        require(ID5bOwned(proxy).owner() == address(tl), "schedule: proxy owner is not the timelock");
        if (isSP) _requireSPImplReady(impl, c);
        else _requireRegistryImplReady(impl);
        bytes memory data = _upgradeCall(impl);
        uint256 delay = tl.getMinDelay();
        id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        if (tl.hasRole(tl.PROPOSER_ROLE(), proposer)) {
            vm.startBroadcast(proposer);
            tl.schedule(proxy, 0, data, bytes32(0), salt, delay);
            vm.stopBroadcast();
            require(tl.isOperationPending(id), "schedule: not pending after schedule");
            console.log("  scheduled; ready at:", tl.getTimestamp(id));
        } else {
            console.log("  broadcaster is not a proposer - submit this from the proposer (Safe):");
            console.log("  to  :", address(tl));
            console.logBytes(abi.encodeCall(TimelockController.schedule, (proxy, 0, data, bytes32(0), salt, delay)));
        }
        console.logBytes32(id);
    }

    function executeUpgrade(Cfg memory c, bool isSP, address impl, bytes32 salt, address executor) public {
        TimelockController tl = _timelock(c);
        address proxy = isSP ? c.sp : c.registry;
        bytes memory data = _upgradeCall(impl);
        bytes32 id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        require(tl.isOperationReady(id), "execute: operation not ready (not scheduled, or minDelay not elapsed)");
        address owner = ID5bOwned(proxy).owner();
        Bls3 memory bls = _bls(c);
        bytes32[] memory before = _slots(proxy, isSP ? SP_LAYOUT_END : REGISTRY_LAYOUT_END);
        bool can = tl.hasRole(tl.EXECUTOR_ROLE(), executor) || tl.hasRole(tl.EXECUTOR_ROLE(), address(0));
        if (!can) {
            console.log("  broadcaster is not an executor - submit this from the executor (Safe):");
            console.logBytes(abi.encodeCall(TimelockController.execute, (proxy, 0, data, bytes32(0), salt)));
            return;
        }
        vm.startBroadcast(executor);
        tl.execute(proxy, 0, data, bytes32(0), salt);
        vm.stopBroadcast();
        require(tl.isOperationDone(id), "execute: operation not done");
        _requireProxyReadBack(proxy, isSP ? "SuperPaymaster" : "Registry", impl, owner,
            isSP ? SPReleaseVersion.SP : REGISTRY_VERSION);
        _requireBlsEq(c, bls);
        _requireSlotsEq(proxy, before, isSP ? "SuperPaymaster" : "Registry");
        if (isSP) {
            require(ID5bSP(c.sp).REGISTRY() == c.registry && ID5bSP(c.sp).entryPoint() == c.entryPoint,
                "SP read-back: immutables != config");
        }
    }

    /// @notice PRE-M1 only (owner is still the broadcaster, e.g. rc1 → D5b before A5s): the same
    ///         pre-swap checks and read-backs as the timelock path, one EOA transaction.
    function directUpgrade(Cfg memory c, bool isSP, address impl, address owner) public {
        address proxy = isSP ? c.sp : c.registry;
        require(ID5bOwned(proxy).owner() == owner, "direct-upgrade: owner is not the broadcaster (after M1 use schedule/execute)");
        if (isSP) _requireSPImplReady(impl, c);
        else _requireRegistryImplReady(impl);
        Bls3 memory bls = _bls(c);
        bytes32[] memory before = _slots(proxy, isSP ? SP_LAYOUT_END : REGISTRY_LAYOUT_END);
        vm.startBroadcast(owner);
        ID5bOwned(proxy).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
        _requireProxyReadBack(proxy, isSP ? "SuperPaymaster" : "Registry", impl, owner,
            isSP ? SPReleaseVersion.SP : REGISTRY_VERSION);
        _requireBlsEq(c, bls);
        _requireSlotsEq(proxy, before, isSP ? "SuperPaymaster" : "Registry");
    }

    function _acceptBatch(Cfg memory c, address safe)
        internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory p)
    {
        t = new address[](3);
        v = new uint256[](3);
        p = new bytes[](3);
        t[0] = c.sp;
        t[1] = c.registry;
        t[2] = c.sp;
        p[0] = abi.encodeCall(ID5bOwned.acceptOwnership, ());
        p[1] = abi.encodeCall(ID5bOwned.acceptOwnership, ());
        p[2] = abi.encodeCall(ID5bSP.setGuardian, (safe));
    }

    function scheduleAccept(Cfg memory c, address safe, bytes32 salt, address proposer) public returns (bytes32 id) {
        TimelockController tl = _timelock(c);
        require(safe != address(0), "SAFE unset");
        require(ID5bOwned(c.sp).pendingOwner() == address(tl), "M1: SP.pendingOwner != timelock (run SP.transferOwnership(timelock) first)");
        require(ID5bOwned(c.registry).pendingOwner() == address(tl), "M1: Registry.pendingOwner != timelock");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _acceptBatch(c, safe);
        uint256 delay = tl.getMinDelay();
        id = tl.hashOperationBatch(t, v, p, bytes32(0), salt);
        if (tl.hasRole(tl.PROPOSER_ROLE(), proposer)) {
            vm.startBroadcast(proposer);
            tl.scheduleBatch(t, v, p, bytes32(0), salt, delay);
            vm.stopBroadcast();
            require(tl.isOperationPending(id), "M1: batch not pending");
            console.log("  M1 batch scheduled; ready at:", tl.getTimestamp(id));
        } else {
            console.log("  broadcaster is not a proposer - submit this scheduleBatch from the Safe:");
            console.logBytes(abi.encodeCall(TimelockController.scheduleBatch, (t, v, p, bytes32(0), salt, delay)));
        }
        console.logBytes32(id);
    }

    function executeAccept(Cfg memory c, address safe, bytes32 salt, address executor) public {
        TimelockController tl = _timelock(c);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _acceptBatch(c, safe);
        bytes32 id = tl.hashOperationBatch(t, v, p, bytes32(0), salt);
        require(tl.isOperationReady(id), "M1: batch not ready");
        if (!tl.hasRole(tl.EXECUTOR_ROLE(), executor)) {
            console.log("  broadcaster is not an executor - submit this executeBatch from the Safe:");
            console.logBytes(abi.encodeCall(TimelockController.executeBatch, (t, v, p, bytes32(0), salt)));
            return;
        }
        vm.startBroadcast(executor);
        tl.executeBatch(t, v, p, bytes32(0), salt);
        vm.stopBroadcast();
        require(ID5bOwned(c.sp).owner() == address(tl) && ID5bOwned(c.registry).owner() == address(tl), "M1 read-back: owner != timelock");
        require(ID5bOwned(c.sp).pendingOwner() == address(0) && ID5bOwned(c.registry).pendingOwner() == address(0), "M1 read-back: pendingOwner != 0");
        require(ID5bSP(c.sp).guardian() == safe, "M2 read-back: guardian != SAFE");
        require(tl.getMinDelay() == GOV1_MIN_DELAY, "M1 read-back: minDelay != 172800");
        require(!tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "M1 read-back: executor is OPEN (spec: multisig only)");
        console.log("  M1/M2 read-back OK: owners == timelock, pendingOwner == 0, guardian == SAFE, minDelay == 48h", address(tl));
    }
}
