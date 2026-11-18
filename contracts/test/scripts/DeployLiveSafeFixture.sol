// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";

// Only the singleton behavior is stubbed; the proxy runtime is recorded chain code.
contract SafeSingletonFixture {
    function getModulesPaginated(address, uint256) external pure returns (address[] memory, address) { return (new address[](0), address(1)); }
    function getThreshold() external pure returns (uint256) { return 2; }
    function getOwners() external pure returns (address[] memory a) {
        a = new address[](2); a[0] = address(91); a[1] = address(92);
    }
}
abstract contract DeployLiveSafeFixture is Test {
    function _installOfficialSafe(address candidate) internal {
        string memory fixture = vm.readFile("contracts/test/fixtures/deploylive/safe-proxy-v141.json");
        address singleton = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
        vm.etch(singleton, type(SafeSingletonFixture).runtimeCode);
        vm.etch(candidate, vm.parseJsonBytes(fixture, ".runtime"));
        vm.store(candidate, 0, bytes32(uint256(uint160(singleton))));
        vm.store(candidate, keccak256("fallback_manager.handler.address"), bytes32(uint256(uint160(0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99))));
    }
}
