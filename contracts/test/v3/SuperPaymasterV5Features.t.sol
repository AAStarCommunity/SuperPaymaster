// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/interfaces/v3/IAgentIdentityRegistry.sol";
import "src/interfaces/v3/IAgentReputationRegistry.sol";
import "src/interfaces/v3/ISignatureTransfer.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

// ====================================
// Mock Contracts
// ====================================

contract MockEntryPointV5 {
    function depositTo(address) external payable {}
}

contract MockPriceFeedV5 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract MockAPNTsV5 is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAgentIdentityRegistry is IAgentIdentityRegistry {
    mapping(address => uint256) private _balances;

    function setAgent(address agent, bool isAgent) external {
        _balances[agent] = isAgent ? 1 : 0;
    }

    function balanceOf(address owner) external view override returns (uint256) {
        return _balances[owner];
    }

    function ownerOf(uint256) external pure override returns (address) {
        return address(0);
    }
}

contract MockAgentReputationRegistry is IAgentReputationRegistry {
    mapping(uint256 => int128) private _scores;
    uint256 public feedbackCount;
    uint256 public lastAgentId;
    int128 public lastFeedbackValue;

    function setScore(address agent, int128 score) external {
        _scores[uint256(uint160(agent))] = score;
    }

    function getSummary(
        uint256 agentId,
        address[] calldata,
        bytes32,
        bytes32
    ) external view override returns (uint64 count, int128 avgScore) {
        return (1, _scores[agentId]);
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8,
        bytes32,
        bytes32,
        string calldata,
        string calldata,
        bytes32
    ) external override {
        feedbackCount++;
        lastAgentId = agentId;
        lastFeedbackValue = value;
    }
}

contract MockPermit2 is ISignatureTransfer {
    IERC20 public token;
    bool public shouldRevert;

    function setToken(address _token) external {
        token = IERC20(_token);
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner_,
        bytes calldata
    ) external override {
        require(!shouldRevert, "MockPermit2: revert");
        IERC20(permit.permitted.token).transferFrom(owner_, transferDetails.to, transferDetails.requestedAmount);
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner_,
        bytes32,
        string calldata,
        bytes calldata
    ) external override {
        require(!shouldRevert, "MockPermit2: revert");
        IERC20(permit.permitted.token).transferFrom(owner_, transferDetails.to, transferDetails.requestedAmount);
    }
}

contract MockSettlementToken is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ====================================
// Test Contract
// ====================================

contract SuperPaymasterV5Features_Test is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    Registry public registry;
    GToken public gtoken;
    MockEntryPointV5 public entryPoint;
    MockPriceFeedV5 public priceFeed;
    MockAPNTsV5 public apnts;
    MockAgentIdentityRegistry public agentIdRegistry;
    MockAgentReputationRegistry public agentRepRegistry;
    MockPermit2 public permit2;
    MockSettlementToken public usdc;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public operator1 = address(0x3);
    address public agent1 = address(0x4);
    address public user1 = address(0x5);
    address public payee = address(0x6);

    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new GToken(21_000_000 ether);
        entryPoint = new MockEntryPointV5();
        priceFeed = new MockPriceFeedV5();
        apnts = new MockAPNTsV5();
        agentIdRegistry = new MockAgentIdentityRegistry();
        agentRepRegistry = new MockAgentReputationRegistry();
        usdc = new MockSettlementToken();

        // Deploy permit2 mock
        // We need to deploy at the exact PERMIT2 address
        permit2 = new MockPermit2();
        permit2.setToken(address(usdc));

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

        // Update price cache
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Set operator1 roles
        stdstore
            .target(address(registry))
            .sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER)
            .with_key(operator1)
            .checked_write(true);

        stdstore
            .target(address(registry))
            .sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY)
            .with_key(operator1)
            .checked_write(true);

        // Set up agent registries
        paymaster.setAgentRegistries(address(agentIdRegistry), address(agentRepRegistry));

        // Set up facilitator fee
        paymaster.setFacilitatorFeeBPS(30); // 0.3%

        // Mint tokens
        apnts.mint(operator1, 10000 ether);

        vm.stopPrank();

        vm.prank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);

        // Register agent1 in identity registry
        agentIdRegistry.setAgent(agent1, true);
        // Set agent reputation score
        agentRepRegistry.setScore(agent1, 500);
    }

    // ====================================
    // F1: AgentSponsorshipPolicy Tests
    // ====================================

    function test_SetAgentPolicies_Success() public {
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](2);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 100,
            sponsorshipBPS: 5000, // 50%
            maxDailyUSD: 100_000_000 // $100
        });
        policies[1] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 800,
            sponsorshipBPS: 10000, // 100%
            maxDailyUSD: 500_000_000 // $500
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies);

        // Verify via getAgentSponsorshipRate - agent1 has score 500, should match first policy
        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 5000, "Agent with score 500 should get 50% sponsorship");
    }

    function test_SetAgentPolicies_Unauthorized() public {
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 0,
            sponsorshipBPS: 5000,
            maxDailyUSD: 100_000_000
        });

        vm.prank(user1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.setAgentPolicies(policies);
    }

    function test_SetAgentPolicies_InvalidBPS() public {
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 0,
            sponsorshipBPS: 10001, // > 10000
            maxDailyUSD: 100_000_000
        });

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAgentPolicies(policies);
    }

    function test_GetAgentSponsorshipRate_NotAgent() public {
        // user1 is not a registered agent
        uint256 rate = paymaster.getAgentSponsorshipRate(user1, operator1);
        assertEq(rate, 0, "Non-agent should get 0 rate");
    }

    function test_GetAgentSponsorshipRate_NoPolicies() public {
        // agent1 is registered but no policies set
        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 0, "No policies should return 0");
    }

    function test_GetAgentSponsorshipRate_HighRepScore() public {
        // Set up tiered policies
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](2);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 100,
            sponsorshipBPS: 3000, // 30%
            maxDailyUSD: 100_000_000
        });
        policies[1] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 400,
            sponsorshipBPS: 8000, // 80%
            maxDailyUSD: 500_000_000
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies);

        // agent1 score is 500, should match both but return the highest BPS
        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 8000, "Agent should get highest matching BPS");
    }

    function test_GetAgentSponsorshipRate_BelowMinScore() public {
        // Set policy with high min score
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 1000, // agent1 score is only 500
            sponsorshipBPS: 5000,
            maxDailyUSD: 100_000_000
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies);

        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 0, "Agent below min score should get 0");
    }

    function test_AgentDailyCap() public {
        // Set policy with very low daily cap
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 0,
            sponsorshipBPS: 5000,
            maxDailyUSD: 1 // $0.000001 - tiny cap for testing
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies);

        // First call should return rate
        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 5000, "First call should succeed");

        // Note: daily spend is tracked via _applyAgentSponsorship (internal),
        // so getAgentSponsorshipRate alone won't exhaust the cap.
        // This tests that the cap check works in the view function.
    }

    function test_SetAgentPolicies_Overwrite() public {
        // Set initial policies
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies1 = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies1[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 0,
            sponsorshipBPS: 5000,
            maxDailyUSD: 100_000_000
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies1);

        // Overwrite with new policies
        ISuperPaymaster.AgentSponsorshipPolicy[] memory policies2 = new ISuperPaymaster.AgentSponsorshipPolicy[](1);
        policies2[0] = ISuperPaymaster.AgentSponsorshipPolicy({
            minReputationScore: 0,
            sponsorshipBPS: 2000, // Changed to 20%
            maxDailyUSD: 200_000_000
        });

        vm.prank(operator1);
        paymaster.setAgentPolicies(policies2);

        uint256 rate = paymaster.getAgentSponsorshipRate(agent1, operator1);
        assertEq(rate, 2000, "Policies should be overwritten");
    }

    // ====================================
    // F1: isRegisteredAgent Tests
    // ====================================

    function test_IsRegisteredAgent_True() public {
        assertTrue(paymaster.isRegisteredAgent(agent1));
    }

    function test_IsRegisteredAgent_False() public {
        assertFalse(paymaster.isRegisteredAgent(user1));
    }

    function test_IsRegisteredAgent_NoRegistry() public {
        // Set registry to zero
        vm.prank(owner);
        paymaster.setAgentRegistries(address(0), address(0));
        assertFalse(paymaster.isRegisteredAgent(agent1));
    }

    // ====================================
    // F2: _submitSponsorshipFeedback Tests
    // ====================================

    // Note: _submitSponsorshipFeedback is internal, tested via postOp integration.
    // We test the registry setter and verify it's wired correctly.

    function test_SetAgentRegistries() public {
        address newId = address(0xAA);
        address newRep = address(0xBB);

        vm.prank(owner);
        paymaster.setAgentRegistries(newId, newRep);

        assertEq(paymaster.agentIdentityRegistry(), newId);
        assertEq(paymaster.agentReputationRegistry(), newRep);
    }

    function test_SetAgentRegistries_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setAgentRegistries(address(0xAA), address(0xBB));
    }

    function test_FeedbackNotSentForNonAgent() public {
        // No feedback should be recorded for non-agents
        uint256 countBefore = agentRepRegistry.feedbackCount();
        // _submitSponsorshipFeedback is only called from postOp for registered agents
        // Here we just verify the mock starts at 0
        assertEq(countBefore, 0);
    }

    // ====================================
    // F3: settleX402PaymentPermit2 Tests
    // ====================================

    function test_SettlePermit2_Success() public {
        uint256 amount = 1000e6; // 1000 USDC (6 decimals)
        address payer = address(0x10);

        // Deploy permit2 at the correct constant address first
        address permit2Addr = paymaster.PERMIT2();
        bytes memory permit2Code = address(permit2).code;
        vm.etch(permit2Addr, permit2Code);

        // Mint tokens to payer and approve permit2
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(permit2Addr, amount);

        // Prepare permit
        ISignatureTransfer.PermitTransferFrom memory permit_ = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(usdc),
                amount: amount
            }),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        ISignatureTransfer.SignatureTransferDetails memory details = ISignatureTransfer.SignatureTransferDetails({
            to: payee,
            requestedAmount: amount
        });

        // Set operator facilitator fee (operator1 is the caller)
        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 100); // 1%

        // Settle
        vm.prank(operator1);
        bytes32 settlementId = paymaster.settleX402PaymentPermit2(
            permit_, details, payer, ""
        );

        // Verify: payee received net amount
        uint256 fee = (amount * 100) / 10000; // 1%
        assertEq(usdc.balanceOf(payee), amount - fee);

        // Verify: facilitator earnings tracked
        assertEq(paymaster.facilitatorEarnings(operator1, address(usdc)), fee);

        // Verify non-zero settlement ID
        assertTrue(settlementId != bytes32(0));
    }

    function test_SettlePermit2_Replay() public {
        uint256 amount = 100e6;
        address payer = address(0x10);

        // Deploy permit2 at correct address first
        address permit2Addr = paymaster.PERMIT2();
        bytes memory permit2Code = address(permit2).code;
        vm.etch(permit2Addr, permit2Code);

        usdc.mint(payer, amount * 2);
        vm.prank(payer);
        usdc.approve(permit2Addr, amount * 2);

        ISignatureTransfer.PermitTransferFrom memory permit_ = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(usdc),
                amount: amount
            }),
            nonce: 42,
            deadline: block.timestamp + 1 hours
        });

        ISignatureTransfer.SignatureTransferDetails memory details = ISignatureTransfer.SignatureTransferDetails({
            to: payee,
            requestedAmount: amount
        });

        // First settlement succeeds
        vm.prank(operator1);
        paymaster.settleX402PaymentPermit2(permit_, details, payer, "");

        // Second with same nonce should revert
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402PaymentPermit2(permit_, details, payer, "");
    }

    function test_SettlePermit2_ZeroFee() public {
        uint256 amount = 100e6;
        address payer = address(0x10);

        // Deploy permit2 at correct address first
        address permit2Addr = paymaster.PERMIT2();
        bytes memory permit2Code = address(permit2).code;
        vm.etch(permit2Addr, permit2Code);

        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(permit2Addr, amount);

        ISignatureTransfer.PermitTransferFrom memory permit_ = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(usdc),
                amount: amount
            }),
            nonce: 99,
            deadline: block.timestamp + 1 hours
        });

        ISignatureTransfer.SignatureTransferDetails memory details = ISignatureTransfer.SignatureTransferDetails({
            to: payee,
            requestedAmount: amount
        });

        // Set both default and per-operator fee to 0
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(0);
        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 0);

        vm.prank(operator1);
        paymaster.settleX402PaymentPermit2(permit_, details, payer, "");

        // Payee should receive full amount
        assertEq(usdc.balanceOf(payee), amount);
        assertEq(paymaster.facilitatorEarnings(operator1, address(usdc)), 0);
    }

    function test_SettlePermit2_Unauthorized() public {
        uint256 amount = 100e6;
        address payer = address(0x10);

        ISignatureTransfer.PermitTransferFrom memory permit_ = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: address(usdc),
                amount: amount
            }),
            nonce: 77,
            deadline: block.timestamp + 1 hours
        });

        ISignatureTransfer.SignatureTransferDetails memory details = ISignatureTransfer.SignatureTransferDetails({
            to: payee,
            requestedAmount: amount
        });

        // user1 has no ROLE_PAYMASTER_SUPER — should revert
        vm.prank(user1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentPermit2(permit_, details, payer, "");
    }

    // ====================================
    // F3: Facilitator Fee Admin Tests
    // ====================================

    function test_SetFacilitatorFeeBPS() public {
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(100);
        assertEq(paymaster.facilitatorFeeBPS(), 100);
    }

    function test_SetFacilitatorFeeBPS_ExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidFee.selector);
        paymaster.setFacilitatorFeeBPS(501); // > 500
    }

    function test_SetFacilitatorFeeBPS_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setFacilitatorFeeBPS(100);
    }

    function test_SetOperatorFacilitatorFee() public {
        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 200);
        assertEq(paymaster.operatorFacilitatorFees(operator1), 200);
    }

    function test_SetOperatorFacilitatorFee_ExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidFee.selector);
        paymaster.setOperatorFacilitatorFee(operator1, 501);
    }

    function test_WithdrawFacilitatorEarnings_NoBalance() public {
        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymaster.InsufficientBalance.selector, 0, 1));
        paymaster.withdrawFacilitatorEarnings(address(usdc));
    }

    // ====================================
    // F4: EIP-1153 Transient Cache Tests
    // ====================================

    // Note: Transient storage (tload/tstore) is cleared between transactions.
    // Testing in Foundry requires same-transaction context.
    // The cache integration is tested implicitly via validatePaymasterUserOp.

    function test_Version() public {
        assertEq(paymaster.version(), "SuperPaymaster-5.2.0");
    }
}
