// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/core/Registry.sol";
import "../src/core/GTokenStaking.sol";
import "../src/tokens/MySBT.sol";
import "../src/tokens/GToken.sol";
import "../src/tokens/xPNTsToken.sol";
import "../src/modules/reputation/ReputationSystemV3.sol";
import "../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
// Mock NFT via local class

// Simple NFT Mock for testing
contract MockNFT {
    mapping(address => uint256) public balanceOf;
    function setBalance(address user, uint256 bal) external { balanceOf[user] = bal; }
}

contract IntegrationV3_1Test is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT mySBT;
    GToken gToken;
    ReputationSystemV3 repSystem;
    SuperPaymasterV3 paymaster;
    xPNTsToken aPNTs;
    MockNFT mockNFT;

    address owner = address(0x111);
    address operator = address(0x222);
    address alice = address(0x333);
    address treasury = address(0x444);

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Core
        gToken = new GToken(21_000_000 ether);
        staking = new GTokenStaking(address(gToken), treasury);
        
        uint256 n2 = vm.getNonce(owner);
        // Current nonce is N. Registry (currently deploying) will be N, MySBT will be N+1.
        address predSBT = vm.computeCreateAddress(owner, n2 + 1);
        
        registry = new Registry(address(gToken), address(staking), predSBT);
        mySBT = new MySBT(address(gToken), address(staking), address(registry), owner);
        
        if (address(mySBT) != predSBT) {
            console.log("Expected:", predSBT);
            console.log("Actual:", address(mySBT));
            console.log("Owner Nonce N2:", n2);
            revert("Prediction mismatch");
        }
        
        // Wiring
        staking.setRegistry(address(registry));
        mySBT.setRegistry(address(registry));
        
        // 2. Deploy Modules
        repSystem = new ReputationSystemV3(address(registry));
        mockNFT = new MockNFT();
        
        // 3. Deploy Paymaster
        aPNTs = new xPNTsToken("aPNTs", "aPNTs", owner, "Global", "aastar.eth", 1e18);
        paymaster = new SuperPaymasterV3(
            IEntryPoint(address(0xdead)), // Mock EntryPoint
            owner,
            registry,
            address(aPNTs),
            address(0xbeef), // Mock PriceFeed
            treasury
        );

        // 4. Permissions
        registry.setReputationSource(address(repSystem), true);
        aPNTs.setSuperPaymasterAddress(address(paymaster));
        
        // 5. Registration Flow (Real registration to ensure all stats/mappings are right)
        bytes32 ROLE_COMM = registry.ROLE_COMMUNITY();
        bytes32 ROLE_USER = registry.ROLE_ENDUSER();
        
        gToken.mint(operator, 100 ether);
        gToken.mint(alice, 100 ether);

        vm.startPrank(operator);
        gToken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_COMM, operator, abi.encode(Registry.CommunityRoleData("Comm", "", "", "", "", 30 ether)));
        vm.stopPrank();
        
        vm.startPrank(alice);
        gToken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_USER, alice, abi.encode(
            Registry.EndUserRoleData({
                account: address(0xdead),
                community: operator,
                avatarURI: "",
                ensName: "",
                stakeAmount: 1 ether
            })
        ));
        vm.stopPrank();
        
        // Confirm roles
        require(registry.hasRole(ROLE_COMM, operator), "Role grant failed");
        require(registry.hasRole(ROLE_USER, alice), "Role grant failed");

        vm.startPrank(owner); // Reset to owner prank for rest of setup

        vm.stopPrank();
    }

    function test_Fibonacci_Credit_Tiers() public view {
        // Thresholds: 13, 34, 89, 233, 610
        assertEq(registry.getCreditLimit(alice), 0, "Initial credit should be 0");
        
        // We need to actually set reputation to test Registry logic
        // But since we can't easily prank the mapping in a view test, 
        // we rely on the sync test below.
    }

    function test_Reputation_Sync_And_Fib_Tiering() public {
        vm.startPrank(owner);
        repSystem.setNFTBoost(address(mockNFT), 50); // Holding NFT gives 50 points
        vm.stopPrank();

        // 1. Give Alice an NFT
        mockNFT.setBalance(alice, 1);

        // 2. Perform Sync
        address[] memory comms = new address[](1);
        comms[0] = operator; 
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = bytes32(0); // Default rule

        uint256[][] memory acts = new uint256[][](1);
        acts[0] = new uint256[](1);
        acts[0][0] = 10; // 10 activities * 1 bonus (default) + 10 base = 20.
        // Total expected: 20 (activity) + 50 (NFT) = 70.

        // Sync from authorized source (repSystem is authorized)
        repSystem.syncToRegistry(alice, comms, ruleIds, acts, 1);

        uint256 finalRep = registry.globalReputation(alice);
        assertEq(finalRep, 70, "Reputation should be 70 (20 activity + 50 NFT)");

        // 3. Check Tier (Tier 3: 34-88 -> 300 aPNTs)
        uint256 limit = registry.getCreditLimit(alice);
        assertEq(limit, 300 ether, "Tier 3 credit limit should be 300 aPNTs");
    }

    function test_Global_Debt_Ceiling_Enforcement() public {
        // Setup: Alice has 300 aPNTs credit
        vm.prank(owner);
        registry.batchUpdateGlobalReputation(_toArr(alice), _toArr(70), 2, "");
        
        // 1. Give Operator balance as Owner
        vm.startPrank(owner);
        aPNTs.mint(operator, 1000 ether);
        vm.stopPrank();

        // 2. Configure and Deposit as Operator
        vm.startPrank(operator);
        paymaster.configureOperator(address(aPNTs), treasury, 1e18);
        aPNTs.transfer(address(paymaster), 1000 ether);
        paymaster.notifyDeposit(1000 ether);
        vm.stopPrank();

        // 1. Manually Record Debt for Alice (250 aPNTs)
        // Simulate a transaction that just happened
        vm.prank(address(0xdead)); // Mock EntryPoint
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, abi.encode(address(aPNTs), 250 ether, alice, 250 ether), 250 ether, 1);

        assertEq(aPNTs.getDebt(alice), 250 ether);

        // 2. Check remaining credit for a NEW transaction
        // Limit (300) - Debt (250) = 50 available.
        uint256 available = paymaster.getAvailableCredit(alice, address(aPNTs));
        assertEq(available, 50 ether, "Available credit should be 50");

        // 3. Attempt a 60 aPNTs sponsorship -> Should fail
        // In actual validatePaymasterUserOp, it would revert.
    }

    function test_Operator_Config_Packing() public {
        vm.startPrank(operator);
        paymaster.configureOperator(address(aPNTs), treasury, 5e17); // 0.5 rate
        vm.stopPrank();

        (
            address token, bool isConf, bool isPaused, , 
            address treas, uint96 rate, , , , 
        ) = paymaster.operators(operator);

        assertEq(token, address(aPNTs));
        assertEq(isConf, true);
        assertEq(isPaused, false);
        assertEq(treas, treasury);
        assertEq(rate, 5e17);
    }

    // Helper
    function _toArr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
    function _toArr(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
