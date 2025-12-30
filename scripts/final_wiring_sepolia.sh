#!/bin/bash
source .env
NEW_APNTS=0x5Cb21d97e0B3e20fe66b9156A7BE50Df4eD4bbAD
SP=0x484cfE327A8caF2666a3f8671F69601609D60B71
REG=0xB6AF283bBc14B2D8305e76e56Ea0BB868cC0533c

echo "Updating APNTs in SuperPaymaster..."
cast send $SP "setAPNTsToken(address)" $NEW_APNTS --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

echo "Minting APNTs to Admin..."
cast send $NEW_APNTS "mint(address,uint256)" 0xb5600060e6de5E11D3636731964218E53caadf0E 1000000000000000000000000 --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

echo "Updating .env.sepolia in SDK..."
sed -i '' "s/APNTS_ADDR=.*/APNTS_ADDR=$NEW_APNTS/" ../aastar-sdk/.env.sepolia
sed -i '' "s/XPNTS_ADDR=.*/XPNTS_ADDR=$NEW_APNTS/" ../aastar-sdk/.env.sepolia
