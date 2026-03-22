// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/**
 * @title MockAgentIdentityRegistry
 * @notice Minimal ERC-721-like mock for testing agent identity checks
 */
contract MockAgentIdentityRegistry {
    mapping(address => uint256) private _balances;
    uint256 private _nextTokenId = 1;

    function mint(address to) external {
        _balances[to] += 1;
        _nextTokenId++;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(0); // Simplified for testing
    }
}

/**
 * @title RevertingRegistry
 * @notice Mock registry that always reverts on balanceOf (for graceful failure testing)
 */
contract RevertingRegistry {
    function balanceOf(address) external pure returns (uint256) {
        revert("ALWAYS_REVERT");
    }
}

/**
 * @title Mock EntryPoint (local to this test)
 */
contract MockEntryPoint8004 {
    function depositTo(address) external payable {}
}

/**
 * @title Mock Price Feed (local to this test)
 */
contract MockPriceFeed8004 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/**
 * @title Mock aPNTs Token (local to this test)
 */
contract MockAPNTs8004 is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ERC8004Integration_Test
 * @notice Tests for ERC-8004 Agent Registry integration in SuperPaymaster
 */
contract ERC8004Integration_Test is Test {
    SuperPaymaster public paymaster;
    Registry public registry;
    GToken public gtoken;
    MockEntryPoint8004 public entryPoint;
    MockPriceFeed8004 public priceFeed;
    MockAPNTs8004 public apnts;
    MockAgentIdentityRegistry public agentRegistry;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public agent1 = address(0x10);
    address public nonAgent = address(0x11);
    address public nonOwner = address(0x99);

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new GToken(21_000_000 ether);
        entryPoint = new MockEntryPoint8004();
        priceFeed = new MockPriceFeed8004();
        apnts = new MockAPNTs8004();
        agentRegistry = new MockAgentIdentityRegistry();

        address mockStaking = address(0x999);
        address mockSBT = address(0x888);
        registry = UUPSDeployHelper.deployRegistryProxy(owner, mockStaking, mockSBT);

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        // Warp and update price cache
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        vm.stopPrank();
    }

    // ====================================
    // setAgentRegistries Tests
    // ====================================

    function testSetAgentRegistries() public {
        address identityReg = address(agentRegistry);
        address reputationReg = address(0xBEEF);

        vm.prank(owner);
        paymaster.setAgentRegistries(identityReg, reputationReg);

        assertEq(paymaster.agentIdentityRegistry(), identityReg);
        assertEq(paymaster.agentReputationRegistry(), reputationReg);
    }

    function testSetAgentRegistriesEmitsEvent() public {
        address identityReg = address(agentRegistry);
        address reputationReg = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit SuperPaymaster.AgentRegistriesUpdated(identityReg, reputationReg);
        paymaster.setAgentRegistries(identityReg, reputationReg);
    }

    function testSetAgentRegistriesNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setAgentRegistries(address(agentRegistry), address(0xBEEF));
    }

    // ====================================
    // isRegisteredAgent Tests
    // ====================================

    function testIsRegisteredAgentWithNFT() public {
        // Mint agent NFT to agent1
        agentRegistry.mint(agent1);

        // Set the registry
        vm.prank(owner);
        paymaster.setAgentRegistries(address(agentRegistry), address(0));

        // Should return true
        assertTrue(paymaster.isRegisteredAgent(agent1));
    }

    function testIsRegisteredAgentWithoutNFT() public {
        // Set the registry but don't mint
        vm.prank(owner);
        paymaster.setAgentRegistries(address(agentRegistry), address(0));

        // nonAgent has no NFT
        assertFalse(paymaster.isRegisteredAgent(nonAgent));
    }

    function testIsRegisteredAgentNoRegistry() public {
        // Registry not set (default address(0))
        assertFalse(paymaster.isRegisteredAgent(agent1));
    }

    function testIsRegisteredAgentRegistryReverts() public {
        // Deploy a reverting registry
        RevertingRegistry revertingReg = new RevertingRegistry();

        vm.prank(owner);
        paymaster.setAgentRegistries(address(revertingReg), address(0));

        // Should gracefully return false instead of reverting
        assertFalse(paymaster.isRegisteredAgent(agent1));
    }

    // ====================================
    // isEligibleForSponsorship Tests
    // ====================================

    function testIsEligibleForSponsorship_withSBT() public {
        // User has SBT, no agent registry set
        vm.prank(address(registry));
        paymaster.updateSBTStatus(agent1, true);

        assertTrue(paymaster.isEligibleForSponsorship(agent1));
    }

    function testIsEligibleForSponsorship_withAgentNFT() public {
        // User has no SBT but is a registered agent
        agentRegistry.mint(agent1);

        vm.prank(owner);
        paymaster.setAgentRegistries(address(agentRegistry), address(0));

        // Verify SBT is not set
        assertFalse(paymaster.sbtHolders(agent1));

        // Should still be eligible via ERC-8004 channel
        assertTrue(paymaster.isEligibleForSponsorship(agent1));
    }

    function testIsEligibleForSponsorship_withBoth() public {
        // User has both SBT and agent NFT
        vm.prank(address(registry));
        paymaster.updateSBTStatus(agent1, true);

        agentRegistry.mint(agent1);

        vm.prank(owner);
        paymaster.setAgentRegistries(address(agentRegistry), address(0));

        assertTrue(paymaster.isEligibleForSponsorship(agent1));
    }

    function testIsEligibleForSponsorship_withNeither() public {
        // User has no SBT and is not an agent
        vm.prank(owner);
        paymaster.setAgentRegistries(address(agentRegistry), address(0));

        assertFalse(paymaster.isEligibleForSponsorship(nonAgent));
    }

    function testIsEligibleForSponsorship_registryNotSet() public {
        // No agent registry configured, no SBT → not eligible
        assertFalse(paymaster.isEligibleForSponsorship(nonAgent));
    }

    function testValidatePaymasterUserOp_acceptsAgent() public {
        // Setup: register operator via mock registry roles
        address operator1 = address(0x30);
        bytes32 ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        // Deploy a mock xPNTs token for operator config
        MockXPNTsForERC8004 xpntsToken = new MockXPNTsForERC8004();

        // We need a full mock registry that supports hasRole for operator validation
        MockRegistryForValidation mockReg = new MockRegistryForValidation();
        mockReg.setRole(ROLE_PAYMASTER_SUPER, operator1, true);
        mockReg.setRole(ROLE_COMMUNITY, operator1, true);

        vm.startPrank(owner);

        // Deploy a new paymaster with the mock registry
        SuperPaymaster pm = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(mockReg)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        // Warp and update price
        vm.warp(block.timestamp + 4 hours);
        pm.updatePrice();

        // Set agent registry and mint agent NFT to agent1
        agentRegistry.mint(agent1);
        pm.setAgentRegistries(address(agentRegistry), address(0));

        vm.stopPrank();

        // Fund operator: mint aPNTs and deposit
        apnts.mint(operator1, 10000 ether);
        vm.startPrank(operator1);
        apnts.approve(address(pm), type(uint256).max);
        pm.configureOperator(address(xpntsToken), address(0x999), 1 ether);
        pm.deposit(5000 ether);
        vm.stopPrank();

        // Verify agent1 has no SBT
        assertFalse(pm.sbtHolders(agent1));
        // Verify agent1 is a registered agent
        assertTrue(pm.isRegisteredAgent(agent1));

        // Build UserOp with agent1 as sender
        PackedUserOperation memory op;
        op.sender = agent1;
        op.paymasterAndData = abi.encodePacked(
            address(pm),      // 20 bytes
            uint256(1000),    // 32 bytes (gasLimits placeholder)
            operator1,        // 20 bytes (operator)
            type(uint256).max // 32 bytes (maxRate)
        );

        // Call validatePaymasterUserOp as entryPoint
        vm.prank(address(entryPoint));
        (, uint256 valData) = pm.validatePaymasterUserOp(op, bytes32(0), 1000);

        // sigFailed should be false (lowest 160 bits == 0 means validation passed)
        assertEq(uint160(valData), 0, "Agent should pass validation without SBT");
    }
}

/**
 * @title MockXPNTsForERC8004
 * @notice Minimal xPNTs mock for validation test
 */
contract MockXPNTsForERC8004 {
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
    function recordDebt(address, uint256) external {}
}

/**
 * @title MockRegistryForValidation
 * @notice Full mock registry that supports role checks for validation tests
 */
contract MockRegistryForValidation is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function setRole(bytes32 role, address account, bool val) external {
        roles[role][account] = val;
    }

    function getCreditLimit(address) external pure returns (uint256) { return 1000 ether; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function setBLSAggregator(address) external {}
    function setBLSValidator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }
    function version() external pure returns (string memory) { return "Mock"; }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function isReputationSource(address) external view returns (bool) { return false; }
    function roleOwners(bytes32) external view returns (address) { return address(0); }
}
