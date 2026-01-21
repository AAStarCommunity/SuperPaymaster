// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/interfaces/IERC1363.sol";

contract MaliciousReentrantReceiver is IERC1363Receiver {
    xPNTsToken public token;
    bool public attemptFailed;

    constructor(address _token) {
        token = xPNTsToken(_token);
    }

    function onTransferReceived(address, address, uint256, bytes memory) external override returns (bytes4) {
        // Attempt to re-enter transferAndCall
        try token.transferAndCall(address(this), 1 ether) {
            // If this succeeds, reentrancy guard failed
        } catch Error(string memory reason) {
            if (keccak256(abi.encodePacked(reason)) == keccak256(abi.encodePacked("ReentrancyGuard: reentrant call"))) {
                attemptFailed = true;
            }
        }
        return IERC1363Receiver.onTransferReceived.selector;
    }
}

contract xPNTsSecurityDeepAuditTest is Test {
    using Clones for address;
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address paymaster = address(0x333);
    address factory = address(0xABC);

    function setUp() public {
        vm.startPrank(factory);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("SecurityToken", "ST", admin, "Comm", "ens.eth", 1e18);
        vm.stopPrank();
        
        vm.prank(admin);
        token.setSuperPaymasterAddress(paymaster);
    }

    // 1. Reentrancy Guard Protection
    function test_Security_ReentrancyGuard() public {
        MaliciousReentrantReceiver mal = new MaliciousReentrantReceiver(address(token));
        vm.prank(admin);
        token.mint(user, 100 ether);

        vm.prank(user);
        token.transferAndCall(address(mal), 10 ether);
        
        assertTrue(mal.attemptFailed(), "Reentrancy should have been caught");
    }

    // 2. Debt Repayment Over-payment prevention
    function test_Security_DebtRepayment_Limits() public {
        vm.prank(admin);
        token.mint(user, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);

        // Attempt to repay 20 when debt is only 10
        vm.prank(user);
        vm.expectRevert("Repay amount exceeds debt");
        token.repayDebt(20 ether);

        // Attempt to repay 10 when balance is 5 (cheat by burning user tokens)
        vm.prank(user);
        token.burn(95 ether); // balance is now 5
        vm.prank(user);
        vm.expectRevert("ERC20: burn amount exceeds balance");
        token.repayDebt(10 ether);
    }

    // 2.5 Single Transaction Limit Boundary Tests
    function test_Security_SingleTxLimit_Boundary() public {
        vm.prank(admin);
        token.mint(user, 20000 ether);

        // A. Exactly 5,000 ether - Should PASS
        vm.prank(paymaster);
        token.transferFrom(user, paymaster, 5000 ether);
        assertEq(token.balanceOf(paymaster), 5000 ether);

        // B. 4,999.99... ether - Should PASS
        vm.prank(paymaster);
        token.transferFrom(user, paymaster, 5000 ether - 1);
        
        // C. 5,000.01... ether - Should REVERT
        vm.prank(paymaster);
        vm.expectRevert("Single transaction limit exceeded");
        token.transferFrom(user, paymaster, 5000 ether + 1);
    }

    // 2.6 Concurrency/Cumulative Verification
    function test_Security_Concurrency_NotCumulative() public {
        vm.prank(admin);
        token.mint(user, 20000 ether);

        // Perform multiple 4,000 ether transfers (Total 12,000 > 5,000)
        // This verifies it is NOT a cumulative daily/total limit
        vm.startPrank(paymaster);
        
        token.transferFrom(user, paymaster, 4000 ether);
        token.transferFrom(user, paymaster, 4000 ether);
        token.transferFrom(user, paymaster, 4000 ether);
        
        vm.stopPrank();
        
        assertEq(token.balanceOf(paymaster), 12000 ether);
        assertEq(token.balanceOf(user), 8000 ether);
    }

    // 3. Factory Renunciation (Decentralization)
    function test_Security_FactoryRenunciation() public {
        // Factory can initially mint
        vm.prank(factory);
        token.mint(user, 10 ether);
        assertEq(token.balanceOf(user), 10 ether);

        // Admin renounces factory
        vm.prank(admin);
        token.renounceFactory();

        // Factory can no longer mint
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, factory));
        token.mint(user, 10 ether);
    }

    // 4. Exchange Rate Sanity
    function test_Security_ExchangeRate_NonZero() public {
        vm.prank(admin);
        vm.expectRevert("Exchange rate cannot be zero");
        token.updateExchangeRate(0);
    }

    // 5. Zero-Address Defense in RecordDebt
    function test_Security_RecordDebt_ZeroSP() public {
        // Deploy a new token without setting paymaster
        vm.startPrank(factory);
        xPNTsToken token2 = xPNTsToken(address(new xPNTsToken()).clone());
        token2.initialize("ST2", "ST2", admin, "Comm", "ens.eth", 1e18);
        vm.stopPrank();

        // Attempt to record debt when SP is not configured
        vm.prank(admin); // even admin can't record debt if SP isn't set
        vm.expectRevert("System: SuperPaymaster not configured");
        token2.recordDebt(user, 1 ether);
    }

    // 6. Emergency Revoke Verification
    function test_Security_EmergencyRevoke() public {
        // Admin calls emergency revoke
        vm.prank(admin);
        token.emergencyRevokePaymaster();
        
        // Verify paymaster is revoked
        assertFalse(token.autoApprovedSpenders(paymaster));
        
        // Verify paymaster can no longer transfer
        vm.prank(admin);
        token.mint(user, 1000 ether);
        
        vm.prank(paymaster);
        vm.expectRevert(); 
        token.transferFrom(user, paymaster, 100 ether);
    }
}
