// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Script.sol";
import {GovernanceOwnerGate, ISafeCompatibleMofN} from "../checks/GovernanceOwnerGate.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {BLS} from "src/utils/BLS.sol";

interface IDeploymentSafe { function getModulesPaginated(address start, uint256 pageSize) external view returns (address[] memory, address); }

interface IDeploymentAccountFactory { function accountImplementation() external view returns (address); }
interface IDeploymentAccount { function entryPoint() external view returns (address); }

abstract contract DeployLiveInputs is Script {
    struct GuardianInput { address account; BLS.G1Point key; BLS.G2Point pop; }
    address internal safeInput;
    address internal governorInput;
    string[5] internal ownerChoices;
    address[5] internal resolvedOwners;
    address internal gtokenRecipient;
    bool internal recipientIsTimelock;
    function _ownerKey(uint256 i) internal pure returns (string memory) {
        string[5] memory keys = ["SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER"];
        return keys[i];
    }
    function _loadOwnerChoices(address sender) internal {
        require(!_inputSet("GOVERNOR_ADDRESS"),
            "DeployLive: GOVERNOR_ADDRESS deleted; use X402_OWNER");
        for (uint256 i; i < 5; ++i) {
            string memory value = _stringInput(_ownerKey(i));
            require(bytes(value).length != 0, string.concat("DeployLive: ", _ownerKey(i)));
            if (keccak256(bytes(value)) != keccak256("timelock") && keccak256(bytes(value)) != keccak256("safe")) {
                address a = vm.parseAddress(value);
                require(a != address(0) && a != sender, string.concat("DeployLive: ", _ownerKey(i)));
                _validateSafeAddress(a, sender);
            }
            ownerChoices[i] = value;
        }
        string memory recipient = _stringInput("DEPLOYER_GTOKEN_RECIPIENT");
        require(bytes(recipient).length != 0, "DeployLive: DEPLOYER_GTOKEN_RECIPIENT");
        recipientIsTimelock = keccak256(bytes(recipient)) == keccak256("timelock");
        if (recipientIsTimelock) return;
        gtokenRecipient = keccak256(bytes(recipient)) == keccak256("safe") ? safeInput : vm.parseAddress(recipient);
        require(gtokenRecipient != address(0) && gtokenRecipient != sender, "DeployLive: DEPLOYER_GTOKEN_RECIPIENT");
        _validateSafeAddress(gtokenRecipient, sender);
    }
    function _resolveOwnerChoices(address tl) internal {
        if (recipientIsTimelock) gtokenRecipient = tl;
        for (uint256 i; i < 5; ++i) {
            bytes32 choice = keccak256(bytes(ownerChoices[i]));
            resolvedOwners[i] = choice == keccak256("timelock") ? tl : choice == keccak256("safe") ? safeInput : vm.parseAddress(ownerChoices[i]);
        }
    }
    address internal guardianInput;
    address internal spGuardianInput;
    address internal genesisInput;
    uint256 internal capInput;
    uint256 internal nInput;
    uint256 internal minInput;
    uint256 internal defaultInput;
    uint256[3] internal slashInput;
    GuardianInput[] internal guardiansInput;

    function _production() internal view returns (bool) { return block.chainid != 31337
        || (block.chainid == 31337 && _uintInput("DEPLOYLIVE_REHEARSAL") == 1); }
    function _stopBeforeBootstrap() internal view returns (bool) {
        uint256 flag = _uintInput("DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP");
        require(flag <= 1, "stop: expected 0 or 1");
        require(flag == 0 || (block.chainid == 31337 && _production()), "stop: rehearsal chain only");
        return flag == 1;
    }
    function _popRequestPath() internal view virtual returns (string memory) {
        return vm.envOr("DEPLOYLIVE_POP_REQUEST_OUT", string(""));
    }
    function _inputSet(string memory key) internal view virtual returns (bool) { return vm.envExists(key); }
    function _stringInput(string memory key) internal view virtual returns (string memory) { return vm.envOr(key, string("")); }
    function _addressInput(string memory key) internal view virtual returns (address) { return vm.envOr(key, address(0)); }
    function _uintInput(string memory key) internal view virtual returns (uint256) { return vm.envOr(key, uint256(0)); }
    function _guardiansInput() internal view virtual returns (bytes memory) { return vm.envOr("GUARDIANS", bytes("")); }
    function _requiredAddress(string memory key, address sender) internal view returns (address value) {
        value = _addressInput(key);
        require(value != address(0) && value != sender, string.concat("DeployLive: ", key));
    }
    function _requiredUint(string memory key) internal view returns (uint256 value) {
        value = _uintInput(key);
        require(value != 0, string.concat("DeployLive: ", key));
    }
    function _validateSafe(address sender) internal view { _validateSafeAddress(safeInput, sender); }
    function _validateSafeAddress(address candidate, address sender) internal view {
        bytes memory code = candidate.code;
        require(code.length > 0 && bytes3(code) != 0xef0100, "DeployLive: Safe code");
        string memory official = vm.readFile("deployments/safe-official.json");
        bytes32[] memory hashes = vm.parseJsonBytes32Array(official, ".proxyCodehashes");
        bool approved;
        for (uint256 i; i < hashes.length; ++i) if (candidate.codehash == hashes[i]) approved = true;
        require(approved, "DeployLive: Safe proxy codehash");
        address[] memory singletons = vm.parseJsonAddressArray(official, ".singletons");
        bytes32 singleton = vm.load(candidate, 0);
        approved = false;
        for (uint256 i; i < singletons.length; ++i) if (singleton == bytes32(uint256(uint160(singletons[i])))) approved = true;
        require(approved, "DeployLive: Safe singleton");
        address[] memory handlers = vm.parseJsonAddressArray(official, ".fallbackHandlers");
        bytes32 handler = vm.load(candidate, keccak256("fallback_manager.handler.address"));
        approved = false;
        for (uint256 i; i < handlers.length; ++i) if (handler == bytes32(uint256(uint160(handlers[i])))) approved = true;
        require(approved, "DeployLive: Safe fallback handler");
        (bool ok,,) = GovernanceOwnerGate.readMofN(candidate);
        require(ok, "DeployLive: Safe threshold/owners");
        address[] memory owners = ISafeCompatibleMofN(candidate).getOwners();
        for (uint256 i; i < owners.length; ++i) require(owners[i] != sender, "DeployLive: deployer is Safe owner");
        (address[] memory modules, address next) = IDeploymentSafe(candidate).getModulesPaginated(address(1), 10);
        require(modules.length == 0 && next == address(1), "DeployLive: Safe modules");
        require(vm.load(candidate, keccak256("guard_manager.guard.address")) == 0, "DeployLive: Safe guard");
    }
    function _externalDependencies() internal view returns (string memory) {
        if (block.chainid == 31337 && _uintInput("ENABLE_AGENT_REGISTRIES") == 1)
            return vm.readFile("contracts/test/fixtures/deploylive/external-deps.31337.agents.json");
        return vm.readFile(string.concat("deployments/external-deps.", vm.toString(block.chainid), ".json"));
    }
    function _validateInfrastructure(address ep, address feed, address factory) internal view {
        require(ep == 0x0000000071727De22E5E9d8BAf0edAc6f37da032 && ep.code.length > 0, "DeployLive: EntryPoint v0.7");
        require(feed.code.length > 0 && factory.code.length > 0, "DeployLive: infrastructure code");
        require(AggregatorV3Interface(feed).decimals() == 8, "DeployLive: feed decimals");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0 && updatedAt > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= 4200, "DeployLive: stale/invalid feed");
        string memory deps = _externalDependencies();
        require(ep == vm.parseJsonAddress(deps, ".entryPoint") && feed == vm.parseJsonAddress(deps, ".ethUsdFeed")
            && factory == vm.parseJsonAddress(deps, ".accountFactory"), "DeployLive: external dependencies");
        _agentRegistryInputs();
        address impl = IDeploymentAccountFactory(factory).accountImplementation();
        require(impl.code.length > 0 && IDeploymentAccount(impl).entryPoint() == ep, "DeployLive: account EntryPoint");
    }
    function _agentRegistryInputs() internal view returns (bool enabled, address identity, address reputation) {
        uint256 flag = _uintInput("ENABLE_AGENT_REGISTRIES");
        require(flag <= 1, "DeployLive: ENABLE_AGENT_REGISTRIES");
        enabled = flag == 1;
        identity = _addressInput("AGENT_IDENTITY_REGISTRY");
        reputation = _addressInput("AGENT_REPUTATION_REGISTRY");
        if (!enabled) {
            require(identity == address(0) && reputation == address(0), "DeployLive: agent registries disabled");
        } else {
            require(identity != address(0) && reputation != address(0), "DeployLive: agent registries zero");
            string memory deps = _externalDependencies();
            require(identity == vm.parseJsonAddress(deps, ".agentIdentityRegistry")
                && reputation == vm.parseJsonAddress(deps, ".agentReputationRegistry"), "DeployLive: agent dependencies");
        }
    }
    function _loadProductionInputs(address sender) internal {
        if (!_production()) return;
        safeInput = _requiredAddress("GOVERNANCE_OWNER", sender);
        _loadOwnerChoices(sender);
        guardianInput = _requiredAddress("GUARDIAN_ADDRESS", sender);
        spGuardianInput = _requiredAddress("SP_GUARDIAN", sender);
        genesisInput = _requiredAddress("GENESIS_AASTAR_OPERATOR", sender);
        capInput = _requiredUint("APNTS_CAP");
        nInput = _requiredUint("GUARDIAN_N");
        minInput = _requiredUint("GUARDIAN_MIN_THRESHOLD");
        defaultInput = _requiredUint("GUARDIAN_DEFAULT_THRESHOLD");
        for (uint256 i; i < 3; ++i) slashInput[i] = _requiredUint(string.concat("GUARDIAN_SLASH_THRESHOLD_", vm.toString(i)));
        require(nInput <= 64 && minInput >= 2 && minInput <= defaultInput && defaultInput <= nInput, "DeployLive: guardian thresholds");
        for (uint256 i; i < 3; ++i) require(slashInput[i] >= 2 && slashInput[i] <= nInput, "DeployLive: slash threshold");
        // Prediction stops before any guardian use; retain all non-guardian preflight checks.
        bool predicting = bytes(_popRequestPath()).length != 0;
        bytes memory encoded = predicting ? abi.encode(new GuardianInput[](0)) : _guardiansInput();
        require(encoded.length != 0, "DeployLive: GUARDIANS");
        GuardianInput[] memory gs = abi.decode(encoded, (GuardianInput[]));
        require(predicting || gs.length == nInput, "DeployLive: GUARDIAN_N mismatch");
        for (uint256 i; i < gs.length; ++i) {
            require(gs[i].account != address(0) && gs[i].account != sender, "DeployLive: guardian account");
            for (uint256 j; j < i; ++j) require(gs[i].account != gs[j].account, "DeployLive: duplicate guardian");
            guardiansInput.push(gs[i]);
        }
        address[] memory distinct = new address[](gs.length + 5);
        distinct[0] = safeInput; distinct[1] = spGuardianInput; distinct[2] = guardianInput;
        distinct[3] = genesisInput; distinct[4] = sender;
        for (uint256 i; i < gs.length; ++i) distinct[i + 5] = gs[i].account;
        for (uint256 i; i < distinct.length; ++i) for (uint256 j; j < i; ++j)
            require(distinct[i] != distinct[j], "DeployLive: principals must differ");
        _validateSafe(sender);
    }
}
