// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title UUPSDeployHelper
 * @notice Shared helper for deploying Registry and SuperPaymaster as UUPS proxies in tests
 */
library UUPSDeployHelper {
    function deployRegistryProxy(
        address _owner,
        address _staking,
        address _mysbt
    ) internal returns (Registry) {
        Registry impl = new Registry();
        bytes memory initData = abi.encodeCall(Registry.initialize, (_owner, _staking, _mysbt));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return Registry(address(proxy));
    }

    function deploySuperPaymasterProxy(
        IEntryPoint _entryPoint,
        IRegistry _registry,
        address _priceFeed,
        address _owner,
        address _apntsToken,
        address _treasury,
        uint256 _staleness
    ) internal returns (SuperPaymaster) {
        SuperPaymaster impl = new SuperPaymaster(_entryPoint, _registry, _priceFeed);
        bytes memory initData = abi.encodeCall(SuperPaymaster.initialize, (_owner, _apntsToken, _treasury, _staleness));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return SuperPaymaster(payable(address(proxy)));
    }
}
