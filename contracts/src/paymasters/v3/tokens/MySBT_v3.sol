// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/utils/Pausable.sol";
import "../../v2/interfaces/Interfaces.sol";
import "../../v2/interfaces/IReputationCalculator.sol";
import "../interfaces/IRegistryV3.sol";
import "../../../interfaces/IVersioned.sol";

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
contract MySBT_v3 is ERC721, ReentrancyGuard, Pausable, IVersioned {
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

    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;

    mapping(address => uint256) public userToSBT;
    mapping(uint256 => SBTData) public sbtData;
    mapping(uint256 => CommunityMembership[]) private _m;
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
    mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public REGISTRY;
    address public daoMultisig;
    address public reputationCalculator;

    // ====================================
    // V2.4.5: SuperPaymaster Integration
    // ====================================

    /// @notice SuperPaymaster address for SBT registry callbacks (V2.4.5)
    address public SUPER_PAYMASTER;

    uint256 public nextTokenId = 1;
    uint256 public minLockAmount = 0.3 ether;
    uint256 public mintFee = 0.1 ether;

    uint256 constant BASE_REP = 20;
    uint256 constant ACT_BONUS = 1;
    uint256 constant ACT_WIN = 4;
    uint256 constant MIN_INT = 5 minutes;

    error E();

    // ====================================
    // V2.4.5: Events
    // ====================================

    /// @notice SuperPaymaster address updated (V2.4.5)
    event SuperPaymasterUpdated(address indexed oldPaymaster, address indexed newPaymaster, uint256 timestamp);

    modifier onlyDAO() {
        require(msg.sender == daoMultisig);
        _;
    }

    modifier onlyReg() {
        require(_isValid(msg.sender));
        _;
    }

    constructor(
        address _g,
        address _s,
        address _r,
        address _d
    ) ERC721("Mycelium Soul Bound Token", "MySBT") {
        require(_g != address(0) && _s != address(0) && _r != address(0) && _d != address(0));
        GTOKEN = _g;
        GTOKEN_STAKING = _s;
        REGISTRY = _r;
        daoMultisig = _d;
    }

    // ====================================
    // IVersioned Implementation
    // ====================================

    function version() external pure override returns (uint256) {
        return 2004005; // v2.4.5: 2 * 1000000 + 4 * 1000 + 5
    }

    function versionString() external pure override returns (string memory) {
        return "v2.4.5";
    }

    // ====================================
    // V2.4.5: SuperPaymaster Callback Helper
    // ====================================

    /**
     * @notice Register SBT holder to SuperPaymaster (V2.4.5)
     * @dev Uses try/catch for graceful degradation if SuperPaymaster not set
     * @param holder SBT owner address
     * @param tokenId MySBT token ID
     */
    function _registerSBTHolder(address holder, uint256 tokenId) internal {
        if (SUPER_PAYMASTER != address(0)) {
            try ISuperPaymaster(SUPER_PAYMASTER).registerSBTHolder(holder, tokenId) {
                // Success - SBT registered to SuperPaymaster
            } catch {
                // Graceful degradation - continue without SuperPaymaster registration
                // This allows MySBT to function even if SuperPaymaster is misconfigured
            }
        }
    }

    /**
     * @notice Remove SBT holder from SuperPaymaster (V2.4.5)
     * @dev Uses try/catch for graceful degradation if SuperPaymaster not set
     * @param holder SBT owner address
     */
    function _removeSBTHolder(address holder) internal {
        if (SUPER_PAYMASTER != address(0)) {
            try ISuperPaymaster(SUPER_PAYMASTER).removeSBTHolder(holder) {
                // Success - SBT removed from SuperPaymaster
            } catch {
                // Graceful degradation - continue without SuperPaymaster removal
            }
        }
    }

    // ====================================
    // V3: Minting Functions
    // ====================================
    //
    // BREAKING CHANGE in v3.0.0:
    // All user-facing mint functions (mintOrAddMembership, userMint, mintWithAutoStake)
    // have been REMOVED to enforce the v3 design principle:
    //
    // ✅ SINGLE ENTRY POINT: All role registration MUST go through Registry.registerRole()
    //
    // Only Registry-callable functions remain:
    // - airdropMint() - Called by Registry during role registration
    // - safeMint() - DAO-only emergency minting
    //
    // Users should call Registry.registerRole(ROLE_ENDUSER, user, data) instead.
    // ====================================

    function safeMint(address to, address comm, string memory meta)
        external
        onlyDAO
        whenNotPaused
        nonReentrant
        returns (uint256 tid)
    {
        require(to != address(0) && comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        require(_isValid(comm));
        tid = userToSBT[to];
        if (tid == 0) {
            tid = nextTokenId++;
            sbtData[tid] = SBTData(to, comm, block.timestamp, 1);
            userToSBT[to] = tid;
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = 0;
            _mint(to, tid);

            // ⚡ V2.4.5: Register SBT holder to SuperPaymaster
            _registerSBTHolder(to, tid);

            emit SBTMinted(to, tid, comm, block.timestamp);
        } else {
            uint256 idx = membershipIndex[tid][comm];
            require(idx >= _m[tid].length || _m[tid][idx].community != comm);
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;
            emit MembershipAdded(tid, comm, meta, block.timestamp);
        }
    }

    /**
     * @notice Airdrop mint - Operator-paid batch minting (v2.4.4)
     * @dev Operator pays all costs (0.4 GT total):
     *      - Operator stakes 0.3 GT on behalf of user using stakeFor()
     *      - Operator burns 0.1 GT mint fee
     *      - User receives SBT with no interaction required
     *      - Idempotent: if user already has SBT, adds community membership (free)
     * @param u User address to receive SBT
     * @param meta Community metadata (JSON string, max 1024 bytes)
     * @return tid Token ID (new or existing)
     * @return isNew True if new SBT was minted, false if membership added
     */
    function airdropMint(address u, string memory meta)
        external
        whenNotPaused
        nonReentrant
        onlyReg
        returns (uint256 tid, bool isNew)
    {
        require(u != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);

        tid = userToSBT[u];
        address op = msg.sender; // Community/operator calling this function

        if (tid == 0) {
            // FIRST MINT: Create SBT (operator pays all fees)
            tid = nextTokenId++;
            isNew = true;

            // Set SBT data
            sbtData[tid] = SBTData(u, op, block.timestamp, 1);
            userToSBT[u] = tid;

            // Add first community membership
            _m[tid].push(CommunityMembership(op, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][op] = 0;

            // ✅ OPERATOR PAYS: Transfer GToken from operator to this contract
            IERC20(GTOKEN).safeTransferFrom(op, address(this), minLockAmount);

            // Approve GTokenStaking to spend
            IERC20(GTOKEN).approve(GTOKEN_STAKING, minLockAmount);

            // Stake for user (user becomes the beneficiary)
            IGTokenStaking(GTOKEN_STAKING).stakeFor(u, minLockAmount);

            // Lock the stake
            IGTokenStaking(GTOKEN_STAKING).lockStake(u, minLockAmount, "MySBT Airdrop");

            // ✅ OPERATOR PAYS: Burn mintFee from operator's balance
            IERC20(GTOKEN).safeTransferFrom(op, BURN_ADDRESS, mintFee);

            // Mint SBT to user
            _mint(u, tid);

            // ⚡ V2.4.5: Register SBT holder to SuperPaymaster
            _registerSBTHolder(u, tid);

            emit SBTMinted(u, tid, op, block.timestamp);
        } else {
            // IDEMPOTENT: Add community membership (no fees for existing SBT)
            isNew = false;

            // Check if membership already exists
            uint256 idx = membershipIndex[tid][op];
            require(idx >= _m[tid].length || _m[tid][idx].community != op);

            // Add new membership
            _m[tid].push(CommunityMembership(op, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][op] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;

            emit MembershipAdded(tid, op, meta, block.timestamp);
        }
    }

    function burnSBT() external whenNotPaused nonReentrant returns (uint256 net) {
        address u = msg.sender;
        uint256 tid = userToSBT[u];
        require(tid != 0 && ownerOf(tid) == u);

        // ⚡ V2.4.5: Remove SBT holder from SuperPaymaster BEFORE burning
        _removeSBTHolder(u);

        CommunityMembership[] storage mems = _m[tid];
        for (uint256 i = 0; i < mems.length; i++) {
            if (mems[i].isActive) {
                mems[i].isActive = false;
                emit MembershipDeactivated(tid, mems[i].community, block.timestamp);
            }
        }
        delete userToSBT[u];
        _burn(tid);
        net = IGTokenStaking(GTOKEN_STAKING).unlockStake(u, minLockAmount);
        emit SBTBurned(u, tid, minLockAmount, net, block.timestamp);
    }

    function leaveCommunity(address comm) external whenNotPaused nonReentrant {
        address u = msg.sender;
        uint256 tid = userToSBT[u];
        require(tid != 0 && ownerOf(tid) == u);
        uint256 idx = membershipIndex[tid][comm];
        require(idx < _m[tid].length);
        CommunityMembership storage mem = _m[tid][idx];
        require(mem.community == comm && mem.isActive);
        mem.isActive = false;
        emit MembershipDeactivated(tid, comm, block.timestamp);
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
    // V2.4.5: SuperPaymaster Configuration
    // ====================================

    /**
     * @notice Set SuperPaymaster address (V2.4.5)
     * @dev Only DAO can call this function
     * @param _paymaster SuperPaymaster address (address(0) to disable callbacks)
     */
    function setSuperPaymaster(address _paymaster) external onlyDAO {
        address oldPaymaster = SUPER_PAYMASTER;
        SUPER_PAYMASTER = _paymaster;
        emit SuperPaymasterUpdated(oldPaymaster, _paymaster, block.timestamp);
    }

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

        try IRegistryV3(REGISTRY).hasRole(ROLE_COMMUNITY, c) returns (bool r) {
            return r;
        } catch {
            // Fallback to v2 for backward compatibility during transition
            try IRegistryV2_1(REGISTRY).isRegisteredCommunity(c) returns (bool r) {
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
