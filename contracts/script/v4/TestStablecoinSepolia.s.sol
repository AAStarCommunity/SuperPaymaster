// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/PaymasterBase.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/mocks/MockUSDT.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/**
 * @title TestStablecoinSepolia
 * @notice Full stablecoin E2E test on Sepolia:
 *   Phase A: Deploy new V4 implementation (with getSupportedTokens etc.)
 *   Phase B: Register impl in factory, deploy new proxy as Anni
 *   Phase C: Configure Circle USDC + MockUSDT, deposit ETH to EntryPoint
 *   Phase D: Mint MockUSDT, deposit USDC + USDT for test user
 *   Phase E: Verify balances, supported tokens list
 *
 * @dev Prerequisites:
 *   - source .env.sepolia
 *   - Deployer has ETH for gas
 *   - For USDC deposit: get tokens from https://faucet.circle.com/
 *
 * Usage:
 *   source .env.sepolia
 *   forge script contracts/script/v4/TestStablecoinSepolia.s.sol:TestStablecoinSepolia \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast --account sepolia-deployer -vvv
 */
contract TestStablecoinSepolia is Script {
    using Clones for address;
    // --- Sepolia Constants ---
    address constant CIRCLE_USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant REGISTRY = 0x997686219F31405503D32728B1f094F115EF24e7;
    address constant FACTORY = 0x58A7F6E44a57028A255794119F8b37124c9a7eB8;

    uint256 constant STABLECOIN_PRICE = 1e8; // $1.00
    uint256 constant SERVICE_FEE = 200;       // 2%
    uint256 constant MAX_GAS_CAP = 0.1 ether;
    uint256 constant STALENESS = 86400;       // 24h
    uint256 constant EP_DEPOSIT = 0.01 ether;

    function run() external {
        address deployer = msg.sender;
        PaymasterFactory factory = PaymasterFactory(FACTORY);

        console.log("============================================");
        console.log("  PaymasterV4 Stablecoin Test - Sepolia");
        console.log("============================================");
        console.log("Deployer:", deployer);

        vm.startBroadcast();

        // =============================================
        // Phase A: Deploy new V4 Implementation
        // =============================================
        console.log("\n--- Phase A: Deploy new V4 Implementation ---");
        Paymaster newImpl = new Paymaster(REGISTRY);
        console.log("New V4 impl deployed:", address(newImpl));

        // =============================================
        // Phase B: Register in factory + deploy proxy
        // =============================================
        console.log("\n--- Phase B: Register impl & deploy proxy ---");
        string memory versionTag = "v4.3.1-stablecoin";

        // Register new implementation (factory owner = deployer)
        factory.addImplementation(versionTag, address(newImpl));
        console.log("Registered impl version:", versionTag);

        // Check if deployer already has a paymaster
        address existingPM = factory.paymasterByOperator(deployer);
        address paymasterAddr;

        if (existingPM != address(0)) {
            console.log("Deployer already has V4 proxy:", existingPM);
            console.log("Deploying new proxy with CREATE2 salt...");

            // Use deterministic deploy with salt to get a new proxy
            // Factory requires different operator, so we deploy directly via Clones
            // Instead: deploy manually (clone + initialize)
            paymasterAddr = Clones.clone(address(newImpl));
            Paymaster(payable(paymasterAddr)).initialize(
                ENTRY_POINT,
                deployer,
                deployer, // treasury = deployer for test
                ETH_USD_FEED,
                SERVICE_FEE,
                MAX_GAS_CAP,
                STALENESS
            );
            console.log("New V4 proxy (manual clone):", paymasterAddr);
        } else {
            // Encode initialize call
            bytes memory initData = abi.encodeCall(
                Paymaster.initialize,
                (ENTRY_POINT, deployer, deployer, ETH_USD_FEED, SERVICE_FEE, MAX_GAS_CAP, STALENESS)
            );
            paymasterAddr = factory.deployPaymaster(versionTag, initData);
            console.log("New V4 proxy (via factory):", paymasterAddr);
        }

        PaymasterBase paymaster = PaymasterBase(payable(paymasterAddr));
        console.log("Version:", Paymaster(payable(paymasterAddr)).version());

        // =============================================
        // Phase C: Configure tokens + fund EntryPoint
        // =============================================
        console.log("\n--- Phase C: Configure tokens ---");

        // Deploy MockUSDT
        MockUSDT mockUSDT = new MockUSDT();
        console.log("MockUSDT deployed:", address(mockUSDT));

        // Configure USDC ($1.00)
        paymaster.setTokenPrice(CIRCLE_USDC_SEPOLIA, STABLECOIN_PRICE);
        console.log("USDC set: price=$1.00  dec=%d", paymaster.tokenDecimals(CIRCLE_USDC_SEPOLIA));

        // Configure MockUSDT ($1.00)
        paymaster.setTokenPrice(address(mockUSDT), STABLECOIN_PRICE);
        console.log("USDT set: price=$1.00  dec=%d", paymaster.tokenDecimals(address(mockUSDT)));

        // Update price cache
        paymaster.updatePrice();
        (uint208 cachedPrice, uint48 cachedAt) = paymaster.cachedPrice();
        console.log("ETH/USD: $%d (8dec) @ %d", uint256(cachedPrice), uint256(cachedAt));

        // Deposit ETH to EntryPoint
        paymaster.addDeposit{value: EP_DEPOSIT}();
        uint256 epBal = IEntryPoint(ENTRY_POINT).balanceOf(paymasterAddr);
        console.log("EntryPoint deposit: %d wei", epBal);

        // =============================================
        // Phase D: Deposit stablecoins for test user
        // =============================================
        console.log("\n--- Phase D: Deposit stablecoins ---");
        address testUser = deployer;

        // MockUSDT: mint + approve + deposit
        uint256 usdtAmount = 100 * 1e6; // 100 USDT
        mockUSDT.mint(testUser, usdtAmount);
        IERC20(address(mockUSDT)).approve(paymasterAddr, usdtAmount);
        paymaster.depositFor(testUser, address(mockUSDT), usdtAmount);
        console.log("[USDT] Deposited %d for %s", usdtAmount, testUser);

        // Circle USDC: check balance first
        uint256 usdcWallet = IERC20(CIRCLE_USDC_SEPOLIA).balanceOf(testUser);
        console.log("[USDC] Wallet balance: %d", usdcWallet);
        if (usdcWallet > 0) {
            uint256 usdcDeposit = usdcWallet > 50 * 1e6 ? 50 * 1e6 : usdcWallet;
            IERC20(CIRCLE_USDC_SEPOLIA).approve(paymasterAddr, usdcDeposit);
            paymaster.depositFor(testUser, CIRCLE_USDC_SEPOLIA, usdcDeposit);
            console.log("[USDC] Deposited %d for %s", usdcDeposit, testUser);
        } else {
            console.log("[USDC] SKIP - no balance. Get from https://faucet.circle.com/");
        }

        vm.stopBroadcast();

        // =============================================
        // Phase E: Verification (read-only)
        // =============================================
        console.log("\n============================================");
        console.log("  VERIFICATION");
        console.log("============================================");

        // Balances
        uint256 usdtBal = paymaster.balances(testUser, address(mockUSDT));
        uint256 usdcBal = paymaster.balances(testUser, CIRCLE_USDC_SEPOLIA);
        console.log("Internal [USDT]: %d", usdtBal);
        console.log("Internal [USDC]: %d", usdcBal);

        // Supported tokens
        address[] memory tokens = paymaster.getSupportedTokens();
        console.log("\nSupported tokens (%d):", tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("  [%d] %s", i, tokens[i]);
            console.log("       price=%d  dec=%d",
                paymaster.tokenPrices(tokens[i]),
                paymaster.tokenDecimals(tokens[i])
            );
        }

        // Assertions
        console.log("\n--- Results ---");
        require(usdtBal == usdtAmount, "FAIL: USDT deposit");
        console.log("[PASS] USDT deposit: %d", usdtBal);

        if (usdcWallet > 0) {
            require(usdcBal > 0, "FAIL: USDC deposit");
            console.log("[PASS] USDC deposit: %d", usdcBal);
        } else {
            console.log("[SKIP] USDC deposit (get from faucet.circle.com)");
        }

        require(tokens.length == 2, "FAIL: expected 2 tokens");
        console.log("[PASS] Token count: %d", tokens.length);

        require(epBal >= EP_DEPOSIT, "FAIL: EntryPoint underfunded");
        console.log("[PASS] EntryPoint funded");

        // Output for next steps
        console.log("\n============================================");
        console.log("  Save these for gasless tx test:");
        console.log("============================================");
        console.log("PAYMASTER_V4=%s", paymasterAddr);
        console.log("MOCK_USDT=%s", address(mockUSDT));
        console.log("USDC=%s", CIRCLE_USDC_SEPOLIA);
    }

}
