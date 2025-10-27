// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ChainlinkFeeds
 * @notice Chainlink ETH/USD Price Feed addresses for different networks
 * @dev Use this library to get the correct Chainlink feed address for your network
 *
 * Reference: https://docs.chain.link/data-feeds/price-feeds/addresses
 *
 * Usage in deployment scripts:
 *   address feed = ChainlinkFeeds.getETHUSDFeed(block.chainid);
 */
library ChainlinkFeeds {
    /// @notice Error when network is not supported
    error UnsupportedNetwork(uint256 chainId);

    /**
     * @notice Get ETH/USD price feed address for a given chain ID
     * @param chainId The chain ID to get the feed for
     * @return feed Address of the ETH/USD price feed
     */
    function getETHUSDFeed(uint256 chainId) internal pure returns (address feed) {
        // Mainnet Networks
        if (chainId == 1) {
            // Ethereum Mainnet
            return 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        } else if (chainId == 137) {
            // Polygon Mainnet
            return 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
        } else if (chainId == 42161) {
            // Arbitrum One
            return 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        } else if (chainId == 10) {
            // Optimism
            return 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
        } else if (chainId == 8453) {
            // Base
            return 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
        } else if (chainId == 56) {
            // BNB Smart Chain
            return 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
        } else if (chainId == 43114) {
            // Avalanche C-Chain
            return 0x976B3D034E162d8bD72D6b9C989d545b839003b0;
        } else if (chainId == 250) {
            // Fantom
            return 0x11DdD3d147E5b83D01cee7070027092397d63658;
        } else if (chainId == 100) {
            // Gnosis Chain
            return 0xa767f745331D267c7751297D982b050c93985627;
        } else if (chainId == 42220) {
            // Celo
            return 0x022F9dCC73C5Fb43F2b4eF2EF9ad3eDD1D853946;
        }
        // Testnet Networks
        else if (chainId == 11155111) {
            // Sepolia
            return 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        } else if (chainId == 80001 || chainId == 80002) {
            // Mumbai (80001 - deprecated) or Amoy (80002 - new)
            if (chainId == 80001) {
                return 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada; // Mumbai
            } else {
                return 0xF0d50568e3A7e8259E16663972b11910F89BD8e7; // Amoy
            }
        } else if (chainId == 421614) {
            // Arbitrum Sepolia
            return 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
        } else if (chainId == 11155420) {
            // Optimism Sepolia
            return 0x61Ec26aA57019C486B10502285c5A3D4A4750AD7;
        } else if (chainId == 84532) {
            // Base Sepolia
            return 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
        } else if (chainId == 97) {
            // BNB Smart Chain Testnet
            return 0x143db3CEEfbdfe5631aDD3E50f7614B6ba708BA7;
        } else if (chainId == 43113) {
            // Avalanche Fuji
            return 0x86d67c3D38D2bCeE722E601025C25a575021c6EA;
        } else {
            revert UnsupportedNetwork(chainId);
        }
    }

    /**
     * @notice Get network name for a given chain ID
     * @param chainId The chain ID
     * @return name Network name
     */
    function getNetworkName(uint256 chainId) internal pure returns (string memory name) {
        if (chainId == 1) return "Ethereum Mainnet";
        if (chainId == 137) return "Polygon";
        if (chainId == 42161) return "Arbitrum One";
        if (chainId == 10) return "Optimism";
        if (chainId == 8453) return "Base";
        if (chainId == 56) return "BNB Chain";
        if (chainId == 43114) return "Avalanche";
        if (chainId == 250) return "Fantom";
        if (chainId == 100) return "Gnosis";
        if (chainId == 42220) return "Celo";
        if (chainId == 11155111) return "Sepolia";
        if (chainId == 80001) return "Mumbai";
        if (chainId == 80002) return "Amoy";
        if (chainId == 421614) return "Arbitrum Sepolia";
        if (chainId == 11155420) return "Optimism Sepolia";
        if (chainId == 84532) return "Base Sepolia";
        if (chainId == 97) return "BNB Testnet";
        if (chainId == 43113) return "Fuji";
        return "Unknown";
    }

    /**
     * @notice Check if a network is supported
     * @param chainId The chain ID to check
     * @return supported True if the network is supported
     */
    function isNetworkSupported(uint256 chainId) internal pure returns (bool supported) {
        // Mainnet chains
        if (chainId == 1) return true;      // Ethereum
        if (chainId == 137) return true;    // Polygon
        if (chainId == 42161) return true;  // Arbitrum
        if (chainId == 10) return true;     // Optimism
        if (chainId == 8453) return true;   // Base
        if (chainId == 56) return true;     // BSC
        if (chainId == 43114) return true;  // Avalanche
        if (chainId == 250) return true;    // Fantom
        if (chainId == 100) return true;    // Gnosis
        if (chainId == 42220) return true;  // Celo

        // Testnet chains
        if (chainId == 11155111) return true; // Sepolia
        if (chainId == 80001) return true;    // Mumbai
        if (chainId == 80002) return true;    // Amoy
        if (chainId == 421614) return true;   // Arbitrum Sepolia
        if (chainId == 11155420) return true; // Optimism Sepolia
        if (chainId == 84532) return true;    // Base Sepolia
        if (chainId == 97) return true;       // BSC Testnet
        if (chainId == 43113) return true;    // Fuji

        return false;
    }
}
