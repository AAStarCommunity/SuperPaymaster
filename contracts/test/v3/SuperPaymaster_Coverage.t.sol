// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

// ─── Mocks ─────────────────────────────────────────────────────────────────────

contract CovMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) {
        return keccak256(abi.encode(op, block.chainid));
    }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract CovMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract CovMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// xPNTs mock that supports approvedFacilitators
contract CovMockXPNTs is ERC20 {
    address public FACTORY;
    uint256 public exchangeRateVal = 1e18;
    mapping(address => bool) public approvedFacilitators;

    constructor() ERC20("xPNTs", "xPNT") { FACTORY = address(this); }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setApprovedFacilitator(address f, bool v) external { approvedFacilitators[f] = v; }

    function exchangeRate() external view returns (uint256) { return exchangeRateVal; }
    function getDebt(address) external pure returns (uint256) { return 0; }

    function burnFromWithOpHash(address from, uint256 amount, bytes32) external {
        _burn(from, amount);
    }
    function recordDebt(address, uint256) external {}
    function recordDebtWithOpHash(address, uint256, bytes32) external {}
}

// A factory that can report a token as NOT from it (for configureOperator failure path)
contract CovMockXPNTsFactory {
    mapping(address => address) private _tokens;
    mapping(address => bool) private _isXPNTs;

    function setToken(address op, address token) external {
        _tokens[op] = token;
        _isXPNTs[token] = true;
    }

    function getTokenAddress(address op) external view returns (address) { return _tokens[op]; }
    function isXPNTs(address t) external view returns (bool) { return _isXPNTs[t]; }
}

// Mock ERC-3009 asset (USDC-like) for x402 settlement tests
contract CovMockERC3009 is ERC20 {
    using ECDSA for bytes32;

    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }

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
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }
}

contract CovMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    function setRole(bytes32 role, address account, bool val) external { roles[role][account] = val; }
    function getCreditLimit(address) external pure returns (uint256) { return 1000 ether; }

    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external override {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function queueBLSAggregator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }

    function version() external pure returns (string memory) { return "MockCov"; }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

// ─── Test Suite ────────────────────────────────────────────────────────────────

/**
 * @title SuperPaymaster_Coverage_Test
 * @notice Branch coverage improvements for SuperPaymaster:
 *   D1  executeAPNTsTokenChange — protocolRevenue == PROTOCOL_REVENUE_BUFFER (passes)
 *   D2  withdrawProtocolRevenue — exact available, above available, buffer boundary
 *   D3  configureOperator — factory token mismatch revert, zero exchangeRate revert
 *   D4  settleX402Payment — nonce already used, non-whitelisted facilitator
 *   D5  settleX402PaymentDirect — non-xPNTs asset, non-whitelisted facilitator
 *   D6  Agent policy — isEligibleForSponsorship paths (SBT vs agent vs neither)
 */
contract SuperPaymaster_Coverage_Test is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    CovMockRegistry public registry;
    CovMockEntryPoint public entryPoint;
    CovMockPriceFeed public priceFeed;
    CovMockAPNTs public apnts;
    CovMockXPNTs public xpnts;
    CovMockXPNTsFactory public mockFactory;

    address public owner     = address(0x1);
    address public treasury  = address(0x2);
    address public operator1 = address(0x3);
    address public operator2 = address(0x4); // non-registered operator
    uint256 public user1Key  = 0x5;
    uint256 public user2Key  = 0x6;
    address public user1     = vm.addr(user1Key);
    address public user2     = vm.addr(user2Key); // no SBT, no agent

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY       = keccak256("COMMUNITY");

    /// @dev PROTOCOL_REVENUE_BUFFER mirrored from SuperPaymaster
    uint256 constant PROTOCOL_REVENUE_BUFFER = 0.1 ether;

    function setUp() public {
        vm.startPrank(owner);

        entryPoint = new CovMockEntryPoint();
        priceFeed  = new CovMockPriceFeed();
        apnts      = new CovMockAPNTs();
        xpnts      = new CovMockXPNTs();
        registry   = new CovMockRegistry();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Register operator1 roles
        registry.setRole(ROLE_PAYMASTER_SUPER, operator1, true);
        registry.setRole(ROLE_COMMUNITY, operator1, true);

        // Deploy factory
        mockFactory = new CovMockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator1, address(xpnts));

        apnts.mint(operator1, 100_000 ether);
        vm.stopPrank();

        // Give SBT to user1
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true);

        // Operator setup
        vm.startPrank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), address(0x999));
        paymaster.deposit(50_000 ether);
        vm.stopPrank();
    }

    // ─── Helper ────────────────────────────────────────────────────────────────

    function _buildPaymasterData() internal view returns (bytes memory) {
        return abi.encodePacked(
            address(paymaster), // 20 bytes
            uint128(0),
            uint128(200000),
            operator1,          // 20 bytes (operator)
            type(uint256).max   // 32 bytes (maxRate)
        );
    }

    function _signEIP3009(
        CovMockERC3009 token,
        uint256 privateKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = token.authorizationDigest(from, to, value, validAfter, validBefore, nonce);
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

    function _runValidate(address user) internal returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _buildPaymasterData();
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(uint256(block.timestamp)), 1000);
    }

    // ─── D1: executeAPNTsTokenChange ───────────────────────────────────────────

    /**
     * @notice D1a: executeAPNTsTokenChange succeeds when protocolRevenue == 0
     * (the standard "everything drained" path)
     */
    function test_D1_ExecuteAPNTsTokenChange_WhenZeroBalances() public {
        // Make sure totalTrackedBalance and protocolRevenue are both zero.
        // Withdraw all from operator1 first.
        (uint128 bal,,,,,,,,) = paymaster.operators(operator1);
        vm.prank(operator1);
        paymaster.withdraw(bal);

        address newToken = address(new CovMockAPNTs());

        vm.prank(owner);
        paymaster.setAPNTsToken(newToken);

        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK() + 1);

        vm.prank(owner);
        paymaster.executeAPNTsTokenChange();

        assertEq(paymaster.APNTS_TOKEN(), newToken, "Token should be updated");
        assertEq(paymaster.pendingAPNTsToken(), address(0), "Pending should be cleared");
    }

    /**
     * @notice D1b: executeAPNTsTokenChange reverts when protocolRevenue > 0
     * (accumulation path: slash pushes into protocolRevenue)
     */
    function test_D1_ExecuteAPNTsTokenChange_Reverts_WhenProtocolRevenueNonZero() public {
        // Slash operator1 to push funds into protocolRevenue
        vm.prank(owner);
        paymaster.slashOperator(operator1, ISuperPaymaster.SlashLevel.MINOR, 10 ether, "test");

        // Drain operator1's balance to zero
        (uint128 bal,,,,,,,,) = paymaster.operators(operator1);
        if (bal > 0) {
            vm.prank(operator1);
            paymaster.withdraw(bal);
        }

        address newToken = address(new CovMockAPNTs());
        vm.prank(owner);
        paymaster.setAPNTsToken(newToken);

        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK() + 1);

        // Must revert because protocolRevenue != 0
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.executeAPNTsTokenChange();
    }

    /**
     * @notice D1c: executeAPNTsTokenChange reverts before timelock elapses
     */
    function test_D1_ExecuteAPNTsTokenChange_Reverts_BeforeTimelock() public {
        // Drain so only balance condition is satisfied
        (uint128 bal,,,,,,,,) = paymaster.operators(operator1);
        vm.prank(operator1);
        paymaster.withdraw(bal);

        address newToken = address(new CovMockAPNTs());
        vm.prank(owner);
        paymaster.setAPNTsToken(newToken);

        // Do NOT warp — timelock has not elapsed
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.executeAPNTsTokenChange();
    }

    // ─── D2: withdrawProtocolRevenue ──────────────────────────────────────────

    /**
     * @notice D2a: Withdraw exactly the available amount (protocolRevenue - BUFFER) succeeds
     */
    function test_D2_WithdrawProtocolRevenue_ExactAvailable() public {
        // Slash to accumulate protocolRevenue
        uint256 slashAmount = PROTOCOL_REVENUE_BUFFER + 5 ether;
        vm.prank(owner);
        paymaster.slashOperator(operator1, ISuperPaymaster.SlashLevel.MINOR, slashAmount, "test");

        uint256 revenue = paymaster.protocolRevenue();
        // available = revenue - PROTOCOL_REVENUE_BUFFER
        uint256 available = revenue - PROTOCOL_REVENUE_BUFFER;

        uint256 treasuryBefore = apnts.balanceOf(treasury);

        vm.prank(owner);
        paymaster.withdrawProtocolRevenue(treasury, available);

        assertEq(apnts.balanceOf(treasury) - treasuryBefore, available, "Treasury should receive exact amount");
        assertEq(paymaster.protocolRevenue(), PROTOCOL_REVENUE_BUFFER, "Should retain buffer");
    }

    /**
     * @notice D2b: Withdraw more than available (above protocolRevenue - BUFFER) reverts
     */
    function test_D2_WithdrawProtocolRevenue_Reverts_WhenAboveAvailable() public {
        uint256 slashAmount = PROTOCOL_REVENUE_BUFFER + 5 ether;
        vm.prank(owner);
        paymaster.slashOperator(operator1, ISuperPaymaster.SlashLevel.MINOR, slashAmount, "test");

        uint256 revenue = paymaster.protocolRevenue();
        uint256 tooMuch = revenue - PROTOCOL_REVENUE_BUFFER + 1;

        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InsufficientRevenue.selector);
        paymaster.withdrawProtocolRevenue(treasury, tooMuch);
    }

    /**
     * @notice D2c: When protocolRevenue <= BUFFER, available == 0 — any nonzero withdraw reverts
     */
    function test_D2_WithdrawProtocolRevenue_Reverts_WhenBelowBuffer() public {
        // Slash with small amount that stays within the buffer
        uint256 slashAmount = PROTOCOL_REVENUE_BUFFER / 2;
        vm.prank(owner);
        paymaster.slashOperator(operator1, ISuperPaymaster.SlashLevel.MINOR, slashAmount, "test");

        // protocolRevenue < BUFFER → available == 0
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InsufficientRevenue.selector);
        paymaster.withdrawProtocolRevenue(treasury, 1);
    }

    /**
     * @notice D2d: withdrawProtocolRevenue reverts on zero address destination
     */
    function test_D2_WithdrawProtocolRevenue_Reverts_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidAddress.selector);
        paymaster.withdrawProtocolRevenue(address(0), 1 ether);
    }

    // ─── D3: configureOperator ─────────────────────────────────────────────────

    /**
     * @notice D3a: configureOperator reverts when token does not match factory mapping
     */
    function test_D3_ConfigureOperator_Reverts_WhenTokenNotFromFactory() public {
        address wrongToken = address(new CovMockXPNTs());
        // mockFactory.getTokenAddress(operator1) == address(xpnts), not wrongToken

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector);
        paymaster.configureOperator(wrongToken, address(0x999));
    }

    /**
     * @notice D3b: configureOperator reverts when treasury == address(0)
     */
    function test_D3_ConfigureOperator_Reverts_ZeroTreasury() public {
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.configureOperator(address(xpnts), address(0));
    }

    /**
     * @notice D3c: configureOperator reverts when caller has no ROLE_PAYMASTER_SUPER
     */
    function test_D3_ConfigureOperator_Reverts_NoRole() public {
        vm.prank(user1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.configureOperator(address(xpnts), address(0x999));
    }

    /**
     * @notice D3d: configureOperator reverts when caller has ROLE_PAYMASTER_SUPER but no ROLE_COMMUNITY
     */
    function test_D3_ConfigureOperator_Reverts_NoCommunityRole() public {
        // Register a second operator with only PAYMASTER_SUPER role, not COMMUNITY
        address op2 = address(0xABC);
        registry.setRole(ROLE_PAYMASTER_SUPER, op2, true);
        // Note: ROLE_COMMUNITY is NOT set for op2

        vm.prank(op2);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.configureOperator(address(xpnts), address(0x999));
    }

    /**
     * @notice D3e: configureOperator reverts when factory is not set (address(0))
     */
    function test_D3_ConfigureOperator_Reverts_FactoryNotSet() public {
        // Deploy a fresh paymaster with no factory set
        SuperPaymaster fresh = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        fresh.configureOperator(address(xpnts), address(0x999));
    }

    // ─── D4: settleX402Payment ─────────────────────────────────────────────────

    /**
     * @notice D4a: settleX402Payment reverts on nonce already used
     */
    function test_D4_SettleX402Payment_Reverts_NonceAlreadyUsed() public {
        CovMockERC3009 usdc = new CovMockERC3009();
        usdc.mint(user1, 100 ether);

        bytes32 salt = bytes32(uint256(42));
        bytes32 nonce = keccak256(abi.encode(treasury, salt));
        uint256 amount = 10 ether;
        uint256 validAfter = 0;
        uint256 validBefore = type(uint256).max;
        bytes memory signature =
            _signEIP3009(usdc, user1Key, user1, address(paymaster), amount, validAfter, validBefore, nonce);

        // Approve paymaster to pull from user1 (via transferWithAuthorization stub)
        vm.prank(user1);
        usdc.approve(address(paymaster), type(uint256).max);

        // First settle — success
        vm.prank(operator1);
        paymaster.settleX402Payment(user1, treasury, address(usdc), amount, validAfter, validBefore, salt, signature);

        // Second settle with same (asset, from, nonce) — should revert
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(user1, treasury, address(usdc), amount, validAfter, validBefore, salt, signature);
    }

    /**
     * @notice D4b: settleX402Payment reverts when caller does not have ROLE_PAYMASTER_SUPER
     */
    function test_D4_SettleX402Payment_Reverts_NonWhitelistedFacilitator() public {
        CovMockERC3009 usdc = new CovMockERC3009();
        usdc.mint(user1, 100 ether);

        bytes32 salt = bytes32(uint256(1));

        // user2 has no ROLE_PAYMASTER_SUPER → should revert Unauthorized
        vm.prank(user2);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402Payment(user1, treasury, address(usdc), 10 ether, 0, type(uint256).max, salt, "");
    }

    /**
     * @notice D4c: settleX402Payment uses nonce key triple (asset, from, nonce).
     * Different payer with same nonce value should be allowed (different namespace).
     */
    function test_D4_SettleX402Payment_DifferentPayer_SameNonce_Allowed() public {
        CovMockERC3009 usdc = new CovMockERC3009();
        usdc.mint(user1, 100 ether);
        usdc.mint(user2, 100 ether);

        bytes32 salt = bytes32(uint256(77));
        bytes32 nonce = keccak256(abi.encode(treasury, salt));
        bytes memory sig1 = _signEIP3009(usdc, user1Key, user1, address(paymaster), 5 ether, 0, type(uint256).max, nonce);
        bytes memory sig2 = _signEIP3009(usdc, user2Key, user2, address(paymaster), 5 ether, 0, type(uint256).max, nonce);

        vm.prank(user1);
        usdc.approve(address(paymaster), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(paymaster), type(uint256).max);

        // Settle for user1
        vm.prank(operator1);
        paymaster.settleX402Payment(user1, treasury, address(usdc), 5 ether, 0, type(uint256).max, salt, sig1);

        // Settle for user2 — same nonce but different from → different key, should succeed
        vm.prank(operator1);
        paymaster.settleX402Payment(user2, treasury, address(usdc), 5 ether, 0, type(uint256).max, salt, sig2);
    }

    // ─── D5: settleX402PaymentDirect ──────────────────────────────────────────

    /**
     * @notice D5a: settleX402PaymentDirect reverts when asset is not an xPNTs token
     */
    function test_D5_SettleX402PaymentDirect_Reverts_NonXPNTs() public {
        // Deploy a factory that will return false for isXPNTs
        CovMockXPNTsFactory strictFactory = new CovMockXPNTsFactory();
        // Do NOT call setToken for this token — isXPNTs returns false

        vm.prank(owner);
        paymaster.setXPNTsFactory(address(strictFactory));
        // Reconfigure operator1 with new factory (mock won't know xpnts, getTokenAddress returns zero)
        // We need to work around: configureOperator checks getTokenAddress. Let's add operator1's token.
        strictFactory.setToken(operator1, address(xpnts));

        // Use a plain ERC20 that is NOT in the factory's isXPNTs mapping
        CovMockAPNTs plainToken = new CovMockAPNTs();
        plainToken.mint(user1, 100 ether);
        uint256 amount = 10 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory signature =
            _signX402Direct(user1Key, user1, treasury, address(plainToken), amount, maxFee, validBefore, nonce);

        vm.prank(user1);
        plainToken.approve(address(paymaster), type(uint256).max);

        // operator1 is an approved super operator; plainToken is NOT an xPNTs
        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector);
        paymaster.settleX402PaymentDirect(
            user1, treasury, address(plainToken), amount, maxFee, validBefore, nonce, signature
        );

        // Restore original factory so other tests still work
        vm.prank(owner);
        paymaster.setXPNTsFactory(address(mockFactory));
    }

    /**
     * @notice D5b: settleX402PaymentDirect reverts when caller is not an approved facilitator
     * on the xPNTs token (P0-12b)
     */
    function test_D5_SettleX402PaymentDirect_Reverts_NotApprovedFacilitator() public {
        xpnts.mint(user1, 100 ether);
        uint256 amount = 10 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory signature =
            _signX402Direct(user1Key, user1, treasury, address(xpnts), amount, maxFee, validBefore, nonce);
        vm.prank(user1);
        xpnts.approve(address(paymaster), type(uint256).max);

        // operator1 is NOT added as an approved facilitator on xpnts
        assertFalse(xpnts.approvedFacilitators(operator1), "Should not be approved yet");

        vm.prank(operator1);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(user1, treasury, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    /**
     * @notice D5c: settleX402PaymentDirect succeeds when facilitator is approved on xPNTs
     */
    function test_D5_SettleX402PaymentDirect_Success_WhenApproved() public {
        xpnts.mint(user1, 100 ether);
        uint256 amount = 10 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(2));
        bytes memory signature =
            _signX402Direct(user1Key, user1, treasury, address(xpnts), amount, maxFee, validBefore, nonce);
        vm.prank(user1);
        xpnts.approve(address(paymaster), type(uint256).max);

        // Approve operator1 as a facilitator on the xPNTs token
        xpnts.setApprovedFacilitator(operator1, true);

        vm.prank(operator1);
        bytes32 sid =
            paymaster.settleX402PaymentDirect(user1, treasury, address(xpnts), amount, maxFee, validBefore, nonce, signature);

        assertTrue(sid != bytes32(0), "Settlement ID should be non-zero");
    }

    /**
     * @notice D5d: settleX402PaymentDirect reverts when caller has no ROLE_PAYMASTER_SUPER
     */
    function test_D5_SettleX402PaymentDirect_Reverts_NoRole() public {
        xpnts.mint(user2, 100 ether);
        uint256 amount = 5 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(3));
        bytes memory signature =
            _signX402Direct(user2Key, user2, treasury, address(xpnts), amount, maxFee, validBefore, nonce);
        vm.prank(user2);
        xpnts.approve(address(paymaster), type(uint256).max);

        vm.prank(user2);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(user2, treasury, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    // ─── D6: Agent / eligibility paths ────────────────────────────────────────

    /**
     * @notice D6a: isEligibleForSponsorship returns true for SBT holder (already covered
     * by validate tests but surfaced here for branch completeness)
     */
    function test_D6_IsEligibleForSponsorship_SBTHolder() public view {
        assertTrue(paymaster.isEligibleForSponsorship(user1), "SBT holder should be eligible");
    }

    /**
     * @notice D6b: isEligibleForSponsorship returns false for non-SBT, non-agent user
     */
    function test_D6_IsEligibleForSponsorship_NotEligible() public view {
        assertFalse(paymaster.isEligibleForSponsorship(user2), "user2 has no SBT and no agent NFT");
    }

    /**
     * @notice D6c: isRegisteredAgent returns false when agentIdentityRegistry is address(0)
     */
    function test_D6_IsRegisteredAgent_ReturnsFalse_WhenNoRegistry() public view {
        assertEq(paymaster.agentIdentityRegistry(), address(0), "No registry set");
        assertFalse(paymaster.isRegisteredAgent(user1), "Should return false when registry is zero");
    }

    /**
     * @notice D6d: setAgentRegistries with non-contract address reverts (P0 check)
     */
    function test_D6_SetAgentRegistries_Reverts_NonContract() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidAddress.selector);
        paymaster.setAgentRegistries(address(0xDEAD), address(0));
    }

    /**
     * @notice D6e: setAgentRegistries with address(0) disables agent sponsorship
     */
    function test_D6_SetAgentRegistries_Zero_Disables() public {
        vm.prank(owner);
        paymaster.setAgentRegistries(address(0), address(0));
        assertEq(paymaster.agentIdentityRegistry(), address(0));
        assertFalse(paymaster.isRegisteredAgent(user1));
    }

    // D7 removed: it asserted the v0.6-era `if (mode == postOpReverted) return;`
    // early-return, which was dead code in EntryPoint v0.7 (postOp is never called
    // with postOpReverted) and was removed as part of the C-04 cleanup. Replay/
    // double-charge is now prevented by the `_settledDebtOps` idempotency guard.

    // ─── Additional coverage: validatePaymasterUserOp rejection paths ─────────

    /**
     * @notice D8: validatePaymasterUserOp returns sig failure when operator not configured
     */
    function test_D8_Validate_NotConfigured_ReturnsSigFailure() public {
        address op9 = address(0x999);
        registry.setRole(ROLE_PAYMASTER_SUPER, op9, true);

        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(0),
            uint128(200000),
            op9, // operator without configureOperator called
            type(uint256).max
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);

        // Sig failure is encoded as address(1) in lower 160 bits
        address authorizer = address(uint160(validationData));
        assertEq(authorizer, address(1), "Should return SIG_FAILURE for unconfigured operator");
    }

    /**
     * @notice D9: validatePaymasterUserOp returns sig failure when user not eligible
     */
    function test_D9_Validate_UserNotEligible_ReturnsSigFailure() public {
        PackedUserOperation memory op;
        op.sender = user2; // no SBT, no agent
        op.paymasterAndData = _buildPaymasterData();

        // Override operator in paymasterAndData to operator1 (already configured)
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),
            uint128(0),
            uint128(200000),
            operator1,
            type(uint256).max
        );

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);

        address authorizer = address(uint160(validationData));
        assertEq(authorizer, address(1), "Should return SIG_FAILURE when user not eligible");
    }

    /**
     * @notice D10: validatePaymasterUserOp returns sig failure when operator is paused
     */
    function test_D10_Validate_OperatorPaused_ReturnsSigFailure() public {
        vm.prank(owner);
        paymaster.setOperatorPaused(operator1, true);

        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = _buildPaymasterData();

        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);

        address authorizer = address(uint160(validationData));
        assertEq(authorizer, address(1), "Should return SIG_FAILURE when operator is paused");
    }

    // ─── D11: Protocol revenue buffer boundary ─────────────────────────────────

    /**
     * @notice D11: When protocolRevenue == PROTOCOL_REVENUE_BUFFER exactly, available == 0
     */
    function test_D11_ProtocolRevenue_ExactlyBuffer_AvailableIsZero() public {
        // Force protocolRevenue to exactly PROTOCOL_REVENUE_BUFFER via slash
        // First drain any existing revenue, then slash exactly the buffer amount.
        vm.prank(owner);
        paymaster.slashOperator(operator1, ISuperPaymaster.SlashLevel.MINOR, PROTOCOL_REVENUE_BUFFER, "exact buffer");

        // Ensure we have exactly the buffer (may differ slightly from slashHistory due to cap logic)
        // available = protocolRevenue - BUFFER = 0 when protocolRevenue == BUFFER
        uint256 rev = paymaster.protocolRevenue();
        if (rev <= PROTOCOL_REVENUE_BUFFER) {
            vm.prank(owner);
            vm.expectRevert(SuperPaymaster.InsufficientRevenue.selector);
            paymaster.withdrawProtocolRevenue(treasury, 1);
        } else {
            // More than buffer: verify we can only withdraw the excess
            uint256 excess = rev - PROTOCOL_REVENUE_BUFFER;
            vm.prank(owner);
            paymaster.withdrawProtocolRevenue(treasury, excess);
            assertEq(paymaster.protocolRevenue(), PROTOCOL_REVENUE_BUFFER);
        }
    }
}
