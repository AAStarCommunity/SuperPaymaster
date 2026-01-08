// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/utils/Pausable.sol";

import "../interfaces/v3/IReputationCalculator.sol";
import "../interfaces/v3/IRegistry.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "src/interfaces/IVersioned.sol";

interface IRegistryLegacy {
    function isRegisteredCommunity(address community) external view returns (bool);
}

/**
 * @title MySBT v3.0.0
 * @notice Integration with Registry v3.0.0 Role-Based System
 * @dev Changelog from v2.4.5:
 *   - REGISTRY V3: Updated community validation to use hasRole(ROLE_COMMUNITY, address)
 *   - COMPAT: Removed deprecated mintOrAddMembership() function (use userMint instead)
 *   - INTERFACE: Simplified API to work with Registry v3 unified role system
 *   - BACKWARD COMPAT: Maintains v2 function signatures for existing integrations
 *   - GAS: Optimized validation using Registry v3 role checks
 */

/**
 * @dev V3 Breaking Change: Does NOT implement IMySBT interface
 *      IMySBT requires mintOrAddMembership() which violates v3 design principle
 *      All minting now goes through Registry.registerRole()
 */
contract MySBT is ERC721, ReentrancyGuard, Pausable, IVersioned {
    using SafeERC20 for IERC20;

    // ====================================
    // V3: Structs (moved from IMySBT since we don't implement that interface)
    // ====================================

    struct SBTData {
        address holder;
        address firstCommunity;    // Immutable, first issuing community
        uint256 mintedAt;
        uint256 totalCommunities;
    }

    struct CommunityMembership {
        address community;
        uint256 joinedAt;
        uint256 lastActiveTime;   // DEPRECATED: Use The Graph to query ActivityRecorded events
        bool isActive;
        string metadata;          // IPFS URI for community data
    }

    // ====================================
    // Events (from IMySBT)
    // ====================================

    event SBTMinted(
        address indexed user,
        uint256 indexed tokenId,
        address indexed firstCommunity,
        uint256 timestamp
    );

    event SBTBurned(
        address indexed user,
        uint256 indexed tokenId,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 timestamp
    );

    event MembershipAdded(
        uint256 indexed tokenId,
        address indexed community,
        string metadata,
        uint256 timestamp
    );

    event MembershipDeactivated(
        uint256 indexed tokenId,
        address indexed community,
        uint256 timestamp
    );

    event ActivityRecorded(
        uint256 indexed tokenId,
        address indexed community,
        uint256 week,
        uint256 timestamp
    );

    event ReputationCalculatorUpdated(
        address indexed oldCalculator,
        address indexed newCalculator,
        uint256 timestamp
    );

    event ContractPaused(address indexed by, uint256 timestamp);
    event ContractUnpaused(address indexed by, uint256 timestamp);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);
    event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);
    event DAOMultisigUpdated(address indexed oldDAO, address indexed newDAO, uint256 timestamp);

    // ====================================
    // State Variables
    // ====================================




    mapping(address => uint256) public userToSBT;
    mapping(uint256 => SBTData) public sbtData;
    mapping(uint256 => CommunityMembership[]) private _m;
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
    mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING;
    

    address public REGISTRY;
    address public daoMultisig;
    address public reputationCalculator;
    string private _baseTokenURI;

    uint256 public nextTokenId = 1;
    uint256 public minLockAmount = 0.3 ether;
    uint256 public mintFee = 0.1 ether;

    uint256 constant BASE_REP = 20;
    uint256 constant ACT_BONUS = 1;
    uint256 constant ACT_WIN = 4;
    uint256 constant MIN_INT = 5 minutes;

    error E();

    modifier onlyDAO() {
        require(msg.sender == daoMultisig, "Only DAO");
        _;
    }

    /**
     * @notice V3: Only Registry can call mint functions
     * @dev Prevents communities from bypassing Registry
     */
    modifier onlyRegistry() {
        require(msg.sender == REGISTRY, "Only Registry");
        _;
    }

    constructor(
        address _g,
        address _s,
        address _r,
        address _d
    ) ERC721("Mycelium Soul Bound Token", "MySBT") {
        require(_g != address(0) && _s != address(0) && _d != address(0));
        GTOKEN = _g;
        GTOKEN_STAKING = _s;
        REGISTRY = _r;
        daoMultisig = _d;
    }

    // ====================================
    // IVersioned Implementation
    // ====================================

    function version() external pure override returns (string memory) {
        return "MySBT-3.1.2";
    }

    // ====================================
    // V3: Minting Functions
    // ====================================
    //
    // BREAKING CHANGE in v3.0.0:
    // ====================================
    // V3 Minting Functions (Registry-only)
    // ====================================
    // All user-facing mint functions (mintOrAddMembership, userMint, mintWithAutoStake, safeMint)
    // have been REMOVED to enforce the v3 single responsibility principle:
    //
    // ✅ SINGLE ENTRY POINT: All role registration MUST go through Registry.registerRole()
    //
    // Only Registry-callable functions remain:
    // - mintForRole() - Self-service registration (user pays)
    // - airdropMint() - Admin airdrop (DAO/community pays)
    //
    // Users/DAO should call Registry.registerRole() or Registry.safeMintForRole() instead.
    // ====================================

    /**
     * @notice V3: Mint SBT for role registration (self-service registration)
     * @dev Called by Registry when user registers a role via registerRole()
     *      - Creates new SBT if user doesn't have one
     *      - Records role metadata on existing SBT
     *      - No staking/burning here (Registry handles that)
     * @param user User address to receive SBT
     * @param roleId Role identifier (e.g., ROLE_COMMUNITY, ROLE_ENDUSER)
     * @param roleData Role-specific metadata (community address, etc.)
     * @return tokenId Token ID (new or existing)
     * @return isNewMint True if new SBT was minted
     */
    function mintForRole(address user, bytes32 roleId, bytes calldata roleData)
        external
        whenNotPaused
        nonReentrant
        onlyRegistry
        returns (uint256 tokenId, bool isNewMint)
    {
        require(user != address(0), "Invalid user");

        tokenId = userToSBT[user];

        if (tokenId == 0) {
            // Create new SBT
            tokenId = nextTokenId++;
            isNewMint = true;

            // Decode community address from roleData
            address community = abi.decode(roleData, (address));

            sbtData[tokenId] = SBTData(user, community, block.timestamp, 1);
            userToSBT[user] = tokenId;

            // Decode full metadata if provided
            string memory meta = "";
            if (roleData.length > 32) {
                (, meta) = abi.decode(roleData, (address, string));
            }

            // Add community membership
            _m[tokenId].push(CommunityMembership(community, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tokenId][community] = 0;

            // Mint SBT to user
            _mint(user, tokenId);

            emit SBTMinted(user, tokenId, community, block.timestamp);
        } else {
            // Add role to existing SBT
            isNewMint = false;

            address community = abi.decode(roleData, (address));

            // Check if membership exists
            uint256 idx = membershipIndex[tokenId][community];
            if (idx < _m[tokenId].length && _m[tokenId][idx].community == community) {
                // HIGH-FIX: Reactivate if inactive (Re-join)
                if (!_m[tokenId][idx].isActive) {
                    _m[tokenId][idx].isActive = true;
                    // No event for reactivation in V3 spec, but we could emit MembershipAdded again or a new event.
                    // For now, emit MembershipAdded to signal effective join.
                    emit MembershipAdded(tokenId, community, "", block.timestamp);
                }
                return (tokenId, false);
            }

            string memory meta = "";
            if (roleData.length > 32) {
                (, meta) = abi.decode(roleData, (address, string));
            }

            // Add new membership
            _m[tokenId].push(CommunityMembership(community, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tokenId][community] = _m[tokenId].length - 1;
            sbtData[tokenId].totalCommunities++;

            emit MembershipAdded(tokenId, community, meta, block.timestamp);
        }
    }

    /**
     * @notice V3: Admin airdrop (DAO-paid minting)
     * @dev REMOVED staking logic - Registry handles all financial operations
     *      MySBT only mints the SBT token itself
     *      Called by Registry.safeMintForRole() for admin airdrops
     * @param u User address to receive SBT
     * @param roleId Role identifier
     * @param roleData Role-specific metadata
     * @return tid Token ID (new or existing)
     * @return isNew True if new SBT was minted
     */
    function airdropMint(address u, bytes32 roleId, bytes calldata roleData)
        external
        whenNotPaused
        nonReentrant
        onlyRegistry
        returns (uint256 tid, bool isNew)
    {
        require(u != address(0), "Invalid user");

        tid = userToSBT[u];

        if (tid == 0) {
            // Create new SBT
            tid = nextTokenId++;
            isNew = true;

            // Decode community address
            address community = abi.decode(roleData, (address));

            sbtData[tid] = SBTData(u, community, block.timestamp, 1);
            userToSBT[u] = tid;

            // Decode metadata if provided
            string memory meta = "";
            if (roleData.length > 32) {
                (, meta) = abi.decode(roleData, (address, string));
            }

            // Add community membership
            _m[tid].push(CommunityMembership(community, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][community] = 0;

            // Mint SBT to user
            _mint(u, tid);

            emit SBTMinted(u, tid, community, block.timestamp);
        } else {
            // Add role to existing SBT
            isNew = false;

            address community = abi.decode(roleData, (address));
            string memory meta = "";
            if (roleData.length > 32) {
                (, meta) = abi.decode(roleData, (address, string));
            }

            // Check if membership exists
            uint256 idx = membershipIndex[tid][community];
            if (idx < _m[tid].length && _m[tid][idx].community == community) {
                if (_m[tid][idx].isActive) {
                    return (tid, false); // Already an active member, nothing to do
                }
                // Reactivate membership
                _m[tid][idx].isActive = true;
                _m[tid][idx].joinedAt = block.timestamp;
                emit MembershipAdded(tid, community, meta, block.timestamp);
                return (tid, false);
            }

            // Add new membership
            _m[tid].push(CommunityMembership(community, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][community] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;

            emit MembershipAdded(tid, community, meta, block.timestamp);
        }
    }

    function burnSBT(address u) external whenNotPaused nonReentrant onlyRegistry {
        uint256 tid = userToSBT[u];
        require(tid != 0 && ownerOf(tid) == u);

        CommunityMembership[] storage mems = _m[tid];
        for (uint256 i = 0; i < mems.length; i++) {
            if (mems[i].isActive) {
                mems[i].isActive = false;
                emit MembershipDeactivated(tid, mems[i].community, block.timestamp);
            }
        }
        delete userToSBT[u];
        _burn(tid);
        // V3: Staking is handled by Registry, removed unlockAndTransfer call here
        emit SBTBurned(u, tid, minLockAmount, 0, block.timestamp);
    }

    function leaveCommunity(address comm) external whenNotPaused nonReentrant {
        _deactivateMembership(msg.sender, comm);
    }

    function deactivateMembership(address user, address community) external onlyRegistry {
        _deactivateMembership(user, community);
    }

    function _deactivateMembership(address user, address community) internal {
        uint256 tid = userToSBT[user];
        if (tid == 0) return;
        
        uint256 idx = membershipIndex[tid][community];
        if (idx >= _m[tid].length) return;
        
        CommunityMembership storage mem = _m[tid][idx];
        if (mem.community == community && mem.isActive) {
            mem.isActive = false;
            emit MembershipDeactivated(tid, community, block.timestamp);
        }
    }

    function verifyCommunityMembership(address u, address comm)
        external
        view
        returns (bool)
    {
        uint256 tid = userToSBT[u];
        if (tid == 0) return false;
        uint256 idx = membershipIndex[tid][comm];
        if (idx >= _m[tid].length) return false;
        CommunityMembership memory mem = _m[tid][idx];
        return mem.community == comm && mem.isActive;
    }

    function getUserSBT(address u) external view returns (uint256) {
        return userToSBT[u];
    }

    function getSBTData(uint256 tid) external view returns (SBTData memory) {
        return sbtData[tid];
    }

    function getMemberships(uint256 tid)
        external
        view
        returns (CommunityMembership[] memory)
    {
        return _m[tid];
    }

    function getCommunityMembership(uint256 tid, address comm)
        external
        view
        returns (CommunityMembership memory mem)
    {
        uint256 idx = membershipIndex[tid][comm];
        require(idx < _m[tid].length);
        mem = _m[tid][idx];
        require(mem.community == comm);
    }

    /**
     * @notice Get all active memberships for an SBT
     * @param tid Token ID
     * @return active Array of active community addresses
     */
    function getActiveMemberships(uint256 tid) external view returns (address[] memory active) {
        CommunityMembership[] memory all = _m[tid];
        uint256 count = 0;
        
        // Count active memberships
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].isActive) {
                count++;
            }
        }
        
        // Build active array
        active = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].isActive) {
                active[j] = all[i].community;
                j++;
            }
        }
    }

    // NFT binding functions removed for contract size optimization (v2.4.5-optimized)

    function recordActivity(address u) external whenNotPaused {
        require(_isValid(msg.sender));
        uint256 tid = userToSBT[u];
        require(tid != 0);
        uint256 idx = membershipIndex[tid][msg.sender];
        require(idx < _m[tid].length && _m[tid][idx].community == msg.sender);
        uint256 last = lastActivityTime[tid][msg.sender];
        require(last == 0 || block.timestamp >= last + MIN_INT);
        lastActivityTime[tid][msg.sender] = block.timestamp;
        emit ActivityRecorded(tid, msg.sender, block.timestamp / 1 weeks, block.timestamp);
    }

    // Reputation calculation functions removed for contract size optimization (v2.4.5-optimized)
    // Use external reputationCalculator contract for reputation queries

    // ====================================
    // Admin Functions
    // ====================================

    function setReputationCalculator(address c) external onlyDAO {
        address old = reputationCalculator;
        reputationCalculator = c;
        emit ReputationCalculatorUpdated(old, c, block.timestamp);
    }

    function setMinLockAmount(uint256 a) external onlyDAO {
        require(a != 0);
        uint256 old = minLockAmount;
        minLockAmount = a;
        emit MinLockAmountUpdated(old, a, block.timestamp);
    }

    function setMintFee(uint256 f) external onlyDAO {
        uint256 old = mintFee;
        mintFee = f;
        emit MintFeeUpdated(old, f, block.timestamp);
    }

    function setDAOMultisig(address d) external onlyDAO {
        require(d != address(0));
        address old = daoMultisig;
        daoMultisig = d;
        emit DAOMultisigUpdated(old, d, block.timestamp);
    }

    function setBaseURI(string calldata baseURI) external onlyDAO {
        _baseTokenURI = baseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setRegistry(address r) external onlyDAO {
        require(r != address(0));
        address old = REGISTRY;
        REGISTRY = r;
        emit RegistryUpdated(old, r, block.timestamp);
    }

    function pause() external onlyDAO {
        _pause();
        emit ContractPaused(msg.sender, block.timestamp);
    }

    function unpause() external onlyDAO {
        _unpause();
        emit ContractUnpaused(msg.sender, block.timestamp);
    }

    /**
     * @dev V3: Validate community using Registry v3 role system
     * @param c Community address to validate
     * @return bool True if address has COMMUNITY role in Registry v3
     */
    function _isValid(address c) internal view returns (bool) {
        if (REGISTRY == address(0)) return false;

        // V3: Use hasRole() with ROLE_COMMUNITY constant
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        try IRegistry(REGISTRY).hasRole(ROLE_COMMUNITY, c) returns (bool r) {
            return r;
        } catch {
            // Fallback to v2 for backward compatibility during transition
            try IRegistryLegacy(REGISTRY).isRegisteredCommunity(c) returns (bool r) {
                return r;
            } catch {
                return false;
            }
        }
    }

    function _update(address to, uint256 tid, address auth)
        internal
        virtual
        override
        returns (address)
    {
        address from = _ownerOf(tid);
        require(from == address(0) || to == address(0));
        return super._update(to, tid, auth);
    }
}
