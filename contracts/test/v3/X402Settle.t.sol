// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/interfaces/v3/IERC3009.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

// ============================================
// Mock Contracts
// ============================================

/**
 * @title MockEntryPointX402
 * @notice Minimal EntryPoint mock for x402 tests
 */
contract MockEntryPointX402 {
    function depositTo(address) external payable {}
}

/**
 * @title MockPriceFeedX402
 * @notice Returns a fixed $2000 ETH/USD price
 */
contract MockPriceFeedX402 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/**
 * @title MockAPNTsX402
 * @notice Simple ERC20 mock for aPNTs
 */
contract MockAPNTsX402 is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockERC3009Token
 * @notice Mock token implementing both ERC20 and EIP-3009 transferWithAuthorization
 * @dev Uses EIP-712 typed data for signature verification.
 *      Supports the bytes-signature variant of transferWithAuthorization (USDC v2.2+).
 */
contract MockERC3009Token is ERC20, IERC3009 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    bytes32 private immutable _DOMAIN_SEPARATOR;
    mapping(bytes32 => bool) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external override {
        require(block.timestamp >= validAfter, "Authorization not yet valid");
        require(block.timestamp <= validBefore, "Authorization expired");
        require(!authorizationState[nonce], "Authorization already used");

        // Reconstruct EIP-712 digest
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash)
        );

        // Recover signer from signature
        require(signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == from, "Invalid signature");

        authorizationState[nonce] = true;
        _transfer(from, to, value);
    }
}

// ============================================
// Test Contract
// ============================================

/**
 * @title X402SettleTest
 * @notice Tests for x402 payment verification and settlement on SuperPaymaster
 */
contract X402SettleTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    Registry public registry;
    GToken public gtoken;
    MockEntryPointX402 public entryPoint;
    MockPriceFeedX402 public priceFeed;
    MockAPNTsX402 public apnts;
    MockERC3009Token public usdc;

    address public owner = address(0x1);
    address public treasury = address(0x2);

    // EIP-712 signing keys
    uint256 internal constant PAYER_KEY = 0xA11CE;
    uint256 internal constant OPERATOR_KEY = 0xB0B;

    address internal payer;
    address internal operator1;

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    function setUp() public {
        payer = vm.addr(PAYER_KEY);
        operator1 = vm.addr(OPERATOR_KEY);

        vm.startPrank(owner);

        gtoken = new GToken(21_000_000 ether);
        entryPoint = new MockEntryPointX402();
        priceFeed = new MockPriceFeedX402();
        apnts = new MockAPNTsX402();
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

        // Warp forward to allow price update
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        vm.stopPrank();

        // Mint USDC to payer
        usdc.mint(payer, 1_000_000e18);
    }

    // ====================================
    // Helpers
    // ====================================

    /// @dev Sign a transferWithAuthorization EIP-712 digest
    function _signAuthorization(
        uint256 signerKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 domainSeparator = usdc.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    // ====================================
    // Fee Configuration Tests
    // ====================================

    function test_SetFacilitatorFeeBPS() public {
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(30);
        assertEq(paymaster.facilitatorFeeBPS(), 30, "Fee should be 30 BPS");
    }

    function test_SetFacilitatorFeeBPS_EmitsEvent() public {
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(100); // Set initial

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ISuperPaymaster.FacilitatorFeeUpdated(100, 200);
        paymaster.setFacilitatorFeeBPS(200);
    }

    function test_SetFacilitatorFeeBPS_MaxFeeRevert() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.FeeExceedsMax.selector);
        paymaster.setFacilitatorFeeBPS(501); // Exceeds 500 (5%)
    }

    function test_SetFacilitatorFeeBPS_NonOwnerRevert() public {
        vm.prank(payer);
        vm.expectRevert();
        paymaster.setFacilitatorFeeBPS(30);
    }

    function test_SetFacilitatorFeeBPS_MaxAllowed() public {
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(500); // Exactly 5%
        assertEq(paymaster.facilitatorFeeBPS(), 500);
    }

    function test_SetOperatorFacilitatorFee() public {
        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 50);
        assertEq(paymaster.operatorFacilitatorFees(operator1), 50, "Operator fee should be 50 BPS");
    }

    function test_SetOperatorFacilitatorFee_MaxFeeRevert() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.FeeExceedsMax.selector);
        paymaster.setOperatorFacilitatorFee(operator1, 501);
    }

    function test_SetOperatorFacilitatorFee_Zero() public {
        // Setting to 0 means "use default"
        vm.prank(owner);
        paymaster.setOperatorFacilitatorFee(operator1, 0);
        assertEq(paymaster.operatorFacilitatorFees(operator1), 0);
    }

    // ====================================
    // verifyX402Payment Tests
    // ====================================

    function test_VerifyX402Payment_Valid() public {
        bytes32 nonce = bytes32(uint256(1));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        (bool valid, string memory reason) = paymaster.verifyX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, ""
        );

        assertTrue(valid, "Should be valid");
        assertEq(bytes(reason).length, 0, "Reason should be empty");
    }

    function test_VerifyX402Payment_NotYetValid() public {
        bytes32 nonce = bytes32(uint256(2));
        uint256 validAfter = block.timestamp + 1 hours; // future
        uint256 validBefore = block.timestamp + 2 hours;

        (bool valid, string memory reason) = paymaster.verifyX402Payment(
            payer, operator1, address(usdc), 100e18, validAfter, validBefore, nonce, ""
        );

        assertFalse(valid, "Should be invalid (not yet valid)");
        assertEq(reason, "Authorization not yet valid");
    }

    function test_VerifyX402Payment_Expired() public {
        bytes32 nonce = bytes32(uint256(3));
        uint256 validAfter = block.timestamp - 2 hours;
        uint256 validBefore = block.timestamp - 1; // already expired

        (bool valid, string memory reason) = paymaster.verifyX402Payment(
            payer, operator1, address(usdc), 100e18, validAfter, validBefore, nonce, ""
        );

        assertFalse(valid, "Should be invalid (expired)");
        assertEq(reason, "Authorization expired");
    }

    function test_VerifyX402Payment_InsufficientBalance() public {
        address poorUser = address(0xDEAD);
        bytes32 nonce = bytes32(uint256(4));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        (bool valid, string memory reason) = paymaster.verifyX402Payment(
            poorUser, operator1, address(usdc), 100e18, validAfter, validBefore, nonce, ""
        );

        assertFalse(valid, "Should be invalid (insufficient balance)");
        assertEq(reason, "Insufficient balance");
    }

    function test_VerifyX402Payment_NonceAlreadyUsed() public {
        // First, settle a payment to consume the nonce
        bytes32 nonce = bytes32(uint256(5));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // Set facilitator fee
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(30);

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Now verify should report nonce used
        (bool valid, string memory reason) = paymaster.verifyX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, ""
        );

        assertFalse(valid, "Should be invalid (nonce used)");
        assertEq(reason, "Nonce already used");
    }

    // ====================================
    // settleX402Payment Tests
    // ====================================

    function test_SettleX402Payment_HappyPath() public {
        bytes32 nonce = bytes32(uint256(10));
        uint256 amount = 1000e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // Set 1% fee (100 BPS)
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(100);

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeBefore = usdc.balanceOf(operator1);
        uint256 contractBefore = usdc.balanceOf(address(paymaster));

        bytes32 settlementId = paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Verify balances
        uint256 expectedFee = (amount * 100) / 10000; // 1% of 1000 = 10
        uint256 expectedNet = amount - expectedFee;    // 990

        assertEq(usdc.balanceOf(payer), payerBefore - amount, "Payer should pay full amount");
        assertEq(usdc.balanceOf(operator1), payeeBefore + expectedNet, "Payee should receive net");
        assertEq(usdc.balanceOf(address(paymaster)), contractBefore + expectedFee, "Contract keeps fee");

        // Verify settlement ID
        bytes32 expectedId = keccak256(abi.encodePacked(payer, operator1, address(usdc), amount, nonce));
        assertEq(settlementId, expectedId, "Settlement ID mismatch");

        // Verify nonce is consumed
        assertTrue(paymaster.x402SettlementNonces(nonce), "Nonce should be marked used");
    }

    function test_SettleX402Payment_EmitsEvent() public {
        bytes32 nonce = bytes32(uint256(11));
        uint256 amount = 500e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(200); // 2%

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        uint256 expectedFee = (amount * 200) / 10000;

        vm.expectEmit(true, true, false, true);
        emit ISuperPaymaster.X402PaymentSettled(payer, operator1, address(usdc), amount, expectedFee, nonce);

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );
    }

    function test_SettleX402Payment_DoubleSettleRevert() public {
        bytes32 nonce = bytes32(uint256(12));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(30);

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        // First settlement succeeds
        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Second settlement with same nonce reverts
        vm.expectRevert(SuperPaymaster.NonceAlreadyUsed.selector);
        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );
    }

    function test_SettleX402Payment_ZeroFee() public {
        bytes32 nonce = bytes32(uint256(13));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // Default fee is 0
        assertEq(paymaster.facilitatorFeeBPS(), 0, "Default fee should be 0");

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        uint256 payeeBefore = usdc.balanceOf(operator1);

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // With 0% fee, payee gets full amount
        assertEq(usdc.balanceOf(operator1), payeeBefore + amount, "Payee should get full amount with 0 fee");
        assertEq(usdc.balanceOf(address(paymaster)), 0, "Contract should have 0 fee balance");
    }

    function test_SettleX402Payment_OperatorFeeOverride() public {
        bytes32 nonce = bytes32(uint256(14));
        uint256 amount = 1000e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // Set default fee to 1% (100 BPS)
        vm.startPrank(owner);
        paymaster.setFacilitatorFeeBPS(100);
        // Set operator-specific fee to 0.5% (50 BPS)
        paymaster.setOperatorFacilitatorFee(operator1, 50);
        vm.stopPrank();

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        uint256 payeeBefore = usdc.balanceOf(operator1);

        // Call as operator1 to trigger operator fee override
        vm.prank(operator1);
        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Operator fee: 0.5% of 1000 = 5
        uint256 expectedFee = (amount * 50) / 10000;
        uint256 expectedNet = amount - expectedFee;

        assertEq(usdc.balanceOf(operator1), payeeBefore + expectedNet, "Payee gets net with operator fee");
        assertEq(usdc.balanceOf(address(paymaster)), expectedFee, "Contract keeps operator fee");
    }

    // ====================================
    // Fee Calculation Tests
    // ====================================

    function test_FeeCalculation_30BPS() public {
        bytes32 nonce = bytes32(uint256(20));
        uint256 amount = 10000e18; // 10,000 USDC
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(30); // 0.3%

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        uint256 payeeBefore = usdc.balanceOf(operator1);

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Fee = 10000 * 30 / 10000 = 30 USDC
        uint256 expectedFee = 30e18;
        uint256 expectedNet = amount - expectedFee;

        assertEq(usdc.balanceOf(operator1), payeeBefore + expectedNet, "Net = 9970 USDC");
        assertEq(usdc.balanceOf(address(paymaster)), expectedFee, "Fee = 30 USDC");
    }

    function test_FeeCalculation_500BPS() public {
        bytes32 nonce = bytes32(uint256(21));
        uint256 amount = 10000e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(500); // 5% max

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Fee = 10000 * 500 / 10000 = 500 USDC
        assertEq(usdc.balanceOf(address(paymaster)), 500e18, "Max fee = 500 USDC (5%)");
    }

    function test_FeeCalculation_SmallAmount() public {
        bytes32 nonce = bytes32(uint256(22));
        uint256 amount = 1e6; // 1 USDC (6 decimals style but using 18 here)
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(30); // 0.3%

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );

        // Fee = 1e6 * 30 / 10000 = 3000
        uint256 expectedFee = (amount * 30) / 10000;
        assertEq(usdc.balanceOf(address(paymaster)), expectedFee, "Fee on small amount");
    }

    // ====================================
    // Edge Case & Security Tests
    // ====================================

    function test_SettleX402Payment_InvalidSignatureReverts() public {
        bytes32 nonce = bytes32(uint256(30));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        // Sign with wrong key (not the payer)
        uint256 wrongKey = 0xDEAD;
        bytes memory sig = _signAuthorization(
            wrongKey, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        vm.expectRevert("Invalid signature");
        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );
    }

    function test_SettleX402Payment_ExpiredAuthReverts() public {
        bytes32 nonce = bytes32(uint256(31));
        uint256 amount = 100e18;
        uint256 validAfter = block.timestamp - 2 hours;
        uint256 validBefore = block.timestamp - 1; // already expired

        bytes memory sig = _signAuthorization(
            PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
        );

        // The MockERC3009Token will revert with "Authorization expired"
        vm.expectRevert("Authorization expired");
        paymaster.settleX402Payment(
            payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
        );
    }

    function test_SettleX402Payment_MultipleSettlements() public {
        vm.prank(owner);
        paymaster.setFacilitatorFeeBPS(100); // 1%

        uint256 payeeBefore = usdc.balanceOf(operator1);
        uint256 totalNet = 0;
        uint256 totalFee = 0;

        // Settle 3 different payments
        for (uint256 i = 0; i < 3; i++) {
            bytes32 nonce = bytes32(uint256(100 + i));
            uint256 amount = (i + 1) * 100e18; // 100, 200, 300
            uint256 validAfter = block.timestamp - 1;
            uint256 validBefore = block.timestamp + 1 hours;

            bytes memory sig = _signAuthorization(
                PAYER_KEY, payer, address(paymaster), amount, validAfter, validBefore, nonce
            );

            paymaster.settleX402Payment(
                payer, operator1, address(usdc), amount, validAfter, validBefore, nonce, sig
            );

            uint256 fee = (amount * 100) / 10000;
            totalFee += fee;
            totalNet += amount - fee;
        }

        assertEq(usdc.balanceOf(operator1), payeeBefore + totalNet, "Payee total net across 3 settlements");
        assertEq(usdc.balanceOf(address(paymaster)), totalFee, "Contract total fees across 3 settlements");
    }

    function test_Version() public view {
        assertEq(paymaster.version(), "SuperPaymaster-5.2.0", "Version should be 5.2.0");
    }
}
