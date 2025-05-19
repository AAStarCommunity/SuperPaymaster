# SuperPaymaster

Collection repo for SuperPaymaster

## Components

- Contract：https://github.com/AAStarCommunity/SuperPaymaster-Contract

- Relay： this repo

- Bundler：this repo

## How to dev

1. git submodule add https://github.com/zerodevapp/ultra-relay
2. install aastar sdk: pnpm install @aastar/sdk
3. pnpm run dev

## How to use

1. install ethers: pnpm install ethers
2. resolve paymaster.aastar.eth and fetch text record
3. use contract address as superpaymaster address
4. use structured json data from text record to fetch signature and submit

## Example

```typescript
import { ethers } from "ethers";
import { Astar } from "@aastar/sdk";

const provider = new ethers.providers.JsonRpcProvider(
    "https://rpc.aastar.network",
);
const astar = new Astar(provider);

const paymasterAddress = await astar.resolvePaymaster("paymaster.aastar.eth");
const superPaymasterAddress = paymasterAddress;
const signature = await astar.getSignature("paymaster.aastar.eth");
```
