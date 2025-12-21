// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/tokens/MySBT.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}
    function mint(address to, uint256 tokenId) external { _mint(to, tokenId); }
}

contract V3_Reputation_SBT_BoostTest is Test {
    ReputationSystemV3 public repSystem;
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
        
        // Circular dependency handling:
        // 1. Deploy Registry with a dummy SBT address
        registry = new Registry(mockGToken, mockStaking, address(0x777));
        
        // 2. Deploy MySBT with the real registry
        mysbt = new MySBT(mockGToken, mockStaking, address(registry), admin);
        
        // 3. Update Registry's SBT (MYSBT is immutable in Registry, so I must RE-DEPLOY Registry or use a mock)
        // Wait, if Registry.MYSBT is immutable, I MUST deploy MySBT first.
        // But MySBT constructor needs REGISTRY. 
        // MySBT has setRegistry(), so I can deploy MySBT with address(0) or dummy, then Registry, then setRegistry.
        
        // Let's do:
        mysbt = new MySBT(mockGToken, mockStaking, address(0), admin);
        registry = new Registry(mockGToken, mockStaking, address(mysbt));
        mysbt.setRegistry(address(registry));
        
        // 4. Set Role Owner for Authorization
        registry.setRoleOwner(keccak256("COMMUNITY"), community);
        
        // Setup Reputation
        repSystem = new ReputationSystemV3(address(registry));
        
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
        vm.prank(user);
        mysbt.burnSBT();
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
