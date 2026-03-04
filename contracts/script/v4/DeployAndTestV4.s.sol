// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/PaymasterBase.sol";
import "src/mocks/MockUSDT.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {PostOpMode} from "singleton-paymaster/src/interfaces/PostOpMode.sol";

/**
 * @title DeployAndTestV4
 * @notice Standalone deployment + comprehensive test of PaymasterV4 on Sepolia.
 *         No dependency on existing factory, deployer keystore, or other contracts.
 *
 * Tests:
 *   T1. Deploy impl + clone proxy + initialize
 *   T2. setTokenPrice (USDC + MockUSDT) + verify decimals auto-detect
 *   T3. getSupportedTokens / getSupportedTokensInfo / isTokenSupported
 *   T4. Deposit ETH to EntryPoint
 *   T5. updatePrice (Chainlink cache)
 *   T6. MockUSDT mint → depositFor → verify internal balance
 *   T7. Circle USDC depositFor (if balance > 0)
 *   T8. withdraw → verify balance decreased + ERC20 returned
 *   T9. removeToken → verify list shrunk + deposit reverts
 *   T10. Re-add token → verify works again
 *   T11. setTokenPrice update (no duplicate in list)
 *   T12. Admin: setTreasury, setServiceFeeRate, setPriceStalenessThreshold
 *   T13. Pause / unpause
 *
 * Usage:
 *   source .env.sepolia
 *   forge script contracts/script/v4/DeployAndTestV4.s.sol:DeployAndTestV4 \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY_JASON --slow -vvv
 */
contract DeployAndTestV4 is Script {
    using Clones for address;

    // Sepolia constants
    address constant ENTRY_POINT   = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ETH_USD_FEED  = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant REGISTRY      = 0x997686219F31405503D32728B1f094F115EF24e7;
    address constant CIRCLE_USDC   = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    uint256 constant STABLECOIN_PRICE = 1e8;   // $1.00
    uint256 constant SERVICE_FEE      = 200;   // 2%
    uint256 constant MAX_GAS_CAP      = 0.5 ether;
    uint256 constant STALENESS        = 86400; // 24h
    uint256 constant EP_DEPOSIT       = 0.02 ether;

    uint256 passed;
    uint256 failed;
    uint256 skipped;

    function pass(string memory name) internal {
        passed++;
        console.log("  [PASS] %s", name);
    }

    function fail(string memory name, string memory reason) internal {
        failed++;
        console.log("  [FAIL] %s: %s", name, reason);
    }

    function skip(string memory name, string memory reason) internal {
        skipped++;
        console.log("  [SKIP] %s: %s", name, reason);
    }

    function run() external {
        address deployer = msg.sender;

        console.log("================================================");
        console.log("  PaymasterV4 Standalone Deploy & Test - Sepolia");
        console.log("================================================");
        console.log("Deployer:", deployer);
        console.log("Chain: Sepolia (11155111)");

        vm.startBroadcast();

        // =============================================
        // T1: Deploy impl + clone + initialize
        // =============================================
        console.log("\n--- T1: Deploy & Initialize ---");

        Paymaster impl = new Paymaster(REGISTRY);
        console.log("Implementation:", address(impl));

        address proxyAddr = address(impl).clone();
        Paymaster proxy = Paymaster(payable(proxyAddr));
        proxy.initialize(
            ENTRY_POINT,
            deployer,   // owner
            deployer,   // treasury (self for test)
            ETH_USD_FEED,
            SERVICE_FEE,
            MAX_GAS_CAP,
            STALENESS
        );

        console.log("Proxy:", proxyAddr);
        console.log("Version:", proxy.version());

        PaymasterBase pm = PaymasterBase(payable(proxyAddr));

        if (pm.treasury() == deployer && pm.serviceFeeRate() == SERVICE_FEE) {
            pass("T1: Deploy + Initialize");
        } else {
            fail("T1", "Bad init state");
        }

        // =============================================
        // T2: Configure tokens
        // =============================================
        console.log("\n--- T2: Configure Tokens ---");

        MockUSDT mockUSDT = new MockUSDT();
        console.log("MockUSDT:", address(mockUSDT));

        pm.setTokenPrice(CIRCLE_USDC, STABLECOIN_PRICE);
        pm.setTokenPrice(address(mockUSDT), STABLECOIN_PRICE);

        bool usdcOk = pm.tokenPrices(CIRCLE_USDC) == STABLECOIN_PRICE
                    && pm.tokenDecimals(CIRCLE_USDC) == 6;
        bool usdtOk = pm.tokenPrices(address(mockUSDT)) == STABLECOIN_PRICE
                    && pm.tokenDecimals(address(mockUSDT)) == 6;

        if (usdcOk && usdtOk) {
            pass("T2: setTokenPrice + decimals auto-detect");
        } else {
            fail("T2", "Price or decimals mismatch");
        }

        // =============================================
        // T3: Token list queries
        // =============================================
        console.log("\n--- T3: Token List Queries ---");

        address[] memory tokens = pm.getSupportedTokens();
        (address[] memory tAddrs, uint256[] memory tPrices, uint8[] memory tDecs)
            = pm.getSupportedTokensInfo();

        bool t3ok = tokens.length == 2
            && pm.isTokenSupported(CIRCLE_USDC)
            && pm.isTokenSupported(address(mockUSDT))
            && !pm.isTokenSupported(address(0x1234))
            && tAddrs.length == 2
            && tPrices[0] == STABLECOIN_PRICE
            && tDecs[0] == 6;

        if (t3ok) {
            pass("T3: getSupportedTokens / Info / isTokenSupported");
        } else {
            fail("T3", "List query mismatch");
        }

        for (uint256 i = 0; i < tAddrs.length; i++) {
            console.log("  token[%d]: %s", i, tAddrs[i]);
            console.log("       price=%d  dec=%d", tPrices[i], tDecs[i]);
        }

        // =============================================
        // T4: Deposit ETH to EntryPoint
        // =============================================
        console.log("\n--- T4: EntryPoint Deposit ---");
        pm.addDeposit{value: EP_DEPOSIT}();
        uint256 epBal = IEntryPoint(ENTRY_POINT).balanceOf(proxyAddr);
        if (epBal >= EP_DEPOSIT) {
            pass("T4: EntryPoint deposit");
            console.log("  Balance: %d wei", epBal);
        } else {
            fail("T4", "EntryPoint underfunded");
        }

        // =============================================
        // T5: Update price cache
        // =============================================
        console.log("\n--- T5: Price Cache ---");
        pm.updatePrice();
        (uint208 cachedPrice, uint48 cachedAt) = pm.cachedPrice();
        if (uint256(cachedPrice) > 0 && uint256(cachedAt) > 0) {
            pass("T5: updatePrice from Chainlink");
            console.log("  ETH/USD: $%d  at=%d", uint256(cachedPrice), uint256(cachedAt));
        } else {
            fail("T5", "Price cache empty");
        }

        // =============================================
        // T6: MockUSDT deposit
        // =============================================
        console.log("\n--- T6: MockUSDT Deposit ---");
        uint256 usdtAmount = 500 * 1e6; // 500 USDT
        mockUSDT.mint(deployer, usdtAmount);
        IERC20(address(mockUSDT)).approve(proxyAddr, usdtAmount);
        pm.depositFor(deployer, address(mockUSDT), usdtAmount);

        uint256 usdtBal = pm.balances(deployer, address(mockUSDT));
        if (usdtBal == usdtAmount) {
            pass("T6: MockUSDT depositFor");
            console.log("  Internal balance: %d", usdtBal);
        } else {
            fail("T6", "Balance mismatch");
        }

        // =============================================
        // T7: Circle USDC deposit (if available)
        // =============================================
        console.log("\n--- T7: Circle USDC Deposit ---");
        uint256 usdcWallet = IERC20(CIRCLE_USDC).balanceOf(deployer);
        if (usdcWallet > 0) {
            uint256 usdcDeposit = usdcWallet > 100 * 1e6 ? 100 * 1e6 : usdcWallet;
            IERC20(CIRCLE_USDC).approve(proxyAddr, usdcDeposit);
            pm.depositFor(deployer, CIRCLE_USDC, usdcDeposit);
            uint256 usdcBal = pm.balances(deployer, CIRCLE_USDC);
            if (usdcBal == usdcDeposit) {
                pass("T7: Circle USDC depositFor");
            } else {
                fail("T7", "USDC balance mismatch");
            }
        } else {
            skip("T7", "No USDC - get from faucet.circle.com");
        }

        // =============================================
        // T8: Withdraw
        // =============================================
        console.log("\n--- T8: Withdraw ---");
        uint256 withdrawAmt = 50 * 1e6; // 50 USDT
        uint256 walletBefore = IERC20(address(mockUSDT)).balanceOf(deployer);
        pm.withdraw(address(mockUSDT), withdrawAmt);
        uint256 walletAfter = IERC20(address(mockUSDT)).balanceOf(deployer);
        uint256 internalAfter = pm.balances(deployer, address(mockUSDT));

        if (walletAfter == walletBefore + withdrawAmt && internalAfter == usdtAmount - withdrawAmt) {
            pass("T8: withdraw");
            console.log("  Wallet: +%d  Internal: %d", withdrawAmt, internalAfter);
        } else {
            fail("T8", "Withdraw balance mismatch");
        }

        // =============================================
        // T9: removeToken
        // =============================================
        console.log("\n--- T9: removeToken ---");
        pm.removeToken(CIRCLE_USDC);

        bool t9ok = !pm.isTokenSupported(CIRCLE_USDC)
            && pm.getSupportedTokens().length == 1
            && pm.tokenPrices(CIRCLE_USDC) == 0
            && pm.tokenDecimals(CIRCLE_USDC) == 0;

        if (t9ok) {
            pass("T9: removeToken (USDC removed)");
        } else {
            fail("T9", "Token not properly removed");
        }

        // Verify deposit reverts for removed token (can't try/catch in script broadcast,
        // so we just verify the state)
        console.log("  Remaining tokens: %d", pm.getSupportedTokens().length);

        // =============================================
        // T10: Re-add token
        // =============================================
        console.log("\n--- T10: Re-add Token ---");
        pm.setTokenPrice(CIRCLE_USDC, STABLECOIN_PRICE);

        bool t10ok = pm.isTokenSupported(CIRCLE_USDC)
            && pm.getSupportedTokens().length == 2
            && pm.tokenPrices(CIRCLE_USDC) == STABLECOIN_PRICE
            && pm.tokenDecimals(CIRCLE_USDC) == 6;

        if (t10ok) {
            pass("T10: Re-add USDC after remove");
        } else {
            fail("T10", "Re-add failed");
        }

        // =============================================
        // T11: Price update (no duplicate)
        // =============================================
        console.log("\n--- T11: Price Update (no dup) ---");
        pm.setTokenPrice(address(mockUSDT), 1.01e8); // $1.01

        bool t11ok = pm.getSupportedTokens().length == 2
            && pm.tokenPrices(address(mockUSDT)) == 1.01e8;

        if (t11ok) {
            pass("T11: setTokenPrice update, no duplicate");
        } else {
            fail("T11", "Duplicate or price wrong");
        }
        // Reset price
        pm.setTokenPrice(address(mockUSDT), STABLECOIN_PRICE);

        // =============================================
        // T12: Admin setters
        // =============================================
        console.log("\n--- T12: Admin Setters ---");
        address newTreasury = address(0xBEEF);
        pm.setTreasury(newTreasury);
        bool t12a = pm.treasury() == newTreasury;
        pm.setTreasury(deployer); // reset

        pm.setServiceFeeRate(300); // 3%
        bool t12b = pm.serviceFeeRate() == 300;
        pm.setServiceFeeRate(SERVICE_FEE); // reset

        pm.setPriceStalenessThreshold(7200);
        bool t12c = pm.priceStalenessThreshold() == 7200;
        pm.setPriceStalenessThreshold(STALENESS); // reset

        pm.setMaxGasCostCap(1 ether);
        bool t12d = pm.maxGasCostCap() == 1 ether;
        pm.setMaxGasCostCap(MAX_GAS_CAP); // reset

        if (t12a && t12b && t12c && t12d) {
            pass("T12: Admin setters (treasury, fee, staleness, gasCap)");
        } else {
            fail("T12", "Setter mismatch");
        }

        // =============================================
        // T13: Pause check (state only, no tx test)
        // =============================================
        console.log("\n--- T13: Pause State ---");
        bool notPaused = !pm.paused();
        // We don't actually pause because there's no unpause function in the contract
        // Just verify initial state
        if (notPaused) {
            pass("T13: Initial state not paused");
        } else {
            fail("T13", "Should not be paused");
        }

        vm.stopBroadcast();

        // =============================================
        // Final Summary
        // =============================================
        console.log("\n================================================");
        console.log("  RESULTS: %d passed, %d failed, %d skipped", passed, failed, skipped);
        console.log("================================================");

        console.log("\n  Deployed Addresses (save these):");
        console.log("  V4_IMPL=%s", address(impl));
        console.log("  V4_PROXY=%s", proxyAddr);
        console.log("  MOCK_USDT=%s", address(mockUSDT));
        console.log("  USDC=%s", CIRCLE_USDC);

        require(failed == 0, "Some tests failed!");
    }
}
