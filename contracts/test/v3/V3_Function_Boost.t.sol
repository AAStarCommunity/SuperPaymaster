// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/Registry.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/tokens/GToken.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "../../src/tokens/xPNTsToken.sol";

contract V3_Function_BoostTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gToken;
    SuperPaymasterV3 paymaster;
    xPNTsToken aPNTs;

    address owner = address(this);
    address user = address(0x2);
    address manager = address(0x3);
    address treasury = address(0x4);

    function setUp() public {
        gToken = new GToken(1000 ether);
        staking = new GTokenStaking(address(gToken), treasury);
        registry = new Registry(address(gToken), address(staking), address(0xdead));
        staking.setRegistry(address(registry));
        
        aPNTs = new xPNTsToken("a", "b", owner, "c", "d", 1e18);
        paymaster = new SuperPaymasterV3(IEntryPoint(address(0x123)), owner, registry, address(aPNTs), address(0x123), treasury);
        
        aPNTs.setSuperPaymasterAddress(address(paymaster));
    }

    // --- Registry Function Boost ---

    function test_Registry_AdminSetters() public {
        // setRoleOwner
        registry.setRoleOwner(registry.ROLE_COMMUNITY(), manager);
        assertEq(registry.roleOwners(registry.ROLE_COMMUNITY()), manager);

        // setRegistry (on Staking side via Registry call if exists or direct)
        // Note: Registry doesn't have setStakingRegistry usually, handled in setup
    }

    function test_Registry_ReputationSource() public {
        registry.setReputationSource(manager, true);
        assertTrue(registry.isReputationSource(manager));
        
        registry.setReputationSource(manager, false);
        assertFalse(registry.isReputationSource(manager));
    }

    function test_Registry_CreditTierConfig() public {
        registry.setCreditTier(10, 5000 ether);
        assertEq(registry.creditTierConfig(10), 5000 ether);
    }

    // --- Staking Function Boost ---

    function test_Staking_AdminSetters() public {
        staking.setTreasury(address(0x888));
        assertEq(staking.treasury(), address(0x888));

        staking.setAuthorizedSlasher(manager, true);
        assertTrue(staking.authorizedSlashers(manager));
    }

    function test_Staking_Getters() public {
        // 1. Setup tokens
        gToken.mint(user, 100 ether);
        vm.prank(user);
        gToken.approve(address(staking), 100 ether);

        // 2. Mock lockStake by Registry
        // Ensure Registry is correctly set in Staking (done in setUp)
        vm.prank(address(registry));
        staking.lockStake(user, registry.ROLE_COMMUNITY(), 30 ether, 3 ether, user);

        // 3. Check getters
        IGTokenStakingV3.RoleLock[] memory locks = staking.getUserRoleLocks(user);
        assertEq(locks.length, 1);
        assertEq(locks[0].amount, 30 ether);

        (uint256 fee, uint256 net) = staking.previewExitFee(user, registry.ROLE_COMMUNITY());
        assertEq(fee, 1.5 ether); 
        assertEq(net, 28.5 ether);
    }

    // --- Paymaster Function Boost ---

    function test_Paymaster_AdminSetters() public {
        paymaster.setAPNTSPrice(0.03 ether);
        assertEq(paymaster.aPNTsPriceUSD(), 0.03 ether);

        paymaster.setTreasury(address(0x999));
        assertEq(paymaster.treasury(), address(0x999));

        paymaster.setProtocolFee(300); // 3%
        assertEq(paymaster.protocolFeeBPS(), 300);
    }

    function test_Paymaster_OperatorPausing() public {
        // 1. Register manager as operator via Registry
        bytes32 role = registry.ROLE_COMMUNITY();
        bytes memory data = abi.encode(Registry.CommunityRoleData("a","b","c","d","e", 30 ether));
        gToken.mint(manager, 100 ether);
        
        vm.prank(manager);
        gToken.approve(address(staking), 100 ether);
        
        vm.prank(manager);
        registry.registerRoleSelf(role, data);
        
        // 2. Configure in Paymaster
        vm.prank(manager);
        paymaster.configureOperator(address(aPNTs), treasury, 1e18);

        // 3. Pause as OWNER (this)
        paymaster.setOperatorPaused(manager, true);
        (,,bool isPaused,,,,,,,) = paymaster.operators(manager);
        assertTrue(isPaused);
        
        paymaster.setOperatorPaused(manager, false);
        (,,bool isPaused2,,,,,,,) = paymaster.operators(manager);
        assertFalse(isPaused2);
    }
}
