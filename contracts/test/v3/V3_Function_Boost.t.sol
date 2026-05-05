// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/Registry.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/tokens/GToken.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "./MockSBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import "src/interfaces/v3/IRegistry.sol";

contract V3_Function_BoostTest is Test {
    using Clones for address;
    Registry registry;
    GTokenStaking staking;
    GToken gToken;
    SuperPaymaster paymaster;
    xPNTsToken aPNTs;
    MockSBT mockSBT;

    address owner = address(this);
    address user = address(0x2);
    address manager = address(0x3);
    address treasury = address(0x4);

    function setUp() public {
        gToken = new GToken(1000 ether);
        mockSBT = new MockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(mockSBT));
        staking = new GTokenStaking(address(gToken), treasury, address(registry));
        registry.setStaking(address(staking));
        
        vm.startPrank(owner);
        staking.setRoleExitFee(registry.ROLE_KMS(), 1000, 5 ether);
        staking.setRoleExitFee(registry.ROLE_COMMUNITY(), 500, 1 ether);
        staking.setRoleExitFee(registry.ROLE_ENDUSER(), 1000, 0.05 ether);
        vm.stopPrank();

        address implementation = address(new xPNTsToken());
        aPNTs = xPNTsToken(implementation.clone());
        aPNTs.initialize("a", "b", owner, "c", "d", 1e18);
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(IEntryPoint(address(0x123)), IRegistry(address(registry)), address(0x123), owner, address(aPNTs), treasury, 3600);
        
        aPNTs.setSuperPaymasterAddress(address(paymaster));
    }

    // --- Registry Function Boost ---

    function test_Registry_AdminSetters() public {
        vm.startPrank(owner);
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(registry.ROLE_COMMUNITY());
        cfg.owner = manager;
        registry.configureRole(registry.ROLE_COMMUNITY(), cfg);
        vm.stopPrank();
        assertEq(registry.getRoleConfig(registry.ROLE_COMMUNITY()).owner, manager);

        // setRegistry (on Staking side via Registry call if exists or direct)
        // Note: Registry doesn't have setStakingRegistry usually, handled in setup
    }

    function test_Registry_ReputationSource() public {
        vm.prank(owner);
        registry.setReputationSource(manager, true);
        assertTrue(registry.isReputationSource(manager));
        
        vm.prank(owner);
        registry.setReputationSource(manager, false);
        assertFalse(registry.isReputationSource(manager));
    }

    function test_Registry_CreditTierConfig() public {
        vm.prank(owner);
        registry.setCreditTier(10, 5000 ether);
        assertEq(registry.creditTierConfig(10), 5000 ether);
    }

    function test_Registry_HistoryAndMembers() public {
        bytes32 commRole = registry.ROLE_COMMUNITY();
        bytes32 kmsRole = registry.ROLE_KMS();

        // 1. Setup Community
        bytes memory commData = abi.encode(Registry.CommunityRoleData("CommA","a","b","c","d", 30 ether));
        gToken.mint(manager, 200 ether);

        vm.startPrank(manager);
        gToken.approve(address(staking), 200 ether);
        registry.registerRole(commRole, manager, commData);
        vm.stopPrank();

        // 2. Setup KMS (operator role that can exit)
        gToken.mint(user, 200 ether);

        vm.startPrank(user);
        gToken.approve(address(staking), 200 ether);
        registry.registerRole(kmsRole, user, abi.encode(uint256(100 ether)));

        // 3. Verify
        assertEq(registry.getRoleUserCount(kmsRole), 1);

        // Exit KMS (operator role)
        vm.stopPrank();
        vm.startPrank(owner);
        IRegistry.RoleConfig memory kmsCfg = registry.getRoleConfig(kmsRole);
        kmsCfg.roleLockDuration = 0;
        registry.configureRole(kmsRole, kmsCfg);
        vm.stopPrank();
        vm.startPrank(user);
        registry.exitRole(kmsRole);
        vm.stopPrank();
    }

    // --- Staking Function Boost ---

    function test_Staking_AdminSetters() public {
        vm.startPrank(owner);
        staking.setTreasury(address(0x888));
        assertEq(staking.treasury(), address(0x888));

        staking.setAuthorizedSlasher(manager, true);
        assertTrue(staking.authorizedSlashers(manager));
        vm.stopPrank();
    }

    function test_Staking_Getters() public {
        // 1. Setup tokens
        bytes32 commRole = registry.ROLE_COMMUNITY();
        
        gToken.mint(user, 100 ether);
        vm.prank(user);
        gToken.approve(address(staking), 100 ether);

        // 2. Mock lockStakeWithTicket by Registry
        vm.startPrank(address(registry));
        staking.lockStakeWithTicket(user, commRole, 30 ether, 3 ether, user);
        vm.stopPrank();

        // 3. Check getters
        IGTokenStaking.RoleLock[] memory locks = staking.getUserRoleLocks(user);
        assertEq(locks.length, 1);

        (uint256 fee, uint256 net) = staking.previewExitFee(user, commRole);
        // setUp() explicitly configures COMMUNITY with 500bps to exercise the fee path
        assertEq(fee, 1.5 ether);
        assertEq(net, 28.5 ether);
    }

    // --- Paymaster Function Boost ---

    function test_Paymaster_AdminSetters() public {
        vm.startPrank(owner);
        paymaster.setAPNTSPrice(0.03 ether);
        assertEq(paymaster.aPNTsPriceUSD(), 0.03 ether);

        paymaster.setTreasury(address(0x999));
        assertEq(paymaster.treasury(), address(0x999));

        paymaster.setProtocolFee(300); // 3%
        assertEq(paymaster.protocolFeeBPS(), 300);
        vm.stopPrank();
    }

    function test_Paymaster_OperatorPausing() public {
        bytes32 commRole = registry.ROLE_COMMUNITY();
        
        // 1. Register manager as operator via Registry
        bytes memory data = abi.encode(Registry.CommunityRoleData("a","b","c","d","e", 30 ether));
        gToken.mint(manager, 100 ether);
        
        vm.startPrank(manager);
        gToken.approve(address(staking), 100 ether);
        registry.registerRole(commRole, manager, data);

        // 1.5 Register as SuperPaymaster
        bytes memory opData = abi.encode(uint256(50 ether));
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), manager, opData);

        // 2. Configure in Paymaster
        paymaster.configureOperator(address(aPNTs), treasury, 1e18);
        vm.stopPrank();

        // 3. Pause as OWNER
        vm.startPrank(owner);
        paymaster.setOperatorPaused(manager, true);
        (,,,bool isPaused,,,,,,) = paymaster.operators(manager);
        assertTrue(isPaused);
        
        paymaster.setOperatorPaused(manager, false);
        (,,,bool isPaused2,,,,,,) = paymaster.operators(manager);
        assertFalse(isPaused2);
        vm.stopPrank();
    }
}
