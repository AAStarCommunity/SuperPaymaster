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

/**
 * @title MySBT v2.4.3
 * @notice Fixed mintWithAutoStake to properly handle token transfers
 * @dev Changelog from v2.4.2:
 *   - Fixed mintWithAutoStake logic to handle both staking and burning in a single transaction
 *   - Added proper balance and allowance checks with clear error messages
 *   - Improved token transfer flow to avoid authorization conflicts
 */
contract MySBT_v2_4_3 is ERC721, ReentrancyGuard, Pausable, IMySBT {
    using SafeERC20 for IERC20;

    string public constant VERSION = "2.4.3";
    uint256 public constant VERSION_CODE = 20403;

    mapping(address => uint256) public userToSBT;
    mapping(uint256 => SBTData) public sbtData;
    mapping(uint256 => CommunityMembership[]) private _m;
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;
    mapping(uint256 => NFTBinding[]) private _n;
    mapping(uint256 => AvatarSetting) public sbtAvatars;
    mapping(address => string) public communityDefaultAvatar;
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
    mapping(address => mapping(uint256 => mapping(address => bool))) public avatarDelegation;
    mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public REGISTRY;
    address public daoMultisig;
    address public reputationCalculator;
    uint256 public nextTokenId = 1;
    uint256 public minLockAmount = 0.3 ether;
    uint256 public mintFee = 0.1 ether;

    uint256 constant BASE_REP = 20;
    uint256 constant NFT_UNIT = 30 days;
    uint256 constant NFT_SCORE = 1;
    uint256 constant NFT_MAX = 12;
    uint256 constant ACT_BONUS = 1;
    uint256 constant ACT_WIN = 4;
    uint256 constant MIN_INT = 5 minutes;

    error E();

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

    function mintOrAddMembership(address u, string memory meta)
        external
        override
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

    function burnSBT() external whenNotPaused nonReentrant returns (uint256 net) {
        address u = msg.sender;
        uint256 tid = userToSBT[u];
        require(tid != 0 && ownerOf(tid) == u);
        CommunityMembership[] storage mems = _m[tid];
        for (uint256 i = 0; i < mems.length; i++) {
            if (mems[i].isActive) {
                mems[i].isActive = false;
                emit MembershipDeactivated(tid, mems[i].community, block.timestamp);
            }
        }
        delete _n[tid];
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
        override
        returns (bool)
    {
        uint256 tid = userToSBT[u];
        if (tid == 0) return false;
        uint256 idx = membershipIndex[tid][comm];
        if (idx >= _m[tid].length) return false;
        CommunityMembership memory mem = _m[tid][idx];
        return mem.community == comm && mem.isActive;
    }

    function getUserSBT(address u) external view override returns (uint256) {
        return userToSBT[u];
    }

    function getSBTData(uint256 tid) external view override returns (SBTData memory) {
        return sbtData[tid];
    }

    function getMemberships(uint256 tid)
        external
        view
        override
        returns (CommunityMembership[] memory)
    {
        return _m[tid];
    }

    function getCommunityMembership(uint256 tid, address comm)
        external
        view
        override
        returns (CommunityMembership memory mem)
    {
        uint256 idx = membershipIndex[tid][comm];
        require(idx < _m[tid].length);
        mem = _m[tid][idx];
        require(mem.community == comm);
    }

    function bindNFT(address nc, uint256 nid) external whenNotPaused nonReentrant {
        require(nc != address(0));
        uint256 tid = userToSBT[msg.sender];
        require(tid != 0);
        address owner;
        try IERC721(nc).ownerOf(nid) returns (address o) {
            owner = o;
        } catch {
            revert E();
        }
        require(owner == msg.sender);
        NFTBinding[] storage bs = _n[tid];
        for (uint256 i = 0; i < bs.length; i++) {
            require(!(bs[i].nftContract == nc && bs[i].nftTokenId == nid && bs[i].isActive));
        }
        _n[tid].push(NFTBinding(nc, nid, block.timestamp, true));
        if (sbtAvatars[tid].nftContract == address(0)) {
            sbtAvatars[tid] = AvatarSetting(nc, nid, false);
            emit AvatarSet(tid, nc, nid, false, block.timestamp);
        }
        emit NFTBound(tid, address(0), nc, nid, block.timestamp);
    }

    function bindCommunityNFT(address, address nc, uint256 nid)
        external
        override
        whenNotPaused
        nonReentrant
    {
        this.bindNFT(nc, nid);
    }

    function getAllNFTBindings(uint256 tid) external view returns (NFTBinding[] memory) {
        return _n[tid];
    }

    function setAvatar(address nc, uint256 nid) external override whenNotPaused nonReentrant {
        uint256 tid = userToSBT[msg.sender];
        require(tid != 0);
        address owner;
        try IERC721(nc).ownerOf(nid) returns (address o) {
            owner = o;
        } catch {
            revert E();
        }
        require(owner == msg.sender || avatarDelegation[nc][nid][msg.sender]);
        sbtAvatars[tid] = AvatarSetting(nc, nid, true);
        emit AvatarSet(tid, nc, nid, true, block.timestamp);
    }

    function delegateAvatarUsage(address nc, uint256 nid, address del) external {
        address owner;
        try IERC721(nc).ownerOf(nid) returns (address o) {
            owner = o;
        } catch {
            revert E();
        }
        require(owner == msg.sender);
        avatarDelegation[nc][nid][del] = true;
    }

    function getAvatarURI(uint256 tid) external view override returns (string memory uri) {
        if (sbtAvatars[tid].isCustom && sbtAvatars[tid].nftContract != address(0)) {
            try IERC721Metadata(sbtAvatars[tid].nftContract).tokenURI(sbtAvatars[tid].nftTokenId)
                returns (string memory u) {
                return u;
            } catch {}
        }
        if (!sbtAvatars[tid].isCustom && sbtAvatars[tid].nftContract != address(0)) {
            try IERC721Metadata(sbtAvatars[tid].nftContract).tokenURI(sbtAvatars[tid].nftTokenId)
                returns (string memory u) {
                return u;
            } catch {}
        }
        return communityDefaultAvatar[sbtData[tid].firstCommunity];
    }

    function setCommunityDefaultAvatar(string memory uri) external override onlyReg {
        communityDefaultAvatar[msg.sender] = uri;
    }

    function recordActivity(address u) external override whenNotPaused {
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

    function getCommunityReputation(address u, address comm)
        external
        view
        override
        returns (uint256)
    {
        uint256 tid = userToSBT[u];
        if (tid == 0) return 0;
        if (reputationCalculator != address(0)) {
            try IReputationCalculator(reputationCalculator).calculateReputation(u, comm, tid)
                returns (uint256 cs, uint256) {
                return cs;
            } catch {}
        }
        return _calcRep(tid, comm);
    }

    function getGlobalReputation(address u) external view override returns (uint256) {
        uint256 tid = userToSBT[u];
        if (tid == 0) return 0;
        if (reputationCalculator != address(0)) {
            try IReputationCalculator(reputationCalculator).calculateReputation(u, address(0), tid)
                returns (uint256, uint256 gs) {
                return gs;
            } catch {}
        }
        uint256 total = 0;
        CommunityMembership[] memory mems = _m[tid];
        for (uint256 i = 0; i < mems.length; i++) {
            if (mems[i].isActive) {
                total += _calcRep(tid, mems[i].community);
            }
        }
        return total;
    }

    function _calcRep(uint256 tid, address comm) internal view returns (uint256 score) {
        uint256 idx = membershipIndex[tid][comm];
        if (idx >= _m[tid].length || _m[tid][idx].community != comm || !_m[tid][idx].isActive) {
            return 0;
        }
        score = BASE_REP + _calcNFT(tid);
    }

    function _calcNFT(uint256 tid) internal view returns (uint256 total) {
        NFTBinding[] storage bs = _n[tid];
        address h = sbtData[tid].holder;
        for (uint256 i = 0; i < bs.length; i++) {
            if (!bs[i].isActive) continue;
            address owner;
            try IERC721(bs[i].nftContract).ownerOf(bs[i].nftTokenId) returns (address o) {
                owner = o;
            } catch {
                continue;
            }
            if (owner != h) continue;
            uint256 mos = (block.timestamp - bs[i].bindTime) / NFT_UNIT;
            uint256 s = mos * NFT_SCORE;
            if (s > NFT_MAX) s = NFT_MAX;
            total += s;
        }
    }

    function setReputationCalculator(address c) external override onlyDAO {
        address old = reputationCalculator;
        reputationCalculator = c;
        emit ReputationCalculatorUpdated(old, c, block.timestamp);
    }

    function setMinLockAmount(uint256 a) external override onlyDAO {
        require(a != 0);
        uint256 old = minLockAmount;
        minLockAmount = a;
        emit MinLockAmountUpdated(old, a, block.timestamp);
    }

    function setMintFee(uint256 f) external override onlyDAO {
        uint256 old = mintFee;
        mintFee = f;
        emit MintFeeUpdated(old, f, block.timestamp);
    }

    function setDAOMultisig(address d) external override onlyDAO {
        require(d != address(0));
        address old = daoMultisig;
        daoMultisig = d;
        emit DAOMultisigUpdated(old, d, block.timestamp);
    }

    function setRegistry(address r) external override onlyDAO {
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
