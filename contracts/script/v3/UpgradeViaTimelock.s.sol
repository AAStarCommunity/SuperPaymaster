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
 *         PRE-M1 EOA path: NOT guarded by the M1 timelock preflight (no timelock is involved yet).
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
            _requireProxyReadBack(c.registry, "Registry", _implOf(c.registry), owner, REGISTRY_VERSION);
            console.log("  5c: Registry already at the D5b build - verified, nothing to do");
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
 *           schedule-call     TL_TARGET, TL_CALLDATA any other governed call on SP / Registry (e.g. the M2
 *                                                    unpause setGlobalPaused(false)); upgradeToAndCall refused
 *           execute-call      TL_TARGET, TL_CALLDATA execute it
 *         OPERATOR PREFLIGHT, NOT AN ENFORCEMENT BOUNDARY: every schedule-* / execute-* mode first runs
 *         operatorPreflight (validateManifest + m1Preflight, a bounded known-account check against
 *         deployments/timelock-roles.<ENV>.json, then requireRolesAttestation on the event-history
 *         checker's UNSIGNED attestation TL_ROLES_ATTESTATION). It only protects the run of THIS script.
 *         On a live chain the Safe is a contract: the calldata this script prints IS the production path,
 *         and nothing binds what the Safe signers later submit (or build themselves) to this preflight or
 *         to any attestation. The on-chain basis of role exclusivity is a CONDITIONAL invariant of the
 *         timelock's self-administration (D5b-design §6.3d): WHILE DEFAULT_ADMIN_ROLE == [timelock] AND
 *         minDelay == 172800, every grantRole / revokeRole / updateDelay is a public timelock operation
 *         delayed >= 48h. A scheduled operation can break either invariant (lower minDelay, or grant
 *         DEFAULT_ADMIN to an outside account that then grants / revokes without scheduling) — but that
 *         FIRST weakening operation is itself publicly scheduled under the current 48h delay, and is what
 *         monitoring must alert on and the Safe signers must refuse. deploy-impl, direct-upgrade and UpgradeRegistryD5b (runbook 5c) are
 *         PRE-M1 EOA paths and do not run the preflight (they touch no timelock; owner == broadcaster).
 *         TL_SALT (bytes32, default keccak256("d5b")). The proposer / executor is the broadcaster
 *         (`--sender`); when it is not the Safe the script only PRINTS the calldata for the Safe.
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
        if (m == keccak256("schedule-accept")) { scheduleAccept(c, _safeOf(_manifest(c)), salt, msg.sender); return; }
        if (m == keccak256("execute-accept")) { executeAccept(c, _safeOf(_manifest(c)), salt, msg.sender); return; }
        if (m == keccak256("schedule-call")) { scheduleCallWith(c, _target(), vm.envBytes("TL_CALLDATA"), salt, msg.sender, _manifest(c)); return; }
        if (m == keccak256("execute-call")) { executeCallWith(c, _target(), vm.envBytes("TL_CALLDATA"), salt, msg.sender, _manifest(c)); return; }
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
    }

    /// @notice Committed, per-network expected-holder manifest of the GOV-1 timelock
    ///         (deployments/timelock-roles.<ENV>.json; schema in deployments/timelock-roles.example.json).
    ///         `mustHoldNothing` are HISTORICAL accounts persisted in the file (deployer, the old SP and
    ///         Registry owners, …) — never derived from the proxies' current owner(), which stops naming
    ///         them once M1 has executed.
    struct RoleManifest {
        uint256 chainId;      // must equal block.chainid (Codex re-check M1)
        address timelock;
        uint256 deploymentBlock;
        address[] admins;
        address[] proposers;
        address[] cancellers;
        address[] executors;
        address[] mustHoldNothing;
        string[] mustHoldNothingLabels; // one non-empty label per mustHoldNothing account
        // preflight inputs (not part of the JSON manifest)
        bytes32 fileKeccak;   // keccak256 of the manifest file bytes as read
        string attestation;   // TL_ROLES_ATTESTATION: path of the checker's attestation file
        bool optOut;          // TL_ALLOW_NO_ATTESTATION: local chains only, loudly logged
    }

    // default and live-chain maximum = the EVM blockhash window, so a live head hash is always checkable;
    // env TL_ATTEST_MAX_AGE may lower it anywhere and raise it only on a local chain
    uint256 internal constant ATTEST_MAX_AGE_BLOCKS = 256;

    function _manifest(Cfg memory c) internal view returns (RoleManifest memory m) {
        string memory env = vm.envOr("ENV", string("anvil"));
        string memory path = string.concat(vm.projectRoot(), "/deployments/timelock-roles.", env, ".json");
        string memory j;
        try vm.readFile(path) returns (string memory body) {
            j = body;
        } catch {
            revert("M1 preflight: manifest deployments/timelock-roles.<ENV>.json missing");
        }
        m = parseManifest(j);
        m.attestation = vm.envOr("TL_ROLES_ATTESTATION", string(""));
        m.optOut = vm.envOr("TL_ALLOW_NO_ATTESTATION", false);
        require(m.timelock == c.timelock, "M1 preflight: manifest timelock != configured timelock");
    }

    string[10] internal MANIFEST_KEYS = [
        ".network", ".chainId", ".timelock", ".deploymentBlock", ".roles.DEFAULT_ADMIN_ROLE",
        ".roles.PROPOSER_ROLE", ".roles.CANCELLER_ROLE", ".roles.EXECUTOR_ROLE", ".mustHoldNothing",
        ".mustHoldNothingLabels"
    ];

    /// @notice Parse a manifest body with forge's normal JSON cheatcodes (BEST EFFORT as to the byte-level
    ///         form: forge coerces types, e.g. "0x.." or long digit strings). The canonical byte form is
    ///         enforced in ONE place, the checker (check-timelock-roles.mjs, CANONICAL FORM); on the
    ///         attested path requireRolesAttestation binds these exact bytes to a PASS attestation and
    ///         requires the values read here to equal the attested ones. EVERY schema field is required (Codex re-check M3: a manifest
    ///         that omits a field must not parse as an empty — vacuously satisfied — set); the content
    ///         rules (chainId, M1 policy, non-empty unique labelled mustHoldNothing) are enforced by
    ///         validateManifest, which m1Preflight runs.
    function parseManifest(string memory j) public view returns (RoleManifest memory m) {
        require(!vm.keyExistsJson(j, "._placeholder"),
            "M1 manifest: placeholder (the example schema with FAKE addresses) - not a network manifest");
        for (uint256 i; i < MANIFEST_KEYS.length; ++i) {
            require(vm.keyExistsJson(j, MANIFEST_KEYS[i]), string.concat("M1 manifest: missing field ", MANIFEST_KEYS[i]));
        }
        require(bytes(vm.parseJsonString(j, ".network")).length > 0, "M1 manifest: empty network");
        // the four role keys exist (checked above); any further key under .roles is rejected, as in the checker
        require(vm.parseJsonKeys(j, ".roles").length == 4, "M1 manifest: unknown role key in .roles");
        m.chainId = vm.parseJsonUint(j, ".chainId");
        m.timelock = vm.parseJsonAddress(j, ".timelock");
        m.deploymentBlock = vm.parseJsonUint(j, ".deploymentBlock");
        m.admins = vm.parseJsonAddressArray(j, ".roles.DEFAULT_ADMIN_ROLE");
        m.proposers = vm.parseJsonAddressArray(j, ".roles.PROPOSER_ROLE");
        m.cancellers = vm.parseJsonAddressArray(j, ".roles.CANCELLER_ROLE");
        m.executors = vm.parseJsonAddressArray(j, ".roles.EXECUTOR_ROLE");
        m.mustHoldNothing = vm.parseJsonAddressArray(j, ".mustHoldNothing");
        m.mustHoldNothingLabels = vm.parseJsonStringArray(j, ".mustHoldNothingLabels");
        m.fileKeccak = keccak256(bytes(j));
    }

    /**
     * @notice Content rules of a manifest (Codex re-check M1 + M3), checked first by m1Preflight:
     *         chainId == block.chainid; a non-zero timelock and deployment block; all four role sets
     *         non-empty (m1Preflight then requires exactly the M1 policy); `mustHoldNothing` non-empty,
     *         every entry non-zero and unique, with exactly one non-empty label per entry. An empty
     *         mustHoldNothing would make the "historical accounts hold nothing" check vacuous.
     */
    function validateManifest(RoleManifest memory m) public view {
        require(m.chainId != 0 && m.chainId == block.chainid, "M1 manifest: chainId != this chain");
        require(m.timelock != address(0), "M1 manifest: zero timelock");
        require(m.deploymentBlock != 0, "M1 manifest: deploymentBlock unset");
        require(m.admins.length != 0 && m.proposers.length != 0 && m.cancellers.length != 0 && m.executors.length != 0,
            "M1 manifest: empty role set");
        uint256 n = m.mustHoldNothing.length;
        require(n != 0, "M1 manifest: mustHoldNothing is empty");
        require(m.mustHoldNothingLabels.length == n, "M1 manifest: one label per mustHoldNothing account");
        for (uint256 i; i < n; ++i) {
            require(m.mustHoldNothing[i] != address(0), "M1 manifest: zero address in mustHoldNothing");
            require(!_isBlank(m.mustHoldNothingLabels[i]), "M1 manifest: empty mustHoldNothing label");
            for (uint256 k = i + 1; k < n; ++k) {
                require(m.mustHoldNothing[i] != m.mustHoldNothing[k], "M1 manifest: duplicate in mustHoldNothing");
            }
        }
    }

    /// @dev True when `s` is empty or consists only of whitespace. Mirrors the checker's JS String.trim():
    ///      ASCII \t \n \v \f \r space, and the UTF-8 encodings of U+00A0, U+1680, U+2000-U+200A,
    ///      U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
    function _isBlank(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        uint256 i;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            if (c == 0x20 || (c >= 0x09 && c <= 0x0d)) { i += 1; continue; }
            if (c == 0xc2 && i + 1 < b.length && uint8(b[i + 1]) == 0xa0) { i += 2; continue; }
            if (i + 2 < b.length) {
                uint8 c1 = uint8(b[i + 1]);
                uint8 c2 = uint8(b[i + 2]);
                bool ws = (c == 0xe1 && c1 == 0x9a && c2 == 0x80)
                    || (c == 0xe2 && c1 == 0x80 && ((c2 >= 0x80 && c2 <= 0x8a) || c2 == 0xa8 || c2 == 0xa9 || c2 == 0xaf))
                    || (c == 0xe2 && c1 == 0x81 && c2 == 0x9f)
                    || (c == 0xe3 && c1 == 0x80 && c2 == 0x80)
                    || (c == 0xef && c1 == 0xbb && c2 == 0xbf);
                if (ws) { i += 3; continue; }
            }
            return false;
        }
        return true;
    }

    /// @notice Public for tests / operators: the manifest the operator preflight checks.
    function manifestOf(Cfg memory c) public view returns (RoleManifest memory) {
        return _manifest(c);
    }

    /// @dev Printed with every calldata handed to the Safe: the preflight does not travel with it.
    function _safeSignerNotice() internal pure {
        console.log("  NOTE for Safe signers: the operator preflight above binds only this script run. Before");
        console.log("  signing, re-run check-timelock-roles.mjs at the current head and review the operation.");
    }

    /// @dev The Safe is the manifest's single proposer; an explicit SAFE env must agree with it.
    function _safeOf(RoleManifest memory m) internal view returns (address safe) {
        require(m.proposers.length == 1, "M1 preflight: manifest must list exactly one proposer (the Safe)");
        safe = m.proposers[0];
        address envSafe = vm.envOr("SAFE", address(0));
        require(envSafe == address(0) || envSafe == safe, "M1 preflight: SAFE env != manifest Safe");
    }

    function _exactly(address[] memory list, address who) internal pure returns (bool) {
        return list.length == 1 && list[0] == who;
    }

    /**
     * @notice GOV-1 / M1 configuration preflight (Codex D5b closing review). Runs BEFORE scheduling and
     *         AGAIN before broadcasting any execute, so THIS SCRIPT does not prepare an ownership
     *         hand-over or an upgrade on a mis-configured timelock (an operator preflight: it does not bind
     *         what the Safe submits). The GOV-2 accept step itself remains the on-chain abort point.
     *
     *         THIS IS A BOUNDED KNOWN-ACCOUNT CHECK. OZ TimelockController (AccessControl, not
     *         AccessControlEnumerable) cannot list role holders on-chain, so this function can only ask
     *         `hasRole` about accounts it is told about: the timelock, the Safe and every account in the
     *         committed manifest. An UNLISTED holder of any role is NOT detected here. Exclusivity is
     *         established off-chain by script/governance/check-timelock-roles.mjs, which rebuilds the
     *         full holder set from the RoleGranted / RoleRevoked history and must equal the manifest
     *         (an operator check; see requireRolesAttestation for what it does and does not establish).
     *
     *         Reverts unless: the manifest passes validateManifest (chainId == block.chainid, complete and
     *         non-vacuous); minDelay == 172800 exactly; the manifest is for this timelock and states the
     *         M1 policy (DEFAULT_ADMIN = [timelock]; PROPOSER = CANCELLER = EXECUTOR = [Safe]); every
     *         listed holder holds its role; the executor role is not open (address(0)); the Safe does not
     *         hold DEFAULT_ADMIN; and no `mustHoldNothing` account holds any of the four roles. Execution
     *         path: the functions below broadcast ONLY when the acting caller IS the Safe (on anvil: the
     *         unlocked / pranked Safe); any other caller only gets the calldata to submit from the Safe.
     */
    function m1Preflight(TimelockController tl, RoleManifest memory m) public view {
        validateManifest(m);
        require(m.timelock == address(tl), "M1 preflight: manifest timelock != timelock");
        require(tl.getMinDelay() == GOV1_MIN_DELAY, "M1 preflight: minDelay != 172800");
        address safe = m.proposers.length == 1 ? m.proposers[0] : address(0);
        require(safe != address(0) && safe != address(tl), "M1 preflight: Safe unset");
        require(_exactly(m.admins, address(tl)) && _exactly(m.proposers, safe) && _exactly(m.cancellers, safe)
            && _exactly(m.executors, safe), "M1 preflight: manifest is not the M1 policy (admin=[timelock], P=C=E=[Safe])");
        bytes32 P = tl.PROPOSER_ROLE();
        bytes32 C = tl.CANCELLER_ROLE();
        bytes32 E = tl.EXECUTOR_ROLE();
        bytes32 A = tl.DEFAULT_ADMIN_ROLE();
        require(tl.hasRole(P, safe) && tl.hasRole(C, safe) && tl.hasRole(E, safe),
            "M1 preflight: Safe must hold PROPOSER, CANCELLER and EXECUTOR");
        require(!tl.hasRole(E, address(0)), "M1 preflight: executor role is OPEN (address(0))");
        require(tl.hasRole(A, address(tl)), "M1 preflight: timelock is not its own admin");
        require(!tl.hasRole(A, safe), "M1 preflight: Safe holds DEFAULT_ADMIN_ROLE");
        for (uint256 i; i < m.mustHoldNothing.length; ++i) {
            address f = m.mustHoldNothing[i];
            require(f != safe && f != address(tl), "M1 preflight: manifest lists the Safe / timelock as must-hold-nothing");
            require(!tl.hasRole(A, f), "M1 preflight: a listed account holds DEFAULT_ADMIN_ROLE");
            require(!tl.hasRole(P, f) && !tl.hasRole(C, f) && !tl.hasRole(E, f),
                "M1 preflight: a listed account holds a timelock role");
        }
    }

    /// @notice Local development chains on which the attestation opt-out / a larger max age is permitted.
    function _isLocalChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }

    function _sameSet(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            bool found;
            for (uint256 k; k < b.length; ++k) if (a[i] == b[k]) { found = true; break; }
            if (!found) return false;
        }
        return true;
    }

    function _attestedRole(TimelockController tl, string memory j, string memory role, bytes32 roleId,
        address[] memory manifestSet) internal view
    {
        address[] memory att = vm.parseJsonAddressArray(j, string.concat(".roles.", role));
        require(_sameSet(att, manifestSet) && _sameSet(manifestSet, att),
            string.concat("roles attestation: attested ", role, " holders != manifest"));
        for (uint256 i; i < att.length; ++i) {
            require(tl.hasRole(roleId, att[i]), string.concat("roles attestation: attested ", role, " holder no longer holds it"));
        }
    }

    string internal constant ATTEST_SCHEMA = "d5b-timelock-roles-attestation/2";

    /// @notice Maximum accepted attestation age: TL_ATTEST_MAX_AGE may LOWER the 256-block default
    ///         anywhere, but raise it only on a local chain (31337 / 1337). Operator safety, not security.
    function attestMaxAge(uint256 requested) public view returns (uint256) {
        require(requested <= ATTEST_MAX_AGE_BLOCKS || _isLocalChain(),
            "roles attestation: TL_ATTEST_MAX_AGE above 256 is local-only");
        return requested;
    }

    /**
     * @notice OPERATOR PREFLIGHT on the event-history checker's attestation — NOT an enforcement
     *         boundary (Codex re-check of 626b6ea8, H1/H2). The attestation is UNSIGNED (a hand-made
     *         file can claim PASS and omit a holder), it is a snapshot (a grant made after its head block
     *         stays invisible until it is TL_ATTEST_MAX_AGE blocks old), and it only gates THIS script:
     *         the Safe can submit the printed calldata later, or build its own, without any of it. What
     *         it is for: stopping an operator from preparing a schedule / execute against a timelock whose
     *         role history no longer matches the committed manifest. Checks, all before anything is
     *         broadcast: schema == ATTEST_SCHEMA; result == "PASS"; chainId == block.chainid; timelock ==
     *         this timelock; manifestKeccak256 == keccak256 of the manifest file as read now (and the
     *         attested manifestChainId / deploymentBlock / mustHoldNothing / labels == the values forge
     *         read: the checker only attests canonical bytes, so this carries the canonical form over); the head
     *         block is not in the future and at most attestMaxAge(TL_ATTEST_MAX_AGE, default 256) blocks
     *         old; on a LIVE chain id the head must be 1..256 blocks older than block.number and
     *         blockhash(head) must be non-zero and equal headBlockHash (fail-closed: same-chain-id fork /
     *         reorg / an attestation of the current block is refused); on a local chain id an unavailable
     *         blockhash is tolerated and loudly logged; each attested holder set equals the manifest's and every
     *         attested holder still holds its role. Opt-out: TL_ALLOW_NO_ATTESTATION=true only on chain ids
     *         31337 / 1337, loudly logged; it reverts on any other chain. The on-chain basis of role
     *         exclusivity is the timelock's self-administration + monitoring (D5b-design §6.3d).
     */
    function requireRolesAttestation(TimelockController tl, RoleManifest memory m) public view {
        if (bytes(m.attestation).length == 0) {
            if (m.optOut) {
                require(_isLocalChain(), "roles attestation: opt-out is impossible on a live chain");
                console.log("  !!!!! WARNING: TL_ALLOW_NO_ATTESTATION - role exclusivity NOT checked (local chain only) !!!!!");
                console.log("  !!!!! WARNING: manifest canonical byte form NOT verified - forge parsed it best-effort (local chain only) !!!!!");
                return;
            }
            revert("roles attestation: missing (set TL_ROLES_ATTESTATION to the check-timelock-roles.mjs output)");
        }
        require(!m.optOut || _isLocalChain(), "roles attestation: opt-out is impossible on a live chain");
        string memory j;
        try vm.readFile(m.attestation) returns (string memory body) {
            j = body;
        } catch {
            revert("roles attestation: file unreadable");
        }
        require(vm.keyExistsJson(j, ".schema")
            && keccak256(bytes(vm.parseJsonString(j, ".schema"))) == keccak256(bytes(ATTEST_SCHEMA)),
            "roles attestation: schema != d5b-timelock-roles-attestation/2");
        require(keccak256(bytes(vm.parseJsonString(j, ".result"))) == keccak256("PASS"), "roles attestation: result != PASS");
        require(vm.parseJsonUint(j, ".chainId") == block.chainid, "roles attestation: chainId != this chain");
        require(vm.parseJsonAddress(j, ".timelock") == address(tl), "roles attestation: timelock mismatch");
        require(vm.parseJsonBytes32(j, ".manifestKeccak256") == m.fileKeccak,
            "roles attestation: manifest changed after the attestation");
        uint256 head = vm.parseJsonUint(j, ".headBlock");
        require(head <= block.number, "roles attestation: head block is in the future");
        require(block.number - head <= attestMaxAge(vm.envOr("TL_ATTEST_MAX_AGE", ATTEST_MAX_AGE_BLOCKS)),
            "roles attestation: stale");
        require(vm.keyExistsJson(j, ".headBlockHash"), "roles attestation: headBlockHash missing");
        bytes32 attestedHash = vm.parseJsonBytes32(j, ".headBlockHash");
        bool inWindow = head < block.number && block.number - head <= 256;
        bytes32 chainHash = inWindow ? blockhash(head) : bytes32(0);
        if (!_isLocalChain()) {
            // Codex re-check of 7ca43549, L1: fail closed on live chains
            require(inWindow, "roles attestation: live chain: head must be 1..256 blocks older than block.number");
            require(chainHash != bytes32(0), "roles attestation: live chain: blockhash(head) unavailable");
        }
        if (chainHash != bytes32(0)) {
            require(chainHash == attestedHash, "roles attestation: headBlockHash != this chain's block (fork / reorg)");
            console.log("  roles attestation: head block hash verified against blockhash()", head);
        } else {
            console.log("  !!!!! roles attestation: head block hash NOT verified (local chain only: blockhash unavailable) !!!!!", head);
        }
        // Canonical form, transitively (Codex re-check of 48cba3bd): the checker attests PASS only for a
        // manifest whose bytes are its canonical serialization; manifestKeccak256 above binds the file
        // forge read to exactly those bytes; so forge's cheatcode reading is a reading of canonical
        // bytes, and it must agree with the values the checker attested. (Still an operator preflight:
        // the attestation is unsigned.)
        require(vm.parseJsonUint(j, ".manifestChainId") == m.chainId, "roles attestation: attested manifest chainId != manifest");
        require(vm.parseJsonUint(j, ".deploymentBlock") == m.deploymentBlock, "roles attestation: attested deploymentBlock != manifest");
        address[] memory attMhn = vm.parseJsonAddressArray(j, ".mustHoldNothing");
        require(attMhn.length == m.mustHoldNothing.length, "roles attestation: attested mustHoldNothing != manifest");
        for (uint256 i; i < attMhn.length; ++i) {
            require(attMhn[i] == m.mustHoldNothing[i], "roles attestation: attested mustHoldNothing != manifest");
        }
        string[] memory attLabels = vm.parseJsonStringArray(j, ".mustHoldNothingLabels");
        require(attLabels.length == m.mustHoldNothingLabels.length, "roles attestation: attested labels != manifest");
        for (uint256 i; i < attLabels.length; ++i) {
            require(keccak256(bytes(attLabels[i])) == keccak256(bytes(m.mustHoldNothingLabels[i])),
                "roles attestation: attested labels != manifest");
        }
        _attestedRole(tl, j, "DEFAULT_ADMIN_ROLE", tl.DEFAULT_ADMIN_ROLE(), m.admins);
        _attestedRole(tl, j, "PROPOSER_ROLE", tl.PROPOSER_ROLE(), m.proposers);
        _attestedRole(tl, j, "CANCELLER_ROLE", tl.CANCELLER_ROLE(), m.cancellers);
        _attestedRole(tl, j, "EXECUTOR_ROLE", tl.EXECUTOR_ROLE(), m.executors);
        console.log("  roles attestation OK (operator preflight; unsigned, not an enforcement boundary), head block", head);
    }

    /// @notice The operator preflight every schedule-* / execute-* mode runs before it broadcasts or prints:
    ///         bounded known-account check, then the attestation check. It binds only this script run.
    function operatorPreflight(TimelockController tl, RoleManifest memory m) public view {
        m1Preflight(tl, m);
        requireRolesAttestation(tl, m);
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
        return scheduleUpgradeWith(c, isSP, impl, salt, proposer, _manifest(c));
    }

    function scheduleUpgradeWith(Cfg memory c, bool isSP, address impl, bytes32 salt, address proposer,
        RoleManifest memory m) public returns (bytes32 id)
    {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m);
        address safe = _safeOf(m);
        address proxy = isSP ? c.sp : c.registry;
        require(ID5bOwned(proxy).owner() == address(tl), "schedule: proxy owner is not the timelock");
        require(vm.load(proxy, OWNERSHIP_2STEP_SLOT) == bytes32(0), "pending ownership nomination: cancel it first (_authorizeUpgrade refuses)");
        if (isSP) _requireSPImplReady(impl, c);
        else _requireRegistryImplReady(impl);
        bytes memory data = _upgradeCall(impl);
        uint256 delay = tl.getMinDelay();
        id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        if (proposer == safe) {
            vm.startBroadcast(proposer);
            tl.schedule(proxy, 0, data, bytes32(0), salt, delay);
            vm.stopBroadcast();
            require(tl.isOperationPending(id), "schedule: not pending after schedule");
            console.log("  scheduled; ready at:", tl.getTimestamp(id));
        } else {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this from the Safe:");
            console.log("  to  :", address(tl));
            console.logBytes(abi.encodeCall(TimelockController.schedule, (proxy, 0, data, bytes32(0), salt, delay)));
        }
        console.logBytes32(id);
    }

    function executeUpgrade(Cfg memory c, bool isSP, address impl, bytes32 salt, address executor) public {
        executeUpgradeWith(c, isSP, impl, salt, executor, _manifest(c));
    }

    function executeUpgradeWith(Cfg memory c, bool isSP, address impl, bytes32 salt, address executor,
        RoleManifest memory m) public
    {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m); // again, immediately before the execute broadcast
        address safe = _safeOf(m);
        address proxy = isSP ? c.sp : c.registry;
        bytes memory data = _upgradeCall(impl);
        bytes32 id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        require(tl.isOperationReady(id), "execute: operation not ready (not scheduled, or minDelay not elapsed)");
        require(vm.load(proxy, OWNERSHIP_2STEP_SLOT) == bytes32(0), "pending ownership nomination: cancel it first (_authorizeUpgrade refuses)");
        // Re-validate at execution time as well as scheduling time. An operation may have been
        // scheduled outside this script, and the non-Safe path below only prints calldata (so its
        // post-execution read-backs cannot protect the signers).
        if (isSP) _requireSPImplReady(impl, c);
        else _requireRegistryImplReady(impl);
        address owner = ID5bOwned(proxy).owner();
        Bls3 memory bls = _bls(c);
        bytes32[] memory before = _slots(proxy, isSP ? SP_LAYOUT_END : REGISTRY_LAYOUT_END);
        if (executor != safe) {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this from the Safe:");
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
        require(vm.load(proxy, OWNERSHIP_2STEP_SLOT) == bytes32(0), "pending ownership nomination: cancel it first (_authorizeUpgrade refuses)");
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
        return scheduleAcceptWith(c, safe, salt, proposer, _manifest(c));
    }

    function scheduleAcceptWith(Cfg memory c, address safe, bytes32 salt, address proposer, RoleManifest memory m)
        public returns (bytes32 id)
    {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m);
        require(safe == _safeOf(m), "M1 preflight: guardian Safe != manifest Safe");
        require(ID5bOwned(c.sp).pendingOwner() == address(tl), "M1: SP.pendingOwner != timelock (run SP.transferOwnership(timelock) first)");
        require(ID5bOwned(c.registry).pendingOwner() == address(tl), "M1: Registry.pendingOwner != timelock");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _acceptBatch(c, safe);
        uint256 delay = tl.getMinDelay();
        id = tl.hashOperationBatch(t, v, p, bytes32(0), salt);
        if (proposer == safe) {
            vm.startBroadcast(proposer);
            tl.scheduleBatch(t, v, p, bytes32(0), salt, delay);
            vm.stopBroadcast();
            require(tl.isOperationPending(id), "M1: batch not pending");
            console.log("  M1 batch scheduled; ready at:", tl.getTimestamp(id));
        } else {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this scheduleBatch from the Safe:");
            console.logBytes(abi.encodeCall(TimelockController.scheduleBatch, (t, v, p, bytes32(0), salt, delay)));
        }
        console.logBytes32(id);
    }

    function executeAccept(Cfg memory c, address safe, bytes32 salt, address executor) public {
        executeAcceptWith(c, safe, salt, executor, _manifest(c));
    }

    function executeAcceptWith(Cfg memory c, address safe, bytes32 salt, address executor, RoleManifest memory m) public {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m); // again, immediately before the acceptance broadcast
        require(safe == _safeOf(m), "M1 preflight: guardian Safe != manifest Safe");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _acceptBatch(c, safe);
        bytes32 id = tl.hashOperationBatch(t, v, p, bytes32(0), salt);
        require(tl.isOperationReady(id), "M1: batch not ready");
        if (executor != safe) {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this executeBatch from the Safe:");
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

    /// @dev A governed call must not be an upgrade: upgrades go through schedule-upgrade / execute-upgrade,
    ///      which carry the implementation checks and read-backs.
    function _governedCall(Cfg memory c, bool isSP, bytes memory data) internal pure returns (address proxy) {
        require(data.length >= 4, "governed call: calldata too short");
        require(bytes4(data) != ID5bOwned.upgradeToAndCall.selector, "governed call: use schedule-upgrade for upgrades");
        proxy = isSP ? c.sp : c.registry;
    }

    /// @notice Schedule any other timelock-governed SP / Registry call (runbook M2 unpause, parameter
    ///         changes) behind the same operator preflight as the upgrade and acceptance paths.
    function scheduleCallWith(Cfg memory c, bool isSP, bytes memory data, bytes32 salt, address proposer,
        RoleManifest memory m) public returns (bytes32 id)
    {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m);
        address safe = _safeOf(m);
        address proxy = _governedCall(c, isSP, data);
        require(ID5bOwned(proxy).owner() == address(tl), "schedule: proxy owner is not the timelock");
        uint256 delay = tl.getMinDelay();
        id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        if (proposer == safe) {
            vm.startBroadcast(proposer);
            tl.schedule(proxy, 0, data, bytes32(0), salt, delay);
            vm.stopBroadcast();
            require(tl.isOperationPending(id), "schedule: not pending after schedule");
            console.log("  call scheduled; ready at:", tl.getTimestamp(id));
        } else {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this from the Safe:");
            console.logBytes(abi.encodeCall(TimelockController.schedule, (proxy, 0, data, bytes32(0), salt, delay)));
        }
        console.logBytes32(id);
    }

    function executeCallWith(Cfg memory c, bool isSP, bytes memory data, bytes32 salt, address executor,
        RoleManifest memory m) public
    {
        TimelockController tl = _timelock(c);
        operatorPreflight(tl, m); // again, immediately before the execute broadcast
        address safe = _safeOf(m);
        address proxy = _governedCall(c, isSP, data);
        bytes32 id = tl.hashOperation(proxy, 0, data, bytes32(0), salt);
        require(tl.isOperationReady(id), "execute: operation not ready (not scheduled, or minDelay not elapsed)");
        if (executor != safe) {
            _safeSignerNotice();
            console.log("  broadcaster is not the Safe - submit this from the Safe:");
            console.logBytes(abi.encodeCall(TimelockController.execute, (proxy, 0, data, bytes32(0), salt)));
            return;
        }
        vm.startBroadcast(executor);
        tl.execute(proxy, 0, data, bytes32(0), salt);
        vm.stopBroadcast();
        require(tl.isOperationDone(id), "execute: operation not done");
        console.log("  governed call executed", proxy);
    }
}
