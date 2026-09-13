// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

// --- Mocks ---

contract MockEntryPointV3 is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32 _unstakeDelaySec) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable withdrawAddress) external {}
    function getSenderAddress(bytes memory initCode) external {}
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata opsPerAggregator, address payable beneficiary) external {}
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32) { return keccak256(abi.encode(userOp)); }
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce) { return 0; }
    function balanceOf(address account) external view returns (uint256) { return 0; }
    function getDepositInfo(address account) external view returns (DepositInfo memory info) {}
    function incrementNonce(uint192 key) external {}
    function fail(bytes memory context, uint256 actualGasCost, uint256 actualUserOpFeePerGas) external {} 
    function delegateAndRevert(address target, bytes calldata data) external {}
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {}
}

contract MockPriceFeedV3 {
    int256 public price = 2000 * 1e8;
    
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1); // $2000
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
    // Helper to change price
    function setPrice(int256 _price) external {
        price = _price;
    }
}

contract MockAPNTsV3 is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockGTokenV3 is ERC20 {
    constructor() ERC20("GToken", "GT") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}


contract MockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    
    function setRole(bytes32 role, address account, bool val) external {
        roles[role][account] = val;
    }
    
    function getCreditLimit(address) external pure returns (uint256) {
        return 1000 ether;
    }
    
    // Stub other interface methods if needed by SuperPaymaster
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external override {}
    
    // Stubs for other IRegistry methods
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
    
    // View constants / getters
    function version() external pure returns (string memory) { return "Mock"; }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

contract SuperPaymasterV3_Pricing_Test is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    MockRegistry public registry;
    MockGTokenV3 public gtoken;
    MockEntryPointV3 public entryPoint;
    MockPriceFeedV3 public priceFeed;
    MockAPNTsV3 public apnts;
    xPNTsTokenV2 public xpntsToken;
    MockXPNTsFactory public mockFactory;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public operator1 = address(0x3);
    address public user1 = address(0x5);
    
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    
    function setUp() public {
        vm.startPrank(owner);
        
        gtoken = new MockGTokenV3();
        entryPoint = new MockEntryPointV3();
        priceFeed = new MockPriceFeedV3();
        apnts = new MockAPNTsV3();

        // Mock Registry
        registry = new MockRegistry();
        
        // Deploy SuperPaymaster via UUPS proxy
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );
        
        // 1. Initialize Cache
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice(); // Cache = $2000
        
        // 2. Setup Roles (Via Mock)
        // Use constants from Registry to ensure perfect match
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator1, true);
        registry.setRole(keccak256("COMMUNITY"), operator1, true);
        
        // Debug Verification
        require(registry.hasRole(keccak256("PAYMASTER_SUPER"), operator1), "Debug: Role Set Failed");
        require(address(paymaster.REGISTRY()) == address(registry), "Debug: Registry Mismatch");
        
        // 3. Fund Operator
        apnts.mint(operator1, 10000 ether);

        // Deploy mock factory (P1-4 fix); operator token bound below
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));

        vm.stopPrank(); // End Owner Prank

        // 5.5.0: operator token must be an xPNTs v2 (balance-mode) token; rate 1:1.
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpntsToken = V2TokenDeployer.newToken(st, operator1, operator1, address(paymaster), 1e18);
        mockFactory.setToken(operator1, address(xpntsToken));
        // Balance mode: the user pays from escrowed xPNTs (credit is OFF by default).
        IxPNTsV2Admin(address(xpntsToken)).mint(user1, 1_000 ether);

        // 4. Mock Registry Update (SBT check) - Must be called by Registry
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true); 
        
        // 5. Operator Config
        vm.startPrank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
        
        // configure first usually
        paymaster.configureOperator(address(xpntsToken), address(0x999));
        paymaster.deposit(5000 ether); 
        vm.stopPrank();
    }

    function test_V3_Pricing_HybridModel_WithBuffer() public {
        // --- Scenario ---
        // Cache Price: $2000 (Set in setUp)
        // Realtime Price: $2000 (Unchanged)
        // Validation Buffer: 10%
        
        // Gas Cost Setup
        uint256 maxCost = 1000; // Wei
        
        PackedUserOperation memory op;
        op.sender = user1;
        // op.paymasterAndData structure for V3:
        // [paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)] ...
        // We construct it manually or just use raw bytes if pure unit test? 
        // validatePaymasterUserOp uses _extractOperator logic.
        // It slices userOp.paymasterAndData[52:72].
        
        // 5.5.0 layout: [pm 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
        op.paymasterAndData = _pmd();
        
        
        // --- Step 1: Validation (Cache + Buffer) ---
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
        
        assertEq(uint160(valData), 0, "Validation should pass");
        
        // Check Operator Balance Deduction
        // Calculation:
        // CostUSD = 1000 * 2000e18 / 1e8 = 20,000,000e10 = 2e7 * 1e10? No.
        // (1000 * 2000e8 * 1e18) / (1e8 * 0.02e18)
        // = (1000 * 2000) / 0.02 = 2,000,000 / 0.02 = 100,000,000
        
        // Buffer = 1.1x => 110,000,000 aPNTs
        
        uint256 expectedPreCharge = 120000000;
        (uint128 balAfter,,,,,,,,) = paymaster.operators(operator1);
        
        // Initial Deposit: 5000 ether (5000 * 1e18)
        // We charged 1.1 * 1e8 roughly.
        assertEq(5000 ether - balAfter, expectedPreCharge, "Operator balance should reduce by Cost + Buffer");
        // 5.5.0 (R10-M1b): a0 is IN FLIGHT, not revenue, until postOp settles
        (address fOp, uint256 fA0) = paymaster.inflightOf(bytes32(0));
        assertEq(fOp, operator1, "in-flight operator");
        assertEq(fA0, expectedPreCharge, "in-flight a0");
        assertEq(paymaster.protocolRevenue(), 0, "a0 is not revenue while in flight");
        // user side: a0 escrowed as xPNTs at 1:1 (x0 = ceil(a0 * rate / 1e18))
        assertEq(xpntsToken.lockedOf(user1), expectedPreCharge, "x0 escrowed at validation");
        uint256 userBal0 = xpntsToken.balanceOf(user1);

        // --- Step 2: PostOp (5.5.0: validation-time price snapshot from context, R10-M3) ---
        // actualUserOpFeePerGas = 0 -> bufWei = 0, so charge = ceil(calc(actualGasCost) * 1.1)
        // Actual Cost = 1.0x (No Buffer, Price same)
        // Protocol Fee = 10% (Set in contract default)
        
        // We deducted 1.1x Cost.
        // Actual Charge Logic in PostOp:
        // 1. Calculate ActualAPNTs = 100,000,000 (Based on Realtime $2000)
        // 2. Add Protocol Fee (10%) = 100,000,000 * 1.1 = 110,000,000
        
        // Wait! Protocol Fee is 1000 BPS (10%).
        // So Final Charge = Actual * 1.1.
        
        // Check my math:
        // Validation with Buffer = Cost * 1.1
        // PostOp with Fee = Cost * 1.1
        // They are EXACTLY EQUAL if buffer == fee and price is stable.
        
        // So Refund should be 0.
        // Revenue should be 110,000,000.
        
        uint256 actualCostWei = maxCost;
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCostWei, 0);
        
        (uint128 balFinal,,,,,,,,) = paymaster.operators(operator1);
        
        assertEq(balFinal, balAfter + 10000000, "Refund expected (Buffer was pre-charged but not in final)");
        assertEq(paymaster.protocolRevenue(), 110000000, "Protocol Revenue should be Cost + Fee");
        // user pays exactly the charge in xPNTs (xc = ceil(c * x0 / a0) = c at 1:1); escrow cleared
        assertEq(userBal0 - xpntsToken.balanceOf(user1), 110000000, "burned xPNTs == aPNTs charge");
        assertEq(xpntsToken.lockedOf(user1), 0, "escrow cleared");
        (fOp, fA0) = paymaster.inflightOf(bytes32(0));
        assertEq(fOp, address(0), "in-flight record deleted");
    }

    function test_V3_Pricing_Refund_When_Gas_Low() public {
        // --- Scenario ---
        // Gas Used is HALF of Max.
        // Validation charged MAX * 1.1
        // PostOp charges HALF * 1.1
        // Refund should be huge.
        
        uint256 maxCost = 1000;
        uint256 actualCost = 500;
        
        // Setup UserOp (Same as above)
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = _pmd();
        
        // 1. Validate
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
        
        (uint128 balAfterVal,,,,,,,,) = paymaster.operators(operator1);
        uint256 preCharge = 120000000; // Based on 1000 gas
        assertEq(5000 ether - balAfterVal, preCharge);
        
        // 2. PostOp
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);
        
        // 3. Verify
        // Actual Cost Base = 50,000,000
        // With Fee (1.1x) = 55,000,000
        // Refund = 120,000,000 - 55,000,000 = 65,000,000
        
        (uint128 balFinal,,,,,,,,) = paymaster.operators(operator1);
        assertEq(balFinal, balAfterVal + 65000000, "Should refund unused gas cost + buffer part");
        assertEq(paymaster.protocolRevenue(), 55000000, "revenue == charge (no a0 left as revenue)");
    }

    // ─── 5.5.0 postOp formula (spec 03 §10.3 / R10-M3) ─────────────────────────

    function _pmd() internal view returns (bytes memory) {
        return V2TokenDeployer.pmd(address(paymaster), 0, 200000, operator1, type(uint256).max, address(xpntsToken), 0);
    }

    function _opWithCallGas(uint128 callGas) internal view returns (PackedUserOperation memory op) {
        op.sender = user1;
        op.accountGasLimits = bytes32((uint256(0) << 128) | uint256(callGas)); // [verif 16][call 16]
        op.paymasterAndData = _pmd();
    }

    /// @notice R10-M3 (exp/buffer): bufWei = (C_POSTOP + ceil((callGas + postOpGas) * 10 / 100) + C_WRAP) * feePerGas,
    ///         charge = min(a0, ceil(calc_snap(actualGasCost + bufWei) * (BPS + fee) / BPS)).
    ///         C_POSTOP = 175_000 (exp/params default), postOpGas = 200_000, callGas = 100_000, C_WRAP = 5_000, feePerGas = 1 gwei:
    ///         bufWei = (175_000 + 30_000 + 5_000) * 1e9 = 2.1e14 wei.
    ///         calc(1e14 + 2.1e14) at $2000 / $0.02 = 3.1e19 aPNTs; charge = 3.41e19.
    ///         a0 = ceil(calc(1e15) * 1.2) = 1.2e20, so the refund is 8.59e19.
    ///         Discriminates the buffer: with bufWei = 0 the charge would be 1.1e19.
    function test_PostOp_ConservativeBuffer_R10M3() public {
        uint256 maxCost = 1e15;
        PackedUserOperation memory op = _opWithCallGas(100_000);
        bytes32 h = keccak256("buf");

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, h, maxCost);
        assertEq(uint160(vd), 0, "validation passes");
        (uint128 balAfterVal,,,,,,,,) = paymaster.operators(operator1);
        assertEq(5000 ether - balAfterVal, 1.2e20, "a0 = ceil(calc(maxCost) * 1.2)");

        vm.expectEmit(true, true, false, true, address(paymaster));
        emit ISuperPaymaster.TransactionSponsored(operator1, user1, 3.1e19, 3.41e19);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);

        (uint128 balFinal,,,,,,,,) = paymaster.operators(operator1);
        assertEq(uint256(balFinal) - balAfterVal, 1.2e20 - 3.41e19, "operator refund = a0 - charge");
        assertEq(paymaster.protocolRevenue(), 3.41e19, "revenue = charge");
    }

    /// @notice §10.3: c = min(a0, ...). An actualGasCost far above maxCost is charged exactly a0
    ///         (the user never pays more than the reservation it committed to); no refund.
    function test_PostOp_ChargeCappedAtReservation() public {
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = _pmd();
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        (uint128 balAfterVal,,,,,,,,) = paymaster.operators(operator1);
        uint256 userBal0 = xpntsToken.balanceOf(user1);

        vm.prank(address(entryPoint));
        // D3-M: low-level call — without the cap the refund (a0 - charge) underflows and postOp
        // reverts; report that through a named assertion.
        (bool ok,) = address(paymaster).call(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 10_000, 0)) // uncapped: 1.1e9
        );
        assertTrue(ok, "actual >> maxCost must still settle (charge capped at a0), not revert");

        (uint128 balFinal,,,,,,,,) = paymaster.operators(operator1);
        assertEq(balFinal, balAfterVal, "no refund when charge == a0");
        assertEq(paymaster.protocolRevenue(), 120000000, "charge capped at a0");
        assertEq(userBal0 - xpntsToken.balanceOf(user1), 120000000, "user burns at most x0");
    }

    /// @notice D3-M: every other test in this file uses round numbers, so the Ceil rounding
    ///         directions of spec §10.3 were never observable. aPNTs at $0.021 makes both the
    ///         conversion and the markups inexact:
    ///           aGas = ceil(1001 * 2000e8 * 1e18 / (1e8 * 0.021e18)) = ceil(95,333,333.3) = 95,333,334
    ///           a0   = ceil(aGas * 1.2)  = ceil(114,400,000.8) = 114,400,001
    ///           c    = ceil(aGas * 1.1)  = ceil(104,866,667.4) = 104,866,668   (feePerGas = 0)
    function test_A0_And_Charge_RoundUp() public {
        vm.prank(owner);
        paymaster.setAPNTSPrice(0.021 ether);
        PackedUserOperation memory op = _opWithCallGas(0);

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, keccak256("round"), 1001);
        assertEq(uint160(vd), 0);
        (uint128 b0,,,,,,,,) = paymaster.operators(operator1);
        assertEq(5000 ether - uint256(b0), 114400001, "a0 rounds up at both steps");

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1001, 0);
        assertEq(paymaster.protocolRevenue(), 104866668, "charge rounds up at both steps");
    }

    /// @notice R10-M3: postOp prices with the VALIDATION-time snapshot carried in context, not
    ///         the cache at postOp time. Positive control: after the cache moves to $3000 a new
    ///         validation reserves a different a0, so the price change is live.
    function test_PostOp_UsesValidationPriceSnapshot() public {
        uint256 maxCost = 1e15;
        PackedUserOperation memory op = _opWithCallGas(0);

        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, keccak256("snap1"), maxCost);
        (uint128 b0,,,,,,,,) = paymaster.operators(operator1);
        assertEq(5000 ether - b0, 1.2e20, "a0 at $2000");

        priceFeed.setPrice(3000e8);
        paymaster.updatePrice();

        // control: the cache really moved (a0 at $3000 = ceil(1.5e20 * 1.2) = 1.8e20)
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, keccak256("snap2"), maxCost);
        (uint128 b1,,,,,,,,) = paymaster.operators(operator1);
        assertEq(uint256(b0) - b1, 1.8e20, "control: a0 at $3000");

        // D3-M: the aPNTs USD price is part of the snapshot too (OpCtx.aPriceUSD). Move it (+5%,
        // inside the ±10% setter band) so a postOp that read the live aPNTsPriceUSD would differ.
        vm.prank(owner);
        paymaster.setAPNTSPrice(0.021 ether);
        assertEq(paymaster.aPNTsPriceUSD(), 0.021 ether, "control: aPNTs price really moved");

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 0);
        // snapshot price $2000: ceil(1e19 * 1.1) = 1.1e19 (at $3000 it would be 1.65e19)
        assertEq(paymaster.protocolRevenue(), 1.1e19, "charge priced at the validation snapshot");
    }
}
