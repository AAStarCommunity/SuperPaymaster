// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./MySBTWithNFTBinding.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MySBTFactory
 * @notice Factory for deploying MySBTWithNFTBinding contracts with protocol-derived marking
 * @dev Provides standardized deployment for community SBT instances with NFT binding capability
 *
 * Key Features:
 * - One-click MySBT deployment for each community with NFT binding support
 * - Protocol-derived marking for authenticity verification
 * - Sequential ID system for tracking all deployments
 * - Guaranteed lock/unlock fee structure
 * - NFT binding with dual modes (CUSTODIAL/NON_CUSTODIAL)
 *
 * Benefits:
 * 1. Lock Guarantee: All SBTs from this factory require 0.3 stGT lock
 * 2. Exit Fee: Standard 0.1 stGT exit fee for all instances
 * 3. NFT Binding: Support both custodial and non-custodial NFT binding
 * 4. Binding Limits: 10 free bindings, 1 stGT lock per additional binding (linear)
 * 5. Cooldown Protection: 7-day unbinding cooldown
 * 6. Authenticity: isProtocolDerived flag verifies factory origin
 */
contract MySBTFactory is Ownable {

    // ====================================
    // Storage
    // ====================================

    /// @notice GToken contract address
    address public immutable GTOKEN;

    /// @notice GTokenStaking contract address
    address public immutable GTOKEN_STAKING;

    /// @notice Mapping: community address => MySBT contract address
    mapping(address => address) public communityToSBT;

    /// @notice Mapping: MySBT contract => protocol-derived flag
    mapping(address => bool) public isProtocolDerived;

    /// @notice Mapping: MySBT contract => sequential ID
    mapping(address => uint256) public sbtToId;

    /// @notice List of all deployed SBT contracts
    address[] public deployedSBTs;

    /// @notice Total number of deployed SBTs
    uint256 public totalDeployed;

    // ====================================
    // Constants
    // ====================================

    /// @notice Default minimum lock amount (0.3 sGT)
    uint256 public constant DEFAULT_MIN_LOCK = 0.3 ether;

    /// @notice Default mint fee (0.1 GT, burned)
    uint256 public constant DEFAULT_MINT_FEE = 0.1 ether;

    // ====================================
    // Events
    // ====================================

    event MySBTDeployed(
        address indexed community,
        address indexed sbtAddress,
        uint256 indexed sbtId,
        string name,
        string symbol
    );

    // ====================================
    // Errors
    // ====================================

    error AlreadyDeployed(address community);
    error InvalidAddress(address addr);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize factory
     * @param _gtoken GToken ERC20 address
     * @param _staking GTokenStaking contract address
     */
    constructor(address _gtoken, address _staking) Ownable(msg.sender) {
        if (_gtoken == address(0) || _staking == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN = _gtoken;
        GTOKEN_STAKING = _staking;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Deploy new MySBTWithNFTBinding contract for a community
     * @return sbtAddress Deployed MySBTWithNFTBinding contract address
     * @return sbtId Sequential ID for this deployment
     *
     * @dev Guarantees:
     * - Lock: 0.3 stGT required for minting
     * - Mint Fee: 0.1 GT burned
     * - Exit Fee: 0.1 stGT (configured in GTokenStaking)
     * - NFT Binding: Dual mode support (CUSTODIAL/NON_CUSTODIAL)
     * - Binding Limits: 10 free bindings, 1 stGT per additional (linear growth)
     * - Cooldown: 7-day unbinding cooldown
     * - Protocol-Derived: Marked with isProtocolDerived flag
     */
    function deployMySBT() external returns (address sbtAddress, uint256 sbtId) {
        if (communityToSBT[msg.sender] != address(0)) {
            revert AlreadyDeployed(msg.sender);
        }

        // Deploy new MySBTWithNFTBinding instance
        MySBTWithNFTBinding newSBT = new MySBTWithNFTBinding(GTOKEN, GTOKEN_STAKING);

        sbtAddress = address(newSBT);
        sbtId = totalDeployed;

        // Mark as protocol-derived
        isProtocolDerived[sbtAddress] = true;
        sbtToId[sbtAddress] = sbtId;
        communityToSBT[msg.sender] = sbtAddress;
        deployedSBTs.push(sbtAddress);

        totalDeployed++;

        emit MySBTDeployed(msg.sender, sbtAddress, sbtId, "Community Soul Bound Token", "MySBT");
    }

    /**
     * @notice Deploy MySBTWithNFTBinding with custom name and symbol
     * @param name Token name
     * @param symbol Token symbol
     * @return sbtAddress Deployed MySBTWithNFTBinding contract address
     * @return sbtId Sequential ID for this deployment
     */
    function deployMySBTCustom(
        string memory name,
        string memory symbol
    ) external returns (address sbtAddress, uint256 sbtId) {
        if (communityToSBT[msg.sender] != address(0)) {
            revert AlreadyDeployed(msg.sender);
        }

        // Deploy new MySBTWithNFTBinding instance (Note: MySBTWithNFTBinding constructor needs to support custom name/symbol)
        // TODO: Update MySBTWithNFTBinding constructor to accept name/symbol parameters
        MySBTWithNFTBinding newSBT = new MySBTWithNFTBinding(GTOKEN, GTOKEN_STAKING);

        sbtAddress = address(newSBT);
        sbtId = totalDeployed;

        // Mark as protocol-derived
        isProtocolDerived[sbtAddress] = true;
        sbtToId[sbtAddress] = sbtId;
        communityToSBT[msg.sender] = sbtAddress;
        deployedSBTs.push(sbtAddress);

        totalDeployed++;

        emit MySBTDeployed(msg.sender, sbtAddress, sbtId, name, symbol);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get MySBT address for a community
     * @param community Community address
     * @return sbt MySBT contract address (address(0) if not deployed)
     */
    function getSBTAddress(address community) external view returns (address sbt) {
        return communityToSBT[community];
    }

    /**
     * @notice Check if community has deployed MySBT
     * @param community Community address
     * @return hasSBT True if MySBT deployed
     */
    function hasSBT(address community) external view returns (bool) {
        return communityToSBT[community] != address(0);
    }

    /**
     * @notice Get all deployed MySBT contracts
     * @return sbts Array of MySBT addresses
     */
    function getAllSBTs() external view returns (address[] memory sbts) {
        return deployedSBTs;
    }

    /**
     * @notice Get total deployed count
     * @return count Total number of deployed SBTs
     */
    function getDeployedCount() external view returns (uint256 count) {
        return totalDeployed;
    }

    /**
     * @notice Get MySBT deployment info
     * @param sbtAddress MySBT contract address
     * @return isProtocol True if protocol-derived
     * @return id Sequential ID
     */
    function getSBTInfo(address sbtAddress)
        external
        view
        returns (bool isProtocol, uint256 id)
    {
        return (isProtocolDerived[sbtAddress], sbtToId[sbtAddress]);
    }

    /**
     * @notice Verify if SBT is protocol-derived from this factory
     * @param sbtAddress MySBT contract address
     * @return True if from this factory
     */
    function verifyProtocolDerived(address sbtAddress) external view returns (bool) {
        return isProtocolDerived[sbtAddress];
    }

    /**
     * @notice Get MySBT by sequential ID
     * @param id Sequential ID
     * @return sbtAddress MySBT contract address
     */
    function getSBTById(uint256 id) external view returns (address sbtAddress) {
        require(id < totalDeployed, "Invalid ID");
        return deployedSBTs[id];
    }
}
