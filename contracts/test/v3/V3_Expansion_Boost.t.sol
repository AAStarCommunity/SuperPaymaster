// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/tokens/MySBT.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import "src/interfaces/v3/IRegistry.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}
    function mint(address to, uint256 tokenId) external { _mint(to, tokenId); }
}

contract V3_Reputation_SBT_BoostTest is Test {
    ReputationSystem public repSystem;
    MySBT public mysbt;
    Registry public registry;
    MockNFT public nft;
    
    address public admin = address(0x1);
    address public community = address(0x2);
    address public user = address(0x3);
    
    function setUp() public {
        vm.startPrank(admin);
        
        address mockGToken = address(0x888);
        address mockStaking = address(0x999);
        
        // Scheme B: Deploy Registry proxy first, then MySBT with immutable Registry
        registry = UUPSDeployHelper.deployRegistryProxy(admin, mockStaking, address(0));
        mysbt = new MySBT(mockGToken, mockStaking, address(registry), admin);
        registry.setMySBT(address(mysbt));

        // Mock staking setRoleExitFee (mockStaking is not a real contract)
        vm.mockCall(mockStaking, abi.encodeWithSignature("setRoleExitFee(bytes32,uint256,uint256)"), "");

        // 4. Set Role Owner for Authorization
        IRegistry.RoleConfig memory commCfg = registry.getRoleConfig(keccak256("COMMUNITY"));
        commCfg.owner = community;
        registry.configureRole(keccak256("COMMUNITY"), commCfg);
        
        // Setup Reputation
        repSystem = new ReputationSystem(address(registry));
        
        // Setup NFT for boost
        nft = new MockNFT();
        
        vm.stopPrank();
    }

    // ====================================
    // MySBT Tests (Boost)
    // ====================================

    function test_SBT_BurnAndAdminSetters() public {
        vm.startPrank(address(registry));
        bytes32 roleId = keccak256("ENDUSER");
        bytes memory data = abi.encode(community);
        (uint256 tid, ) = mysbt.mintForRole(user, roleId, data);
        vm.stopPrank();

        // Burn SBT
        vm.prank(address(registry));
        mysbt.burnSBT(user);
        assertEq(mysbt.userToSBT(user), 0);

        // Admin setters
        vm.startPrank(admin);
        mysbt.setMinLockAmount(1 ether);
        mysbt.setMintFee(0.2 ether);
        mysbt.pause();
        mysbt.unpause();
        vm.stopPrank();
    }
}
