// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

interface IGTokenStaking {
    function configureLocker(
        address locker,
        bool authorized,
        uint256 feeRateBps,
        uint256 minExitFee,
        uint256 maxFeePercent,
        uint256[] memory timeTiers,
        uint256[] memory tierFees,
        address feeRecipient
    ) external;
}

contract ConfigureGTokenStaking_v2_4_3 is Script {
    address constant GTOKENSTAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;
    address constant MYSBT_V2_4_3 = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C;

    function run() external {
        vm.startBroadcast();

        IGTokenStaking gtokenStaking = IGTokenStaking(GTOKENSTAKING);

        uint256[] memory timeTiers = new uint256[](0);
        uint256[] memory tierFees = new uint256[](0);

        gtokenStaking.configureLocker(
            MYSBT_V2_4_3,
            true,              // authorized
            100,               // feeRateBps (1%)
            0.01 ether,        // minExitFee
            500,               // maxFeePercent (5%)
            timeTiers,
            tierFees,
            MYSBT_V2_4_3       // feeRecipient
        );

        vm.stopBroadcast();
    }
}
