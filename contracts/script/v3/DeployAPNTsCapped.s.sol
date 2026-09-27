// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { DefaultArtifacts } from "./DefaultArtifacts.sol";

/// @dev Minimal views/calls of APNTsCapped (the contract is deployed from its artifact, not `new`).
interface IAPNTsCappedDeploy {
    function version() external view returns (string memory);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function cap() external view returns (uint256);
    function issuanceCap() external view returns (uint256);
    function isOverIssued() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function minter() external view returns (address);
    function capGuardian() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function mint(address to, uint256 amount) external;
    function raiseCap(uint256 newCap) external;
    function lowerCap(uint256 newCap) external;
    function renounceOwnership() external;
}

interface ITimelockDeploy {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function PROPOSER_ROLE() external view returns (bytes32);
    function CANCELLER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external pure returns (bytes32);
    function schedule(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt, uint256 delay)
        external;
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        external payable;
    function isOperationDone(bytes32 id) external view returns (bool);
}

/**
 * @title DeployAPNTsCapped — GOV-4 (b) aPNTs with an enforced cap (runbook §6 step 1 ②)
 * @notice Deploys APNTsCapped FROM ITS profile.default ARTIFACT (T-4 "tested == deployed":
 *         runtime compared to the artifact, immutables masked), then starts the Ownable2Step
 *         handover to the GOV-1 48h TimelockController. The handover completes only when the
 *         timelock executes `acceptOwnership()` (governance multisig proposes, 48h, executes);
 *         the script prints that Safe payload. Parameters are fixed by the author's decisions:
 *           name/symbol  "AAStar PNTs" / "aPNTs"
 *           minter       = capGuardian = governance multisig 0x51eD…E114 (Mycelium multisig)
 *           owner        = the 48h TimelockController (proposer/canceller = that multisig)
 *           cap          Sepolia / anvil: TEST_CAP_SEPOLIA = 10,000,000e18 (a TEST VALUE, not a
 *                        production number)
 *                        mainnet (chainid 1 / 10): the author's DECIDED initial cap is
 *                        300,000e18 aPNTs (MAINNET_DECIDED_CAP, 2026-09-13 via DSR). It must still
 *                        be passed EXPLICITLY as APNTS_CAP=300000000000000000000000 — the script
 *                        refuses to run without it, and logs a loud WARNING (in run() and in
 *                        verify()) if the value differs from the decided one.
 *
 * Usage (never broadcast to a public network from an unreviewed run):
 *   forge build   # the default artifacts must be fresh
 *   # fresh anvil: deploys a GOV-1-shaped timelock itself when TIMELOCK is unset
 *   forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped \
 *       --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <anvil acct>
 *   # Sepolia / mainnet: TIMELOCK=<GOV-1 timelock> [APNTS_CAP=<wei> on mainnet]
 *   # dry-run the acceptance in simulation: APNTS_SIMULATE_ACCEPT=true
 *   # after the timelock executed acceptOwnership() (TIMELOCK is required off anvil):
 *   TIMELOCK=<GOV-1 timelock> forge script ...:DeployAPNTsCapped \
 *       --sig "verify(address,address)" <token> <deployer> --rpc-url ...
 */
contract DeployAPNTsCapped is DefaultArtifacts {
    address internal constant GOV_MULTISIG = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    /// @notice TEST VALUE for Sepolia / anvil (author: "explicitly a test value"). NOT a mainnet cap.
    uint256 internal constant TEST_CAP_SEPOLIA = 10_000_000e18;
    /// @notice The author's decided mainnet initial cap (300,000 aPNTs). Documentation + read-back
    ///         reference only: mainnet mode still REQUIRES an explicit APNTS_CAP env value.
    uint256 internal constant MAINNET_DECIDED_CAP = 300_000e18;
    uint256 internal constant GOV_DELAY = 172_800; // 48h (GOV-1)
    string internal constant NAME = "AAStar PNTs";
    string internal constant SYMBOL = "aPNTs";
    string internal constant VERSION = "APNTsCapped-1.0.0";
    string internal constant SRC = "contracts/src/tokens/APNTsCapped.sol";
    bytes32 internal constant ACCEPT_SALT = keccak256("APNTsCapped-1.0.0/acceptOwnership");
    uint256 internal constant DEFAULT_RUNS = 500;

    string internal _artifactPath;

    // ------------------------------------------------------------------
    // entry points
    // ------------------------------------------------------------------

    function run() external {
        (string memory mode, uint256 cap_) = _modeAndCap();
        address deployer = msg.sender;
        console.log("=== DeployAPNTsCapped ===  mode:", mode);
        console.log("  chainid", block.chainid);
        console.log("  deployer", deployer);
        console.log("  governance multisig (minter + capGuardian + timelock proposer)", GOV_MULTISIG);

        bool isAnvil = block.chainid == 31337;
        address timelock = vm.envOr("TIMELOCK", address(0));
        if (!isAnvil) {
            require(timelock != address(0), "TIMELOCK (the GOV-1 48h TimelockController) is required off anvil");
            require(GOV_MULTISIG.code.length > 0, "governance multisig has no code on this chain");
        }

        string memory path = _apntsArtifact();

        vm.startBroadcast();
        if (timelock == address(0)) {
            // anvil only: a GOV-1-shaped timelock (48h; proposer = canceller = executor = multisig; no admin)
            address[] memory ms = new address[](1);
            ms[0] = GOV_MULTISIG;
            _requireCancunArtifact(_defaultArtifact("TimelockController"));
            timelock = _deployDefault("TimelockController", abi.encode(GOV_DELAY, ms, ms, address(0)));
            console.log("  [anvil] deployed GOV-1-shaped TimelockController", timelock);
        }
        _checkTimelock(timelock, deployer);

        address token = vm.deployCode(path, abi.encode(NAME, SYMBOL, cap_, deployer, GOV_MULTISIG, GOV_MULTISIG));
        IAPNTsCappedDeploy(token).transferOwnership(timelock);
        vm.stopBroadcast();

        require(_codeEqArtifact(token, path), "APNTsCapped runtime != profile.default artifact (T-4)");
        console.log("  [artifact] default artifact OK: APNTsCapped", token, token.code.length);
        console.log("  artifact", path);
        console.log("  runtime codehash");
        console.logBytes32(token.codehash);

        _checkPhaseA(token, timelock, cap_, deployer);
        _printSafePayloads(token, timelock);

        if (vm.envOr("APNTS_SIMULATE_ACCEPT", false)) {
            _simulateAccept(token, timelock);
            _verifyFinal(token, timelock, cap_, deployer);
            console.log("=== SIMULATED acceptance + final read-backs: ALL PASS (simulation only, nothing broadcast) ===");
        } else {
            console.log("=== Phase A done. Ownership is PENDING until the timelock executes acceptOwnership() ===");
        }
    }

    /// @notice Final read-backs on real chain state, after the timelock executed acceptOwnership().
    function verify(address token, address deployer) external {
        (, uint256 cap_) = _modeAndCap();
        address actualOwner = IAPNTsCappedDeploy(token).owner();
        address expectedTimelock = vm.envOr("TIMELOCK", address(0));
        if (block.chainid != 31337) {
            require(expectedTimelock != address(0), "verify: TIMELOCK is required off anvil");
        }
        if (expectedTimelock != address(0)) {
            require(actualOwner == expectedTimelock, "verify: token owner != expected TIMELOCK");
        }
        address timelock = expectedTimelock == address(0) ? actualOwner : expectedTimelock;
        console.log("=== verify APNTsCapped ===", token);
        require(_codeEqArtifact(token, _apntsArtifact()), "APNTsCapped runtime != profile.default artifact (T-4)");
        console.log("  [artifact] default artifact OK: APNTsCapped", token, token.code.length);
        _checkTimelock(timelock, deployer);
        _verifyFinal(token, timelock, cap_, deployer);
        console.log("=== verify: ALL PASS ===");
    }

    // ------------------------------------------------------------------
    // parameters
    // ------------------------------------------------------------------

    function _modeAndCap() internal view returns (string memory mode, uint256 cap_) {
        uint256 envCap = vm.envOr("APNTS_CAP", uint256(0));
        if (block.chainid == 1 || block.chainid == 10) {
            require(envCap != 0, "mainnet: APNTS_CAP (wei) is REQUIRED (decided value 300000e18 = 300000000000000000000000); refusing to run");
            _logMainnetCap(envCap);
            return ("mainnet", envCap);
        }
        if (block.chainid == 11155111 || block.chainid == 31337) {
            require(envCap == 0, "APNTS_CAP is mainnet-only; Sepolia/anvil use TEST_CAP_SEPOLIA");
            console.log("  cap = TEST_CAP_SEPOLIA =", TEST_CAP_SEPOLIA, "(TEST VALUE - not a production cap)");
            return (block.chainid == 31337 ? "anvil (TEST_CAP_SEPOLIA)" : "sepolia (TEST_CAP_SEPOLIA)", TEST_CAP_SEPOLIA);
        }
        revert("unsupported chain: expected 31337 (anvil), 11155111 (sepolia), 1 / 10 (mainnet)");
    }

    /// @dev Defense in depth at the call site: DefaultArtifacts already resolves by full default
    ///      metadata, including Cancun; keep this assertion beside the anvil timelock deployment.
    function _requireCancunArtifact(string memory rel) internal view {
        string memory j = vm.readFile(string.concat(vm.projectRoot(), "/", rel));
        require(
            keccak256(bytes(vm.parseJsonString(j, ".metadata.settings.evmVersion"))) == keccak256("cancun"),
            string.concat("artifact is not a cancun (profile.default) build - run a plain `forge build`: ", rel)
        );
    }

    /// @dev Mainnet cap read-back: log it, and warn LOUDLY when it is not the decided 300,000e18.
    function _logMainnetCap(uint256 c) internal pure {
        console.log("  cap (APNTS_CAP) =", c);
        console.log("  decided mainnet cap (MAINNET_DECIDED_CAP) =", MAINNET_DECIDED_CAP);
        if (c != MAINNET_DECIDED_CAP) {
            console.log("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            console.log("  !!! WARNING: APNTS_CAP differs from the author's decided mainnet cap 300000e18 !!!");
            console.log("  !!! Do NOT broadcast unless the author has changed the decision.            !!!");
            console.log("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        } else {
            console.log("  cap matches the decided mainnet cap (300000e18)");
        }
    }

    /// @dev profile.default artifact of APNTsCapped, identified by its OWN metadata — exact target,
    ///      solc, optimizer, evmVersion and viaIR — never by file name alone. Every source in the
    ///      artifact's compilation closure must still match disk, and conflicting matching candidates
    ///      fail instead of silently picking the first one.
    function _apntsArtifact() internal returns (string memory) {
        if (bytes(_artifactPath).length != 0) return _artifactPath;
        string[2] memory c = ["out/APNTsCapped.sol/APNTsCapped.json", "out/APNTsCapped.sol/APNTsCapped.default.json"];
        uint256 found;
        bytes32 selectedCreationCode;
        for (uint256 i; i < c.length; ++i) {
            try vm.readFile(string.concat(vm.projectRoot(), "/", c[i])) returns (string memory j) {
                if (_isCurrentDefaultAPNTsArtifact(j)) {
                    bytes32 creationCode = keccak256(vm.parseJsonBytes(j, ".bytecode.object"));
                    if (found != 0) {
                        require(
                            creationCode == selectedCreationCode,
                            "ambiguous profile.default APNTsCapped artifacts - run a clean plain `forge build`"
                        );
                    } else {
                        selectedCreationCode = creationCode;
                    }
                    _artifactPath = c[i];
                    found++;
                }
            } catch { }
        }
        if (found != 0) {
            console.log("  [artifact] APNTsCapped current default profile (cancun, solc 0.8.33, runs 500, via_ir):", _artifactPath);
            return _artifactPath;
        }
        revert("no profile.default (cancun/runs 500/via_ir) artifact of APNTsCapped - run a plain `forge build`");
    }

    function _isCurrentDefaultAPNTsArtifact(string memory j) internal view returns (bool) {
        string memory targetKey = string.concat("$.metadata.settings.compilationTarget['", SRC, "']");
        if (!vm.keyExistsJson(j, targetKey)) return false;
        try vm.parseJsonString(j, targetKey) returns (string memory target) {
            if (keccak256(bytes(target)) != keccak256("APNTsCapped")) return false;
        } catch { return false; }
        try vm.parseJsonString(j, ".metadata.compiler.version") returns (string memory compilerVersion) {
            if (!_startsWithAPNTs(compilerVersion, "0.8.33+")) return false;
        } catch { return false; }
        try vm.parseJsonBool(j, ".metadata.settings.optimizer.enabled") returns (bool enabled) {
            if (!enabled) return false;
        } catch { return false; }
        try vm.parseJsonUint(j, ".metadata.settings.optimizer.runs") returns (uint256 runs) {
            if (runs != DEFAULT_RUNS) return false;
        } catch { return false; }
        try vm.parseJsonString(j, ".metadata.settings.evmVersion") returns (string memory evmVersion) {
            if (keccak256(bytes(evmVersion)) != keccak256("cancun")) return false;
        } catch { return false; }
        try vm.parseJsonBool(j, ".metadata.settings.viaIR") returns (bool viaIR) {
            if (!viaIR) return false;
        } catch { return false; }
        try vm.parseJsonString(j, ".metadata.settings.metadata.bytecodeHash") returns (string memory bytecodeHash) {
            if (keccak256(bytes(bytecodeHash)) != keccak256("none")) return false;
        } catch { return false; }
        return _allArtifactSourcesFresh(j);
    }

    function _allArtifactSourcesFresh(string memory j) internal view returns (bool) {
        string[] memory sources;
        try vm.parseJsonKeys(j, "$.metadata.sources") returns (string[] memory keys) {
            sources = keys;
        } catch {
            return false;
        }
        for (uint256 i; i < sources.length; ++i) {
            string memory body;
            try vm.readFile(string.concat(vm.projectRoot(), "/", sources[i])) returns (string memory sourceBody) {
                body = sourceBody;
            } catch {
                return false;
            }
            try vm.parseJsonBytes32(j, string.concat("$.metadata.sources['", sources[i], "'].keccak256")) returns (bytes32 sourceHash) {
                if (sourceHash != keccak256(bytes(body))) return false;
            } catch {
                return false;
            }
        }
        return true;
    }

    function _startsWithAPNTs(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(value);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) if (a[i] != b[i]) return false;
        return true;
    }

    // ------------------------------------------------------------------
    // checks
    // ------------------------------------------------------------------

    function _checkTimelock(address timelock, address deployer) internal view {
        require(timelock.code.length > 0, "timelock has no code");
        ITimelockDeploy t = ITimelockDeploy(timelock);
        require(t.getMinDelay() == GOV_DELAY, "timelock getMinDelay() != 172800 (GOV-1 48h)");
        require(t.hasRole(t.PROPOSER_ROLE(), GOV_MULTISIG), "timelock: governance multisig is not PROPOSER");
        require(t.hasRole(t.CANCELLER_ROLE(), GOV_MULTISIG), "timelock: governance multisig is not CANCELLER");
        require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), timelock), "timelock: not self-administered");
        require(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), GOV_MULTISIG), "timelock: governance multisig still holds DEFAULT_ADMIN_ROLE");
        require(!t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer), "timelock: deployer still holds DEFAULT_ADMIN_ROLE");
        require(!t.hasRole(t.PROPOSER_ROLE(), deployer), "timelock: deployer still holds PROPOSER_ROLE");
        require(!t.hasRole(t.CANCELLER_ROLE(), deployer), "timelock: deployer still holds CANCELLER_ROLE");
        require(!t.hasRole(t.EXECUTOR_ROLE(), deployer), "timelock: deployer still holds EXECUTOR_ROLE");
        bool execMs = t.hasRole(t.EXECUTOR_ROLE(), GOV_MULTISIG);
        bool execOpen = t.hasRole(t.EXECUTOR_ROLE(), address(0));
        require(execMs && !execOpen, "timelock: executor policy must be multisig-only (not open)");
        console.log("  [timelock] OK", timelock);
        console.log("    minDelay 172800; multisig proposer+canceller+executor; executor open:", execOpen);
    }

    function _checkPhaseA(address token, address timelock, uint256 cap_, address deployer) internal view {
        IAPNTsCappedDeploy a = IAPNTsCappedDeploy(token);
        require(keccak256(bytes(a.version())) == keccak256(bytes(VERSION)), "version");
        require(keccak256(bytes(a.name())) == keccak256(bytes(NAME)), "name");
        require(keccak256(bytes(a.symbol())) == keccak256(bytes(SYMBOL)), "symbol");
        require(a.decimals() == 18, "decimals");
        require(a.cap() == cap_, "cap");
        require(a.minter() == GOV_MULTISIG, "minter");
        require(a.capGuardian() == GOV_MULTISIG, "capGuardian");
        require(a.totalSupply() == 0, "initial supply must be 0");
        require(a.owner() == deployer, "phase A: owner is still the deployer until accept");
        require(a.pendingOwner() == timelock, "phase A: pendingOwner == timelock");
        console.log("  [phase A] version", a.version());
        console.log("  [phase A] cap", a.cap());
        console.log("  [phase A] owner (deployer) / pendingOwner (timelock)", a.owner(), a.pendingOwner());
    }

    function _printSafePayloads(address token, address timelock) internal view {
        bytes memory data = abi.encodeCall(IAPNTsCappedDeploy.acceptOwnership, ());
        ITimelockDeploy t = ITimelockDeploy(timelock);
        console.log("  --- governance multisig -> timelock payloads (to:", timelock, ") ---");
        console.log("  1) schedule (now), then wait >= 48h:");
        console.logBytes(abi.encodeCall(ITimelockDeploy.schedule, (token, 0, data, bytes32(0), ACCEPT_SALT, GOV_DELAY)));
        console.log("  2) execute (after 48h):");
        console.logBytes(abi.encodeCall(ITimelockDeploy.execute, (token, 0, data, bytes32(0), ACCEPT_SALT)));
        console.log("  operation id:");
        console.logBytes32(t.hashOperation(token, 0, data, bytes32(0), ACCEPT_SALT));
    }

    /// @dev SIMULATION ONLY (pranks outside any broadcast are never sent): the multisig schedules
    ///      acceptOwnership, an early execute must fail, 48h later it executes.
    function _simulateAccept(address token, address timelock) internal {
        ITimelockDeploy t = ITimelockDeploy(timelock);
        bytes memory data = abi.encodeCall(IAPNTsCappedDeploy.acceptOwnership, ());
        bytes memory exec = abi.encodeCall(ITimelockDeploy.execute, (token, 0, data, bytes32(0), ACCEPT_SALT));
        vm.prank(GOV_MULTISIG);
        t.schedule(token, 0, data, bytes32(0), ACCEPT_SALT, GOV_DELAY);
        vm.warp(vm.getBlockTimestamp() + GOV_DELAY - 1);
        vm.prank(GOV_MULTISIG);
        (bool early, ) = timelock.call(exec);
        require(!early, "negative control: execute 1s before 48h must revert");
        console.log("  [sim] execute before 48h reverted (expected)");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(GOV_MULTISIG);
        (bool ok, ) = timelock.call(exec);
        require(ok, "timelock execute(acceptOwnership) after 48h failed");
        require(t.isOperationDone(t.hashOperation(token, 0, data, bytes32(0), ACCEPT_SALT)), "operation not done");
        console.log("  [sim] timelock executed acceptOwnership after 48h");
    }

    /// @dev `who` calling `data` on `token` must revert with exactly `expected` (a revert for the
    ///      wrong reason — e.g. a wrong selector — does not count).
    function _mustRevert(address token, address who, bytes memory data, bytes memory expected, string memory tag)
        internal
    {
        vm.prank(who);
        (bool ok, bytes memory ret) = token.call(data);
        require(!ok, string.concat("negative control FAILED (call succeeded): ", tag));
        require(keccak256(ret) == keccak256(expected), string.concat("negative control reverted for the wrong reason: ", tag));
        console.log("  [neg] reverted as expected:", tag);
    }

    function _verifyFinal(address token, address timelock, uint256 cap_, address deployer) internal {
        IAPNTsCappedDeploy a = IAPNTsCappedDeploy(token);
        require(keccak256(bytes(a.version())) == keccak256(bytes(VERSION)), "version");
        require(a.owner() == timelock, "owner() == timelock (Ownable2Step accept completed)");
        require(a.pendingOwner() == address(0), "pendingOwner() == 0");
        require(a.cap() == cap_, "cap");
        require(a.issuanceCap() == cap_, "issuanceCap == cap");
        require(a.minter() == GOV_MULTISIG, "minter == governance multisig");
        require(a.capGuardian() == GOV_MULTISIG, "capGuardian == governance multisig");
        require(a.totalSupply() <= a.cap(), "totalSupply <= cap");
        require(!a.isOverIssued(), "isOverIssued() == false");
        console.log("  [final] owner (timelock)", a.owner());
        console.log("  [final] pendingOwner", a.pendingOwner());
        console.log("  [final] cap / totalSupply", a.cap(), a.totalSupply());
        console.log("  [final] minter / capGuardian", a.minter(), a.capGuardian());

        // Negative controls: the deployer holds no power any more.
        _mustRevert(token, deployer, abi.encodeCall(IAPNTsCappedDeploy.mint, (deployer, 1)),
            abi.encodeWithSignature("NotMinter(address)", deployer), "deployer mint");
        _mustRevert(token, deployer, abi.encodeCall(IAPNTsCappedDeploy.raiseCap, (cap_ + 1)),
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer), "deployer raiseCap");
        _mustRevert(token, deployer, abi.encodeCall(IAPNTsCappedDeploy.lowerCap, (cap_ - 1)),
            abi.encodeWithSignature("NotCapGuardian(address)", deployer), "deployer lowerCap");
        _mustRevert(token, deployer, abi.encodeCall(IAPNTsCappedDeploy.transferOwnership, (deployer)),
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", deployer), "deployer transferOwnership");
        _mustRevert(token, timelock, abi.encodeCall(IAPNTsCappedDeploy.renounceOwnership, ()),
            abi.encodeWithSignature("RenounceDisabled()"), "timelock renounceOwnership");

        // Positive controls (simulation only, rolled back): the same calls from the right role
        // succeed, so the negative controls above failed for the reason they claim.
        uint256 snap = vm.snapshot();
        uint256 room = a.cap() - a.totalSupply();
        vm.prank(GOV_MULTISIG);
        a.mint(GOV_MULTISIG, room); // exactly up to the cap
        require(a.totalSupply() == a.cap(), "pos: minter mints up to exactly cap");
        vm.prank(GOV_MULTISIG);
        (bool over, ) = token.call(abi.encodeCall(IAPNTsCappedDeploy.mint, (GOV_MULTISIG, 1)));
        require(!over, "pos/neg: +1 wei over cap must revert");
        vm.prank(timelock);
        a.raiseCap(cap_ + 1);
        vm.prank(GOV_MULTISIG);
        a.lowerCap(cap_);
        require(a.cap() == cap_, "pos: owner raise + guardian lower");
        require(vm.revertTo(snap), "revertTo");
        require(a.cap() == cap_ && a.totalSupply() <= cap_, "state restored after positive controls");
        console.log("  [pos] minter mint-to-cap / +1 wei rejected / owner raise / guardian lower: OK (rolled back)");
    }
}
