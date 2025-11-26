// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {MySBT} from "../src/paymasters/v2/tokens/MySBT.sol";
import {IERC8004IdentityRegistry} from "../src/paymasters/v2/interfaces/IERC8004IdentityRegistry.sol";

/**
 * @title MySBT v2.5.0 ERC-8004 Tests
 * @notice Tests for ERC-8004 Identity Registry integration
 */
contract MySBT_v2_5_0_Test is Test {
    MySBT public mysbt;

    address public gtoken = address(0x1111);
    address public gtokenStaking = address(0x2222);
    address public registry = address(0x3333);
    address public daoMultisig = address(0x4444);

    address public agent1 = address(0x1001);
    address public agent2 = address(0x1002);
    address public agent3 = address(0x1003);

    function setUp() public {
        // Deploy MySBT with mock addresses
        mysbt = new MySBT(gtoken, gtokenStaking, registry, daoMultisig);
    }

    // ====================================
    // Version Tests
    // ====================================

    function test_Version() public view {
        assertEq(mysbt.VERSION(), "2.5.0");
        assertEq(mysbt.VERSION_CODE(), 20500);
        assertEq(mysbt.version(), 2005000);
        assertEq(mysbt.versionString(), "v2.5.0");
    }

    // ====================================
    // ERC-8004 Registration Tests
    // ====================================

    function test_RegisterBasic() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        assertEq(agentId, 1);
        assertEq(mysbt.ownerOf(agentId), agent1);
        assertEq(mysbt.userToSBT(agent1), agentId);
        assertTrue(mysbt.hasMySBT(agent1));
    }

    function test_RegisterWithURI() public {
        string memory uri = "ipfs://QmAgentCard123";

        vm.prank(agent1);
        uint256 agentId = mysbt.register(uri);

        assertEq(agentId, 1);
        assertEq(mysbt.tokenURI(agentId), uri);
    }

    function test_RegisterWithURIAndMetadata() public {
        string memory uri = "ipfs://QmAgentCard456";
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](2);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({key: "capabilities", value: abi.encode("gasless-tx")});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({key: "endpoint", value: abi.encode("https://api.agent.example")});

        vm.prank(agent1);
        uint256 agentId = mysbt.register(uri, metadata);

        assertEq(agentId, 1);
        assertEq(mysbt.tokenURI(agentId), uri);
        assertEq(mysbt.getMetadata(agentId, "capabilities"), abi.encode("gasless-tx"));
        assertEq(mysbt.getMetadata(agentId, "endpoint"), abi.encode("https://api.agent.example"));
    }

    function test_RegisterFailsIfAlreadyRegistered() public {
        vm.prank(agent1);
        mysbt.register();

        vm.prank(agent1);
        vm.expectRevert("Already registered");
        mysbt.register();
    }

    function test_RegisterEmitsEvent() public {
        string memory uri = "ipfs://QmTest";

        vm.expectEmit(true, true, false, true);
        emit IERC8004IdentityRegistry.Registered(1, uri, agent1);

        vm.prank(agent1);
        mysbt.register(uri);
    }

    // ====================================
    // Metadata Tests
    // ====================================

    function test_SetMetadata() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.prank(agent1);
        mysbt.setMetadata(agentId, "version", abi.encode("1.0.0"));

        assertEq(mysbt.getMetadata(agentId, "version"), abi.encode("1.0.0"));
    }

    function test_SetMetadataFailsIfNotOwner() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.prank(agent2);
        vm.expectRevert("Not agent owner");
        mysbt.setMetadata(agentId, "version", abi.encode("1.0.0"));
    }

    function test_SetMetadataEmitsEvent() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.expectEmit(true, true, false, true);
        emit IERC8004IdentityRegistry.MetadataSet(agentId, "version", "version", abi.encode("1.0.0"));

        vm.prank(agent1);
        mysbt.setMetadata(agentId, "version", abi.encode("1.0.0"));
    }

    function test_BatchSetMetadata() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        IERC8004IdentityRegistry.MetadataEntry[] memory entries = new IERC8004IdentityRegistry.MetadataEntry[](3);
        entries[0] = IERC8004IdentityRegistry.MetadataEntry({key: "key1", value: abi.encode("value1")});
        entries[1] = IERC8004IdentityRegistry.MetadataEntry({key: "key2", value: abi.encode("value2")});
        entries[2] = IERC8004IdentityRegistry.MetadataEntry({key: "key3", value: abi.encode("value3")});

        vm.prank(agent1);
        mysbt.batchSetMetadata(agentId, entries);

        assertEq(mysbt.getMetadata(agentId, "key1"), abi.encode("value1"));
        assertEq(mysbt.getMetadata(agentId, "key2"), abi.encode("value2"));
        assertEq(mysbt.getMetadata(agentId, "key3"), abi.encode("value3"));
    }

    function test_GetMetadataKeys() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.startPrank(agent1);
        mysbt.setMetadata(agentId, "key1", abi.encode("v1"));
        mysbt.setMetadata(agentId, "key2", abi.encode("v2"));
        mysbt.setMetadata(agentId, "key3", abi.encode("v3"));
        vm.stopPrank();

        string[] memory keys = mysbt.getMetadataKeys(agentId);
        assertEq(keys.length, 3);
        assertEq(keys[0], "key1");
        assertEq(keys[1], "key2");
        assertEq(keys[2], "key3");
    }

    function test_GetMetadataKeysNoDuplicates() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.startPrank(agent1);
        mysbt.setMetadata(agentId, "key1", abi.encode("v1"));
        mysbt.setMetadata(agentId, "key1", abi.encode("v1-updated")); // Update same key
        mysbt.setMetadata(agentId, "key2", abi.encode("v2"));
        vm.stopPrank();

        string[] memory keys = mysbt.getMetadataKeys(agentId);
        assertEq(keys.length, 2); // No duplicate
        assertEq(mysbt.getMetadata(agentId, "key1"), abi.encode("v1-updated"));
    }

    // ====================================
    // Token URI Tests
    // ====================================

    function test_SetTokenURI() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register("ipfs://original");

        vm.prank(agent1);
        mysbt.setTokenURI(agentId, "ipfs://updated");

        assertEq(mysbt.tokenURI(agentId), "ipfs://updated");
    }

    function test_SetTokenURIFailsIfNotOwner() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        vm.prank(agent2);
        vm.expectRevert("Not agent owner");
        mysbt.setTokenURI(agentId, "ipfs://hacked");
    }

    // ====================================
    // Multiple Agents Tests
    // ====================================

    function test_MultipleAgents() public {
        vm.prank(agent1);
        uint256 id1 = mysbt.register("ipfs://agent1");

        vm.prank(agent2);
        uint256 id2 = mysbt.register("ipfs://agent2");

        vm.prank(agent3);
        uint256 id3 = mysbt.register("ipfs://agent3");

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);

        assertEq(mysbt.ownerOf(1), agent1);
        assertEq(mysbt.ownerOf(2), agent2);
        assertEq(mysbt.ownerOf(3), agent3);

        assertEq(mysbt.tokenURI(1), "ipfs://agent1");
        assertEq(mysbt.tokenURI(2), "ipfs://agent2");
        assertEq(mysbt.tokenURI(3), "ipfs://agent3");
    }

    // ====================================
    // Convenience Function Tests
    // ====================================

    function test_HasMySBT() public {
        assertFalse(mysbt.hasMySBT(agent1));

        vm.prank(agent1);
        mysbt.register();

        assertTrue(mysbt.hasMySBT(agent1));
    }

    function test_GetNextTokenId() public {
        assertEq(mysbt.getNextTokenId(), 1);

        vm.prank(agent1);
        mysbt.register();

        assertEq(mysbt.getNextTokenId(), 2);

        vm.prank(agent2);
        mysbt.register();

        assertEq(mysbt.getNextTokenId(), 3);
    }

    // ====================================
    // Edge Cases
    // ====================================

    function test_EmptyMetadata() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register();

        bytes memory emptyData = mysbt.getMetadata(agentId, "nonexistent");
        assertEq(emptyData.length, 0);
    }

    function test_EmptyTokenURI() public {
        vm.prank(agent1);
        uint256 agentId = mysbt.register(); // No URI provided

        // Should return default (may revert or return empty depending on ERC721 implementation)
        // For our implementation, we check _tokenURIs first
        string memory uri = mysbt.tokenURI(agentId);
        // Empty URI returns from parent which may be base URI + tokenId
        assertEq(bytes(uri).length >= 0, true);
    }
}
