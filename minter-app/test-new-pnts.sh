#!/bin/bash
# Test new GasToken PNT contract

set -e

RPC_URL="https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
PNTS="0xf2996D81b264d071f99FD13d76D15A9258f4cFa9"
SETTLEMENT="0x5Df95ECe6a35F55CeA2c02Da15c0ef1F6B795B85"
TEST_ADDR="0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"

echo "=== Testing New GasToken PNT ==="
echo "Contract: $PNTS"
echo "Settlement: $SETTLEMENT"
echo "Test Address: $TEST_ADDR"
echo ""

echo "1. Check PNT balance..."
BALANCE=$(cast call $PNTS "balanceOf(address)" $TEST_ADDR --rpc-url $RPC_URL)
echo "Balance: $BALANCE wei"
echo ""

echo "2. Check Settlement approval..."
ALLOWANCE=$(cast call $PNTS "allowance(address,address)" $TEST_ADDR $SETTLEMENT --rpc-url $RPC_URL)
echo "Allowance: $ALLOWANCE"
echo ""

echo "3. Check exchange rate..."
RATE=$(cast call $PNTS "exchangeRate()" --rpc-url $RPC_URL)
echo "Exchange Rate: $RATE"
echo ""

echo "4. Check settlement address..."
SETTLEMENT_ADDR=$(cast call $PNTS "settlement()" --rpc-url $RPC_URL)
echo "Settlement in contract: $SETTLEMENT_ADDR"
echo ""

if [ "$ALLOWANCE" == "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ]; then
  echo "✅ Settlement has MAX approval!"
else
  echo "❌ Settlement approval is not MAX"
fi
