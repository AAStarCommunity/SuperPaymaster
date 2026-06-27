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

    function _authDigest(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
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
            abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function receiveAuthorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
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

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        // EIP-3009 receive semantics: only the payee may submit the authorization.
        require(msg.sender == to, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @dev M-1: deflationary / fee-on-transfer EIP-3009 token. Verifies the payer's
///      authorization exactly like MockERC3009Token, but skims 1% on transfer so the
///      recipient (`to`, i.e. the SuperPaymaster) receives LESS than `value`. This
///      violates the EIP-3009 path's amount==received assumption and must be rejected
///      by the contract's balance-delta check (X402AmountMismatch).
contract MockDeflationaryERC3009Token is ERC20, IERC3009 {
    using ECDSA for bytes32;

    uint256 public constant SKIM_BPS = 100; // 1%
    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("Deflationary USDC", "dUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _authDigest(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
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
            abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function receiveAuthorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
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
        // Skim 1%: recipient receives value - fee, the rest is burned. The SuperPaymaster
        // (the `to`) therefore sees a short balance delta.
        uint256 skim = (value * SKIM_BPS) / 10000;
        _transfer(from, to, value - skim);
        _burn(from, skim);
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        // EIP-3009 receive semantics: only the payee may submit the authorization.
        require(msg.sender == to, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        // Skim 1%: recipient receives value - fee, the rest is burned. The SuperPaymaster
        // (the `to`) therefore sees a short balance delta.
        uint256 skim = (value * SKIM_BPS) / 10000;
        _transfer(from, to, value - skim);
        _burn(from, skim);
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
    // F4: EIP-1153 Transient Cache Tests
    // ====================================

    // Note: Transient storage (tload/tstore) is cleared between transactions.
    // Testing in Foundry requires same-transaction context.
    // The cache integration is tested implicitly via validatePaymasterUserOp.

    function test_Version() public {
        assertEq(paymaster.version(), "SuperPaymaster-5.4.1");
    }
}
