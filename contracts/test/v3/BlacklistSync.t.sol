// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/core/Registry.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/GToken.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/tokens/MySBT.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract MockAggregator is AggregatorV3Interface {
    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "Mock"; }
    function version() external pure returns (uint256) { return 1; }
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
}

contract MockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function balanceOf(address) external view returns (uint256) { return 0; }
    function getDepositInfo(address) external view returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external {} 
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {} 
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function getUserOpHash(PackedUserOperation calldata) external view returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view returns (uint256) { return 0; }
    function incrementNonce(uint192) external {}
    function delegateAndRevert(address, bytes calldata) external {}
}

contract BlacklistSyncTest is Test {
    Registry registry;
    SuperPaymaster paymaster;
    xPNTsToken apnts;
    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    MockEntryPoint entryPoint;
    MockAggregator priceFeed;

    address owner = address(1);
    address dvtNode = address(2); // Trusted Reputation Source
    address operator = address(3);
    address maliciousUser = address(4);
    address treasury = address(5);

    function setUp() public {
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(owner);

        // 1. Deploy Core Dependencies
        gtoken = new GToken(1_000_000_000 ether);
        staking = new GTokenStaking(address(gtoken), owner);
        mysbt = new MySBT(address(gtoken), address(staking), address(0), owner);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));
        
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));

        // 2. Deploy Paymaster Dependencies
        entryPoint = new MockEntryPoint();
        priceFeed = new MockAggregator();
        apnts = new xPNTsToken("APNTS", "APNTS", owner, "Comm", "ens", 1e18);
        
        paymaster = new SuperPaymaster(entryPoint, owner, registry, address(apnts), address(priceFeed), treasury, 3600);

        // 3. Connect Registry & Paymaster
        registry.setSuperPaymaster(address(paymaster));
        apnts.setSuperPaymasterAddress(address(paymaster));

        // 4. Setup Roles
        registry.setReputationSource(dvtNode, true);
        
        // Register Operator (Community + Paymaster)
        gtoken.mint(operator, 10000 ether);
        vm.stopPrank();
        
        vm.startPrank(operator);
        gtoken.approve(address(staking), 10000 ether);
        registry.registerRole(registry.ROLE_COMMUNITY(), operator, abi.encode("OpComm", "op.eth", "", "", "", 100 ether));
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), operator, abi.encode(uint256(100 ether)));
        
        // Configure Operator
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        paymaster.updatePrice();
        
        // Fund Operator
        vm.stopPrank();
        vm.prank(owner);
        apnts.mint(operator, 1000 ether);
        
        vm.prank(operator);
        apnts.approve(address(paymaster), 1000 ether);
        vm.prank(operator);
        paymaster.depositFor(operator, 1000 ether);
    }

    function test_BlacklistFlow() public {
        // 1. Verify User NOT blocked initially
        bool blocked = paymaster.blockedUsers(operator, maliciousUser);
        assertFalse(blocked, "Should not be blocked initially");

        // 2. DVT triggers blacklist via Registry
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        
        vm.prank(dvtNode);
        registry.updateOperatorBlacklist(operator, users, statuses, ""); // Empty proof for now (Mock BLS validator)

        // 3. Verify Blocked in Paymaster
        blocked = paymaster.blockedUsers(operator, maliciousUser);
        assertTrue(blocked, "Should be blocked after sync");

        // 4. Try to validate UserOp (Should Fail)
        PackedUserOperation memory op = _createOp(maliciousUser);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        
        // ValidationData != 0 means failure (SIG_VALIDATION_FAILED)
        // Actually BasePaymaster packs it. 
        // 0 = Success. 
        // 1 = SIG_VALIDATION_FAILED (Signature mismatch, but here we return packed data)
        // _packValidationData(true, ...) returns a large number (authorizer=1 => failure)
        
        // Let's decode validationData
        // validationData: [authorizer(20 bytes)][validUntil(6 bytes)][validAfter(6 bytes)]
        // If authorizer != 0, it failed.
        uint256 authorizer = validationData & uint256(type(uint160).max);
        assertEq(authorizer, 1, "Should fail validation");
    }

    function test_UnblockFlow() public {
        // Block first
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        
        vm.prank(dvtNode);
        registry.updateOperatorBlacklist(operator, users, statuses, "");
        
        assertTrue(paymaster.blockedUsers(operator, maliciousUser));

        // Unblock
        statuses[0] = false;
        vm.prank(dvtNode);
        registry.updateOperatorBlacklist(operator, users, statuses, "");
        
        assertFalse(paymaster.blockedUsers(operator, maliciousUser));
        
        // Validation should pass now
        PackedUserOperation memory op = _createOp(maliciousUser);
        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        assertEq(validationData, 0, "Should pass validation");
    }

    function test_Revert_UnauthorizedSource() public {
        address hacker = address(0xdead);
        address[] memory users = new address[](1);
        users[0] = maliciousUser;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(hacker);
        vm.expectRevert("Unauthorized Reputation Source");
        registry.updateOperatorBlacklist(operator, users, statuses, "");
    }

    function _createOp(address sender) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(100000))),
            preVerificationGas: 21000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei))),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint128(100000),
                uint128(0),
                operator // Paymaster Data: Operator
            ),
            signature: ""
        });
    }
}
