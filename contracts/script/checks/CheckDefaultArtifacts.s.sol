// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {DefaultArtifacts} from "../v3/DefaultArtifacts.sol";
import {SPReleaseVersion} from "../v3/SPReleaseVersion.sol";

/**
 * @title CheckDefaultArtifacts
 * @notice T-4 read-back gate ("tested == deployed"), run by prepare-test and audit-core on EVERY
 *         network. Fail-closed by construction (Codex stop-review HIGH-4/5, MEDIUM-7):
 *
 *   - EVERY key of the config is classified. An unknown key FAILS. A contract key whose value
 *     is zero, not an address, or has no code FAILS. The only non-contract keys are the
 *     reviewed exclusions in `_classify` (metadata strings/numbers, EOA lists), each justified.
 *   - Contracts: runtime == the profile.default artifact (immutables masked), THEN every
 *     constructor-argument immutable is read back through its getter and compared with the
 *     config (`_bindings`). A contract whose artifact HAS immutables but has no binding rule
 *     FAILS, except the reviewed self-derived list (`_selfDerivedOnly`).
 *   - ERC-1967 proxies: proxy vs ERC1967Proxy AND implementation (from the ERC-1967 slot) vs its
 *     artifact + bindings; `registryImpl`/`spImpl` must equal the slot.
 *   - EIP-1167 clones: embedded implementation must be the EXPECTED one (factory template /
 *     registered V4 version / v2 template), then that implementation is checked.
 *   - Factory products are enumerated on-chain (xPNTsFactory / xPNTsFactoryV2 getAllTokens,
 *     PaymasterFactory paymasterList) and each is checked as a clone of the expected template.
 *   - Third-party contracts on live chains (canonical EntryPoint, Chainlink feed, ERC-8004
 *     registries, sample account factory) cannot be compared with OUR artifacts; they must have
 *     code AND be bound where the protocol uses them (SP.entryPoint, SP.ETH_USD_PRICE_FEED,
 *     SP.agent*Registry); the canonical EntryPoint must also match its canonical codehash.
 *   - Superseded components (`*Prev`, `blsValidator`) must have code AND must NOT be wired
 *     anywhere live (a "historical" key that is still wired fails).
 *   - A DELETED key fails too: the required key set (base / 5.5.0 v2 stack / full deploy) must be
 *     present, and the live wiring (Registry.SUPER_PAYMASTER/GTOKEN_STAKING/MYSBT/blsAggregator,
 *     DVT.BLS_AGGREGATOR, SP.APNTS_TOKEN/xpntsFactory) must point at the config's addresses.
 *   The run fails if ANY row fails; nothing is ever skipped silently.
 *
 * Run (after a plain `forge build`):
 *   CONFIG_FILE=config.anvil.json forge script \
 *     contracts/script/checks/CheckDefaultArtifacts.s.sol:CheckDefaultArtifacts --rpc-url <rpc>
 *   (CONFIG_PATH=<absolute path> overrides, e.g. for the RepCredit output config)
 */
contract CheckDefaultArtifacts is DefaultArtifacts {
    address internal constant CANONICAL_EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    bytes32 internal constant CANONICAL_EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;

    string internal cfg;
    bool internal isLocal;
    uint256 internal fails;
    uint256 internal passes;

    function run() external {
        string memory path = vm.envOr("CONFIG_PATH", string(""));
        if (bytes(path).length == 0) {
            path = string.concat(vm.projectRoot(), "/deployments/", vm.envOr("CONFIG_FILE", string("config.anvil.json")));
        }
        cfg = vm.readFile(path);
        isLocal = block.chainid == 31337;
        console.log("T-4 read-back of", path);
        console.log("row | address | check | result");

        _requiredKeys();
        string[] memory keys = vm.parseJsonKeys(cfg, "$");
        for (uint256 i; i < keys.length; ++i) {
            _classify(keys[i]);
        }
        _factoryProducts();
        _liveWiring();

        console.log("T-4 read-back: passed", passes, "failed", fails);
        require(fails == 0, "CheckDefaultArtifacts: FAILED (see rows above)");
        require(passes > 0, "CheckDefaultArtifacts: nothing checked");
    }

    // =========================================================================================
    // Classification of every config key
    // =========================================================================================

    function _classify(string memory key) internal {
        bytes32 k = keccak256(bytes(key));

        // --- reviewed NON-CONTRACT keys (exclusions) -------------------------------------------
        // Deployment metadata written by the deploy scripts / deploy-core; not addresses.
        if (k == keccak256("srcHash") || k == keccak256("updateTime") || k == keccak256("schemaVersion")
                || k == keccak256("experimentLabel") || k == keccak256("chainId")
                || k == keccak256("entryPointDepositWei")) {
            _row(key, address(0), "metadata (not an address) - excluded by review", true);
            return;
        }
        // Guardian / deployer keys are EOAs by design (they sign; they are never called as
        // contracts). Excluded from the artifact check, but they must really be code-less: a
        // key that turned into a contract would be an unreviewed contract and fails.
        if (k == keccak256("blsGuardians")) { _eoaList(key); return; }
        if (k == keccak256("deployer")) { _eoa(key); return; }

        // --- our contracts -----------------------------------------------------------------------
        if (k == keccak256("registry")) { _proxy(key, "Registry"); return; }
        if (k == keccak256("superPaymaster")) { _proxy(key, "SuperPaymaster"); return; }
        if (k == keccak256("registryImpl")) { _implKey(key, "registry", "Registry"); return; }
        if (k == keccak256("spImpl")) { _implKey(key, "superPaymaster", "SuperPaymaster"); return; }
        if (k == keccak256("gToken")) { _direct(key, "GTokenAuthorization"); return; }
        if (k == keccak256("staking")) { _direct(key, "GTokenStaking"); return; }
        if (k == keccak256("sbt")) { _direct(key, "MySBT"); return; }
        if (k == keccak256("xPNTsFactory")) { _direct(key, "xPNTsFactory"); return; }
        if (k == keccak256("reputationSystem")) { _direct(key, "ReputationSystem"); return; }
        if (k == keccak256("dvtValidator")) { _direct(key, "DVTValidator"); return; }
        if (k == keccak256("blsAggregator")) { _direct(key, "BLSAggregator"); return; }
        if (k == keccak256("paymasterFactory")) { _direct(key, "PaymasterFactory"); return; }
        if (k == keccak256("paymasterV4Impl")) { _direct(key, "Paymaster"); return; }
        if (k == keccak256("microPaymentChannel")) { _direct(key, "MicroPaymentChannel"); return; }
        if (k == keccak256("x402Facilitator")) { _direct(key, "X402Facilitator"); return; }
        if (k == keccak256("policyRegistry")) { _direct(key, "PolicyRegistry"); return; }
        if (k == keccak256("timelockController")) { _direct(key, "TimelockController"); return; }
        if (k == keccak256("livenessRegistry")) { _direct(key, "LivenessRegistry"); return; }
        if (k == keccak256("aoaProtocolRegistry")) { _direct(key, "AOAProtocolRegistry"); return; }
        if (k == keccak256("globalTierSource")) { _direct(key, "GlobalTierSource"); return; }
        if (k == keccak256("xPNTsTokenV2Ext")) { _direct(key, "xPNTsTokenV2Ext"); return; }
        if (k == keccak256("xPNTsTokenV2Impl")) { _direct(key, "xPNTsTokenV2"); return; }
        if (k == keccak256("xPNTsFactoryV2")) { _direct(key, "xPNTsFactoryV2"); return; }
        if (k == keccak256("superPaymasterLens")) { _direct(key, "SuperPaymasterLens"); return; }
        if (k == keccak256("xPNTsFactoryCC28")) { _direct(key, "xPNTsFactory"); return; }

        // --- factory clones (embedded impl must be the expected template) -----------------------
        if (k == keccak256("aPNTs")) { _clone(key, _cfgAddr("aPNTs"), "xPNTsToken", _call(_cfgAddr("xPNTsFactory"), "implementation()")); return; }
        if (k == keccak256("xPNTsTokenCC28Test")) { _clone(key, _cfgAddr(key), "xPNTsToken", _call(_cfgAddr("xPNTsFactoryCC28"), "implementation()")); return; }
        if (k == keccak256("aPNTsPaymasterV4") || k == keccak256("pNTsPaymasterV4")) { _v4Clone(key, _cfgAddr(key)); return; }
        if (k == keccak256("pnts") || k == keccak256("aastarXPNTsV2") || k == keccak256("operatorXPNTsV2")) {
            _v2Clone(key, _cfgAddr(key));
            return;
        }
        if (k == keccak256("xPNTsV2Tokens")) { // UpgradeToV5_5_0 output: community => v2 token
            string[] memory comms = vm.parseJsonKeys(cfg, ".xPNTsV2Tokens");
            for (uint256 i; i < comms.length; ++i) {
                _v2Clone(string.concat("xPNTsV2Tokens.", comms[i]), vm.parseJsonAddress(cfg, string.concat(".xPNTsV2Tokens.", comms[i])));
            }
            return;
        }

        // --- infrastructure: ours on a local chain, third-party (bound + canonical) on live ------
        if (k == keccak256("entryPoint")) {
            if (isLocal) _direct(key, "EntryPoint");
            else _external(key, "canonical EntryPoint v0.7", _cfgAddr(key) == CANONICAL_EP && _cfgAddr(key).codehash == CANONICAL_EP_CODEHASH
                && _call(_cfgAddr("superPaymaster"), "entryPoint()") == _cfgAddr(key));
            return;
        }
        if (k == keccak256("simpleAccountFactory")) {
            if (isLocal) _direct(key, "SimpleAccountFactory");
            else _external(key, "sample SimpleAccountFactory bound to config.entryPoint",
                _call(_call(_cfgAddr(key), "accountImplementation()"), "entryPoint()") == _cfgAddr("entryPoint"));
            return;
        }
        if (k == keccak256("priceFeed")) {
            if (isLocal) _direct(key, "AnvilMockPriceFeed");
            else _external(key, "Chainlink ETH/USD bound as SP.ETH_USD_PRICE_FEED",
                _call(_cfgAddr("superPaymaster"), "ETH_USD_PRICE_FEED()") == _cfgAddr(key));
            return;
        }
        if (k == keccak256("agentIdentityRegistry")) {
            if (isLocal) _direct(key, "MockAgentIdentityRegistry");
            else _external(key, "ERC-8004 identity registry bound in SP", _call(_cfgAddr("superPaymaster"), "agentIdentityRegistry()") == _cfgAddr(key));
            return;
        }
        if (k == keccak256("agentReputationRegistry")) {
            if (isLocal) _direct(key, "MockAgentReputationRegistry");
            else _external(key, "ERC-8004 reputation registry bound in SP", _call(_cfgAddr("superPaymaster"), "agentReputationRegistry()") == _cfgAddr(key));
            return;
        }
        if (k == keccak256("agentValidationRegistry")) {
            // Reviewed exclusion: recorded for future use, NOT wired into SP. DeployAnvil writes 0
            // on purpose (no validation mock); on live chains it must be the ERC-8004 contract.
            address a = _cfgAddr(key);
            if (isLocal && a == address(0)) _row(key, a, "zero by design on anvil (unwired ERC-8004 validation) - excluded by review", true);
            else _external(key, "ERC-8004 validation registry (unwired)", a.code.length > 0);
            return;
        }

        // --- superseded components: must exist and must NOT be live-wired -----------------------
        if (k == keccak256("blsAggregatorPrev") || k == keccak256("blsValidator")) {
            address a = _cfgAddr(key);
            bool notWired = a != _call(_cfgAddr("registry"), "blsAggregator()") && a != _call(_cfgAddr("superPaymaster"), "BLS_AGGREGATOR()")
                && a != _call(_cfgAddr("dvtValidator"), "BLS_AGGREGATOR()");
            _row(key, a, "historical (superseded) - has code and is NOT wired into Registry/SP/DVT", a.code.length > 0 && notWired);
            return;
        }
        if (k == keccak256("blsFraudProofVerifierPrev")) {
            address a = _cfgAddr(key);
            bool notWired = a != _call(_cfgAddr("blsAggregator"), "fraudProofVerifier()");
            _row(key, a, "historical (superseded) - has code and is NOT the live fraudProofVerifier", a.code.length > 0 && notWired);
            return;
        }

        _row(key, address(0), "UNKNOWN KEY - add a reviewed rule to CheckDefaultArtifacts", false);
    }

    // =========================================================================================
    // Completeness: a DELETED key must fail too (iterating the keys that exist cannot see it)
    // =========================================================================================

    function _requiredKeys() internal {
        string[12] memory base = [
            "registry", "superPaymaster", "entryPoint", "priceFeed", "gToken", "staking", "sbt",
            "xPNTsFactory", "aPNTs", "reputationSystem", "dvtValidator", "blsAggregator"
        ];
        for (uint256 i; i < base.length; ++i) _needKey(base[i]);
        if (_isV55()) {
            string[6] memory v2 = ["aoaProtocolRegistry", "globalTierSource", "xPNTsTokenV2Ext", "xPNTsTokenV2Impl", "xPNTsFactoryV2", "superPaymasterLens"];
            for (uint256 i; i < v2.length; ++i) _needKey(v2[i]);
        }
        // Full deployments (deploy-core configs); the RepCredit experiment stack is minimal by design.
        if (!vm.keyExistsJson(cfg, ".experimentLabel")) {
            string[9] memory full = [
                "registryImpl", "spImpl", "paymasterFactory", "paymasterV4Impl", "microPaymentChannel",
                "x402Facilitator", "policyRegistry", "timelockController", "simpleAccountFactory"
            ];
            for (uint256 i; i < full.length; ++i) _needKey(full[i]);
        }
    }

    function _needKey(string memory key) internal {
        if (!vm.keyExistsJson(cfg, string.concat(".", key))) _row(key, address(0), "REQUIRED KEY MISSING from config", false);
    }

    function _isV55() internal view returns (bool) {
        address sp = _cfgAddr("superPaymaster");
        if (sp.code.length == 0) return false;
        (bool ok, bytes memory r) = sp.staticcall(abi.encodeWithSignature("version()"));
        return ok && keccak256(abi.decode(r, (bytes))) == keccak256(bytes(SPReleaseVersion.SP));
    }

    /// @notice The live wiring must point at the config's addresses — a config that omits or
    ///         misstates a component is caught here even if every listed address checks out.
    function _liveWiring() internal {
        address reg = _cfgAddr("registry");
        address sp = _cfgAddr("superPaymaster");
        _row("wiring Registry.SUPER_PAYMASTER", _call(reg, "SUPER_PAYMASTER()"), "== config.superPaymaster", _call(reg, "SUPER_PAYMASTER()") == sp && sp != address(0));
        _row("wiring Registry.GTOKEN_STAKING", _call(reg, "GTOKEN_STAKING()"), "== config.staking", _is(reg, "GTOKEN_STAKING()", "staking"));
        _row("wiring Registry.MYSBT", _call(reg, "MYSBT()"), "== config.sbt", _is(reg, "MYSBT()", "sbt"));
        _row("wiring Registry.blsAggregator", _call(reg, "blsAggregator()"), "== config.blsAggregator", _is(reg, "blsAggregator()", "blsAggregator"));
        _row("wiring DVTValidator.BLS_AGGREGATOR", _call(_cfgAddr("dvtValidator"), "BLS_AGGREGATOR()"), "== config.blsAggregator", _is(_cfgAddr("dvtValidator"), "BLS_AGGREGATOR()", "blsAggregator"));
        _row("wiring SP.APNTS_TOKEN", _call(sp, "APNTS_TOKEN()"), "== config.aPNTs", _is(sp, "APNTS_TOKEN()", "aPNTs"));
        string memory fk = _isV55() ? "xPNTsFactoryV2" : "xPNTsFactory";
        _row("wiring SP.xpntsFactory", _call(sp, "xpntsFactory()"), string.concat("== config.", fk), _is(sp, "xpntsFactory()", fk));
    }

    // =========================================================================================
    // Checks
    // =========================================================================================

    function _direct(string memory key, string memory name) internal {
        _contract(key, _cfgAddr(key), name);
    }

    /// @dev runtime == default artifact, bindings, immutable coverage.
    function _contract(string memory label, address a, string memory name) internal returns (bool ok) {
        if (a == address(0) || a.code.length == 0) {
            _row(label, a, string.concat(name, ": zero / no code"), false);
            return false;
        }
        string memory rel = _defaultArtifact(name);
        if (!_codeEqArtifact(a, rel)) {
            _row(label, a, string.concat(name, ": runtime != profile.default artifact ", rel), false);
            return false;
        }
        (bool bOk, string memory why) = _bindings(name, a);
        if (!bOk) {
            _row(label, a, string.concat(name, ": default artifact OK but IMMUTABLE BINDING WRONG: ", why), false);
            return false;
        }
        _row(label, a, string.concat(name, ": default artifact OK (", rel, "); ", why), true);
        return true;
    }

    function _proxy(string memory key, string memory implName) internal {
        address p = _cfgAddr(key);
        if (!_contract(string.concat(key, " (ERC-1967 proxy)"), p, "ERC1967Proxy")) return;
        address impl = address(uint160(uint256(vm.load(p, ERC1967_IMPLEMENTATION_SLOT))));
        _contract(string.concat(key, " (implementation)"), impl, implName);
    }

    function _implKey(string memory key, string memory proxyKey, string memory name) internal {
        address a = _cfgAddr(key);
        address slot = address(uint160(uint256(vm.load(_cfgAddr(proxyKey), ERC1967_IMPLEMENTATION_SLOT))));
        if (a != slot) {
            _row(key, a, string.concat(name, ": config impl != live ERC-1967 slot of ", proxyKey), false);
            return;
        }
        _contract(key, a, name);
    }

    function _clone(string memory label, address clone, string memory implName, address expectedImpl) internal {
        address impl = _eip1167Impl(clone);
        if (impl == address(0)) {
            _row(label, clone, string.concat("not an EIP-1167 clone (expected clone of ", implName, ")"), false);
            return;
        }
        if (expectedImpl == address(0) || impl != expectedImpl) {
            _row(label, clone, string.concat("EIP-1167 clone of an UNEXPECTED implementation ", vm.toString(impl), " (expected ", vm.toString(expectedImpl), ")"), false);
            return;
        }
        _contract(string.concat(label, " (clone ", vm.toString(clone), ") -> impl"), impl, implName);
    }

    function _v4Clone(string memory label, address clone) internal {
        address registered = _call(_cfgAddr("paymasterFactory"), "implementations(string)", "v4.2");
        address cfgImpl = _cfgAddr("paymasterV4Impl");
        if (registered != cfgImpl) {
            _row(label, clone, "PaymasterFactory.implementations(v4.2) != config.paymasterV4Impl", false);
            return;
        }
        _clone(label, clone, "Paymaster", cfgImpl);
    }

    function _v2Clone(string memory label, address clone) internal {
        address tmpl = _cfgAddr("xPNTsTokenV2Impl");
        address fImpl = _call(_cfgAddr("xPNTsFactoryV2"), "implementation()");
        if (tmpl == address(0)) {
            _row(label, clone, "config has no xPNTsTokenV2Impl: an SP operator token must be an xPNTs v2 clone (pre-5.5.0 deployment?)", false);
            return;
        }
        if (fImpl != tmpl) {
            _row(label, clone, "xPNTsFactoryV2.implementation() != config.xPNTsTokenV2Impl", false);
            return;
        }
        _clone(label, clone, "xPNTsTokenV2", tmpl);
    }

    function _external(string memory key, string memory what, bool bound) internal {
        address a = _cfgAddr(key);
        _row(key, a, string.concat("third-party: ", what), a != address(0) && a.code.length > 0 && bound);
    }

    function _eoa(string memory key) internal {
        address a = _cfgAddr(key);
        _row(key, a, "EOA by design - excluded by review; must be code-less", a != address(0) && a.code.length == 0);
    }

    function _eoaList(string memory key) internal {
        address[] memory as_ = vm.parseJsonAddressArray(cfg, string.concat(".", key));
        for (uint256 i; i < as_.length; ++i) {
            _row(string.concat(key, "[", vm.toString(i), "]"), as_[i], "EOA by design - excluded by review; must be code-less",
                as_[i] != address(0) && as_[i].code.length == 0);
        }
    }

    /// @notice Every factory PRODUCT, enumerated on-chain, is a clone of the expected template.
    function _factoryProducts() internal {
        _factoryTokens("xPNTsFactory", "xPNTsToken", false);
        _factoryTokens("xPNTsFactoryCC28", "xPNTsToken", false);
        _factoryTokens("xPNTsFactoryV2", "xPNTsTokenV2", true);
        if (vm.keyExistsJson(cfg, ".paymasterFactory")) {
            address pf = _cfgAddr("paymasterFactory");
            if (pf.code.length == 0) { _row("paymasterFactory products", pf, "factory has no code - cannot enumerate", false); return; }
            (bool ok, bytes memory r) = pf.staticcall(abi.encodeWithSignature("totalDeployed()"));
            uint256 n = ok && r.length == 32 ? abi.decode(r, (uint256)) : type(uint256).max;
            if (n == type(uint256).max) { _row("paymasterFactory products", pf, "cannot enumerate", false); return; }
            for (uint256 i; i < n; ++i) {
                (bool ok2, bytes memory r2) = pf.staticcall(abi.encodeWithSignature("paymasterList(uint256)", i));
                address pm = ok2 && r2.length == 32 ? abi.decode(r2, (address)) : address(0);
                _v4Clone(string.concat("paymasterFactory.paymasterList[", vm.toString(i), "]"), pm);
            }
        }
    }

    function _factoryTokens(string memory factoryKey, string memory tmplName, bool v2) internal {
        if (!vm.keyExistsJson(cfg, string.concat(".", factoryKey))) return;
        address f = _cfgAddr(factoryKey);
        if (f.code.length == 0) { _row(string.concat(factoryKey, " products"), f, "factory has no code - cannot enumerate", false); return; }
        (bool ok, bytes memory r) = f.staticcall(abi.encodeWithSignature("getAllTokens()"));
        if (!ok || r.length < 64) { _row(string.concat(factoryKey, " products"), f, "cannot enumerate getAllTokens()", false); return; }
        address[] memory toks = abi.decode(r, (address[]));
        address tmpl = _call(f, "implementation()");
        for (uint256 i; i < toks.length; ++i) {
            string memory label = string.concat(factoryKey, ".getAllTokens[", vm.toString(i), "]");
            if (v2) _v2Clone(label, toks[i]);
            else _clone(label, toks[i], tmplName, tmpl);
        }
    }

    // =========================================================================================
    // Immutable bindings (constructor-argument immutables, read back via their getters)
    // =========================================================================================

    function _bindings(string memory name, address a) internal view returns (bool, string memory) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("SuperPaymaster")) {
            // D5b-design §2.2: EXTENSION is masked by the runtime comparison; require it to be the
            // default SuperPaymasterAdmin build carrying the same three immutables.
            address ext = _call(a, "EXTENSION()");
            bool extOk = ext != address(0) && _codeEqArtifact(ext, _defaultArtifact("SuperPaymasterAdmin"))
                && _is(ext, "REGISTRY()", "registry") && _is(ext, "entryPoint()", "entryPoint")
                && _is(ext, "ETH_USD_PRICE_FEED()", "priceFeed");
            return _all3(_is(a, "REGISTRY()", "registry") && extOk, _is(a, "entryPoint()", "entryPoint"),
                _is(a, "ETH_USD_PRICE_FEED()", "priceFeed"),
                "REGISTRY, entryPoint, ETH_USD_PRICE_FEED == config; EXTENSION == default SuperPaymasterAdmin with the same three");
        }
        if (n == keccak256("GTokenAuthorization")) return _one(_is(a, "factory()", "xPNTsFactory"), "factory == config.xPNTsFactory");
        if (n == keccak256("GTokenStaking")) return _two(_is(a, "GTOKEN()", "gToken"), _is(a, "REGISTRY()", "registry"), "GTOKEN, REGISTRY == config");
        if (n == keccak256("MySBT")) {
            return _all3(_is(a, "GTOKEN()", "gToken"), _is(a, "GTOKEN_STAKING()", "staking"), _is(a, "REGISTRY()", "registry"),
                "GTOKEN, GTOKEN_STAKING, REGISTRY == config");
        }
        if (n == keccak256("xPNTsFactory")) {
            // REGISTRY binding + the template it clones is itself the default xPNTsToken build.
            address tmpl = _call(a, "implementation()");
            bool tOk = tmpl != address(0) && _codeEqArtifact(tmpl, _defaultArtifact("xPNTsToken"));
            return _two(_is(a, "REGISTRY()", "registry"), tOk, "REGISTRY == config; implementation == default xPNTsToken");
        }
        if (n == keccak256("ReputationSystem") || n == keccak256("DVTValidator") || n == keccak256("BLSAggregator")
                || n == keccak256("GlobalTierSource")) {
            return _one(_is(a, "REGISTRY()", "registry"), "REGISTRY == config.registry");
        }
        if (n == keccak256("Paymaster")) return _one(_is(a, "registry()", "registry"), "registry == config.registry");
        if (n == keccak256("X402Facilitator")) return _two(_is(a, "REGISTRY()", "registry"), _is(a, "XPNTS_FACTORY()", "xPNTsFactory"), "REGISTRY, XPNTS_FACTORY == config");
        if (n == keccak256("PolicyRegistry")) return _one(_is(a, "timelock()", "timelockController"), "timelock == config.timelockController");
        if (n == keccak256("xPNTsTokenV2Ext")) return _one(_is(a, "PROTOCOL_REGISTRY()", "aoaProtocolRegistry"), "PROTOCOL_REGISTRY == config");
        if (n == keccak256("xPNTsTokenV2")) {
            return _two(_is(a, "PROTOCOL_REGISTRY()", "aoaProtocolRegistry"), _is(a, "EXTENSION()", "xPNTsTokenV2Ext"), "PROTOCOL_REGISTRY, EXTENSION == config");
        }
        if (n == keccak256("xPNTsFactoryV2")) return _two(_is(a, "REGISTRY()", "registry"), _is(a, "implementation()", "xPNTsTokenV2Impl"), "REGISTRY, implementation == config");
        if (n == keccak256("SimpleAccountFactory")) {
            address impl = _call(a, "accountImplementation()");
            bool iOk = impl != address(0) && _codeEqArtifact(impl, _defaultArtifact("SimpleAccount"))
                && _call(impl, "entryPoint()") == _cfgAddr("entryPoint");
            return _one(iOk, "accountImplementation == default SimpleAccount bound to config.entryPoint");
        }
        // No constructor-argument immutables: either none at all, or only self-derived ones.
        uint256 imm = _t4Reader.t4ImmutableCount(_defaultArtifact(name));
        if (imm == 0) return (true, "no immutables");
        if (_selfDerivedOnly(n)) return (true, "only self-derived immutables (reviewed)");
        return (false, string.concat(vm.toString(imm), " immutable(s) with NO binding rule"));
    }

    /// @dev Reviewed: these artifacts' immutables are derived from the contract itself (UUPS
    ///      `__self` = address(this); EIP-712 domain cache = address(this), chainid, constant
    ///      name/version hashes) or created by its own constructor (EntryPoint.senderCreator) —
    ///      nothing a deployer passes in, so there is no config value to bind them to.
    function _selfDerivedOnly(bytes32 n) internal pure returns (bool) {
        return n == keccak256("Registry") || n == keccak256("xPNTsToken") || n == keccak256("MicroPaymentChannel")
            || n == keccak256("EntryPoint");
    }

    // =========================================================================================
    // helpers
    // =========================================================================================

    function _cfgAddr(string memory key) internal view returns (address) {
        string memory k = string.concat(".", key);
        if (!vm.keyExistsJson(cfg, k)) return address(0);
        try vm.parseJsonAddress(cfg, k) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _call(address target, string memory sig) internal view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory r) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && r.length == 32 ? abi.decode(r, (address)) : address(0);
    }

    function _call(address target, string memory sig, string memory arg) internal view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory r) = target.staticcall(abi.encodeWithSignature(sig, arg));
        return ok && r.length == 32 ? abi.decode(r, (address)) : address(0);
    }

    function _is(address a, string memory getter, string memory cfgKey) internal view returns (bool) {
        address want = _cfgAddr(cfgKey);
        return want != address(0) && _call(a, getter) == want;
    }

    function _one(bool a, string memory what) internal pure returns (bool, string memory) {
        return (a, what);
    }

    function _two(bool a, bool b, string memory what) internal pure returns (bool, string memory) {
        return (a && b, what);
    }

    function _all3(bool a, bool b, bool c, string memory what) internal pure returns (bool, string memory) {
        return (a && b && c, what);
    }

    function _row(string memory key, address a, string memory what, bool ok) internal {
        if (ok) passes++;
        else fails++;
        console.log(string.concat(key, " | ", vm.toString(a), " | ", what, " | ", ok ? "OK" : "FAIL"));
    }
}
