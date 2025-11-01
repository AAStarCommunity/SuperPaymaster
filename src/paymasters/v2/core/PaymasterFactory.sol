// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title PaymasterFactory
 * @notice Factory contract for deploying Paymaster instances using EIP-1167 Minimal Proxy
 * @dev Implements version management for different Paymaster implementations
 *
 * Key Features:
 * - EIP-1167 Minimal Proxy for gas-efficient deployments (~100k gas)
 * - Version management system (v1.0, v2.0, etc.)
 * - Operator → Paymaster mapping for easy tracking
 * - Upgradeable implementation without affecting existing Paymasters
 */
contract PaymasterFactory is Ownable {
    using Clones for address;

    // ====================================
    // Version Management
    // ====================================

    /// @notice Contract version (semantic versioning)
    string public constant VERSION = "1.0.0";

    /// @notice Numeric version code (10000 = 1.0.0)
    uint256 public constant VERSION_CODE = 10000;

    // ====================================
    // Storage
    // ====================================

    /// @notice Mapping of version string to implementation address
    /// @dev Example: "v1.0" => 0x123..., "v2.0" => 0x456...
    mapping(string => address) public implementations;

    /// @notice Mapping of operator address to their deployed Paymaster address
    mapping(address => address) public paymasterByOperator;

    /// @notice Reverse mapping: Paymaster address to operator
    mapping(address => address) public operatorByPaymaster;

    /// @notice List of all deployed Paymaster addresses
    address[] public paymasterList;

    /// @notice Current default version
    string public defaultVersion;

    /// @notice Total number of deployed Paymasters
    uint256 public totalDeployed;

    // ====================================
    // Events
    // ====================================

    event PaymasterDeployed(
        address indexed operator,
        address indexed paymaster,
        string version,
        uint256 timestamp
    );

    event ImplementationUpgraded(
        string indexed version,
        address indexed oldImplementation,
        address indexed newImplementation
    );

    event DefaultVersionChanged(
        string oldVersion,
        string newVersion
    );

    event ImplementationAdded(
        string indexed version,
        address indexed implementation
    );

    // ====================================
    // Errors
    // ====================================

    error ImplementationNotFound(string version);
    error OperatorAlreadyHasPaymaster(address operator);
    error InvalidImplementation(address implementation);
    error VersionAlreadyExists(string version);
    error PaymasterNotFound(address paymaster);

    // ====================================
    // Constructor
    // ====================================

    constructor() Ownable(msg.sender) {}

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Deploy a new Paymaster using minimal proxy pattern
     * @param version Version of Paymaster implementation to use
     * @param initData Initialization data for the Paymaster
     * @return paymaster Address of the newly deployed Paymaster
     */
    function deployPaymaster(
        string memory version,
        bytes memory initData
    ) external returns (address paymaster) {
        address operator = msg.sender;

        // Check if operator already has a Paymaster
        if (paymasterByOperator[operator] != address(0)) {
            revert OperatorAlreadyHasPaymaster(operator);
        }

        // Get implementation address
        address implementation = implementations[version];
        if (implementation == address(0)) {
            revert ImplementationNotFound(version);
        }

        // Deploy minimal proxy using OpenZeppelin Clones
        paymaster = implementation.clone();

        // Initialize the Paymaster (if initData provided)
        if (initData.length > 0) {
            (bool success, ) = paymaster.call(initData);
            require(success, "Initialization failed");
        }

        // Update mappings
        paymasterByOperator[operator] = paymaster;
        operatorByPaymaster[paymaster] = operator;
        paymasterList.push(paymaster);

        totalDeployed++;

        emit PaymasterDeployed(operator, paymaster, version, block.timestamp);
    }

    /**
     * @notice Deploy Paymaster with default version
     * @param initData Initialization data
     * @return paymaster Address of the newly deployed Paymaster
     */
    function deployPaymasterDefault(bytes memory initData)
        external
        returns (address paymaster)
    {
        require(bytes(defaultVersion).length > 0, "No default version set");
        return this.deployPaymaster(defaultVersion, initData);
    }

    /**
     * @notice Deploy Paymaster using deterministic address (CREATE2)
     * @param version Version of Paymaster implementation
     * @param salt Salt for deterministic deployment
     * @param initData Initialization data
     * @return paymaster Deterministically deployed Paymaster address
     */
    function deployPaymasterDeterministic(
        string memory version,
        bytes32 salt,
        bytes memory initData
    ) external returns (address paymaster) {
        address operator = msg.sender;

        if (paymasterByOperator[operator] != address(0)) {
            revert OperatorAlreadyHasPaymaster(operator);
        }

        address implementation = implementations[version];
        if (implementation == address(0)) {
            revert ImplementationNotFound(version);
        }

        // Deploy with deterministic address
        paymaster = implementation.cloneDeterministic(salt);

        if (initData.length > 0) {
            (bool success, ) = paymaster.call(initData);
            require(success, "Initialization failed");
        }

        paymasterByOperator[operator] = paymaster;
        operatorByPaymaster[paymaster] = operator;
        paymasterList.push(paymaster);

        totalDeployed++;

        emit PaymasterDeployed(operator, paymaster, version, block.timestamp);
    }

    /**
     * @notice Predict deterministic Paymaster address
     * @param version Version to use
     * @param salt Salt for CREATE2
     * @return predicted Predicted Paymaster address
     */
    function predictPaymasterAddress(string memory version, bytes32 salt)
        external
        view
        returns (address predicted)
    {
        address implementation = implementations[version];
        if (implementation == address(0)) {
            revert ImplementationNotFound(version);
        }

        return implementation.predictDeterministicAddress(salt);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Add new implementation version
     * @param version Version string (e.g., "v1.0", "v2.0")
     * @param implementation Implementation contract address
     */
    function addImplementation(string memory version, address implementation)
        external
        onlyOwner
    {
        if (implementation == address(0) || implementation.code.length == 0) {
            revert InvalidImplementation(implementation);
        }

        if (implementations[version] != address(0)) {
            revert VersionAlreadyExists(version);
        }

        implementations[version] = implementation;

        // Set as default if first version
        if (bytes(defaultVersion).length == 0) {
            defaultVersion = version;
        }

        emit ImplementationAdded(version, implementation);
    }

    /**
     * @notice Upgrade existing implementation version
     * @param version Version to upgrade
     * @param newImplementation New implementation address
     * @dev Does NOT affect already deployed Paymasters (immutable proxies)
     */
    function upgradeImplementation(string memory version, address newImplementation)
        external
        onlyOwner
    {
        if (newImplementation == address(0) || newImplementation.code.length == 0) {
            revert InvalidImplementation(newImplementation);
        }

        address oldImplementation = implementations[version];
        if (oldImplementation == address(0)) {
            revert ImplementationNotFound(version);
        }

        implementations[version] = newImplementation;

        emit ImplementationUpgraded(version, oldImplementation, newImplementation);
    }

    /**
     * @notice Set default version for deployments
     * @param version Version string
     */
    function setDefaultVersion(string memory version) external onlyOwner {
        if (implementations[version] == address(0)) {
            revert ImplementationNotFound(version);
        }

        string memory oldVersion = defaultVersion;
        defaultVersion = version;

        emit DefaultVersionChanged(oldVersion, version);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get Paymaster address by operator
     * @param operator Operator address
     * @return paymaster Paymaster address (address(0) if none)
     */
    function getPaymasterByOperator(address operator)
        external
        view
        returns (address paymaster)
    {
        return paymasterByOperator[operator];
    }

    /**
     * @notice Get operator address by Paymaster
     * @param paymaster Paymaster address
     * @return operator Operator address
     */
    function getOperatorByPaymaster(address paymaster)
        external
        view
        returns (address operator)
    {
        operator = operatorByPaymaster[paymaster];
        if (operator == address(0)) {
            revert PaymasterNotFound(paymaster);
        }
    }

    /**
     * @notice Get implementation address by version
     * @param version Version string
     * @return implementation Implementation contract address
     */
    function getImplementation(string memory version)
        external
        view
        returns (address implementation)
    {
        implementation = implementations[version];
        if (implementation == address(0)) {
            revert ImplementationNotFound(version);
        }
    }

    /**
     * @notice Get paginated list of deployed Paymasters
     * @param offset Start index
     * @param limit Number of results
     * @return paymasters Array of Paymaster addresses
     */
    function getPaymasterList(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory paymasters)
    {
        uint256 total = paymasterList.length;

        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 size = end - offset;
        paymasters = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            paymasters[i] = paymasterList[offset + i];
        }
    }

    /**
     * @notice Get total number of deployed Paymasters
     * @return count Total Paymasters
     */
    function getPaymasterCount() external view returns (uint256 count) {
        return paymasterList.length;
    }

    /**
     * @notice Check if implementation exists for version
     * @param version Version string
     * @return exists True if implementation exists
     */
    function hasImplementation(string memory version)
        external
        view
        returns (bool exists)
    {
        return implementations[version] != address(0);
    }

    /**
     * @notice Check if operator has deployed Paymaster
     * @param operator Operator address
     * @return hasPaymaster True if operator has Paymaster
     */
    function hasPaymaster(address operator)
        external
        view
        returns (bool hasPaymaster)
    {
        return paymasterByOperator[operator] != address(0);
    }

    /**
     * @notice Get Paymaster info
     * @param paymaster Paymaster address
     * @return operator Operator address
     * @return isValid True if Paymaster was deployed by this factory
     */
    function getPaymasterInfo(address paymaster)
        external
        view
        returns (address operator, bool isValid)
    {
        operator = operatorByPaymaster[paymaster];
        isValid = operator != address(0);
    }
}
