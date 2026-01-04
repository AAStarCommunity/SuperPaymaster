// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract DVTSlashTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    GToken gtoken;
    SuperPaymaster paymaster;

    address owner = address(0x1);
    address dao = address(0x2);
    address treasury = address(0x3);
    address operator = address(0x4);
    address dvtAggregator = address(0x5);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);
        
        gtoken = new GToken(1000000 ether);
        staking = new GTokenStaking(address(gtoken), treasury);
        
        // 1. Deploy MySBT with placeholder registry
        sbt = new MySBT(address(gtoken), address(staking), address(0), dao);
        
        // 2. Deploy Registry with real MySBT
        registry = new Registry(address(gtoken), address(staking), address(sbt));
        
        // 3. Finalize linkage
        staking.setRegistry(address(registry));
        vm.stopPrank();
        vm.prank(dao);
        sbt.setRegistry(address(registry));
        vm.startPrank(owner);
        
        paymaster = new SuperPaymaster(
            IEntryPoint(address(0x123)), // Dummy non-zero address
            owner,
            registry,
            address(gtoken),
            address(0), // No price feed needed
            treasury
        );

        paymaster.setBLSAggregator(dvtAggregator);
        staking.setAuthorizedSlasher(dvtAggregator, true);
        
        // Initialize reputation
        paymaster.updateReputation(operator, 100);
        
        gtoken.mint(operator, 1000000 ether);
        vm.stopPrank();
    }

    function test_FullTwoTierSlashIntegration() public {
        // 1. Register Operator
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        
        bytes memory commData = abi.encode(
            Registry.CommunityRoleData({
                name: "OpComm",
                ensName: "",
                website: "",
                description: "",
                logoURI: "",
                stakeAmount: 30 ether
            })
        );
        registry.registerRole(registry.ROLE_COMMUNITY(), operator, commData);

        bytes memory roleData = abi.encode(
            Registry.PaymasterRoleData({
                paymasterContract: address(0x123),
                name: "TestPM",
                apiEndpoint: "https://pm.com",
                stakeAmount: 50 ether
            })
        );
        registry.registerRole(ROLE_PAYMASTER_SUPER, operator, roleData);
        vm.stopPrank();

        // Verify initial stake (30 for community + 50 for paymaster)
        assertEq(staking.balanceOf(operator), 80 ether);

        // 2. Perform Tier 1 Slash (aPNTs Rep Loss) via SuperPaymaster
        vm.startPrank(dvtAggregator);
        paymaster.executeSlashWithBLS(
            operator,
            ISuperPaymaster.SlashLevel.MINOR,
            "Tier 1 Penalty"
        );
        
        // Verify rep loss (assuming starting rep is 100, MINOR loss is 20)
        (,,,,, uint32 reputation,,,,) = paymaster.operators(operator);
        assertEq(reputation, 80);

        // 3. Perform Tier 2 Slash (GToken Stake) via GTokenStaking
        staking.slashByDVT(
            operator,
            ROLE_PAYMASTER_SUPER,
            10 ether,
            "Tier 2 Penalty"
        );
        
        // Verify GToken balance reduced (80 - 10 = 70)
        assertEq(staking.balanceOf(operator), 70 ether);
        assertEq(staking.totalStaked(), 70 ether);
        
        vm.stopPrank();
    }

    function test_SlashByDVT_Unauthorized_Reverts() public {
        address hacker = address(0x1337);
        vm.startPrank(hacker);
        
        vm.expectRevert("Not authorized slasher");
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 1 ether, "Hacked");
        
        vm.stopPrank();
    }

    function test_SlashByDVT_InsufficientStake_Reverts() public {
        vm.prank(owner);
        staking.setAuthorizedSlasher(dvtAggregator, true);

        vm.startPrank(dvtAggregator);
        vm.expectRevert("Insufficient stake");
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 1 ether, "No stake yet");
        vm.stopPrank();
    }
}
