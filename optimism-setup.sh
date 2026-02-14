source .env.op-mainnet && forge script contracts/script/v3/L4SetupOpMainnet.s.sol:L4SetupOpMainnet \
  --rpc-url $RPC_URL \
  --account optimism-deployer \
  --sender 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3 \
  --broadcast
