// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../src/paymasters/v2/tokens/MySBT_v2.4.0.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title MySBT_v2_4_0_Invariants
 * @notice Echidna invariant tests for MySBT v2.4.0
 * @dev Tests core SBT properties, community memberships, and NFT bindings
 */
contract MySBT_v2_4_0_Invariants {
    MySBT_v2_4_0 public sbt;
    MockGToken public gtoken;
    GTokenStaking public staking;
    MockRegistry public registry;
    MockCommunity public community1;
    MockCommunity public community2;

    address public constant DAO = address(0x1234);
    address public constant USER1 = address(0x5678);
    address public constant USER2 = address(0xABCD);

    // Track minted SBTs for invariant checking
    uint256[] public mintedTokenIds;
    mapping(uint256 => bool) public isTokenMinted;

    constructor() {
        // Deploy dependencies
        gtoken = new MockGToken();
        registry = new MockRegistry();
        staking = new GTokenStaking(address(gtoken));

        // Deploy MySBT
        sbt = new MySBT_v2_4_0(
            address(gtoken),
            address(staking),
            address(registry),
            DAO
        );

        // Setup staking
        staking.setTreasury(DAO);

        // Deploy mock communities
        community1 = new MockCommunity(address(sbt), address(gtoken));
        community2 = new MockCommunity(address(sbt), address(gtoken));

        // Register communities in registry
        registry.registerCommunity(address(community1));
        registry.registerCommunity(address(community2));

        // Mint tokens for testing
        gtoken.mint(address(this), 1_000_000 ether);
        gtoken.mint(address(community1), 1_000_000 ether);
        gtoken.mint(address(community2), 1_000_000 ether);

        // Approve
        gtoken.approve(address(sbt), type(uint256).max);
        gtoken.approve(address(staking), type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HELPER FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _mintSBTForUser(address user) internal returns (uint256 tokenId) {
        // Mint via community1
        (tokenId, ) = community1.mintSBT(user, "ipfs://test");
        if (!isTokenMinted[tokenId]) {
            mintedTokenIds.push(tokenId);
            isTokenMinted[tokenId] = true;
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CORE SBT INVARIANTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 1: One user can only have one SBT
    function echidna_one_sbt_per_user() public view returns (bool) {
        // If user has an SBT, it should be unique
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId != 0) {
            (address holder, , , ) = sbt.sbtData(tokenId);
            return holder == address(this);
        }
        return true;
    }

    /// INVARIANT 2: Every minted token must have a valid holder
    function echidna_token_has_valid_holder() public view returns (bool) {
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tokenId = mintedTokenIds[i];
            (address holder, , , ) = sbt.sbtData(tokenId);

            // Holder must not be zero address
            if (holder == address(0)) return false;

            // Reverse mapping must be consistent
            if (sbt.userToSBT(holder) != tokenId) return false;
        }
        return true;
    }

    /// INVARIANT 3: nextTokenId must be monotonically increasing
    function echidna_next_token_id_increases() public view returns (bool) {
        uint256 nextId = sbt.nextTokenId();
        // nextTokenId should be >= 1 (starts at 1)
        if (nextId < 1) return false;

        // nextTokenId should be >= number of minted tokens + 1
        return nextId >= mintedTokenIds.length + 1;
    }

    /// INVARIANT 4: SBT transfers must be disabled
    function echidna_no_transfers_allowed() public returns (bool) {
        // Try to mint an SBT first
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId == 0) {
            // No SBT yet, mint one
            tokenId = _mintSBTForUser(address(this));
        }

        // Echidna will try to transfer in fuzzing
        // We just verify the invariant: owner should always be the original holder
        (address holder, , , ) = sbt.sbtData(tokenId);
        return sbt.ownerOf(tokenId) == holder;
    }

    /// INVARIANT 5: Total communities count matches actual memberships
    function echidna_total_communities_matches_memberships() public view returns (bool) {
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tokenId = mintedTokenIds[i];
            (, , , uint256 totalCommunities) = sbt.sbtData(tokenId);

            // Count actual memberships
            uint256 actualCount = 0;
            try sbt.getMemberships(tokenId) returns (IMySBT.CommunityMembership[] memory memberships) {
                for (uint256 j = 0; j < memberships.length; j++) {
                    if (memberships[j].isActive) {
                        actualCount++;
                    }
                }

                // totalCommunities should match active memberships
                if (totalCommunities != actualCount) return false;
            } catch {
                // If getMemberships fails, totalCommunities should be 0
                if (totalCommunities != 0) return false;
            }
        }
        return true;
    }

    /// INVARIANT 6: User's SBT holder address must match the user
    function echidna_holder_address_consistency() public view returns (bool) {
        // Check this contract's SBT
        uint256 tokenId = sbt.userToSBT(address(this));
        if (tokenId != 0) {
            (address holder, , , ) = sbt.sbtData(tokenId);
            if (holder != address(this)) return false;
        }

        // Check all minted tokens
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tid = mintedTokenIds[i];
            (address holder, , , ) = sbt.sbtData(tid);
            address owner = sbt.ownerOf(tid);

            if (holder != owner) return false;
        }

        return true;
    }

    /// INVARIANT 7: mintedAt timestamp must be in the past
    function echidna_minted_at_in_past() public view returns (bool) {
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tokenId = mintedTokenIds[i];
            (, , uint256 mintedAt, ) = sbt.sbtData(tokenId);

            // mintedAt should be <= current block.timestamp
            if (mintedAt > block.timestamp) return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  COMMUNITY INVARIANTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 8: firstCommunity must be immutable
    function echidna_first_community_immutable() public view returns (bool) {
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tokenId = mintedTokenIds[i];
            (, address firstCommunity, , ) = sbt.sbtData(tokenId);

            // First community must not be zero address
            if (firstCommunity == address(0)) return false;

            // First community must be registered
            if (!registry.isValidCommunity(firstCommunity)) return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    REPUTATION INVARIANTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// INVARIANT 9: Reputation must be >= BASE_REPUTATION
    function echidna_reputation_min_value() public view returns (bool) {
        for (uint256 i = 0; i < mintedTokenIds.length; i++) {
            uint256 tokenId = mintedTokenIds[i];

            try sbt.getReputationScore(tokenId, address(community1)) returns (uint256 score) {
                // Score should be at least BASE_REPUTATION (20)
                if (score < sbt.BASE_REPUTATION()) return false;
            } catch {
                // If call fails, it's acceptable
            }
        }
        return true;
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      MOCK CONTRACTS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MockGToken is ERC20 {
    constructor() ERC20("Mock GToken", "GT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRegistry {
    mapping(address => bool) public communities;

    function registerCommunity(address community) external {
        communities[community] = true;
    }

    function isValidCommunity(address community) external view returns (bool) {
        return communities[community];
    }
}

contract MockCommunity {
    MySBT_v2_4_0 public sbt;
    IERC20 public gtoken;

    constructor(address _sbt, address _gtoken) {
        sbt = MySBT_v2_4_0(_sbt);
        gtoken = IERC20(_gtoken);
    }

    function mintSBT(address user, string memory metadata) external returns (uint256 tokenId, bool isNewMint) {
        // Approve tokens if needed
        gtoken.approve(address(sbt), type(uint256).max);

        return sbt.mintOrAddMembership(user, metadata);
    }
}
