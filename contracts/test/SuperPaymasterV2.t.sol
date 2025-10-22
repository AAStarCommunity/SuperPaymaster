// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/v2/core/Registry.sol";
import "../../src/v2/core/GTokenStaking.sol";
import "../../src/v2/core/SuperPaymasterV2.sol";
import "../../src/v2/tokens/xPNTsFactory.sol";
import "../../src/v2/tokens/xPNTsToken.sol";
import "../../src/v2/tokens/MySBT.sol";
import "../../src/v2/monitoring/DVTValidator.sol";
import "../../src/v2/monitoring/BLSAggregator.sol";

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

    // ====================================
    // Setup
    // ====================================

    function setUp() public {
        // Deploy GToken
        gtoken = new MockERC20("GToken", "GT", 18);

        // Deploy core contracts
        gtokenStaking = new GTokenStaking(address(gtoken));
        registry = new Registry();
        superPaymaster = new SuperPaymasterV2(
            address(gtokenStaking),
            address(registry)
        );

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
        mysbt.setSuperPaymaster(address(superPaymaster));
        superPaymaster.setDVTAggregator(address(blsAggregator));
        dvtValidator.setBLSAggregator(address(blsAggregator));

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

        // Lock stake for SuperPaymaster
        gtokenStaking.approve(address(superPaymaster), 50 ether);

        // Register operator
        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(
            50 ether,
            sbts,
            address(0) // Will set xPNTs token later
        );

        vm.stopPrank();

        // Verify registration
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator1);
        assertEq(account.sGTokenLocked, 50 ether);
        assertEq(account.reputationLevel, 1);
        assertFalse(account.isPaused);
    }

    function testFail_RegistrationInsufficientStake() public {
        // Try to register with insufficient stake
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 20 ether);
        gtokenStaking.stake(20 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        // Should fail: MIN_STAKE = 30 GT
        superPaymaster.registerOperator(
            20 ether,
            sbts,
            address(0)
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
            100,        // avgDailyTx
            0.001 ether, // avgGasCost
            "DeFi",     // industry (2.0x multiplier)
            1.5 ether   // safetyFactor
        );

        // Get prediction
        uint256 suggested = xpntsFactory.predictDepositAmount(community1);

        // Expected: 100 * 0.001 * 30 * 2.0 * 1.5 = 9 ether
        assertEq(suggested, 9 ether);

        vm.stopPrank();
    }

    // ====================================
    // MySBT Tests
    // ====================================

    function test_SBTMinting() public {
        // User mints SBT
        vm.startPrank(user1);
        gtoken.approve(address(mysbt), 0.3 ether);

        uint256 tokenId = mysbt.mintSBT(community1);

        assertTrue(tokenId > 0);
        assertEq(mysbt.ownerOf(tokenId), user1);
        assertTrue(mysbt.hasSBT(user1, community1));

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
        gtoken.approve(address(mysbt), 0.3 ether);
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
        gtoken.approve(address(mysbt), 0.3 ether);
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
        gtokenStaking.approve(address(superPaymaster), 50 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(
            50 ether,
            sbts,
            tokenAddr
        );

        // Deposit aPNTs
        superPaymaster.depositAPNTs(500 ether);

        vm.stopPrank();

        // Verify balance
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator1);
        assertEq(account.aPNTsBalance, 500 ether);
        assertEq(token.balanceOf(operator1), 500 ether); // 500 xPNTs burned
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
        gtokenStaking.approve(address(superPaymaster), 50 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(50 ether, sbts, address(0));
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

    function testFail_DoubleRegistration() public {
        vm.startPrank(operator1);
        gtoken.approve(address(gtokenStaking), 100 ether);
        gtokenStaking.stake(100 ether);
        gtokenStaking.approve(address(superPaymaster), 50 ether);

        address[] memory sbts = new address[](1);
        sbts[0] = address(mysbt);

        superPaymaster.registerOperator(50 ether, sbts, address(0));

        // Try to register again (should fail)
        superPaymaster.registerOperator(50 ether, sbts, address(0));
        vm.stopPrank();
    }

    function testFail_DepositWithoutRegistration() public {
        vm.prank(operator1);
        superPaymaster.depositAPNTs(100 ether);
    }

    function testFail_SBTDoubleMint() public {
        vm.startPrank(user1);
        gtoken.approve(address(mysbt), 1 ether);

        mysbt.mintSBT(community1);

        // Try to mint again for same community (should fail)
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
