// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/Registry.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBT_v2.4.0.sol";
import "../../src/paymasters/v2/monitoring/DVTValidator.sol";
import "../../src/paymasters/v2/monitoring/BLSAggregator.sol";
import "./mocks/MockChainlinkAggregator.sol";

/**
 * @title SuperPaymasterV2Test
 * @notice E2E integration tests for SuperPaymaster v2.0
 * @dev Tests complete user flow: registration → deposit → sponsorship → slash
 */
contract SuperPaymasterV2Test is Test {

    // ====================================
    // Contracts
    // ====================================

    MockERC20 public gtoken;
    MockERC20 public apntsToken;  // AAStar community token
    MockChainlinkAggregator public ethUsdPriceFeed;  // Chainlink ETH/USD price feed mock
    GTokenStaking public gtokenStaking;
    Registry public registry;
    SuperPaymasterV2 public superPaymaster;
    xPNTsFactory public xpntsFactory;
    MySBT_v2_4_0 public mysbt;
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    // ====================================
    // Test Accounts
    // ====================================

    address public owner = address(this);
    address public operator1 = address(0x1);
    address public operator2 = address(0x2);
    address public user1 = address(0x101);
    address public user2 = address(0x102);
    address public community1 = address(0x201);
    address public validator1 = address(0x301);
    address public validator2 = address(0x302);
    address public validator3 = address(0x303);
    address public treasury1 = address(0x401); // Treasury for operator1
    address public treasury2 = address(0x402); // Treasury for operator2

    // ====================================
    // Setup
    // ====================================

    function setUp() public {
        // Deploy GToken
        gtoken = new MockERC20("GToken", "GT", 18);

        // Deploy aPNTs token (AAStar community token)
        apntsToken = new MockERC20("AAStar Points", "aPNTs", 18);

        // Deploy Chainlink ETH/USD price feed mock (8 decimals, $3000/ETH)
        ethUsdPriceFeed = new MockChainlinkAggregator(8, 3000 * 10**8);

        // Deploy core contracts
        gtokenStaking = new GTokenStaking(address(gtoken));
        registry = new Registry(address(gtokenStaking));
        superPaymaster = new SuperPaymasterV2(
            address(gtokenStaking),
            address(registry),
            address(ethUsdPriceFeed)
        );

        // Configure aPNTs token
        superPaymaster.setAPNTsToken(address(apntsToken));

        // Deploy token system
        xpntsFactory = new xPNTsFactory(
            address(superPaymaster),
            address(registry)
        );
        mysbt = new MySBT_v2_4_0(
            address(gtoken),
            address(gtokenStaking),
            address(registry),
            owner  // dao address
        );

        // Deploy monitoring system
        dvtValidator = new DVTValidator(address(superPaymaster));
        blsAggregator = new BLSAggregator(
            address(superPaymaster),
            address(dvtValidator)
        );

        // Initialize connections
        gtokenStaking.authorizeSlasher(address(superPaymaster), true);
        gtokenStaking.authorizeSlasher(address(registry), true);
        // Note: MySBT v2.4.0 no longer requires setSuperPaymaster()
        superPaymaster.setDVTAggregator(address(blsAggregator));
        dvtValidator.setBLSAggregator(address(blsAggregator));

        // Configure lock system and exit fees (v2.0-beta)
        gtokenStaking.setTreasury(owner);

        // Configure MySBT locker (flat 0.1 sGT exit fee)
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        gtokenStaking.configureLocker(
            address(mysbt),
            true,           // authorized
            0.1 ether,     // baseExitFee
            emptyTiers,
            emptyFees,
            address(0)
        );

        // Configure SuperPaymaster locker (tiered exit fees)
        uint256[] memory spTiers = new uint256[](3);
        spTiers[0] = 90 days;
        spTiers[1] = 180 days;
        spTiers[2] = 365 days;
        uint256[] memory spFees = new uint256[](4);
        spFees[0] = 15 ether;
        spFees[1] = 10 ether;
        spFees[2] = 7 ether;
        spFees[3] = 5 ether;
        gtokenStaking.configureLocker(
            address(superPaymaster),
            true,
            0,
            spTiers,
            spFees,
            address(0)
        );

        // Mint GToken to test accounts
        gtoken.mint(operator1, 1000 ether);
        gtoken.mint(operator2, 1000 ether);
        gtoken.mint(user1, 100 ether);
        gtoken.mint(user2, 100 ether);
        gtoken.mint(community1, 1000 ether);

        // Mock Registry.isRegisteredCommunity for community1 (required for MySBT v2.4.0)
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community1),
            abi.encode(true)
        );
    }

    // ====================================
    // Registration Tests
    // ====================================

    function test_OperatorRegistration() public {
        // Operator stakes GT
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 100 ether);
        gtokenStaking.stake(100 ether);

        // Register operator
        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(
            50 ether,
            sbts,
            address(0), // Will set xPNTs token later
            treasury1   // Treasury address for operator1
        );
        vm.stopPrank();

        // Verify registration
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator1);
        assertEq(account.stGTokenLocked, 50 ether);
        assertEq(account.reputationLevel, 1);
        assertFalse(account.isPaused);
    }

    function test_RevertWhen_RegistrationInsufficientStake() public {
        // v2.0-beta: GTokenStaking MIN_STAKE = 0.01 GT (Lido-like)
        // But SuperPaymaster minOperatorStake = 30 sGT

        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 20 ether);
        gtokenStaking.stake(20 ether);  // Get 20 sGT (enough for GTokenStaking, but not for operator)

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        // Should fail: minOperatorStake = 30 sGT, but only have 20 sGT
        vm.expectRevert();
        superPaymaster.registerOperator(
            20 ether,  // Trying to register with 20 sGT (insufficient)
            sbts,
            address(0),
            treasury1
        );

        vm.stopPrank();
    }

    // ====================================
    // xPNTs Token Tests
    // ====================================

    function test_XPNTsDeployment() public {
        vm.startPrank(community1);

        // Deploy xPNTs token
        address tokenAddr = xpntsFactory.deployxPNTsToken(
            "MyDAO Points",
            "xMDAO",
            "MyDAO Community",
            "mydao.eth",
            1 ether,       // exchangeRate: 1:1 with aPNTs
            address(0)     // paymasterAOA: not using AOA mode
        );

        assertTrue(tokenAddr != address(0));
        assertTrue(xpntsFactory.hasToken(community1));

        xPNTsToken token = xPNTsToken(tokenAddr);
        assertEq(token.name(), "MyDAO Points");
        assertEq(token.symbol(), "xMDAO");
        assertEq(token.communityOwner(), community1);

        vm.stopPrank();
    }

    function test_XPNTsPreAuthorization() public {
        // Deploy token
        vm.startPrank(community1);
        address tokenAddr = xpntsFactory.deployxPNTsToken(
            "MyDAO Points",
            "xMDAO",
            "MyDAO",
            "mydao.eth",
            1 ether,       // exchangeRate: 1:1 with aPNTs
            address(0)     // paymasterAOA: not using AOA mode
        );
        xPNTsToken token = xPNTsToken(tokenAddr);

        // Mint tokens to user
        token.mint(user1, 1000 ether);
        vm.stopPrank();

        // Check pre-authorization
        uint256 allowance = token.allowance(user1, address(superPaymaster));
        assertEq(allowance, type(uint256).max); // Infinite allowance!

        // User can burn without approve
        vm.prank(address(superPaymaster));
        token.burn(user1, 100 ether);

        assertEq(token.balanceOf(user1), 900 ether);
    }

    function test_XPNTsAIPrediction() public {
        vm.startPrank(community1);

        // Deploy token
        xpntsFactory.deployxPNTsToken(
            "DeFi DAO Points",
            "xDEFI",
            "DeFi DAO",
            "defi.eth",
            1 ether,       // exchangeRate: 1:1 with aPNTs
            address(0)     // paymasterAOA: not using AOA mode
        );

        // Update prediction parameters
        xpntsFactory.updatePrediction(
            1000,       // avgDailyTx
            0.01 ether, // avgGasCost
            "DeFi",     // industry (2.0x multiplier)
            1.5 ether   // safetyFactor
        );

        // Get prediction
        uint256 suggested = xpntsFactory.predictDepositAmount(community1);

        // Expected: 1000 * 0.01 * 30 * 2.0 * 1.5 = 900 ether
        assertEq(suggested, 900 ether);

        vm.stopPrank();
    }

    // ====================================
    // MySBT Tests
    // ====================================

    function test_SBTMinting() public {
        vm.startPrank(user1);

        // v2.0-beta: User must first stake GT to get stGToken
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);  // Get 1 stGToken

        // Then approve GT for mint fee burn
        gtoken.approve(address(mysbt), 0.1 ether);
        vm.stopPrank();

        // Mint SBT via community (v2.4.0: community calls mintOrAddMembership)
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        vm.startPrank(user1);

        assertTrue(tokenId > 0);
        assertEq(mysbt.ownerOf(tokenId), user1);
        assertTrue(mysbt.verifyCommunityMembership(user1, community1));

        // Note: MySBT v2.4.0 removed stGToken locking mechanism

        vm.stopPrank();

        // NOTE: MySBTWithNFTBinding v2.1-beta uses NFT binding model instead of CommunityData
        // Community-specific activity tracking (txCount, contributionScore) will be implemented
        // in a future version. Current version focuses on membership verification via NFT binding.
        // Verification: verifyCommunityMembership() confirmed working above (line 290)
    }

    function test_SBTNonTransferable() public {
        // Mint SBT
        vm.startPrank(user1);
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);
        gtoken.approve(address(mysbt), 0.1 ether);
        vm.stopPrank();

        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        // Try to transfer (should fail)
        vm.prank(user1);
        vm.expectRevert(MySBT_v2_4_0.TransferNotAllowed.selector);
        mysbt.transferFrom(user1, user2, tokenId);
    }

    function test_SBTActivityUpdate() public {
        // Mint SBT
        vm.startPrank(user1);
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);
        gtoken.approve(address(mysbt), 0.1 ether);
        vm.stopPrank();

        vm.prank(community1);
        mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        // NOTE: MySBT v2.4.0 removed setSuperPaymaster() and activity tracking functions
        // Activity metrics are not tracked in v2.4.0, focusing on NFT binding reputation instead

        // NOTE: MySBTWithNFTBinding v2.1-beta does not track per-community activity metrics
        // The updateActivity() function exists but does not maintain CommunityData or UserProfile structs
        // Future versions will implement reputation scoring and contribution tracking
        // Current version focuses on SBT ownership and NFT binding for membership verification
    }

    // ====================================
    // aPNTs Deposit Tests
    // ====================================

    function test_APNTsDeposit() public {
        // Setup operator with xPNTs token
        vm.startPrank(community1);
        address tokenAddr = xpntsFactory.deployxPNTsToken(
            "Test Points",
            "xTEST",
            "Test",
            "test.eth",
            1 ether,       // exchangeRate: 1:1 with aPNTs
            address(0)     // paymasterAOA: not using AOA mode
        );
        xPNTsToken token = xPNTsToken(tokenAddr);
        token.mint(operator1, 1000 ether);
        vm.stopPrank();

        // Register operator
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 100 ether);
        gtokenStaking.stake(100 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(
            50 ether,
            sbts,
            tokenAddr,
            treasury1
        );

        // Mint aPNTs (AAStar token) to operator
        vm.stopPrank();
        vm.startPrank(owner);
        apntsToken.mint(operator1, 1000 ether);
        vm.stopPrank();

        // Approve and deposit aPNTs
        vm.startPrank(operator1);
        apntsToken.approve(address(superPaymaster), 500 ether);
        superPaymaster.depositAPNTs(500 ether);

        vm.stopPrank();

        // Verify balance
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator1);
        assertEq(account.aPNTsBalance, 500 ether); // aPNTs记录在operator账户中
        assertEq(token.balanceOf(operator1), 1000 ether); // xPNTs余额不变（没有burn）
        assertEq(apntsToken.balanceOf(operator1), 500 ether); // 剩余500 aPNTs
        assertEq(apntsToken.balanceOf(address(superPaymaster)), 500 ether); // 500 aPNTs在SuperPaymaster合约中
    }

    // ====================================
    // DVT & BLS Tests
    // ====================================

    function test_ValidatorRegistration() public {
        bytes memory blsKey = abi.encodePacked(
            bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
            bytes16(0x1234567890abcdef1234567890abcdef)
        ); // 48 bytes

        dvtValidator.registerValidator(
            validator1,
            blsKey,
            "https://validator1.example.com"
        );

        DVTValidator.ValidatorInfo memory info = dvtValidator.getValidator(0);
        assertEq(info.validatorAddress, validator1);
        assertTrue(info.isActive);
    }

    function test_SlashProposalCreation() public {
        // Register validator
        bytes memory blsKey = new bytes(48);
        dvtValidator.registerValidator(validator1, blsKey, "https://validator1.example.com");

        // Create slash proposal
        vm.prank(validator1);
        uint256 proposalId = dvtValidator.createSlashProposal(
            operator1,
            1, // MINOR
            "Low aPNTs balance"
        );

        assertTrue(proposalId > 0);

        DVTValidator.SlashProposal memory proposal = dvtValidator.getProposal(proposalId);
        assertEq(proposal.operator, operator1);
        assertEq(proposal.slashLevel, 1);
        assertFalse(proposal.executed);
    }

    function test_SlashProposalSigning() public {
        // Register 7 validators
        for (uint i = 0; i < 7; i++) {
            address validatorAddr = address(uint160(0x301 + i));
            bytes memory blsKey = new bytes(48);
            dvtValidator.registerValidator(validatorAddr, blsKey, "https://validator.example.com");

            // Register BLS public key
            blsAggregator.registerBLSPublicKey(validatorAddr, blsKey);
        }

        // Validator1 creates proposal
        vm.prank(validator1);
        uint256 proposalId = dvtValidator.createSlashProposal(
            operator1,
            0, // WARNING
            "Test proposal"
        );

        // 7 validators sign
        for (uint i = 0; i < 7; i++) {
            address validatorAddr = address(uint160(0x301 + i));
            bytes memory signature = new bytes(96); // Mock BLS signature

            vm.prank(validatorAddr);
            dvtValidator.signProposal(proposalId, signature);
        }

        // Check signature count
        uint256 sigCount = dvtValidator.getSignatureCount(proposalId);
        assertEq(sigCount, 7);

        assertTrue(dvtValidator.hasEnoughSignatures(proposalId));
    }

    // ====================================
    // Reputation System Tests
    // ====================================

    function test_ReputationUpgrade() public {
        // Register operator
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 100 ether);
        gtokenStaking.stake(100 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(50 ether, sbts, address(0), treasury1);
        vm.stopPrank();

        // Simulate reputation upgrade conditions
        // (This would require extensive mocking of time and transactions)

        // Check eligibility (should be false initially)
        bool eligible = superPaymaster.isEligibleForUpgrade(operator1);
        assertFalse(eligible);
    }

    // ====================================
    // Edge Cases
    // ====================================

    function test_RevertWhen_DoubleRegistration() public {
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 100 ether);
        gtokenStaking.stake(100 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(50 ether, sbts, address(0), treasury1);

        // Try to register again (should fail)
        vm.expectRevert();
        superPaymaster.registerOperator(50 ether, sbts, address(0), treasury1);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWithoutRegistration() public {
        vm.prank(operator1);
        vm.expectRevert();
        superPaymaster.depositAPNTs(100 ether);
    }

    function test_RevertWhen_SBTDoubleMint() public {
        vm.startPrank(user1);

        // v2.0-beta: User must first stake GT to get stGToken
        gtoken.approve(address(gtokenStaking), 2 ether);
        gtokenStaking.stake(2 ether);  // Get 2 stGToken (enough for 2 mint attempts)

        // Approve GT for mint fees
        gtoken.approve(address(mysbt), 1 ether);
        vm.stopPrank();

        // Mint SBT via community
        vm.prank(community1);
        mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        // Try to mint again from same community (should fail - MembershipAlreadyExists)
        vm.prank(community1);
        vm.expectRevert(); // MySBT v2.4.0 prevents duplicate membership from same community
        mysbt.mintOrAddMembership(user1, "ipfs://metadata2");
    }
}

// ====================================
// Mock ERC20 for Testing
// ====================================

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
