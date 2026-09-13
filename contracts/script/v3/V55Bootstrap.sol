// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { SuperPaymasterLens } from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";

/// @dev Functions of an xPNTs v2 token that live in the EXTENSION (reached through the core's
///      fallback), plus the core views the scripts read back. One address serves both.
interface IxPNTsV2Script {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockedOf(address) external view returns (uint256);
    function creditReservedOf(address) external view returns (uint256);
    function debts(address) external view returns (uint256);
    function communityOwner() external view returns (address);
    function community() external view returns (address);
    function FACTORY() external view returns (address);
    function SUPERPAYMASTER_ADDRESS() external view returns (address);
    function BALANCE_MODE_VERSION() external view returns (uint16);
    function exchangeRate() external view returns (uint256);
    function creditTierSource() external view returns (address);
    function creditPolicy() external view returns (uint8);
    function usedOpHashes(bytes32) external view returns (bool);
    function version() external view returns (string memory);
}

/// @dev Minimal SP surface used by the v5.5.0 helpers (kept as an interface so this file does not
///      pull SuperPaymaster's full closure into every script that only needs the helpers).
interface ISPV55Script {
    function version() external view returns (string memory);
    function xpntsFactory() external view returns (address);
    function setXPNTsFactory(address) external;
    function configureOperator(address xPNTsToken, address treasury) external;
    function updatePrice() external;
    function cachedPrice() external view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals);
    function priceStalenessThreshold() external view returns (uint256);
    function operators(address operator) external view returns (
        uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken,
        uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored
    );
}

/**
 * @title V55Bootstrap
 * @notice Shared deploy / read-back helpers for the SuperPaymaster 5.5.0 + xPNTs v2 stack
 *         (spec docs/design/aoa-balance-mode/03-final-spec.md §6 runbook step 4, 6, 7a, 7c).
 * @dev    Order (mirrors contracts/test/helpers/V2TokenDeployer.sol):
 *           GlobalTierSource(registry)
 *           AOAProtocolRegistry(owner) -> bootstrapApprove(KIND_SP, spKey(SP))
 *                                     -> bootstrapApprove(KIND_TIER_SOURCE, tierSource.codehash)
 *                                     -> seal()
 *           xPNTsTokenV2Ext(aoa) -> xPNTsTokenV2(aoa, ext) [template]
 *           xPNTsFactoryV2(SP, registry, template, tierSource)
 *           SuperPaymasterLens
 *         then SP.setXPNTsFactory(factoryV2) (owner) and per community
 *         factoryV2.deployxPNTsToken(...) + SP.configureOperator(v2Token, treasury).
 *
 *         Every `_ensure*` helper is idempotent: a component whose address is supplied AND whose
 *         read-back matches is reused; anything else is (re)deployed. Every step READS BACK and
 *         `require`s the state it claims — a call that silently no-ops fails the script.
 */
abstract contract V55Bootstrap is Script {
    string internal constant SP_V55_VERSION = "SuperPaymaster-5.5.0";
    string internal constant XPNTS_V2_VERSION = "XPNTs-4.0.0";
    string internal constant FACTORY_V2_VERSION = "xPNTsFactory-3.0.0-v2";
    string internal constant AOA_REG_VERSION = "AOAProtocolRegistry-1.0.0";
    string internal constant TIER_SOURCE_VERSION = "GlobalTierSource-1.0.0";
    string internal constant LENS_VERSION = "SuperPaymasterLens-1.0.0";

    struct V55Stack {
        address tierSource;
        address aoaRegistry;
        address ext;
        address impl;
        address factory;
        address lens;
    }

    // ---------------------------------------------------------------------
    // Step 4: deploy (or resume) the v2 stack
    // ---------------------------------------------------------------------

    /// @notice Deploy or resume the stack. MUST run inside a broadcast whose sender == `owner`
    ///         (the AOA registry owner bootstraps the approvals; the factory owner wires SP).
    /// @param prev   addresses from a previous (possibly partial) run; zero = deploy fresh
    /// @param sp     SuperPaymaster PROXY address (KIND_SP is address-keyed, §10.5)
    /// @param registry Registry proxy (GlobalTierSource reads Registry.getCreditLimit)
    /// @param owner  broadcaster; becomes owner of the AOA registry and the factory
    function _ensureV55Stack(V55Stack memory prev, address sp, address registry, address owner)
        internal
        returns (V55Stack memory st)
    {
        require(sp != address(0) && registry != address(0), "V55: sp/registry = 0");

        // (1) GlobalTierSource — stateless, immutable REGISTRY
        if (_hasCode(prev.tierSource) && address(GlobalTierSource(prev.tierSource).REGISTRY()) == registry) {
            st.tierSource = prev.tierSource;
            console.log("  [v55] reuse GlobalTierSource   ", st.tierSource);
        } else {
            st.tierSource = _deployDefault("GlobalTierSource", abi.encode(registry));
            console.log("  [v55] new   GlobalTierSource   ", st.tierSource);
        }

        // (2) AOAProtocolRegistry — bootstrap approvals, then seal
        AOAProtocolRegistry aoa;
        if (_hasCode(prev.aoaRegistry)) {
            aoa = AOAProtocolRegistry(prev.aoaRegistry);
            console.log("  [v55] reuse AOAProtocolRegistry", address(aoa));
        } else {
            aoa = AOAProtocolRegistry(_deployDefault("AOAProtocolRegistry", abi.encode(owner)));
            console.log("  [v55] new   AOAProtocolRegistry", address(aoa));
        }
        st.aoaRegistry = address(aoa);
        bytes32 tierHash = st.tierSource.codehash;
        bool spOk = aoa.approved(aoa.KIND_SP(), aoa.spKey(sp));
        bool tierOk = aoa.approved(aoa.KIND_TIER_SOURCE(), tierHash);
        if (!aoa.sealed_()) {
            require(aoa.owner() == owner, "V55: AOA registry owner != broadcaster (cannot bootstrap)");
            if (!spOk) aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(sp));
            if (!tierOk) aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), tierHash);
            aoa.seal();
        } else {
            // Sealed: additions need the 48 h proposeApproval/executeApproval path. Refuse to
            // pretend — a resumed run with a missing approval must be fixed by hand.
            require(spOk, "V55: AOA registry sealed WITHOUT SP approval (needs 48h proposeApproval)");
            require(tierOk, "V55: AOA registry sealed WITHOUT tier-source approval (needs 48h proposeApproval)");
        }

        // (3) extension + (4) core template, both bound to this AOA registry
        if (_hasCode(prev.ext) && address(xPNTsTokenV2Ext(prev.ext).PROTOCOL_REGISTRY()) == st.aoaRegistry) {
            st.ext = prev.ext;
            console.log("  [v55] reuse xPNTsTokenV2Ext    ", st.ext);
        } else {
            st.ext = _deployDefault("xPNTsTokenV2Ext", abi.encode(st.aoaRegistry));
            console.log("  [v55] new   xPNTsTokenV2Ext    ", st.ext);
        }
        if (
            _hasCode(prev.impl) && xPNTsTokenV2(prev.impl).EXTENSION() == st.ext
                && address(xPNTsTokenV2(prev.impl).PROTOCOL_REGISTRY()) == st.aoaRegistry
        ) {
            st.impl = prev.impl;
            console.log("  [v55] reuse xPNTsTokenV2 impl  ", st.impl);
        } else {
            st.impl = _deployDefault("xPNTsTokenV2", abi.encode(st.aoaRegistry, st.ext));
            console.log("  [v55] new   xPNTsTokenV2 impl  ", st.impl);
        }

        // (5) factory: SUPERPAYMASTER = SP, template, default tier source
        if (
            _hasCode(prev.factory) && xPNTsFactoryV2(prev.factory).implementation() == st.impl
                && xPNTsFactoryV2(prev.factory).REGISTRY() == registry
        ) {
            st.factory = prev.factory;
            console.log("  [v55] reuse xPNTsFactoryV2     ", st.factory);
            xPNTsFactoryV2 f = xPNTsFactoryV2(st.factory);
            if (f.SUPERPAYMASTER() != sp) f.setSuperPaymasterAddress(sp);
            if (f.defaultTierSource() != st.tierSource) f.setDefaultTierSource(st.tierSource);
        } else {
            st.factory = _deployDefault("xPNTsFactoryV2", abi.encode(sp, registry, st.impl, st.tierSource));
            console.log("  [v55] new   xPNTsFactoryV2     ", st.factory);
        }

        // (6) lens (F1: dryRunValidation moved out of SP)
        if (_hasCode(prev.lens) && _strEq(SuperPaymasterLens(prev.lens).version(), LENS_VERSION)) {
            st.lens = prev.lens;
            console.log("  [v55] reuse SuperPaymasterLens ", st.lens);
        } else {
            st.lens = _deployDefault("SuperPaymasterLens", "");
            console.log("  [v55] new   SuperPaymasterLens ", st.lens);
        }
    }

    /// @notice Read back every property step 4 claims (D5-plan §4 step 4). View-only.
    /// @dev    The template's runtime code is compared byte-for-byte with the compiled artifact
    ///         after masking the immutable ranges the compiler reports (`_artifactMatch`). A
    ///         reference-instance codehash cannot be used: the template carries `address(this)`
    ///         immutables (EIP-712 domain cache), so two correct instances never share a codehash.
    ///         Constructor arguments are checked separately through the immutable getters.
    function _verifyV55Stack(V55Stack memory st, address sp, address registry) internal view {
        AOAProtocolRegistry aoa = AOAProtocolRegistry(st.aoaRegistry);
        require(_strEq(aoa.version(), AOA_REG_VERSION), "V55 readback: AOA registry version");
        require(aoa.sealed_(), "V55 readback: AOA registry not sealed");
        require(aoa.isApprovedSP(sp), "V55 readback: SP proxy not approved (KIND_SP)");
        require(aoa.isApprovedImpl(aoa.KIND_TIER_SOURCE(), st.tierSource), "V55 readback: tier source not approved");

        require(_strEq(GlobalTierSource(st.tierSource).version(), TIER_SOURCE_VERSION), "V55 readback: tier version");
        require(address(GlobalTierSource(st.tierSource).REGISTRY()) == registry, "V55 readback: tier REGISTRY");

        require(address(xPNTsTokenV2Ext(st.ext).PROTOCOL_REGISTRY()) == st.aoaRegistry, "V55 readback: ext registry");
        xPNTsTokenV2 impl = xPNTsTokenV2(st.impl);
        require(impl.EXTENSION() == st.ext, "V55 readback: template EXTENSION");
        require(address(impl.PROTOCOL_REGISTRY()) == st.aoaRegistry, "V55 readback: template registry");
        require(_strEq(impl.version(), XPNTS_V2_VERSION), "V55 readback: template version");
        require(impl.BALANCE_MODE_VERSION() == 1, "V55 readback: BALANCE_MODE_VERSION");
        // AUD-4 / R10-M5: every 5.5.0 contract must run the profile.default (runs=500) bytes —
        // the ones that were measured and audited — never the registry-size variant. Also covers
        // components REUSED by a resumed run, which `_deployDefault` never touched.
        _requireDefaultArtifact(st.tierSource, "GlobalTierSource");
        _requireDefaultArtifact(st.aoaRegistry, "AOAProtocolRegistry");
        _requireDefaultArtifact(st.ext, "xPNTsTokenV2Ext");
        _requireDefaultArtifact(st.impl, "xPNTsTokenV2");
        _requireDefaultArtifact(st.factory, "xPNTsFactoryV2");
        _requireDefaultArtifact(st.lens, "SuperPaymasterLens");

        xPNTsFactoryV2 f = xPNTsFactoryV2(st.factory);
        require(_strEq(f.version(), FACTORY_V2_VERSION), "V55 readback: factory version");
        require(f.SUPERPAYMASTER() == sp, "V55 readback: factory.SUPERPAYMASTER != SP");
        require(f.REGISTRY() == registry, "V55 readback: factory.REGISTRY");
        require(f.implementation() == st.impl, "V55 readback: factory.implementation");
        require(f.defaultTierSource() == st.tierSource, "V55 readback: factory.defaultTierSource");

        require(_strEq(SuperPaymasterLens(st.lens).version(), LENS_VERSION), "V55 readback: lens version");
        require(
            SuperPaymasterLens(st.lens).EXPECTED_SP_VERSION() == keccak256(bytes(SP_V55_VERSION)),
            "V55 readback: lens bound to another SP version"
        );
        console.log("  [v55] step-4 read-back OK (sealed registry, approvals, template codehash, factory->SP)");
    }

    /// @notice out/<name>.sol/<name>.json — the profile.default (runs=500) artifact.
    function _defaultArtifact(string memory name) internal pure returns (string memory) {
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    /// @notice Deploy `name` from the profile.default artifact BY PATH, then require the deployed
    ///         runtime to equal that artifact (immutables masked). A plain `new X(...)` in a file
    ///         that imports Registry.sol would silently pick the runs=200 "registry-size" build
    ///         (foundry.toml compilation_restrictions); an explicit artifact path cannot.
    /// @dev    Inside a broadcast, vm.deployCode is broadcast as a CREATE from the broadcaster.
    function _deployDefault(string memory name, bytes memory args) internal returns (address a) {
        a = vm.deployCode(_defaultArtifact(name), args);
        _requireDefaultArtifact(a, name);
    }

    function _requireDefaultArtifact(address a, string memory name) internal view {
        require(
            _codeEqArtifact(a, _defaultArtifact(name)),
            string.concat("V55: ", name, " runtime != profile.default artifact (AUD-4)")
        );
        console.log(string.concat("  [v55] artifact default (runs=500): ", name), a, a.code.length);
    }

    struct ImmRef {
        uint256 length; // JSON keys decode in alphabetical order
        uint256 start;
    }

    /// @notice Which compiled artifact `target`'s runtime code equals, immutables masked:
    ///         1 = out/<name>.sol/<name>.json (profile.default, runs=500),
    ///         2 = out/<name>.sol/<name>.registry-size.json (the runs=200 compiler profile that
    ///             foundry.toml's Registry `compilation_restrictions` pulls in for any source file
    ///             importing Registry.sol — including every deploy script that does),
    ///         0 = neither.
    function _artifactMatch(address target, string memory name) internal view returns (uint8) {
        string memory base = string.concat("out/", name, ".sol/", name);
        if (_codeEqArtifact(target, string.concat(base, ".json"))) return 1;
        if (_codeEqArtifact(target, string.concat(base, ".registry-size.json"))) return 2;
        return 0;
    }

    function _codeEqArtifact(address target, string memory rel) internal view returns (bool) {
        string memory path = string.concat(vm.projectRoot(), "/", rel);
        string memory json;
        try vm.readFile(path) returns (string memory j) {
            json = j;
        } catch {
            return false; // artifact variant not built
        }
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
                require(end <= code.length, "V55: immutable ref out of range");
                for (uint256 k = refs[j].start; k < end; ++k) {
                    code[k] = 0;
                    art[k] = 0;
                }
            }
        }
        return keccak256(code) == keccak256(art);
    }

    // ---------------------------------------------------------------------
    // Step 6: point SP at factoryV2
    // ---------------------------------------------------------------------

    function _wireSPFactory(address sp, address factory) internal {
        if (ISPV55Script(sp).xpntsFactory() != factory) ISPV55Script(sp).setXPNTsFactory(factory);
    }

    function _verifySPFactory(address sp, address factory) internal view {
        require(ISPV55Script(sp).xpntsFactory() == factory, "V55 readback: SP.xpntsFactory != factoryV2");
    }

    // ---------------------------------------------------------------------
    // Step 7a: issue a v2 community token (broadcast as the COMMUNITY)
    // ---------------------------------------------------------------------

    function _issueV2Token(
        address factory,
        address community,
        string memory name_,
        string memory symbol_,
        string memory communityName,
        string memory ens,
        uint256 rate
    ) internal returns (address token) {
        token = xPNTsFactoryV2(factory).getTokenAddress(community);
        if (token == address(0)) {
            token = xPNTsFactoryV2(factory).deployxPNTsToken(name_, symbol_, communityName, ens, rate, address(0));
            console.log("  [v55] v2 token issued:", symbol_, token);
        } else {
            console.log("  [v55] v2 token reused:", symbol_, token);
        }
    }

    /// @notice D5-plan §4 step 7a read-back.
    function _verifyV2Token(address token, address factory, address community, address sp) internal view {
        xPNTsFactoryV2 f = xPNTsFactoryV2(factory);
        IxPNTsV2Script t = IxPNTsV2Script(token);
        require(f.getTokenAddress(community) == token, "V55 readback: factory mapping");
        require(f.isXPNTs(token), "V55 readback: factory isXPNTs");
        // EIP-1167 clone resolved to its embedded implementation (AOAProtocolRegistry.implCodehash).
        require(
            AOAProtocolRegistry(_aoaOf(factory)).implCodehash(token) == f.implementation().codehash,
            "V55 readback: token clone codehash != template"
        );
        require(t.BALANCE_MODE_VERSION() == 1, "V55 readback: token BALANCE_MODE_VERSION");
        require(_strEq(t.version(), XPNTS_V2_VERSION), "V55 readback: token version");
        require(t.FACTORY() == factory, "V55 readback: token FACTORY");
        require(t.community() == community, "V55 readback: token community");
        require(t.SUPERPAYMASTER_ADDRESS() == sp, "V55 readback: token genesis SP");
        require(t.creditTierSource() == f.defaultTierSource(), "V55 readback: token default tier source");
        require(t.creditPolicy() == 0, "V55 readback: token creditPolicy must start OFF");
    }

    function _aoaOf(address factory) internal view returns (address) {
        return address(xPNTsTokenV2(xPNTsFactoryV2(factory).implementation()).PROTOCOL_REGISTRY());
    }

    // ---------------------------------------------------------------------
    // Step 7c: price cache, then configureOperator (broadcast as the OPERATOR)
    // ---------------------------------------------------------------------

    /// @notice DSR D3 §8(a): with a zero/expired price cache validate reverts (AA33) or returns an
    ///         expired validUntil (AA32). Refresh and read back BEFORE any operator goes live.
    function _refreshAndCheckPrice(address sp) internal {
        ISPV55Script(sp).updatePrice();
    }

    function _verifyPriceFresh(address sp) internal view {
        (int256 price, uint256 updatedAt,,) = ISPV55Script(sp).cachedPrice();
        require(price > 0, "V55 readback: cachedPrice.price == 0");
        require(updatedAt > 0, "V55 readback: cachedPrice.updatedAt == 0");
        require(
            updatedAt + ISPV55Script(sp).priceStalenessThreshold() > block.timestamp,
            "V55 readback: cachedPrice expired"
        );
    }

    function _configureOperatorV2(address sp, address token, address treasury, address operator) internal {
        (, bool cfg,, address cur,,,,,) = ISPV55Script(sp).operators(operator);
        if (!cfg || cur != token) ISPV55Script(sp).configureOperator(token, treasury);
    }

    function _verifyOperatorV2(address sp, address operator, address token, address treasury) internal view {
        (, bool cfg,, address cur,,, address tr,,) = ISPV55Script(sp).operators(operator);
        require(cfg, "V55 readback: operator not configured");
        require(cur == token, "V55 readback: operator token != v2 token");
        require(tr == treasury, "V55 readback: operator treasury");
        require(IxPNTsV2Script(token).BALANCE_MODE_VERSION() == 1, "V55 readback: operator token is not v2");
    }

    // ---------------------------------------------------------------------
    // paymasterAndData (SP 5.5.0, spec §3.2)
    // ---------------------------------------------------------------------

    /// @notice [paymaster 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][token 20][flags 1]
    function _pmdV55(address sp, uint128 verifGas, uint128 postOpGas, address operator, uint256 maxRate, address token, uint8 flags)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(sp, verifGas, postOpGas, operator, maxRate, token, flags);
    }

    // ---------------------------------------------------------------------
    // utils
    // ---------------------------------------------------------------------

    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _optAddrV55(string memory json, string memory key) internal view returns (address) {
        if (!vm.keyExistsJson(json, key)) return address(0);
        try vm.parseJsonAddress(json, key) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _stackFromConfig(string memory json) internal view returns (V55Stack memory st) {
        st.tierSource = _optAddrV55(json, ".globalTierSource");
        st.aoaRegistry = _optAddrV55(json, ".aoaProtocolRegistry");
        st.ext = _optAddrV55(json, ".xPNTsTokenV2Ext");
        st.impl = _optAddrV55(json, ".xPNTsTokenV2Impl");
        st.factory = _optAddrV55(json, ".xPNTsFactoryV2");
        st.lens = _optAddrV55(json, ".superPaymasterLens");
    }

    /// @notice Patch the six v2 keys into an existing config file WITHOUT removing any key.
    function _writeStackKeys(string memory path, V55Stack memory st) internal {
        vm.writeJson(vm.toString(st.aoaRegistry), path, ".aoaProtocolRegistry");
        vm.writeJson(vm.toString(st.tierSource), path, ".globalTierSource");
        vm.writeJson(vm.toString(st.ext), path, ".xPNTsTokenV2Ext");
        vm.writeJson(vm.toString(st.impl), path, ".xPNTsTokenV2Impl");
        vm.writeJson(vm.toString(st.factory), path, ".xPNTsFactoryV2");
        vm.writeJson(vm.toString(st.lens), path, ".superPaymasterLens");
    }
}
