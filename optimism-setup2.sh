source .env.op-mainnet && forge script contracts/script/v3/L4SetupOpMainnet.s.sol:L4SetupOpMainnet \
  --rpc-url $RPC_URL \
  --account optimism-anni \
  --sender 0x08822612177e93a5B8dA59b45171638eb53D495a \
  --broadcast
