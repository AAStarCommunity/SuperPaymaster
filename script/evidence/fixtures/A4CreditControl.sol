// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {xPNTsTokenV2} from "../../../contracts/src/tokens/v2/xPNTsTokenV2.sol";

// Only sets fixture configuration; reserve/release execute inherited production code.
contract A4CreditControl is xPNTsTokenV2 {
    constructor(address user) xPNTsTokenV2(address(1), address(2)) {
        SUPERPAYMASTER_ADDRESS = msg.sender;
        creditTierSource = address(this);
        creditPolicy = POLICY_MANUAL;
        maxSingleTxLimit = 100;
        creditReq[user] = CreditReq(100, 100, 0);
    }
    function tierOf(address, address) external pure returns (uint256) { return 100; }
}
