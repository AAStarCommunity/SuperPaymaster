// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

interface IxPNTsToken {
    function addAutoApprovedSpender(address spender) external;
    function isAutoApproved(address spender) external view returns (bool);
}

interface IxPNTsFactory {
    function owner() external view returns (address);
}

/**
 * @notice Add SuperPaymaster to xPNTs token's autoApprovedSpenders list
 * @dev Call via factory owner since factory has permission
 */
contract AddAutoApprove is Script {
    address constant XPNTS_TOKEN = 0xfb56CB85C9a214328789D3C92a496d6AA185e3d3;
    address constant SUPER_PAYMASTER = 0xD6aa17587737C59cbb82986Afbac88Db75771857;
    address constant FACTORY = 0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Factory:", FACTORY);
        console.log("xPNTs Token:", XPNTS_TOKEN);
        console.log("SuperPaymaster:", SUPER_PAYMASTER);

        // Verify deployer owns factory
        address factoryOwner = IxPNTsFactory(FACTORY).owner();
        console.log("Factory Owner:", factoryOwner);
        require(factoryOwner == deployer, "Deployer is not factory owner");

        // Check current status
        bool isApprovedBefore = IxPNTsToken(XPNTS_TOKEN).isAutoApproved(SUPER_PAYMASTER);
        console.log("SuperPaymaster approved before:", isApprovedBefore);

        if (isApprovedBefore) {
            console.log("Already approved, skipping");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Call addAutoApprovedSpender via low-level call from factory
        // We need to make factory call the token
        // Since we can't directly make factory call, we need to do it through factory owner

        // Actually, factory doesn't have a function to proxy this call
        // So we need to call it from deployer AS the factory's owner
        // But that won't work because the check is msg.sender != FACTORY

        // The solution: deploy a helper contract that will be called by factory owner
        // Or: Check if we can add a function to factory

        // For now, let's try calling from factory address (won't work via cast)
        console.log("Cannot call addAutoApprovedSpender from factory via script");
        console.log("Factory needs to have a function to proxy this call");

        vm.stopBroadcast();
    }
}
