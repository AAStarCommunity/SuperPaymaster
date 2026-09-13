// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title DefaultArtifacts
 * @notice "Tested == deployed" (AUD-4 / R10-M5 / T-4): deploy every contract from its
 *         profile.default compiler artifact BY EXPLICIT PATH and require the deployed runtime to
 *         equal that artifact (immutable ranges masked).
 * @dev    Why: foundry.toml's Registry `compilation_restrictions` compiles any source file that
 *         imports Registry.sol — and its whole closure — under the runs=200 "registry-size"
 *         compiler profile. Every deploy script imports Registry.sol, so a plain `new X(...)` in a
 *         script ships the runs=200 bytes, not the runs=500 bytes the test suite and the size
 *         evidence were measured on.
 *
 *         Which file is "the default artifact" is NOT decided by its name: forge names an artifact
 *         `X.json` when only one profile built X and `X.default.json` / `X.registry-size.json` when
 *         both did (and nests it, e.g. out/core/EntryPoint.sol/, when source names collide), and
 *         that changes from build to build; the unsuffixed file is simply the LAST compile
 *         (`forge test --evm-version prague` rewrites it with a Prague build). The resolver maps
 *         each contract to its source file, tries every layout forge uses, and accepts only an
 *         artifact whose OWN metadata matches [profile.default] exactly: compilation target,
 *         solc 0.8.33, optimizer on with runs 500 (Registry: its compilation_restrictions 200),
 *         viaIR, evmVersion cancun, and the source keccak256 == the source file now. Zero or
 *         two different matching builds fail.
 *
 *         Run a plain `forge build` before any script using this (deploy-core, prepare-test and
 *         audit-core do): `forge script` only compiles the script's own closure, so it does not
 *         refresh the default artifacts.
 */
/// @notice Artifact lookups / comparisons, each executed in its OWN call frame.
/// @dev    A script's run() is ONE call frame and Solidity never frees memory: reading and handing
///         an artifact JSON to the parsing cheatcodes per check, dozens of times, grows that frame until
///         the quadratic memory-expansion cost ends the script with MemoryOOG (observed after the
///         5th contract). DefaultArtifacts therefore calls this separate helper through EXTERNAL
///         VIEW calls (STATICCALL: never recorded as a broadcast transaction); each call's memory
///         is released on return. (A self-call is not an option: forge rejects `address(this)` in
///         a script contract.) The helper is created in the script's constructor, i.e. outside any
///         broadcast, so it is never deployed on-chain.
contract T4ArtifactReader is Script {
    uint256 internal constant DEFAULT_RUNS = 500;
    uint256 internal constant REGISTRY_RUNS = 200; // foundry.toml compilation_restrictions, every profile

    struct ImmRef {
        uint256 length; // JSON keys decode in alphabetical order
        uint256 start;
    }

    function _expectedRuns(string memory name) internal pure returns (uint256) {
        return keccak256(bytes(name)) == keccak256("Registry") ? REGISTRY_RUNS : DEFAULT_RUNS;
    }

    function _runsOf(string memory json) internal pure returns (uint256) {
        try vm.parseJsonUint(json, ".metadata.settings.optimizer.runs") returns (uint256 r) {
            return r;
        } catch {
            return 0;
        }
    }

    function _tryRead(string memory rel) internal view returns (bool ok, string memory json) {
        try vm.readFile(string.concat(vm.projectRoot(), "/", rel)) returns (string memory j) {
            return (true, j);
        } catch {
            return (false, "");
        }
    }

    /// @notice Source file of every contract the deploy scripts create. The artifact is identified
    ///         by its compilation target (source) and optimizer runs, never by file name alone:
    ///         names collide (three EntryPoint.sol in the tree → out/core/EntryPoint.sol/…) and the
    ///         suffix scheme changes with which profiles happened to build a source.
    function _sourceOf(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(name));
        string memory OZ = "singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/";
        string memory AA = "singleton-paymaster/lib/account-abstraction-v7/contracts/";
        if (h == keccak256("Registry")) return "contracts/src/core/Registry.sol";
        if (h == keccak256("GTokenStaking")) return "contracts/src/core/GTokenStaking.sol";
        if (h == keccak256("PolicyRegistry")) return "contracts/src/core/PolicyRegistry.sol";
        if (h == keccak256("LivenessRegistry")) return "contracts/src/core/LivenessRegistry.sol";
        if (h == keccak256("GTokenAuthorization")) return "contracts/src/tokens/GTokenAuthorization.sol";
        if (h == keccak256("MySBT")) return "contracts/src/tokens/MySBT.sol";
        if (h == keccak256("xPNTsFactory")) return "contracts/src/tokens/xPNTsFactory.sol";
        if (h == keccak256("xPNTsToken")) return "contracts/src/tokens/xPNTsToken.sol";
        if (h == keccak256("AOAProtocolRegistry")) return "contracts/src/tokens/v2/AOAProtocolRegistry.sol";
        if (h == keccak256("GlobalTierSource")) return "contracts/src/tokens/v2/GlobalTierSource.sol";
        if (h == keccak256("xPNTsTokenV2Ext")) return "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol";
        if (h == keccak256("xPNTsTokenV2")) return "contracts/src/tokens/v2/xPNTsTokenV2.sol";
        if (h == keccak256("xPNTsFactoryV2")) return "contracts/src/tokens/v2/xPNTsFactoryV2.sol";
        if (h == keccak256("ReputationSystem")) return "contracts/src/modules/reputation/ReputationSystem.sol";
        if (h == keccak256("DVTValidator")) return "contracts/src/modules/monitoring/DVTValidator.sol";
        if (h == keccak256("BLSAggregator")) return "contracts/src/modules/monitoring/BLSAggregator.sol";
        if (h == keccak256("SuperPaymaster")) return "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
        if (h == keccak256("SuperPaymasterAdmin")) return "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol";
        if (h == keccak256("SuperPaymasterLens")) return "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
        if (h == keccak256("MicroPaymentChannel")) return "contracts/src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
        if (h == keccak256("X402Facilitator")) return "contracts/src/paymasters/superpaymaster/v3/X402Facilitator.sol";
        if (h == keccak256("PaymasterFactory")) return "contracts/src/paymasters/v4/core/PaymasterFactory.sol";
        if (h == keccak256("Paymaster")) return "contracts/src/paymasters/v4/Paymaster.sol";
        if (h == keccak256("MockAgentIdentityRegistry")) return "contracts/src/mocks/MockAgentIdentityRegistry.sol";
        if (h == keccak256("MockAgentReputationRegistry")) return "contracts/src/mocks/MockAgentReputationRegistry.sol";
        if (h == keccak256("AnvilMockPriceFeed")) return "contracts/test/helpers/AnvilMockPriceFeed.sol";
        if (h == keccak256("ERC1967Proxy")) return string.concat(OZ, "proxy/ERC1967/ERC1967Proxy.sol");
        if (h == keccak256("TimelockController")) return string.concat(OZ, "governance/TimelockController.sol");
        if (h == keccak256("EntryPoint")) return string.concat(AA, "core/EntryPoint.sol");
        if (h == keccak256("SimpleAccountFactory")) return string.concat(AA, "samples/SimpleAccountFactory.sol");
        if (h == keccak256("SimpleAccount")) return string.concat(AA, "samples/SimpleAccount.sol");
        revert(string.concat("DefaultArtifacts: no source mapping for ", name));
    }

    function t4DefaultArtifact(string calldata name) external view returns (string memory) {
        return _defaultArtifactImpl(name);
    }

    function t4CodeEqArtifact(address target, string calldata rel) external view returns (bool) {
        return _codeEqArtifactImpl(target, rel);
    }

    /// @notice Number of distinct immutables (AST ids) in the artifact's runtime.
    function t4ImmutableCount(string calldata rel) external view returns (uint256) {
        (bool ok, string memory json) = _tryRead(rel);
        require(ok, string.concat("DefaultArtifacts: artifact missing: ", rel));
        try vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences") returns (string[] memory k) {
            return k.length;
        } catch {
            return 0;
        }
    }

    /// @notice The exact [profile.default] build settings (foundry.toml). An artifact is accepted
    ///         only if its OWN metadata carries every one of them — see `_isDefaultBuild`.
    string internal constant DEFAULT_SOLC_PREFIX = "0.8.33+";
    string internal constant DEFAULT_EVM = "cancun";

    /// @notice Relative path of the profile.default artifact of contract `name` (Registry: its
    ///         only, compilation_restrictions-limited runs=200 build). Reverts unless EXACTLY one
    ///         distinct build matches (run a plain `forge build` first).
    /// @dev Candidate paths are every layout forge uses for a source (plain, `.default` suffix,
    ///      nested under 1–2 parent directories when names collide). File names prove nothing:
    ///      the UNSUFFIXED `X.json` is overwritten by whichever compile ran last — e.g.
    ///      `forge test --evm-version prague` leaves a Prague/500 `SuperPaymaster.json` next to a
    ///      Cancun/500 `SuperPaymaster.default.json`, and a check on optimizer runs alone picked
    ///      the Prague one (Codex stop-review, CRITICAL-1). Several candidates may be byte-identical
    ///      copies of the same build (stale unsuffixed + suffixed); two DIFFERENT matching builds
    ///      is ambiguous and fails. (The forge cache index would give the path directly, but
    ///      handing its ~0.8 MB to a JSON cheatcode costs ~12M gas per lookup.)
    function _defaultArtifactImpl(string memory name) internal view returns (string memory) {
        string memory src = _sourceOf(name);
        (string memory file, string memory d1, string memory d2) = _tail3(src);
        string memory n1 = string.concat("/", name, ".json");
        string memory n2 = string.concat("/", name, ".default.json");
        string[6] memory c = [
            string.concat("out/", file, n1),
            string.concat("out/", file, n2),
            string.concat("out/", d1, "/", file, n1),
            string.concat("out/", d1, "/", file, n2),
            string.concat("out/", d2, "/", d1, "/", file, n1),
            string.concat("out/", d2, "/", d1, "/", file, n2)
        ];
        (bool okSrc, string memory source) = _tryRead(src);
        require(okSrc, string.concat("DefaultArtifacts: source file missing: ", src));
        bytes32 srcHash = keccak256(bytes(source));
        uint256 found;
        string memory pick;
        bytes32 pickCode;
        for (uint256 i; i < c.length; ++i) {
            (bool ok, string memory j) = _tryRead(c[i]);
            if (!ok || !_isDefaultBuild(j, src, srcHash, _expectedRuns(name))) continue;
            bytes32 code = keccak256(vm.parseJsonBytes(j, ".deployedBytecode.object"));
            if (found == 0) {
                pick = c[i];
                pickCode = code;
            } else {
                require(code == pickCode, string.concat("DefaultArtifacts: ambiguous default builds of ", name, ": ", pick, " vs ", c[i]));
            }
            found++;
        }
        require(found != 0, string.concat("DefaultArtifacts: no profile.default build of ", name, " from ", src, " (run a plain `forge build`)"));
        return pick;
    }

    /// @notice Artifact metadata == [profile.default]: compilation target, compiler version,
    ///         optimizer enabled + runs, viaIR, evmVersion, and the source keccak256 == the source
    ///         file as it is NOW (a stale artifact of an edited source fails).
    function _isDefaultBuild(string memory j, string memory src, bytes32 srcHash, uint256 runs)
        internal view returns (bool)
    {
        if (!vm.keyExistsJson(j, string.concat("$.metadata.settings.compilationTarget['", src, "']"))) return false;
        if (_runsOf(j) != runs) return false;
        try vm.parseJsonBool(j, ".metadata.settings.optimizer.enabled") returns (bool e) { if (!e) return false; } catch { return false; }
        try vm.parseJsonBool(j, ".metadata.settings.viaIR") returns (bool v) { if (!v) return false; } catch { return false; }
        try vm.parseJsonString(j, ".metadata.settings.evmVersion") returns (string memory ev) {
            if (keccak256(bytes(ev)) != keccak256(bytes(DEFAULT_EVM))) return false;
        } catch { return false; }
        try vm.parseJsonString(j, ".metadata.compiler.version") returns (string memory cv) {
            if (!_startsWith(cv, DEFAULT_SOLC_PREFIX)) return false;
        } catch { return false; }
        try vm.parseJsonBytes32(j, string.concat("$.metadata.sources['", src, "'].keccak256")) returns (bytes32 k) {
            if (k != srcHash) return false;
        } catch { return false; }
        return true;
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) if (a[i] != b[i]) return false;
        return true;
    }

    /// @dev "a/b/c/File.sol" -> ("File.sol", "c", "b").
    function _tail3(string memory path) internal pure returns (string memory f, string memory d1, string memory d2) {
        bytes memory b = bytes(path);
        uint256 end = b.length;
        string[3] memory parts;
        for (uint256 k; k < 3; ++k) {
            uint256 i = end;
            while (i > 0 && b[i - 1] != "/") --i;
            bytes memory seg = new bytes(end - i);
            for (uint256 m; m < seg.length; ++m) seg[m] = b[i + m];
            parts[k] = string(seg);
            if (i == 0) break;
            end = i - 1;
        }
        return (parts[0], parts[1], parts[2]);
    }

    function _codeEqArtifactImpl(address target, string memory rel) internal view returns (bool) {
        (bool ok, string memory json) = _tryRead(rel);
        if (!ok) return false;
        bytes memory art = vm.parseJsonBytes(json, ".deployedBytecode.object");
        bytes memory code = target.code;
        if (art.length == 0 || art.length != code.length) return false;
        // A contract without immutables has an empty/absent immutableReferences object, which
        // parseJsonKeys rejects — that simply means "nothing to mask".
        string[] memory keys;
        try vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences") returns (string[] memory k) {
            keys = k;
        } catch {
            keys = new string[](0);
        }
        for (uint256 i; i < keys.length; ++i) {
            ImmRef[] memory refs = abi.decode(
                vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences.", keys[i])), (ImmRef[])
            );
            for (uint256 j; j < refs.length; ++j) {
                uint256 end = refs[j].start + refs[j].length;
                require(end <= code.length, "DefaultArtifacts: immutable ref out of range");
                for (uint256 k = refs[j].start; k < end; ++k) {
                    code[k] = 0;
                    art[k] = 0;
                }
            }
        }
        return keccak256(code) == keccak256(art);
    }

}

abstract contract DefaultArtifacts is Script {
    /// @dev Simulation-only helper (constructor-time, outside any broadcast); see T4ArtifactReader.
    T4ArtifactReader internal _t4Reader = new T4ArtifactReader();

    function _defaultArtifact(string memory name) internal view returns (string memory) {
        return _t4Reader.t4DefaultArtifact(name);
    }

    /// @notice Deploy `name` from its profile.default artifact and require the deployed runtime
    ///         to equal it. Inside a broadcast, vm.deployCode is broadcast as a CREATE.
    function _deployDefault(string memory name, bytes memory args) internal returns (address a) {
        a = vm.deployCode(_defaultArtifact(name), args);
        _requireDefaultArtifact(a, name);
    }

    /// @notice Hard-fail unless `a`'s runtime equals the profile.default artifact of `name`.
    function _requireDefaultArtifact(address a, string memory name) internal view {
        require(
            _codeEqArtifact(a, _defaultArtifact(name)),
            string.concat("DefaultArtifacts: ", name, " runtime != profile.default artifact (T-4/AUD-4)")
        );
        console.log(string.concat("  [artifact] default artifact OK: ", name), a, a.code.length);
        if (keccak256(bytes(name)) == keccak256("SuperPaymaster")) _requireSPExtensionBinding(a);
    }

    /// @notice D5b-design §2.2: the SuperPaymaster core's EXTENSION immutable is MASKED by the runtime
    ///         comparison above, so a core bound to a foreign extension would pass it. Require the
    ///         extension (created by the core's constructor) to be the profile.default
    ///         SuperPaymasterAdmin build AND to carry the core's own immutables.
    function _requireSPExtensionBinding(address core) internal view {
        address ext = _addrCall(core, "EXTENSION()");
        require(ext != address(0) && ext.code.length > 0, "DefaultArtifacts: SuperPaymaster.EXTENSION missing");
        require(
            _codeEqArtifact(ext, _defaultArtifact("SuperPaymasterAdmin")),
            "DefaultArtifacts: SuperPaymaster.EXTENSION runtime != profile.default SuperPaymasterAdmin (T-4/AUD-4)"
        );
        string[3] memory imm = ["entryPoint()", "REGISTRY()", "ETH_USD_PRICE_FEED()"];
        for (uint256 i; i < 3; ++i) {
            address c = _addrCall(core, imm[i]);
            require(c != address(0) && c == _addrCall(ext, imm[i]),
                string.concat("DefaultArtifacts: extension/core immutable mismatch: ", imm[i]));
        }
        console.log("  [artifact] SuperPaymasterAdmin extension OK (default build; entryPoint/REGISTRY/feed == core)", ext);
    }

    function _addrCall(address target, string memory sig) internal view returns (address r) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (ok && ret.length >= 32) r = abi.decode(ret, (address));
    }

    /// @notice ERC-1967 proxy: the proxy runtime against ERC1967Proxy's default artifact, the
    ///         implementation (read from the ERC-1967 slot) against `implName`'s.
    function _requireDefaultProxy(address proxy, string memory implName) internal view returns (address impl) {
        _requireDefaultArtifact(proxy, "ERC1967Proxy");
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
        _requireDefaultArtifact(impl, implName);
    }

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice 1 = default artifact, 2 = registry-size artifact, 0 = neither (diagnostic).
    function _artifactMatch(address target, string memory name) internal view returns (uint8) {
        if (_codeEqArtifact(target, _defaultArtifact(name))) return 1;
        if (_codeEqArtifact(target, string.concat("out/", name, ".sol/", name, ".registry-size.json"))) return 2;
        return 0;
    }

    /// @notice Runtime code of `target` == `deployedBytecode` of the artifact at `rel`, with every
    ///         range listed in `immutableReferences` zeroed on both sides.
    function _codeEqArtifact(address target, string memory rel) internal view returns (bool) {
        return _t4Reader.t4CodeEqArtifact(target, rel);
    }

    /// @notice EIP-1167 clone (factory-made token / paymaster): the clone must be a canonical
    ///         minimal proxy and its embedded implementation must be `implName`'s default build.
    function _requireDefaultClone(address clone, string memory implName) internal view returns (address impl) {
        impl = _eip1167Impl(clone);
        require(impl != address(0), string.concat("DefaultArtifacts: not an EIP-1167 clone of ", implName));
        _requireDefaultArtifact(impl, implName);
        console.log(string.concat("  [artifact] EIP-1167 clone OK -> ", implName), clone);
    }

    /// @notice Implementation embedded in a canonical EIP-1167 minimal proxy (0 if not one).
    function _eip1167Impl(address clone) internal view returns (address) {
        bytes memory c = clone.code;
        if (c.length != 45) return address(0);
        bytes32 w0;
        bytes32 w1;
        assembly {
            w0 := mload(add(c, 0x20))
            w1 := mload(add(c, 0x40))
        }
        if (bytes10(w0) != bytes10(0x363d3d373d3d3d363d73)) return address(0);
        if (bytes2(w0 << 240) != bytes2(0x5af4) || bytes13(w1) != bytes13(0x3d82803e903d91602b57fd5bf3)) {
            return address(0);
        }
        return address(uint160(uint256(w0 >> 16)));
    }
}
