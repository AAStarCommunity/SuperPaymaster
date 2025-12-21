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
import "../../../interfaces/IVersioned.sol";

/**
 * @title MySBT v2.4.5
 * @notice SuperPaymaster V2.3.3 SBT Registry Integration
 * @dev Changelog from v2.4.4:
 *   - V2.3.3 INTEGRATION: Added SuperPaymaster callback on mint/burn
 *   - ARCH: MySBT now calls SuperPaymaster.registerSBTHolder() after _mint()
 *   - ARCH: MySBT now calls SuperPaymaster.removeSBTHolder() before _burn()
 *   - GAS: Enables SuperPaymaster internal SBT verification (~800 gas saved per tx)
 *   - SECURITY: Uses try/catch for optional external calls (graceful degradation)
 *   - CONFIG: Added setSuperPaymaster() function (DAO only)
 *   - NOTE: ISuperPaymaster interface is defined in Interfaces.sol
 */

contract MySBT is ERC721, ReentrancyGuard, Pausable, IMySBT, IVersioned {
    using SafeERC20 for IERC20;

    string public constant VERSION = "2.4.5";
    uint256 public constant VERSION_CODE = 20405;

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
}
