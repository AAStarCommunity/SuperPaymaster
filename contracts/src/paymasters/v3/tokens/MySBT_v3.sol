// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/utils/Pausable.sol";
import "../interfaces/IRegistryV3.sol";
import "../interfaces/IGTokenStakingV3.sol";
import "../../v2/interfaces/IMySBT.sol";
import "../../v2/interfaces/IReputationCalculator.sol";
import "../../../interfaces/IVersioned.sol";
import "../../../config/shared-config.sol";

/**
 * @title MySBT v3.0.0
 * @notice Soul-Bound Token with Registry v3 Integration
 * @dev Major changes from v2.4.5:
 *   - REGISTRY V3: Uses unified registerRole() API
 *   - ROLE-BASED: Community validation via roleId
 *   - GTOKENSTAKING V3: Role-based stake locking
 *   - SHARED CONFIG: Centralized configuration
 *   - BACKWARD COMPAT: Maintains v2 interface support
 */
contract MySBT_v3 is ERC721, ReentrancyGuard, Pausable, IMySBT, IVersioned {
    using SafeERC20 for IERC20;

    // ====================================
    // Version
    // ====================================

    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;

    // ====================================
    // Storage (v2 compatible)
    // ====================================

    mapping(address => uint256) public userToSBT;
    mapping(uint256 => SBTData) public sbtData;
    mapping(uint256 => CommunityMembership[]) private _m;
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
    mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

    // ====================================
    // Immutable Contracts
    // ====================================

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING_V3;
    address public immutable SHARED_CONFIG;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ====================================
    // Configurable Contracts
    // ====================================

    address public REGISTRY_V3;
    address public daoMultisig;
    address public reputationCalculator;
    address public SUPER_PAYMASTER; // For SBT holder callbacks

    // ====================================
    // Configuration
    // ====================================

    uint256 public nextTokenId = 1;
    uint256 public minLockAmount = 0.3 ether;
    uint256 public mintFee = 0.1 ether;

    uint256 constant BASE_REP = 20;
    uint256 constant ACT_BONUS = 1;
    uint256 constant ACT_WIN = 4;
    uint256 constant MIN_INT = 5 minutes;

    error E();

    // ====================================
    // Events (v3 additions)
    // ====================================

    event RegistryV3Updated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);
    event RoleBasedMint(uint256 indexed tokenId, address indexed user, bytes32 indexed roleId, uint256 timestamp);

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyDAO() {
        require(msg.sender == daoMultisig);
        _;
    }

    modifier onlyReg() {
        require(_isValidCommunity(msg.sender), "Not a valid community");
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _g,
        address _s,
        address _r,
        address _d,
        address _config
    ) ERC721("Mycelium Soul Bound Token v3", "MySBT-v3") {
        require(_g != address(0) && _s != address(0) && _r != address(0) && _d != address(0) && _config != address(0));
        GTOKEN = _g;
        GTOKEN_STAKING_V3 = _s;
        REGISTRY_V3 = _r;
        daoMultisig = _d;
        SHARED_CONFIG = _config;
    }

    // ====================================
    // IVersioned Implementation
    // ====================================

    function version() external pure override returns (string memory) {
        return VERSION;
    }

    function versionCode() external pure override returns (uint256) {
        return VERSION_CODE;
    }

    // ====================================
    // Core Functions - V3 Updated
    // ====================================

    /**
     * @notice Mint SBT and join community (v3 with role validation)
     * @param comm Community address
     * @param meta Metadata for membership
     * @return tid Token ID
     */
    function safeMintAndJoin(address comm, bytes calldata meta)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tid)
    {
        require(comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);

        // V3: Check community has COMMUNITY role and allows permissionless mint
        require(
            _isValidCommunity(comm) &&
            _isPermissionlessMintAllowed(comm),
            "Community not valid or permissionless mint disabled"
        );

        address u = msg.sender;
        tid = userToSBT[u];

        if (tid == 0) {
            tid = _mintSBT(u, 0);
        }

        _joinCommunity(tid, comm, meta);
    }

    /**
     * @notice Mint with auto-stake (v3 with role-based locking)
     * @param comm Community address
     * @param meta Metadata
     * @param stakeAmount Amount to stake
     * @return tid Token ID
     */
    function safeMintAndJoinWithAutoStake(
        address comm,
        bytes calldata meta,
        uint256 stakeAmount
    ) external nonReentrant whenNotPaused returns (uint256 tid) {
        require(comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        require(_isValidCommunity(comm) && _isPermissionlessMintAllowed(comm));

        uint256 avail = IGTokenStakingV3(GTOKEN_STAKING_V3).availableBalance(msg.sender);
        if (avail > 0) {
            require(stakeAmount == 0, "Already has stake");
            require(avail >= minLockAmount, "Insufficient available stake");
        } else {
            require(stakeAmount >= minLockAmount, "Insufficient stake amount");
            IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), stakeAmount + mintFee);
            IERC20(GTOKEN).approve(GTOKEN_STAKING_V3, stakeAmount);
            IGTokenStakingV3(GTOKEN_STAKING_V3).stakeFor(msg.sender, stakeAmount);
        }

        // V3: Lock stake with ENDUSER role
        bytes32 roleId = SharedConfig(SHARED_CONFIG).ROLE_ENDUSER();
        IGTokenStakingV3(GTOKEN_STAKING_V3).lockStake(
            msg.sender,
            roleId,
            minLockAmount,
            mintFee
        );

        tid = _mintSBT(msg.sender, mintFee);
        _joinCommunity(tid, comm, meta);
    }

    /**
     * @notice Join additional community
     * @param comm Community address
     * @param meta Metadata
     */
    function joinCommunity(address comm, bytes calldata meta)
        external
        nonReentrant
        whenNotPaused
    {
        uint256 tid = userToSBT[msg.sender];
        require(tid != 0, "No SBT");
        require(comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        require(_isValidCommunity(comm) && _isPermissionlessMintAllowed(comm));
        _joinCommunity(tid, comm, meta);
    }

    /**
     * @notice Exit from community
     * @param comm Community address
     */
    function exitCommunity(address comm) external nonReentrant {
        uint256 tid = userToSBT[msg.sender];
        require(tid != 0, "No SBT");
        require(membershipIndex[tid][comm] != 0, "Not a member");

        uint256 idx = membershipIndex[tid][comm] - 1;
        CommunityMembership[] storage memberships = _m[tid];

        // Remove membership
        if (idx < memberships.length - 1) {
            memberships[idx] = memberships[memberships.length - 1];
            membershipIndex[tid][memberships[idx].community] = idx + 1;
        }
        memberships.pop();
        delete membershipIndex[tid][comm];

        emit CommunityExited(tid, comm, block.timestamp);
    }

    /**
     * @notice Burn SBT and unlock stake
     * @param tid Token ID
     */
    function burn(uint256 tid) external nonReentrant {
        require(ownerOf(tid) == msg.sender, "Not owner");

        // Clear memberships
        delete _m[tid];
        delete userToSBT[msg.sender];
        delete sbtData[tid];

        // V3: Unlock stake from ENDUSER role
        bytes32 roleId = SharedConfig(SHARED_CONFIG).ROLE_ENDUSER();
        try IGTokenStakingV3(GTOKEN_STAKING_V3).unlockStake(msg.sender, roleId) returns (uint256) {
            // Stake unlocked successfully
        } catch {
            // No stake to unlock or already unlocked
        }

        // Notify SuperPaymaster if configured
        if (SUPER_PAYMASTER != address(0)) {
            try ISuperPaymaster(SUPER_PAYMASTER).removeSBTHolder(msg.sender) {} catch {}
        }

        _burn(tid);
        emit SBTBurned(tid, msg.sender, block.timestamp);
    }

    // ====================================
    // Admin Functions - V3
    // ====================================

    /**
     * @notice Set Registry v3 contract
     * @param r New registry address
     */
    function setRegistryV3(address r) external onlyDAO {
        require(r != address(0));
        address old = REGISTRY_V3;
        REGISTRY_V3 = r;
        emit RegistryV3Updated(old, r, block.timestamp);
    }

    /**
     * @notice Set SuperPaymaster for callbacks
     * @param s SuperPaymaster address
     */
    function setSuperPaymaster(address s) external onlyDAO {
        address old = SUPER_PAYMASTER;
        SUPER_PAYMASTER = s;
        emit SuperPaymasterUpdated(old, s, block.timestamp);
    }

    // ====================================
    // View Functions - V3
    // ====================================

    /**
     * @notice Get community membership details
     * @param tid Token ID
     * @param comm Community address
     * @return membership Membership details
     */
    function getCommunityMembership(uint256 tid, address comm)
        external
        view
        override
        returns (CommunityMembership memory)
    {
        uint256 idx = membershipIndex[tid][comm];
        require(idx != 0, "Not a member");
        return _m[tid][idx - 1];
    }

    /**
     * @notice Get all memberships for a token
     * @param tid Token ID
     * @return Array of memberships
     */
    function getMemberships(uint256 tid)
        external
        view
        override
        returns (CommunityMembership[] memory)
    {
        return _m[tid];
    }

    /**
     * @notice Calculate reputation
     * @param tid Token ID
     * @return rep Reputation score
     */
    function getReputationScore(uint256 tid)
        external
        view
        override
        returns (uint256 rep)
    {
        if (reputationCalculator != address(0)) {
            try IReputationCalculator(reputationCalculator).calculateReputation(tid) returns (uint256 r) {
                return r;
            } catch {}
        }

        // Fallback calculation
        SBTData memory d = sbtData[tid];
        rep = BASE_REP + (d.entryBurn / 0.01 ether);
        uint256 w = _getWeek();

        for (uint256 i = 0; i < _m[tid].length; i++) {
            address c = _m[tid][i].community;
            if (weeklyActivity[tid][c][w]) rep += ACT_WIN;
            else if (weeklyActivity[tid][c][w - 1]) rep += ACT_BONUS;
        }
    }

    // ====================================
    // Internal Functions - V3
    // ====================================

    /**
     * @notice Check if address is valid community (v3)
     * @param c Address to check
     * @return True if has COMMUNITY role
     */
    function _isValidCommunity(address c) internal view returns (bool) {
        if (REGISTRY_V3 == address(0)) return false;

        bytes32 communityRole = SharedConfig(SHARED_CONFIG).ROLE_COMMUNITY();
        try IRegistryV3(REGISTRY_V3).hasRole(communityRole, c) returns (bool r) {
            return r;
        } catch {
            return false;
        }
    }

    /**
     * @notice Check if community allows permissionless mint (v3)
     * @param c Community address
     * @return True if allowed
     */
    function _isPermissionlessMintAllowed(address c) internal view returns (bool) {
        bytes32 communityRole = SharedConfig(SHARED_CONFIG).ROLE_COMMUNITY();
        try IRegistryV3(REGISTRY_V3).getRoleConfig(communityRole) returns (IRegistryV3.RoleConfig memory config) {
            return config.allowPermissionlessMint;
        } catch {
            return false;
        }
    }

    /**
     * @notice Mint new SBT
     * @param u User address
     * @param entryBurn Amount burned on entry
     * @return tid Token ID
     */
    function _mintSBT(address u, uint256 entryBurn) internal returns (uint256 tid) {
        tid = nextTokenId++;
        _mint(u, tid);
        userToSBT[u] = tid;

        sbtData[tid] = SBTData({
            owner: u,
            tokenURI: "",
            createdAt: block.timestamp,
            entryBurn: entryBurn,
            exitFee: 0,
            customData: ""
        });

        // Notify SuperPaymaster if configured
        if (SUPER_PAYMASTER != address(0)) {
            try ISuperPaymaster(SUPER_PAYMASTER).registerSBTHolder(u, tid) {} catch {}
        }

        // Burn entry fee
        if (entryBurn > 0) {
            IERC20(GTOKEN).transfer(BURN_ADDRESS, entryBurn);
        }

        emit SBTMinted(tid, u, block.timestamp);
    }

    /**
     * @notice Join a community
     * @param tid Token ID
     * @param comm Community address
     * @param meta Metadata
     */
    function _joinCommunity(uint256 tid, address comm, bytes memory meta) internal {
        require(membershipIndex[tid][comm] == 0, "Already member");

        _m[tid].push(CommunityMembership({
            community: comm,
            joinedAt: block.timestamp,
            metadata: meta
        }));

        membershipIndex[tid][comm] = _m[tid].length;
        emit CommunityJoined(tid, comm, block.timestamp);
    }

    /**
     * @notice Get current week number
     * @return Week number since epoch
     */
    function _getWeek() internal view returns (uint256) {
        return block.timestamp / 1 weeks;
    }

    // ====================================
    // ERC721 Overrides (Soul-Bound)
    // ====================================

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Soul-bound: only allow minting and burning
        if (from != address(0) && to != address(0)) {
            revert("SBT: Transfer not allowed");
        }

        return super._update(to, tokenId, auth);
    }
}