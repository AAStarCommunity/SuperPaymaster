// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/utils/Pausable.sol";
import "../interfaces/Interfaces.sol";
import "../interfaces/IMySBT.sol";
import "../interfaces/IReputationCalculator.sol";
import "../../../interfaces/IVersioned.sol";

/**
 * @title MySBT v3.0.0
 * @notice SuperPaymaster V3 Registry-Driven SBT
 * @dev Mycelium Protocol Integration
 *   - ARCH: All minting/burning through Registry only
 *   - PATTERN: mintForRole() for entry, burnForRole() for exit
 *   - ROLE: Tracks roleId for reputation calculation
 *   - BURN: Records burn amount for reputation scoring
 *   - REPUTATION: Calculates from roleId + burnAmount + activity
 */

contract MySBT is ERC721, ReentrancyGuard, Pausable, IMySBT, IVersioned {
    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;

    // ====================================
    // Structs
    // ====================================

    /// @notice SBT data per token
    struct SBTData {
        address owner;
        bytes32 roleId;           // Role assigned (ENDUSER, COMMUNITY, etc)
        uint256 burnAmount;       // Total burn on entry
        uint256 mintedAt;         // Mint timestamp
        uint256 lastActivityAt;   // Last reputation activity
        bool active;              // Is SBT active
        string metadata;          // IPFS/URI metadata
    }

    // ====================================
    // Storage
    // ====================================

    mapping(address => uint256) public userToSBT;              // user -> tokenId (1:1)
    mapping(uint256 => SBTData) public sbtData;                // tokenId -> data
    mapping(address => bool) public authorizedRegistries;      // Only Registry can mint/burn

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public REGISTRY;
    address public daoMultisig;
    address public reputationCalculator;

    uint256 public nextTokenId = 1;

    // Reputation constants
    uint256 constant BASE_REP = 20;
    uint256 constant ACT_BONUS = 1;
    uint256 constant ACT_WIN = 4;
    uint256 constant MIN_INT = 5 minutes;

    // ====================================
    // Events
    // ====================================

    event MintedForRole(
        address indexed user,
        uint256 indexed tokenId,
        bytes32 indexed roleId,
        uint256 burnAmount,
        uint256 timestamp
    );

    event BurnedForRole(
        address indexed user,
        uint256 indexed tokenId,
        bytes32 indexed roleId,
        uint256 timestamp
    );

    event AuthorizationChanged(
        address indexed account,
        bool authorized,
        uint256 timestamp
    );

    event RegistryUpdated(address indexed newRegistry, uint256 timestamp);

    event ReputationCalculatorUpdated(address indexed newCalculator, uint256 timestamp);

    error Unauthorized();
    error InvalidAddress();
    error RoleNotSet();
    error SBTNotActive();
    error AlreadyHasSBT();

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyDAO() {
        require(msg.sender == daoMultisig, "Only DAO");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedRegistries[msg.sender], "Only authorized");
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _gtoken,
        address _gstaking,
        address _registry,
        address _dao
    ) ERC721("Mycelium Soul Bound Token", "MySBT") {
        require(
            _gtoken != address(0) &&
            _gstaking != address(0) &&
            _registry != address(0) &&
            _dao != address(0),
            "Invalid address"
        );

        GTOKEN = _gtoken;
        GTOKEN_STAKING = _gstaking;
        REGISTRY = _registry;
        daoMultisig = _dao;

        // Registry is authorized by default
        authorizedRegistries[_registry] = true;
    }

    // ====================================
    // IVersioned Implementation
    // ====================================

    function getVersion() external pure override returns (uint256) {
        return VERSION_CODE;
    }

    // ====================================
    // Minting (Registry Only)
    // ====================================

    /**
     * @notice Mint SBT for role (Registry only)
     * @param user User to receive SBT
     * @param roleId Role assigned
     * @param metadata IPFS/URI metadata
     * @return tokenId New SBT token ID
     *
     * @dev Called by Registry.registerRole() after staking
     *      Records burn amount for reputation
     */
    function mintForRole(
        address user,
        bytes32 roleId,
        bytes calldata metadata
    ) external onlyAuthorized nonReentrant whenNotPaused returns (uint256 tokenId) {
        // === CHECKS ===
        if (user == address(0)) revert InvalidAddress();
        if (roleId == bytes32(0)) revert RoleNotSet();
        if (userToSBT[user] != 0) revert AlreadyHasSBT();

        // === EFFECTS ===
        tokenId = nextTokenId++;

        // Prepare SBT data
        SBTData memory data;
        data.owner = user;
        data.roleId = roleId;
        data.mintedAt = block.timestamp;
        data.lastActivityAt = block.timestamp;
        data.active = true;
        data.metadata = string(metadata);

        // Record burn amount (0 for safeMint, actual for registerRole)
        // Registry will pass this via calling with approproate context
        data.burnAmount = 0;  // Will be set by Registry post-mint if needed

        sbtData[tokenId] = data;
        userToSBT[user] = tokenId;

        // === INTERACTIONS ===
        _mint(user, tokenId);

        emit MintedForRole(user, tokenId, roleId, 0, block.timestamp);

        return tokenId;
    }

    /**
     * @notice Set burn amount for user (after stake lock in Registry)
     * @param user User address
     * @param burnAmount Amount burned on entry
     *
     * @dev Called by Registry after GTokenStaking.lockStake() confirms burn
     *      Records burn for reputation calculation
     */
    function recordBurn(
        address user,
        uint256 burnAmount
    ) external onlyAuthorized {
        uint256 tokenId = userToSBT[user];
        require(tokenId != 0, "No SBT");

        sbtData[tokenId].burnAmount = burnAmount;
    }

    // ====================================
    // Burning (Registry Only)
    // ====================================

    /**
     * @notice Burn SBT for role (Registry only)
     * @param user User to burn from
     * @param roleId Role being exited
     *
     * @dev Called by Registry.exitRole() after unlocking stake
     *      Removes SBT from user permanently
     */
    function burnForRole(
        address user,
        bytes32 roleId
    ) external onlyAuthorized nonReentrant whenNotPaused {
        // === CHECKS ===
        uint256 tokenId = userToSBT[user];
        require(tokenId != 0, "No SBT");

        SBTData storage data = sbtData[tokenId];
        require(data.active, "Already inactive");
        require(data.roleId == roleId, "Role mismatch");

        // === EFFECTS ===
        data.active = false;
        delete userToSBT[user];

        // === INTERACTIONS ===
        _burn(tokenId);

        emit BurnedForRole(user, tokenId, roleId, block.timestamp);
    }

    // ====================================
    // Reputation
    // ====================================

    /**
     * @notice Calculate reputation for user
     * @param user User address
     * @return Reputation score
     *
     * @dev Score = BASE_REP + (burnAmount / 0.01 ether) + activity_bonus
     *      Example (ENDUSER, 0.1 burned):
     *        - Base: 20
     *        - Burn: 10 (0.1 / 0.01 = 10)
     *        - Activity: 0-X (depends on activity)
     *        - Total: 30+
     */
    function getReputation(address user) external view returns (uint256) {
        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return 0;

        SBTData memory data = sbtData[tokenId];
        if (!data.active) return 0;

        uint256 reputation = BASE_REP;

        // Add burn-based reputation (every 0.01 burned = 1 point)
        reputation += (data.burnAmount / 0.01 ether);

        // Call external calculator if available
        if (reputationCalculator != address(0)) {
            try
                IReputationCalculator(reputationCalculator).calculateBonus(user)
            returns (uint256 bonus) {
                reputation += bonus;
            } catch {}
        }

        return reputation;
    }

    /**
     * @notice Get SBT data
     * @param tokenId Token ID
     * @return SBT data struct
     */
    function getSBTData(uint256 tokenId) external view returns (SBTData memory) {
        return sbtData[tokenId];
    }

    /**
     * @notice Get user's SBT token ID
     * @param user User address
     * @return tokenId (0 if no SBT)
     */
    function getUserSBT(address user) external view returns (uint256) {
        return userToSBT[user];
    }

    /**
     * @notice Check if user has active SBT
     * @param user User address
     * @return True if active SBT
     */
    function hasSBT(address user) external view returns (bool) {
        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return false;
        return sbtData[tokenId].active;
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice DAO: Set authorized registry
     * @param account Account to authorize
     * @param authorized True to authorize
     */
    function setAuthorization(address account, bool authorized) external onlyDAO {
        require(account != address(0), "Invalid address");
        authorizedRegistries[account] = authorized;
        emit AuthorizationChanged(account, authorized, block.timestamp);
    }

    /**
     * @notice DAO: Update Registry address
     * @param newRegistry New registry address
     */
    function setRegistry(address newRegistry) external onlyDAO {
        require(newRegistry != address(0), "Invalid address");
        REGISTRY = newRegistry;
        authorizedRegistries[newRegistry] = true;
        emit RegistryUpdated(newRegistry, block.timestamp);
    }

    /**
     * @notice DAO: Update reputation calculator
     * @param newCalculator New calculator address
     */
    function setReputationCalculator(address newCalculator) external onlyDAO {
        reputationCalculator = newCalculator;
        emit ReputationCalculatorUpdated(newCalculator, block.timestamp);
    }

    /**
     * @notice DAO: Update DAO multisig
     * @param newDAO New DAO address
     */
    function setDAO(address newDAO) external onlyDAO {
        require(newDAO != address(0), "Invalid address");
        daoMultisig = newDAO;
    }

    /**
     * @notice DAO: Pause/unpause
     */
    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }

    // ====================================
    // ERC721 Overrides
    // ====================================

    /**
     * @notice Prevent transfers (Soul Bound)
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public pure override {
        revert("Soul Bound: No transfers");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public pure override {
        revert("Soul Bound: No transfers");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) public pure override {
        revert("Soul Bound: No transfers");
    }

    // ====================================
    // Overrides (ERC721Metadata)
    // ====================================

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return sbtData[tokenId].metadata;
    }
}
