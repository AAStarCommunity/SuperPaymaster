// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {DefaultArtifacts} from "../v3/DefaultArtifacts.sol";

/**
 * @title CheckDefaultArtifacts
 * @notice T-4 read-back ("tested == deployed"): for EVERY address in deployments/<CONFIG_FILE>,
 *         compare the on-chain runtime with the profile.default compiler artifact (immutable
 *         ranges masked). ERC-1967 proxies: proxy vs ERC1967Proxy AND the slot implementation vs
 *         its own artifact. EIP-1167 clones (factory tokens, V4 paymasters): embedded
 *         implementation vs its artifact. Prints one row per address; fails if any row mismatches.
 *         External / non-deployed keys (ERC-8004 registries on live chains, zero addresses) are
 *         listed as SKIP with the reason.
 *
 * Run (after `forge build`):
 *   CONFIG_FILE=config.anvil.json forge script \
 *     contracts/script/checks/CheckDefaultArtifacts.s.sol:CheckDefaultArtifacts --rpc-url http://127.0.0.1:8545
 */
contract CheckDefaultArtifacts is DefaultArtifacts {
    struct Row {
        string key;
        string artifact;
        uint8 kind; // 0 direct, 1 ERC-1967 proxy, 2 EIP-1167 clone
    }

    uint256 internal fails;
    uint256 internal checked;

    function run() external {
        string memory file = vm.envOr("CONFIG_FILE", string("config.anvil.json"));
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", file));
        bool isLocal = block.chainid == 31337;

        Row[] memory rows = new Row[](36);
        uint256 n;
        rows[n++] = Row("registry", "Registry", 1);
        rows[n++] = Row("registryImpl", "Registry", 0);
        rows[n++] = Row("superPaymaster", "SuperPaymaster", 1);
        rows[n++] = Row("spImpl", "SuperPaymaster", 0);
        rows[n++] = Row("gToken", "GTokenAuthorization", 0);
        rows[n++] = Row("staking", "GTokenStaking", 0);
        rows[n++] = Row("sbt", "MySBT", 0);
        rows[n++] = Row("xPNTsFactory", "xPNTsFactory", 0);
        rows[n++] = Row("aPNTs", "xPNTsToken", 2);
        rows[n++] = Row("reputationSystem", "ReputationSystem", 0);
        rows[n++] = Row("dvtValidator", "DVTValidator", 0);
        rows[n++] = Row("blsAggregator", "BLSAggregator", 0);
        rows[n++] = Row("paymasterFactory", "PaymasterFactory", 0);
        rows[n++] = Row("paymasterV4Impl", "Paymaster", 0);
        rows[n++] = Row("aPNTsPaymasterV4", "Paymaster", 2);
        rows[n++] = Row("pNTsPaymasterV4", "Paymaster", 2);
        rows[n++] = Row("microPaymentChannel", "MicroPaymentChannel", 0);
        rows[n++] = Row("x402Facilitator", "X402Facilitator", 0);
        rows[n++] = Row("policyRegistry", "PolicyRegistry", 0);
        rows[n++] = Row("timelockController", "TimelockController", 0);
        rows[n++] = Row("aoaProtocolRegistry", "AOAProtocolRegistry", 0);
        rows[n++] = Row("globalTierSource", "GlobalTierSource", 0);
        rows[n++] = Row("xPNTsTokenV2Ext", "xPNTsTokenV2Ext", 0);
        rows[n++] = Row("xPNTsTokenV2Impl", "xPNTsTokenV2", 0);
        rows[n++] = Row("xPNTsFactoryV2", "xPNTsFactoryV2", 0);
        rows[n++] = Row("superPaymasterLens", "SuperPaymasterLens", 0);
        rows[n++] = Row("aastarXPNTsV2", "xPNTsTokenV2", 2);
        rows[n++] = Row("pnts", "xPNTsTokenV2", 2);
        if (isLocal) {
            // Deployed by DeployAnvil only; on live chains these are canonical / third-party.
            rows[n++] = Row("entryPoint", "EntryPoint", 0);
            rows[n++] = Row("simpleAccountFactory", "SimpleAccountFactory", 0);
            rows[n++] = Row("priceFeed", "AnvilMockPriceFeed", 0);
            rows[n++] = Row("agentIdentityRegistry", "MockAgentIdentityRegistry", 0);
            rows[n++] = Row("agentReputationRegistry", "MockAgentReputationRegistry", 0);
        }

        console.log("key | address | artifact | kind | runtime bytes | result");
        for (uint256 i; i < n; ++i) {
            _check(json, rows[i]);
        }
        console.log("T-4 read-back: checked", checked, "mismatches", fails);
        require(fails == 0, "CheckDefaultArtifacts: runtime != profile.default artifact");
        require(checked > 0, "CheckDefaultArtifacts: nothing checked");
    }

    function _check(string memory json, Row memory r) internal {
        string memory k = string.concat(".", r.key);
        if (!vm.keyExistsJson(json, k)) {
            console.log(string.concat(r.key, " | - | ", r.artifact, " | SKIP (key absent)"));
            return;
        }
        address a = vm.parseJsonAddress(json, k);
        if (a == address(0) || a.code.length == 0) {
            console.log(string.concat(r.key, " | ", vm.toString(a), " | ", r.artifact, " | SKIP (no code)"));
            return;
        }
        bool ok;
        string memory detail;
        if (r.kind == 1) {
            address impl = address(uint160(uint256(vm.load(a, ERC1967_IMPLEMENTATION_SLOT))));
            bool p = _codeEqArtifact(a, _defaultArtifact("ERC1967Proxy"));
            bool m = _codeEqArtifact(impl, _defaultArtifact(r.artifact));
            ok = p && m;
            detail = string.concat("ERC1967Proxy ", p ? "OK" : "MISMATCH", " / impl ", vm.toString(impl), " ", m ? "OK" : "MISMATCH");
        } else if (r.kind == 2) {
            address impl = _eip1167Impl(a);
            ok = impl != address(0) && _codeEqArtifact(impl, _defaultArtifact(r.artifact));
            detail = string.concat("EIP-1167 -> ", vm.toString(impl), impl.code.length == 0 ? "" : string.concat(" (", vm.toString(impl.code.length), " B)"));
        } else {
            ok = _codeEqArtifact(a, _defaultArtifact(r.artifact));
            detail = string.concat(vm.toString(a.code.length), " B");
        }
        checked++;
        if (!ok) fails++;
        console.log(string.concat(
            r.key, " | ", vm.toString(a), " | ", r.artifact, " | ", detail, " | ", ok ? "default artifact OK" : "MISMATCH"
        ));
    }
}
