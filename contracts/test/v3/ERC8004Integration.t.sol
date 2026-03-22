// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
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
}
