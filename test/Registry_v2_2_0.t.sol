// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/paymasters/v2/core/Registry_v2_2_0.sol";
import "../src/paymasters/v2/interfaces/Interfaces.sol";

/**
 * @title Registry v2.2.0 Test Suite
 * @notice Tests for auto-stake registration feature
 */
contract RegistryV220Test is Test {
    Registry public registry;
    MockGToken public gtoken;
    MockGTokenStaking public staking;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);

    uint256 constant PAYMASTER_AOA_MIN_STAKE = 30 ether;
    uint256 constant PAYMASTER_SUPER_MIN_STAKE = 50 ether;
    uint256 constant ANODE_MIN_STAKE = 20 ether;
    uint256 constant KMS_MIN_STAKE = 100 ether;

    event CommunityRegistered(address indexed community, string name, Registry.NodeType indexed nodeType, uint256 staked);
    event CommunityRegisteredWithAutoStake(address indexed community, string name, uint256 staked, uint256 autoStaked);

    function setUp() public {
        // Deploy mocks
        gtoken = new MockGToken();
        staking = new MockGTokenStaking(address(gtoken));

        // Deploy Registry
        vm.startPrank(owner);
        registry = new Registry(address(gtoken), address(staking));

        // Register Registry as authorized locker in staking contract
        staking.addLocker(address(registry));
        vm.stopPrank();

        // Mint GToken to test users
        gtoken.mint(alice, 1000 ether);
        gtoken.mint(bob, 1000 ether);
    }

    // ==================== Basic Tests ====================

    function test_Version() public view {
        assertEq(registry.VERSION(), "2.2.0");
        assertEq(registry.VERSION_CODE(), 20200);
    }

    function test_Constructor() public view {
        assertEq(address(registry.GTOKEN()), address(gtoken));
        assertEq(address(registry.GTOKEN_STAKING()), address(staking));
        assertEq(registry.owner(), owner);
    }

    // ==================== Auto-Stake Registration Tests ====================

    function test_RegisterCommunityWithAutoStake_NoExistingStake() public {
        // Alice has 1000 GT in wallet but 0 staked
        assertEq(gtoken.balanceOf(alice), 1000 ether);
        assertEq(staking.stakedBalance(alice), 0);

        // Prepare profile
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        // Alice approves Registry to spend GToken
        vm.startPrank(alice);
        gtoken.approve(address(registry), PAYMASTER_AOA_MIN_STAKE);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit CommunityRegistered(alice, "AliceCommunity", Registry.NodeType.PAYMASTER_AOA, PAYMASTER_AOA_MIN_STAKE);

        vm.expectEmit(true, true, true, true);
        emit CommunityRegisteredWithAutoStake(alice, "AliceCommunity", PAYMASTER_AOA_MIN_STAKE, PAYMASTER_AOA_MIN_STAKE);

        // Register with auto-stake
        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);
        vm.stopPrank();

        // Verify results
        Registry.CommunityProfile memory registered = registry.getCommunityProfile(alice);
        assertEq(registered.name, "AliceCommunity");
        assertEq(registered.community, alice);
        assertTrue(registered.isActive);

        // Verify staking and locking
        assertEq(staking.stakedBalance(alice), PAYMASTER_AOA_MIN_STAKE);
        assertEq(staking.availableBalance(alice), 0); // All staked tokens are locked
        assertEq(staking.getLockedStake(alice, address(registry)), PAYMASTER_AOA_MIN_STAKE);

        // Verify GToken balance decreased
        assertEq(gtoken.balanceOf(alice), 1000 ether - PAYMASTER_AOA_MIN_STAKE);
    }

    function test_RegisterCommunityWithAutoStake_WithPartialExistingStake() public {
        // Alice stakes 20 GT first
        vm.startPrank(alice);
        gtoken.approve(address(staking), 20 ether);
        staking.stake(20 ether);
        vm.stopPrank();

        // Verify initial state
        assertEq(staking.stakedBalance(alice), 20 ether);
        assertEq(staking.availableBalance(alice), 20 ether);

        // Prepare profile (needs 30 GT, already has 20 GT staked)
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        // Alice approves Registry for the additional 10 GT needed
        vm.startPrank(alice);
        gtoken.approve(address(registry), 10 ether);

        vm.expectEmit(true, true, true, true);
        emit CommunityRegisteredWithAutoStake(alice, "AliceCommunity", PAYMASTER_AOA_MIN_STAKE, 10 ether);

        // Register with auto-stake (will auto-stake 10 GT)
        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);
        vm.stopPrank();

        // Verify staking
        assertEq(staking.stakedBalance(alice), PAYMASTER_AOA_MIN_STAKE);
        assertEq(staking.availableBalance(alice), 0); // All 30 GT locked
        assertEq(staking.getLockedStake(alice, address(registry)), PAYMASTER_AOA_MIN_STAKE);
    }

    function test_RegisterCommunityWithAutoStake_WithSufficientExistingStake() public {
        // Alice stakes 50 GT first
        vm.startPrank(alice);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        vm.stopPrank();

        assertEq(staking.availableBalance(alice), 50 ether);

        // Prepare profile (needs 30 GT, already has 50 GT available)
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        // No need to approve Registry since no additional staking needed

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit CommunityRegisteredWithAutoStake(alice, "AliceCommunity", PAYMASTER_AOA_MIN_STAKE, 0); // autoStaked = 0

        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);
        vm.stopPrank();

        // Verify staking (total 50 GT, 30 GT locked)
        assertEq(staking.stakedBalance(alice), 50 ether);
        assertEq(staking.availableBalance(alice), 20 ether); // 50 - 30 = 20 GT available
        assertEq(staking.getLockedStake(alice, address(registry)), PAYMASTER_AOA_MIN_STAKE);
    }

    // ==================== Error Cases ====================

    function test_RevertWhen_InsufficientGTokenBalance() public {
        // Alice only has 1000 GT but tries to register with 2000 GT stake
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        vm.startPrank(alice);
        gtoken.approve(address(registry), 2000 ether);

        vm.expectRevert();
        registry.registerCommunityWithAutoStake(profile, 2000 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_AlreadyRegistered() public {
        // Alice registers first time
        vm.startPrank(alice);
        gtoken.approve(address(registry), PAYMASTER_AOA_MIN_STAKE);

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);

        // Try to register again
        gtoken.approve(address(registry), PAYMASTER_AOA_MIN_STAKE);

        vm.expectRevert(abi.encodeWithSelector(Registry.CommunityAlreadyRegistered.selector, alice));
        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientStakeAmount() public {
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceCommunity",
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        vm.startPrank(alice);
        gtoken.approve(address(registry), 10 ether);

        // Try to register with only 10 GT (needs 30 GT)
        vm.expectRevert(abi.encodeWithSelector(Registry.InsufficientStake.selector, 10 ether, PAYMASTER_AOA_MIN_STAKE));
        registry.registerCommunityWithAutoStake(profile, 10 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_EmptyName() public {
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "", // Empty name
            ensName: "alice.eth",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        vm.startPrank(alice);
        gtoken.approve(address(registry), PAYMASTER_AOA_MIN_STAKE);

        vm.expectRevert(Registry.NameEmpty.selector);
        registry.registerCommunityWithAutoStake(profile, PAYMASTER_AOA_MIN_STAKE);
        vm.stopPrank();
    }

    // ==================== Different Node Types ====================

    function test_RegisterWithAutoStake_PaymasterSuper() public {
        vm.startPrank(alice);
        gtoken.approve(address(registry), PAYMASTER_SUPER_MIN_STAKE);

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AliceSuperPaymaster",
            ensName: "",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_SUPER,
            paymasterAddress: address(0x123),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        registry.registerCommunityWithAutoStake(profile, PAYMASTER_SUPER_MIN_STAKE);
        vm.stopPrank();

        assertEq(staking.getLockedStake(alice, address(registry)), PAYMASTER_SUPER_MIN_STAKE);
    }

    function test_RegisterWithAutoStake_ANode() public {
        vm.startPrank(bob);
        gtoken.approve(address(registry), ANODE_MIN_STAKE);

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "BobANode",
            ensName: "",
            xPNTsToken: address(0),
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.ANODE,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            allowPermissionlessMint: false
        });

        registry.registerCommunityWithAutoStake(profile, ANODE_MIN_STAKE);
        vm.stopPrank();

        assertEq(staking.getLockedStake(bob, address(registry)), ANODE_MIN_STAKE);
    }
}

// ==================== Mock Contracts ====================

contract MockGToken is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balances[from] >= amount, "Insufficient balance");
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");

        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;

        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return allowances[owner][spender];
    }
}

contract MockGTokenStaking is IGTokenStaking {
    IERC20 public gtoken;
    mapping(address => uint256) public stakedBalances;
    mapping(address => uint256) public lockedBalances;
    mapping(address => mapping(address => uint256)) public lockedByLocker;
    mapping(address => bool) public authorizedLockers;

    constructor(address _gtoken) {
        gtoken = IERC20(_gtoken);
    }

    function addLocker(address locker) external {
        authorizedLockers[locker] = true;
    }

    function stake(uint256 amount) external returns (uint256) {
        gtoken.transferFrom(msg.sender, address(this), amount);
        stakedBalances[msg.sender] += amount;
        return amount;
    }

    function stakeFor(address beneficiary, uint256 amount) external returns (uint256) {
        gtoken.transferFrom(msg.sender, address(this), amount);
        stakedBalances[beneficiary] += amount;
        return amount;
    }

    function lockStake(address user, uint256 amount, string memory) external {
        require(authorizedLockers[msg.sender], "Not authorized locker");
        uint256 available = stakedBalances[user] - lockedBalances[user];
        require(available >= amount, "Insufficient available balance");

        lockedBalances[user] += amount;
        lockedByLocker[user][msg.sender] += amount;
    }

    function unlockStake(address user, uint256 amount, string memory) external {
        require(authorizedLockers[msg.sender], "Not authorized locker");
        require(lockedByLocker[user][msg.sender] >= amount, "Insufficient locked balance");

        lockedBalances[user] -= amount;
        lockedByLocker[user][msg.sender] -= amount;
    }

    function stakedBalance(address user) external view returns (uint256) {
        return stakedBalances[user];
    }

    function availableBalance(address user) external view returns (uint256) {
        return stakedBalances[user] - lockedBalances[user];
    }

    function lockedStake(address user) external view returns (uint256) {
        return lockedBalances[user];
    }

    function getLockedStake(address user, address locker) external view returns (uint256) {
        return lockedByLocker[user][locker];
    }

    function isLocker(address locker) external view returns (bool) {
        return authorizedLockers[locker];
    }

    function slash(address, uint256, string memory) external pure returns (uint256) {
        return 0;
    }

    // Additional required interface implementations
    function balanceOf(address user) external view returns (uint256) {
        return stakedBalances[user];
    }

    function unlockStake(address user, uint256 grossAmount) external returns (uint256 netAmount) {
        require(authorizedLockers[msg.sender], "Not authorized locker");
        require(lockedByLocker[user][msg.sender] >= grossAmount, "Insufficient locked balance");

        lockedBalances[user] -= grossAmount;
        lockedByLocker[user][msg.sender] -= grossAmount;

        return grossAmount; // No fee in mock
    }

    function previewExitFee(address, address) external pure returns (uint256 fee, uint256 netAmount) {
        return (0, 0); // No fee in mock
    }
}
