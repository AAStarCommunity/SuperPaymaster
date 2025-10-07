#!/bin/bash

# Gemini Minter Balance Checker Script
# Usage: ./check-balances.sh [ADDRESS]
# If no address provided, uses default owner address

# Contract addresses (from backend/.env)
PNTS_ADDRESS="0x3e7B771d4541eC85c8137e950598Ac97553a337a"
NFT_ADDRESS="0xC9fB3Fe98442A23a0CA5884dC114989FF7b3d97a" 
SBT_ADDRESS="0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f"

# Default owner address
DEFAULT_ADDRESS="0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"

# RPC URL
RPC_URL="https://eth-sepolia.g.alchemy.com/v2/IIY_LZOlEuy66agzhxpYexmEaHuMskl-"

# Use provided address or default
ADDRESS=${1:-$DEFAULT_ADDRESS}

echo "🔍 Checking balances for address: $ADDRESS"
echo "📅 $(date)"
echo "🌐 Network: Ethereum Sepolia Testnet"
echo "═══════════════════════════════════════════════════════════════════"

# Function to convert hex to decimal using cast
hex_to_decimal() {
    cast --to-dec "$1" 2>/dev/null || echo "0"
}

# Function to format PNTs balance (divide by 10^18)
format_pnts() {
    local balance_hex="$1"
    local balance_dec=$(hex_to_decimal "$balance_hex")
    # Use bc for decimal division if available, otherwise show raw value
    if command -v bc >/dev/null 2>&1 && [ "$balance_dec" != "0" ]; then
        echo "scale=6; $balance_dec / 1000000000000000000" | bc
    else
        echo "$balance_dec (raw Wei - divide by 10^18 for token amount)"
    fi
}

echo "💰 PNTs Token Balance (ERC20):"
echo "   Contract: $PNTS_ADDRESS"
pnts_balance=$(cast call $PNTS_ADDRESS "balanceOf(address)" $ADDRESS --rpc-url $RPC_URL 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$pnts_balance" ]; then
    formatted_pnts=$(format_pnts "$pnts_balance")
    echo "   Balance: $formatted_pnts PNTs"
    echo "   Raw: $pnts_balance"
else
    echo "   ❌ Failed to fetch PNTs balance"
fi

echo ""
echo "🖼️  NFT Balance (ERC721):"
echo "   Contract: $NFT_ADDRESS"
nft_balance=$(cast call $NFT_ADDRESS "balanceOf(address)" $ADDRESS --rpc-url $RPC_URL 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$nft_balance" ]; then
    nft_count=$(hex_to_decimal "$nft_balance")
    echo "   Balance: $nft_count NFTs"
    echo "   Raw: $nft_balance"
    
    # Try to get token ID 0 owner if balance > 0
    if [ "$nft_count" -gt 0 ]; then
        echo "   🔍 Checking NFT #0 owner:"
        nft_owner=$(cast call $NFT_ADDRESS "ownerOf(uint256)" 0 --rpc-url $RPC_URL 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$nft_owner" ]; then
            nft_owner_checksum=$(cast --to-checksum-address "$nft_owner" 2>/dev/null)
            echo "      Owner: $nft_owner_checksum"
        fi
    fi
else
    echo "   ❌ Failed to fetch NFT balance"
fi

echo ""
echo "🔒 SBT Balance (Soul-Bound Token):"
echo "   Contract: $SBT_ADDRESS"
sbt_balance=$(cast call $SBT_ADDRESS "balanceOf(address)" $ADDRESS --rpc-url $RPC_URL 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$sbt_balance" ]; then
    sbt_count=$(hex_to_decimal "$sbt_balance")
    echo "   Balance: $sbt_count SBTs"
    echo "   Raw: $sbt_balance"
    
    # Try to get token ID 0 owner if balance > 0
    if [ "$sbt_count" -gt 0 ]; then
        echo "   🔍 Checking SBT #0 owner:"
        sbt_owner=$(cast call $SBT_ADDRESS "ownerOf(uint256)" 0 --rpc-url $RPC_URL 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$sbt_owner" ]; then
            sbt_owner_checksum=$(cast --to-checksum-address "$sbt_owner" 2>/dev/null)
            echo "      Owner: $sbt_owner_checksum"
        fi
    fi
else
    echo "   ❌ Failed to fetch SBT balance"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "🔗 Etherscan Links:"
echo "   Address: https://sepolia.etherscan.io/address/$ADDRESS"
echo "   PNTs: https://sepolia.etherscan.io/address/$PNTS_ADDRESS"
echo "   NFT: https://sepolia.etherscan.io/address/$NFT_ADDRESS"  
echo "   SBT: https://sepolia.etherscan.io/address/$SBT_ADDRESS"
echo ""
echo "💡 Usage Examples:"
echo "   ./check-balances.sh                                    # Check owner balance"
echo "   ./check-balances.sh 0xE3D28Aa77c95d5C098170698e5ba68824BFC008d  # Check specific address"
echo "   ./check-balances.sh 0x008DcCfB60B5AC6e53d4062b1B11d7e87A6F3b69  # Check SBT holder"