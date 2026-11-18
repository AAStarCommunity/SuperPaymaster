// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Script.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {BLS} from "src/utils/BLS.sol";

interface IDeploymentAccountFactory { function accountImplementation() external view returns (address); }
interface IDeploymentAccount { function entryPoint() external view returns (address); }

abstract contract DeployLiveInputs is Script {
    struct GuardianInput { address account; BLS.G1Point key; BLS.G2Point pop; }
    address internal safeInput;
    address internal governorInput;
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
    function _validateSafe() internal view {
        bytes memory code = safeInput.code;
        require(code.length > 0 && bytes3(code) != 0xef0100, "DeployLive: Safe code");
        (bool ok,,) = GovernanceOwnerGate.readMofN(safeInput);
        require(ok, "DeployLive: Safe threshold/owners");
    }
    function _validateInfrastructure(address ep, address feed, address factory) internal view {
        require(ep == 0x0000000071727De22E5E9d8BAf0edAc6f37da032 && ep.code.length > 0, "DeployLive: EntryPoint v0.7");
        require(feed.code.length > 0 && factory.code.length > 0, "DeployLive: infrastructure code");
        require(AggregatorV3Interface(feed).decimals() == 8, "DeployLive: feed decimals");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0 && updatedAt > 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= 4200, "DeployLive: stale/invalid feed");
        address impl = IDeploymentAccountFactory(factory).accountImplementation();
        require(impl.code.length > 0 && IDeploymentAccount(impl).entryPoint() == ep, "DeployLive: account EntryPoint");
    }
    function _loadProductionInputs(address sender) internal {
        if (!_production()) return;
        safeInput = _requiredAddress("GOVERNANCE_OWNER", sender);
        governorInput = _requiredAddress("GOVERNOR_ADDRESS", sender);
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
        bytes memory encoded = _guardiansInput();
        require(encoded.length != 0, "DeployLive: GUARDIANS");
        GuardianInput[] memory gs = abi.decode(encoded, (GuardianInput[]));
        require(gs.length == nInput, "DeployLive: GUARDIAN_N mismatch");
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
        _validateSafe();
    }
}
