// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "../interfaces/IMySBT.sol";

/**
 * @title MySBTAvatarManager
 * @notice External NFT avatar management for MySBT (v2.4.5+ extension)
 * @dev Minimal external contract to handle NFT binding and avatar display
 *      Keeps MySBT contract size small while providing full avatar functionality
 *
 * Features:
 * - Bind external NFTs as avatars
 * - Set custom/community avatars
 * - Delegate avatar usage
 * - Query avatar URI
 *
 * Architecture:
 * - MySBT: Minimal interface (getUserSBT only)
 * - This contract: Full avatar logic
 * - No storage in MySBT, all avatar data here
 */
contract MySBTAvatarManager is Ownable {

    // ====================================
    // Data Structures
    // ====================================

    struct NFTBinding {
        address nftContract;
        uint256 nftTokenId;
        uint256 bindTime;
        bool isActive;
    }

    struct AvatarSetting {
        address nftContract;
        uint256 nftTokenId;
        bool isCustom; // true = user set, false = first bound NFT
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice MySBT contract address
    IMySBT public immutable MYSBT;

    /// @notice NFT bindings per SBT token
    mapping(uint256 => NFTBinding[]) private _bindings;

    /// @notice Avatar settings per SBT token
    mapping(uint256 => AvatarSetting) public avatars;

    /// @notice Community default avatars
    mapping(address => string) public communityDefaultAvatar;

    /// @notice Avatar usage delegation (nftContract => tokenId => delegate => allowed)
    mapping(address => mapping(uint256 => mapping(address => bool))) public avatarDelegation;

    // ====================================
    // Events
    // ====================================

    event NFTBound(uint256 indexed tokenId, address indexed nftContract, uint256 nftTokenId, uint256 timestamp);
    event NFTUnbound(uint256 indexed tokenId, address indexed nftContract, uint256 nftTokenId, uint256 timestamp);
    event AvatarSet(uint256 indexed tokenId, address indexed nftContract, uint256 nftTokenId, bool isCustom, uint256 timestamp);
    event CommunityAvatarSet(address indexed community, string avatarURI, uint256 timestamp);
    event AvatarDelegated(address indexed nftContract, uint256 indexed nftTokenId, address indexed delegate, uint256 timestamp);

    // ====================================
    // Errors
    // ====================================

    error NotSBTOwner();
    error NotNFTOwner();
    error InvalidNFT();
    error AlreadyBound();
    error NotBound();

    // ====================================
    // Constructor
    // ====================================

    constructor(address _mysbt) Ownable(msg.sender) {
        require(_mysbt != address(0), "Invalid MySBT address");
        MYSBT = IMySBT(_mysbt);
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Bind external NFT to SBT
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function bindNFT(address nftContract, uint256 nftTokenId) external {
        uint256 sbtTokenId = MYSBT.getUserSBT(msg.sender);
        if (sbtTokenId == 0) revert NotSBTOwner();

        // Verify NFT ownership
        address nftOwner;
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert InvalidNFT();
        }

        if (nftOwner != msg.sender) revert NotNFTOwner();

        // Check if already bound
        NFTBinding[] storage bindings = _bindings[sbtTokenId];
        for (uint256 i = 0; i < bindings.length; i++) {
            if (bindings[i].nftContract == nftContract &&
                bindings[i].nftTokenId == nftTokenId &&
                bindings[i].isActive) {
                revert AlreadyBound();
            }
        }

        // Bind NFT
        _bindings[sbtTokenId].push(NFTBinding({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            bindTime: block.timestamp,
            isActive: true
        }));

        // Set as default avatar if none set
        if (avatars[sbtTokenId].nftContract == address(0)) {
            avatars[sbtTokenId] = AvatarSetting({
                nftContract: nftContract,
                nftTokenId: nftTokenId,
                isCustom: false
            });
            emit AvatarSet(sbtTokenId, nftContract, nftTokenId, false, block.timestamp);
        }

        emit NFTBound(sbtTokenId, nftContract, nftTokenId, block.timestamp);
    }

    /**
     * @notice Unbind NFT from SBT
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function unbindNFT(address nftContract, uint256 nftTokenId) external {
        uint256 sbtTokenId = MYSBT.getUserSBT(msg.sender);
        if (sbtTokenId == 0) revert NotSBTOwner();

        NFTBinding[] storage bindings = _bindings[sbtTokenId];
        bool found = false;

        for (uint256 i = 0; i < bindings.length; i++) {
            if (bindings[i].nftContract == nftContract &&
                bindings[i].nftTokenId == nftTokenId &&
                bindings[i].isActive) {
                bindings[i].isActive = false;
                found = true;
                break;
            }
        }

        if (!found) revert NotBound();

        // Clear avatar if it was using this NFT
        if (avatars[sbtTokenId].nftContract == nftContract &&
            avatars[sbtTokenId].nftTokenId == nftTokenId) {
            delete avatars[sbtTokenId];
        }

        emit NFTUnbound(sbtTokenId, nftContract, nftTokenId, block.timestamp);
    }

    /**
     * @notice Set custom avatar
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function setAvatar(address nftContract, uint256 nftTokenId) external {
        uint256 sbtTokenId = MYSBT.getUserSBT(msg.sender);
        if (sbtTokenId == 0) revert NotSBTOwner();

        // Verify NFT ownership or delegation
        address nftOwner;
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert InvalidNFT();
        }

        if (nftOwner != msg.sender && !avatarDelegation[nftContract][nftTokenId][msg.sender]) {
            revert NotNFTOwner();
        }

        avatars[sbtTokenId] = AvatarSetting({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            isCustom: true
        });

        emit AvatarSet(sbtTokenId, nftContract, nftTokenId, true, block.timestamp);
    }

    /**
     * @notice Delegate avatar usage to another address
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     * @param delegate Address to delegate to
     */
    function delegateAvatarUsage(address nftContract, uint256 nftTokenId, address delegate) external {
        address nftOwner;
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert InvalidNFT();
        }

        if (nftOwner != msg.sender) revert NotNFTOwner();

        avatarDelegation[nftContract][nftTokenId][delegate] = true;
        emit AvatarDelegated(nftContract, nftTokenId, delegate, block.timestamp);
    }

    /**
     * @notice Set community default avatar
     * @param avatarURI Default avatar URI for community
     */
    function setCommunityDefaultAvatar(string memory avatarURI) external {
        // Verify caller is a registered community (via MySBT)
        // Note: Requires MySBT to expose community verification, or use Registry
        communityDefaultAvatar[msg.sender] = avatarURI;
        emit CommunityAvatarSet(msg.sender, avatarURI, block.timestamp);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get avatar URI for SBT
     * @param tokenId SBT token ID
     * @return uri Avatar URI
     */
    function getAvatarURI(uint256 tokenId) external view returns (string memory uri) {
        AvatarSetting memory avatar = avatars[tokenId];

        // Try custom/bound NFT avatar
        if (avatar.nftContract != address(0)) {
            try IERC721Metadata(avatar.nftContract).tokenURI(avatar.nftTokenId) returns (string memory u) {
                return u;
            } catch {
                // NFT metadata failed, fall through to community default
            }
        }

        // Fall back to community default avatar
        IMySBT.SBTData memory data = MYSBT.getSBTData(tokenId);
        return communityDefaultAvatar[data.firstCommunity];
    }

    /**
     * @notice Get all NFT bindings for SBT
     * @param tokenId SBT token ID
     * @return bindings Array of NFT bindings
     */
    function getAllNFTBindings(uint256 tokenId) external view returns (NFTBinding[] memory) {
        return _bindings[tokenId];
    }

    /**
     * @notice Get active NFT bindings for SBT
     * @param tokenId SBT token ID
     * @return activeBindings Array of active NFT bindings
     */
    function getActiveNFTBindings(uint256 tokenId) external view returns (NFTBinding[] memory activeBindings) {
        NFTBinding[] memory all = _bindings[tokenId];

        // Count active bindings
        uint256 activeCount = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].isActive) activeCount++;
        }

        // Copy active bindings
        activeBindings = new NFTBinding[](activeCount);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].isActive) {
                activeBindings[j] = all[i];
                j++;
            }
        }
    }

    /**
     * @notice Check if NFT is bound to SBT
     * @param tokenId SBT token ID
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     * @return isBound True if NFT is bound
     */
    function isNFTBound(uint256 tokenId, address nftContract, uint256 nftTokenId) external view returns (bool) {
        NFTBinding[] memory bindings = _bindings[tokenId];
        for (uint256 i = 0; i < bindings.length; i++) {
            if (bindings[i].nftContract == nftContract &&
                bindings[i].nftTokenId == nftTokenId &&
                bindings[i].isActive) {
                return true;
            }
        }
        return false;
    }
}
