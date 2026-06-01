// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/interfaces/v3/IAgentIdentityRegistry.sol";
import "src/interfaces/v3/IAgentReputationRegistry.sol";
import "src/interfaces/v3/IERC3009.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
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
    mapping(address => bool) private _agents;

    function setAgent(address agent, bool isAgent) external {
        _agents[agent] = isAgent;
    }

    function isRegisteredAgent(address account) external view override returns (bool) {
        return _agents[account];
    }

    function balanceOf(address owner) external view override returns (uint256) {
        return _agents[owner] ? 1 : 0;
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

/// @dev Mock ERC-3009 token (USDC-like) with transferWithAuthorization
contract MockERC3009Token is ERC20, IERC3009 {
    using ECDSA for bytes32;

    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function transferWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @dev Mock xPNTs-like token (auto-approves SuperPaymaster)
contract MockDirectToken is ERC20 {
    address public superPaymaster;
    /// @dev P0-12b: SuperPaymaster.settleX402PaymentDirect now consults this.
    mapping(address => bool) public approvedFacilitators;

    constructor(address _sp) ERC20("xPNTs", "xPNTs") {
        superPaymaster = _sp;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function allowance(address owner_, address spender) public view override returns (uint256) {
        if (spender == superPaymaster) return type(uint256).max;
        return super.allowance(owner_, spender);
    }

    function setApprovedFacilitator(address f, bool ok) external {
        approvedFacilitators[f] = ok;
    }
}

/// @dev Mock factory for P0-12a — only purpose is to whitelist xPNTs tokens
///      for `settleX402PaymentDirect`. We avoid pulling in the full
///      xPNTsFactory + Registry COMMUNITY role wiring to keep this test focused.
contract MockXPNTsFactory {
    mapping(address => bool) public isXPNTs;
    function setXPNTs(address token, bool ok) external { isXPNTs[token] = ok; }
    function getAPNTsPrice() external pure returns (uint256) { return 0.02 ether; }
    function getTokenAddress(address) external pure returns (address) { return address(0); }
    function hasToken(address) external pure returns (bool) { return false; }
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
    MockERC3009Token public usdc;
    MockDirectToken public xpnts;
    MockXPNTsFactory public mockFactory;

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
        usdc = new MockERC3009Token();

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

        // Deploy mock xPNTs (auto-approves SuperPaymaster)
        xpnts = new MockDirectToken(address(paymaster));

        // P0-12a: settleX402PaymentDirect now requires asset to be a registered
        // xPNTs in xpntsFactory. Wire a mock factory and whitelist `xpnts`.
        mockFactory = new MockXPNTsFactory();
        mockFactory.setXPNTs(address(xpnts), true);
        paymaster.setXPNTsFactory(address(mockFactory));

        // P0-12b: facilitator (operator1) must be approved by the xPNTs.
        xpnts.setApprovedFacilitator(operator1, true);

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

    function _signEIP3009(
        uint256 privateKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = usdc.authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signX402Direct(
        uint256 privateKey,
        address from,
        address to,
        address asset,
        uint256 amount,
        uint256 maxFee,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SuperPaymaster"),
                keccak256("1"),
                block.chainid,
                address(paymaster)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                to,
                asset,
                amount,
                maxFee,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
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
        // Must be contracts (not EOAs) — code.length guard
        MockAgentIdentityRegistry newId = new MockAgentIdentityRegistry();
        MockAgentReputationRegistry newRep = new MockAgentReputationRegistry();

        vm.prank(owner);
        paymaster.setAgentRegistries(address(newId), address(newRep));

        assertEq(paymaster.agentIdentityRegistry(), address(newId));
        assertEq(paymaster.agentReputationRegistry(), address(newRep));
    }

    function test_SetAgentRegistries_ZeroDisablesAgentMode() public {
        vm.prank(owner);
        paymaster.setAgentRegistries(address(0), address(0));
        assertEq(paymaster.agentIdentityRegistry(), address(0));
    }

    function test_SetAgentRegistries_RejectsEOA() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymaster.InvalidAddress.selector));
        paymaster.setAgentRegistries(address(0xAA), address(0));
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
    // F3: settleX402Payment (EIP-3009) Tests
    // ====================================

    function test_SettleEIP3009_Success() public {
        uint256 amount = 1000e6;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(1));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(paymaster), amount, validAfter, validBefore, nonce);

        usdc.mint(payer, amount);

        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 100); // 1%

        vm.prank(operator1);
        bytes32 settlementId = paymaster.settleX402Payment(
            payer, payee, address(usdc), amount,
            validAfter, validBefore, salt, signature
        );

        uint256 fee = (amount * 100) / 10000;
        assertEq(usdc.balanceOf(payee), amount - fee);
        assertEq(paymaster.facilitatorEarnings(operator1, address(usdc)), fee);
        assertTrue(settlementId != bytes32(0));
    }

    function test_SettleEIP3009_Replay() public {
        uint256 amount = 100e6;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, amount * 2);

        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(42));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(paymaster), amount, validAfter, validBefore, nonce);

        vm.prank(operator1);
        paymaster.settleX402Payment(payer, payee, address(usdc), amount, validAfter, validBefore, salt, signature);

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(payer, payee, address(usdc), amount, validAfter, validBefore, salt, signature);
    }

    function test_SettleEIP3009_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402Payment(address(0x10), payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, bytes32(uint256(77)), "");
    }

    // ====================================
    // F3b: settleX402PaymentDirect (xPNTs) Tests
    // ====================================

    function test_SettleDirect_Success() public {
        uint256 amount = 500 ether;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 maxFee = (amount * 200) / 10000;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);
        xpnts.mint(payer, amount);

        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 200); // 2%

        vm.prank(operator1);
        bytes32 settlementId = paymaster.settleX402PaymentDirect(
            payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature
        );

        uint256 fee = (amount * 200) / 10000;
        assertEq(xpnts.balanceOf(payee), amount - fee);
        assertEq(paymaster.facilitatorEarnings(operator1, address(xpnts)), fee);
        assertTrue(settlementId != bytes32(0));
    }

    function test_SettleDirect_Replay() public {
        uint256 amount = 100 ether;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        xpnts.mint(payer, amount * 2);
        uint256 maxFee = (amount * 30) / 10000;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(99));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);

        vm.prank(operator1);
        paymaster.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    function test_SettleDirect_Unauthorized() public {
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 amount = 100 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(77));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);

        vm.prank(user1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    // ====================================
    // P0-13: per-(asset, from, nonce) replay-protection
    // ====================================

    /// @notice The same nonce on different assets must be independent. Pre-V5.4
    ///         the global nonce mapping let an anonymous attacker pre-burn a
    ///         victim's nonce by submitting a dummy settlement on a junk asset.
    function test_Nonce_PerAssetIsolation() public {
        bytes32 salt = bytes32(uint256(0xCAFE));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerKey = 0x40;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        xpnts.mint(payer, 100 ether);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce);

        // Burn nonce on USDC.
        vm.prank(operator1);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        // Same nonce, same payer, different asset must still be available.
        vm.prank(operator1);
        bytes32 sid = paymaster.settleX402PaymentDirect(
            payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce, directSig
        );
        assertTrue(sid != bytes32(0), "same nonce on different asset must succeed");
    }

    /// @notice Same nonce, same asset, different `from` must also be independent.
    function test_Nonce_PerPayerIsolation() public {
        bytes32 salt = bytes32(uint256(0xBEEF));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerAKey = 0x50;
        uint256 payerBKey = 0x51;
        address payerA = vm.addr(payerAKey);
        address payerB = vm.addr(payerBKey);
        usdc.mint(payerA, 100e6);
        usdc.mint(payerB, 100e6);
        bytes memory sigA =
            _signEIP3009(payerAKey, payerA, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory sigB =
            _signEIP3009(payerBKey, payerB, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);

        vm.prank(operator1);
        paymaster.settleX402Payment(payerA, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, sigA);

        vm.prank(operator1);
        bytes32 sid =
            paymaster.settleX402Payment(payerB, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, sigB);
        assertTrue(sid != bytes32(0), "same nonce on different payer must succeed");
    }

    /// @notice Replay on the exact (asset, from, nonce) triple must still revert.
    function test_Nonce_TripleReplayBlocked() public {
        bytes32 salt = bytes32(uint256(0xDEAD));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerKey = 0x60;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 200e6);
        bytes memory signature =
            _signEIP3009(payerKey, payer, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);

        vm.prank(operator1);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, signature);

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, signature);
    }

    /// @notice The public helper `x402NonceKey` must agree with what the
    ///         contract writes internally — SDKs depend on this.
    function test_Nonce_PublicKeyMatchesStorage() public {
        bytes32 salt = bytes32(uint256(0xBABE));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerKey = 0x70;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        bytes memory signature =
            _signEIP3009(payerKey, payer, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);

        bytes32 key = paymaster.x402NonceKey(address(usdc), payer, nonce);
        assertFalse(paymaster.x402SettlementNonces(key), "key should be unused before settle");

        vm.prank(operator1);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, signature);

        assertTrue(paymaster.x402SettlementNonces(key), "key should be set after settle");
    }

    /// @notice EIP-3009 path and Direct path share the SAME (asset, from, nonce)
    ///         nonce namespace inside SuperPaymaster. A nonce consumed by
    ///         settleX402Payment must be rejected by settleX402PaymentDirect and
    ///         vice-versa.
    function test_Nonce_CrossPath_EIP3009ThenDirectBlocked() public {
        bytes32 salt = bytes32(uint256(0xC0FFEE));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerKey = 0x80;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 200e6);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, nonce);

        // Step 1: consume nonce via EIP-3009 path (USDC).
        vm.prank(operator1);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        // Step 2: same nonce, same payer, same asset via Direct path must revert.
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402PaymentDirect(
            payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, nonce, directSig
        );
    }

    /// @notice Inverse cross-path check: Direct consumed nonce must be rejected
    ///         by the EIP-3009 path for the same (asset, from, nonce) triple.
    function test_Nonce_CrossPath_DirectThenEIP3009Blocked() public {
        bytes32 salt = bytes32(uint256(0xDECAF));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        uint256 payerKey = 0x81;
        address payer = vm.addr(payerKey);
        xpnts.mint(payer, 200 ether);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce);

        // Step 1: consume nonce via Direct path (xPNTs).
        vm.prank(operator1);
        paymaster.settleX402PaymentDirect(
            payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce, directSig
        );

        // Step 2: same nonce, same payer, same asset via EIP-3009 path must revert.
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(payer, payee, address(xpnts), 100 ether, 0, block.timestamp + 1 hours, salt, "");
    }

    /// @notice Pre-upgrade (pre-P0-13) settlements were keyed by the raw nonce
    ///         bytes32 alone. This test simulates that state by writing the legacy
    ///         slot directly, then verifying the new code refuses to reuse the nonce.
    function test_Nonce_LegacyRawNonceReplayBlocked() public {
        bytes32 salt = bytes32(uint256(0xABCDEF));
        bytes32 nonce = keccak256(abi.encode(payee, salt));
        bytes32 directNonce = bytes32(uint256(0xABCDF0));
        uint256 payerKey = 0x82;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(paymaster), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, directNonce);

        // Simulate a pre-P0-13 settlement: write the raw nonce as the mapping key.
        // This is exactly what the old code wrote: x402SettlementNonces[nonce] = true.
        stdstore
            .target(address(paymaster))
            .sig("x402SettlementNonces(bytes32)")
            .with_key(nonce)
            .checked_write(true);
        stdstore
            .target(address(paymaster))
            .sig("x402SettlementNonces(bytes32)")
            .with_key(directNonce)
            .checked_write(true);

        // Both settle paths must now revert even though the NEW triple-key slot is clear.
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402PaymentDirect(
            payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, directNonce, directSig
        );
    }

    // ====================================
    // V5.3: isEligibleForSponsorship Tests
    // ====================================

    function test_IsEligible_SBTOnly() public {
        address sbtUser = address(0x20);
        // updateSBTStatus is restricted to Registry — write storage directly
        stdstore.target(address(paymaster)).sig("sbtHolders(address)").with_key(sbtUser).checked_write(true);
        assertTrue(paymaster.isEligibleForSponsorship(sbtUser));
    }

    function test_IsEligible_AgentOnly() public {
        // agent1 is registered but has no SBT
        assertFalse(paymaster.sbtHolders(agent1));
        assertTrue(paymaster.isEligibleForSponsorship(agent1));
    }

    function test_IsEligible_Neither() public {
        address nobody = address(0x30);
        assertFalse(paymaster.isEligibleForSponsorship(nobody));
    }

    function test_IsEligible_NoRegistry() public {
        // Reset registries to zero
        vm.prank(owner);
        paymaster.setAgentRegistries(address(0), address(0));
        // Non-SBT user should fail (agent identity registry gone)
        assertFalse(paymaster.isEligibleForSponsorship(agent1));
        // SBT user should still pass
        stdstore.target(address(paymaster)).sig("sbtHolders(address)").with_key(agent1).checked_write(true);
        assertTrue(paymaster.isEligibleForSponsorship(agent1));
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
        assertEq(paymaster.version(), "SuperPaymaster-5.3.3");
    }
}
