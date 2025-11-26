// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/utils/Pausable.sol";
import "../interfaces/Interfaces.sol";
import "../interfaces/IMySBT.sol";
import "../interfaces/IReputationCalculator.sol";
import "../interfaces/IERC8004IdentityRegistry.sol";
import "../../../interfaces/IVersioned.sol";

/**
 * @title MySBT v2.5.0
 * @notice SuperPaymaster SBT with ERC-8004 Identity Registry Support
 * @dev Changelog from v2.4.5:
 *   - ERC-8004 INTEGRATION: Native Identity Registry implementation
 *   - NEW: register() overloads for ERC-8004 agent registration
 *   - NEW: getMetadata() / setMetadata() for on-chain agent metadata
 *   - NEW: setTokenURI() for customizable token URIs
 *   - NEW: batchSetMetadata() for efficient batch updates
 *   - NEW: getMetadataKeys() to enumerate metadata
 *   - ARCH: Token ID = Agent ID (1:1 mapping, no adapter needed)
 *   - COMPAT: All existing MySBT functionality preserved
 */

contract MySBT is ERC721, ReentrancyGuard, Pausable, IMySBT, IVersioned, IERC8004IdentityRegistry {
    using SafeERC20 for IERC20;

    string public constant VERSION = "2.5.0";
    uint256 public constant VERSION_CODE = 20500;

    mapping(address => uint256) public userToSBT;
    mapping(uint256 => SBTData) public sbtData;
    mapping(uint256 => CommunityMembership[]) private _m;
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
    mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

    // ====================================
    // V2.5.0: ERC-8004 Identity Registry Storage
    // ====================================

    /// @notice Custom token URIs (agentId => URI)
    mapping(uint256 => string) private _tokenURIs;

    /// @notice Agent metadata storage (agentId => key => value)
    mapping(uint256 => mapping(string => bytes)) private _agentMetadata;

    /// @notice Metadata keys for enumeration (agentId => keys[])
    mapping(uint256 => string[]) private _metadataKeys;

    /// @notice Track if key exists for agent (agentId => key => exists)
    mapping(uint256 => mapping(string => bool)) private _metadataKeyExists;

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

    // ====================================
    // V2.5.0: ERC-8004 Events
    // ====================================

    /// @notice Emitted when token URI is updated
    event TokenURIUpdated(uint256 indexed agentId, string oldUri, string newUri);

    /// @notice Emitted when batch metadata is set
    event BatchMetadataSet(uint256 indexed agentId, uint256 count);

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
        return 2005000; // v2.5.0: 2 * 1000000 + 5 * 1000 + 0
    }

    function versionString() external pure override returns (string memory) {
        return "v2.5.0";
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
    // Minting Functions
    // ====================================

    function mintOrAddMembership(address u, string memory meta)
        external
        whenNotPaused
        nonReentrant
        onlyReg
        returns (uint256 tid, bool isNew)
    {
        require(u != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        tid = userToSBT[u];
        if (tid == 0) {
            tid = nextTokenId++;
            isNew = true;
            sbtData[tid] = SBTData(u, msg.sender, block.timestamp, 1);
            userToSBT[u] = tid;
            _m[tid].push(CommunityMembership(msg.sender, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][msg.sender] = 0;
            IGTokenStaking(GTOKEN_STAKING).lockStake(u, minLockAmount, "MySBT");
            IERC20(GTOKEN).safeTransferFrom(u, BURN_ADDRESS, mintFee);
            _mint(u, tid);

            // ⚡ V2.4.5: Register SBT holder to SuperPaymaster
            _registerSBTHolder(u, tid);

            emit SBTMinted(u, tid, msg.sender, block.timestamp);
        } else {
            uint256 idx = membershipIndex[tid][msg.sender];
            require(idx >= _m[tid].length || _m[tid][idx].community != msg.sender);
            _m[tid].push(CommunityMembership(msg.sender, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][msg.sender] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;
            emit MembershipAdded(tid, msg.sender, meta, block.timestamp);
        }
    }

    function userMint(address comm, string memory meta)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 tid, bool isNew)
    {
        require(comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        require(_isValid(comm) && IRegistryV2_1(REGISTRY).isPermissionlessMintAllowed(comm));
        address u = msg.sender;
        tid = userToSBT[u];
        if (tid == 0) {
            tid = nextTokenId++;
            isNew = true;
            sbtData[tid] = SBTData(u, comm, block.timestamp, 1);
            userToSBT[u] = tid;
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = 0;
            IGTokenStaking(GTOKEN_STAKING).lockStake(u, minLockAmount, "MySBT");
            IERC20(GTOKEN).safeTransferFrom(u, BURN_ADDRESS, mintFee);
            _mint(u, tid);

            // ⚡ V2.4.5: Register SBT holder to SuperPaymaster
            _registerSBTHolder(u, tid);

            emit SBTMinted(u, tid, comm, block.timestamp);
        } else {
            uint256 idx = membershipIndex[tid][comm];
            require(idx >= _m[tid].length || _m[tid][idx].community != comm);
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;
            emit MembershipAdded(tid, comm, meta, block.timestamp);
        }
    }

    // v2.4.3: Fixed to handle both staking and burning
    function mintWithAutoStake(address comm, string memory meta)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tid, bool isNew)
    {
        require(comm != address(0) && bytes(meta).length > 0 && bytes(meta).length <= 1024);
        require(_isValid(comm) && IRegistryV2_1(REGISTRY).isPermissionlessMintAllowed(comm));

        uint256 avail = IGTokenStaking(GTOKEN_STAKING).availableBalance(msg.sender);
        uint256 need = avail < minLockAmount ? minLockAmount - avail : 0;
        uint256 total = need + mintFee;

        IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), total);

        if (need > 0) {
            IERC20(GTOKEN).approve(GTOKEN_STAKING, need);
            IGTokenStaking(GTOKEN_STAKING).stakeFor(msg.sender, need);
        }

        IERC20(GTOKEN).safeTransfer(BURN_ADDRESS, mintFee);

        tid = userToSBT[msg.sender];
        if (tid == 0) {
            tid = nextTokenId++;
            isNew = true;
            sbtData[tid] = SBTData(msg.sender, comm, block.timestamp, 1);
            userToSBT[msg.sender] = tid;
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = 0;
            IGTokenStaking(GTOKEN_STAKING).lockStake(msg.sender, minLockAmount, "MySBT");
            _mint(msg.sender, tid);

            // ⚡ V2.4.5: Register SBT holder to SuperPaymaster
            _registerSBTHolder(msg.sender, tid);

            emit SBTMinted(msg.sender, tid, comm, block.timestamp);
        } else {
            uint256 idx = membershipIndex[tid][comm];
            require(idx >= _m[tid].length || _m[tid][idx].community != comm);
            _m[tid].push(CommunityMembership(comm, block.timestamp, block.timestamp, true, meta));
            membershipIndex[tid][comm] = _m[tid].length - 1;
            sbtData[tid].totalCommunities++;
            emit MembershipAdded(tid, comm, meta, block.timestamp);
        }
    }

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

    function _isValid(address c) internal view returns (bool) {
        if (REGISTRY == address(0)) return false;
        try IRegistryV2_1(REGISTRY).isRegisteredCommunity(c) returns (bool r) {
            return r;
        } catch {
            return false;
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

    // ====================================
    // V2.5.0: ERC-8004 Identity Registry
    // ====================================

    /**
     * @notice Register a new agent with token URI and metadata (ERC-8004)
     * @dev This is a simplified registration - no staking required
     *      For full MySBT benefits, use userMint() or mintWithAutoStake()
     * @param agentTokenURI URI pointing to agent registration JSON
     * @param metadata Array of metadata entries
     * @return agentId The newly registered agent ID (= token ID)
     */
    function register(string calldata agentTokenURI, MetadataEntry[] calldata metadata)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 agentId)
    {
        require(userToSBT[msg.sender] == 0, "Already registered");

        agentId = nextTokenId++;
        sbtData[agentId] = SBTData(msg.sender, address(0), block.timestamp, 0);
        userToSBT[msg.sender] = agentId;

        // Set token URI
        if (bytes(agentTokenURI).length > 0) {
            _tokenURIs[agentId] = agentTokenURI;
        }

        // Set metadata
        for (uint256 i = 0; i < metadata.length; i++) {
            _setMetadataInternal(agentId, metadata[i].key, metadata[i].value);
        }

        _mint(msg.sender, agentId);
        _registerSBTHolder(msg.sender, agentId);

        emit Registered(agentId, agentTokenURI, msg.sender);
    }

    /**
     * @notice Register a new agent with token URI only (ERC-8004)
     * @param agentTokenURI URI pointing to agent registration JSON
     * @return agentId The newly registered agent ID
     */
    function register(string calldata agentTokenURI)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 agentId)
    {
        require(userToSBT[msg.sender] == 0, "Already registered");

        agentId = nextTokenId++;
        sbtData[agentId] = SBTData(msg.sender, address(0), block.timestamp, 0);
        userToSBT[msg.sender] = agentId;

        if (bytes(agentTokenURI).length > 0) {
            _tokenURIs[agentId] = agentTokenURI;
        }

        _mint(msg.sender, agentId);
        _registerSBTHolder(msg.sender, agentId);

        emit Registered(agentId, agentTokenURI, msg.sender);
    }

    /**
     * @notice Register a new agent with default settings (ERC-8004)
     * @return agentId The newly registered agent ID
     */
    function register()
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 agentId)
    {
        require(userToSBT[msg.sender] == 0, "Already registered");

        agentId = nextTokenId++;
        sbtData[agentId] = SBTData(msg.sender, address(0), block.timestamp, 0);
        userToSBT[msg.sender] = agentId;

        _mint(msg.sender, agentId);
        _registerSBTHolder(msg.sender, agentId);

        emit Registered(agentId, "", msg.sender);
    }

    /**
     * @notice Get metadata value for agent (ERC-8004)
     * @param agentId The agent token ID
     * @param key The metadata key
     * @return value The metadata value as bytes
     */
    function getMetadata(uint256 agentId, string calldata key)
        external
        view
        override
        returns (bytes memory value)
    {
        require(_ownerOf(agentId) != address(0), "Agent not found");
        return _agentMetadata[agentId][key];
    }

    /**
     * @notice Set metadata for agent (ERC-8004)
     * @param agentId The agent token ID
     * @param key The metadata key
     * @param value The metadata value as bytes
     */
    function setMetadata(uint256 agentId, string calldata key, bytes calldata value)
        external
        override
    {
        require(ownerOf(agentId) == msg.sender, "Not agent owner");
        _setMetadataInternal(agentId, key, value);
        emit MetadataSet(agentId, key, key, value);
    }

    /**
     * @notice Internal helper to set metadata
     */
    function _setMetadataInternal(uint256 agentId, string memory key, bytes memory value) internal {
        if (!_metadataKeyExists[agentId][key]) {
            _metadataKeys[agentId].push(key);
            _metadataKeyExists[agentId][key] = true;
        }
        _agentMetadata[agentId][key] = value;
    }

    /**
     * @notice Set token URI for existing token (V2.5.0)
     * @param agentId Token/Agent ID
     * @param uri New token URI
     */
    function setTokenURI(uint256 agentId, string calldata uri) external {
        require(ownerOf(agentId) == msg.sender, "Not agent owner");
        string memory oldUri = _tokenURIs[agentId];
        _tokenURIs[agentId] = uri;
        emit TokenURIUpdated(agentId, oldUri, uri);
    }

    /**
     * @notice Batch set metadata (V2.5.0)
     * @param agentId Agent ID
     * @param entries Array of metadata entries
     */
    function batchSetMetadata(uint256 agentId, MetadataEntry[] calldata entries) external {
        require(ownerOf(agentId) == msg.sender, "Not agent owner");
        for (uint256 i = 0; i < entries.length; i++) {
            _setMetadataInternal(agentId, entries[i].key, entries[i].value);
            emit MetadataSet(agentId, entries[i].key, entries[i].key, entries[i].value);
        }
        emit BatchMetadataSet(agentId, entries.length);
    }

    /**
     * @notice Get all metadata keys for agent (V2.5.0)
     * @param agentId Agent ID
     * @return keys Array of metadata keys
     */
    function getMetadataKeys(uint256 agentId) external view returns (string[] memory keys) {
        require(_ownerOf(agentId) != address(0), "Agent not found");
        return _metadataKeys[agentId];
    }

    /**
     * @notice Override tokenURI to support custom URIs (V2.5.0)
     * @param agentId Token ID
     * @return URI for the token
     */
    function tokenURI(uint256 agentId) public view override(ERC721, IERC8004IdentityRegistry) returns (string memory) {
        require(_ownerOf(agentId) != address(0), "Token not found");

        string memory customUri = _tokenURIs[agentId];
        if (bytes(customUri).length > 0) {
            return customUri;
        }

        // Fall back to default behavior
        return super.tokenURI(agentId);
    }

    /**
     * @notice Check if address has MySBT (convenience function)
     * @param account Address to check
     * @return True if account has MySBT
     */
    function hasMySBT(address account) external view returns (bool) {
        return userToSBT[account] != 0;
    }

    /**
     * @notice Get next token ID (convenience function)
     * @return Next token ID to be minted
     */
    function getNextTokenId() external view returns (uint256) {
        return nextTokenId;
    }

    /**
     * @notice Override ownerOf to satisfy IERC8004IdentityRegistry
     */
    function ownerOf(uint256 agentId) public view override(ERC721, IERC8004IdentityRegistry) returns (address) {
        return super.ownerOf(agentId);
    }
}
