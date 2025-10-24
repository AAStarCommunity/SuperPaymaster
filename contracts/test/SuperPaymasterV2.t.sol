// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/Registry.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import "../../src/paymasters/v2/tokens/MySBT.sol";
import "../../src/paymasters/v2/monitoring/DVTValidator.sol";
import "../../src/paymasters/v2/monitoring/BLSAggregator.sol";

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
    GTokenStaking public gtokenStaking;
    Registry public registry;
    SuperPaymasterV2 public superPaymaster;
    xPNTsFactory public xpntsFactory;
    MySBT public mysbt;
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

        // Deploy core contracts
        gtokenStaking = new GTokenStaking(address(gtoken));
        registry = new Registry();
        superPaymaster = new SuperPaymasterV2(
            address(gtokenStaking),
            address(registry)
        );

        // Configure aPNTs token
        superPaymaster.setAPNTsToken(address(apntsToken));

        // Deploy token system
        xpntsFactory = new xPNTsFactory(
            address(superPaymaster),
            address(registry)
        );
        mysbt = new MySBT(
            address(gtoken),
            address(gtokenStaking)
        );

        // Deploy monitoring system
        dvtValidator = new DVTValidator(address(superPaymaster));
        blsAggregator = new BLSAggregator(
            address(superPaymaster),
            address(dvtValidator)
        );

        // Initialize connections
        gtokenStaking.setSuperPaymaster(address(superPaymaster));
        mysbt.setSuperPaymaster(address(superPaymaster));
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
        assertEq(account.sGTokenLocked, 50 ether);
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
            "mydao.eth"
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
            "mydao.eth"
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
            "defi.eth"
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

        // v2.0-beta: User must first stake GT to get sGToken
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);  // Get 1 sGToken

        // Then approve GT for mint fee burn
        gtoken.approve(address(mysbt), 0.1 ether);

        // Mint SBT (will lock 0.3 sGToken)
        uint256 tokenId = mysbt.mintSBT(community1);

        assertTrue(tokenId > 0);
        assertEq(mysbt.ownerOf(tokenId), user1);
        assertTrue(mysbt.hasSBT(user1, community1));

        // Verify sGToken is locked
        assertEq(gtokenStaking.lockedBalanceBy(user1, address(mysbt)), 0.3 ether);
        assertEq(gtokenStaking.availableBalance(user1), 0.7 ether);

        vm.stopPrank();

        // Verify community data
        MySBT.CommunityData memory data = mysbt.getCommunityData(user1, community1);
        assertEq(data.community, community1);
        assertEq(data.txCount, 0);
        assertEq(data.contributionScore, 0);
    }

    function test_SBTNonTransferable() public {
        // Mint SBT
        vm.startPrank(user1);
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);
        gtoken.approve(address(mysbt), 0.1 ether);
        uint256 tokenId = mysbt.mintSBT(community1);
        vm.stopPrank();

        // Try to transfer (should fail)
        vm.prank(user1);
        vm.expectRevert(MySBT.TransferNotAllowed.selector);
        mysbt.transferFrom(user1, user2, tokenId);
    }

    function test_SBTActivityUpdate() public {
        // Mint SBT
        vm.startPrank(user1);
        gtoken.approve(address(gtokenStaking), 1 ether);
        gtokenStaking.stake(1 ether);
        gtoken.approve(address(mysbt), 0.1 ether);
        mysbt.mintSBT(community1);
        vm.stopPrank();

        // SuperPaymaster updates activity
        mysbt.setSuperPaymaster(address(this)); // Set test contract as SuperPaymaster
        mysbt.updateActivity(user1, community1, 0.001 ether);

        // Verify updated data
        MySBT.CommunityData memory data = mysbt.getCommunityData(user1, community1);
        assertEq(data.txCount, 1);
        assertEq(data.contributionScore, 1); // 0.001 ether / 1e15 = 1

        MySBT.UserProfile memory profile = mysbt.getUserProfile(user1);
        assertEq(profile.reputationScore, 1);
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
            "test.eth"
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

        // v2.0-beta: User must first stake GT to get sGToken
        gtoken.approve(address(gtokenStaking), 2 ether);
        gtokenStaking.stake(2 ether);  // Get 2 sGToken (enough for 2 mint attempts)

        // Approve GT for mint fees
        gtoken.approve(address(mysbt), 1 ether);

        mysbt.mintSBT(community1);

        // Try to mint again for same community (should fail)
        vm.expectRevert();
        mysbt.mintSBT(community1);
        vm.stopPrank();
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
