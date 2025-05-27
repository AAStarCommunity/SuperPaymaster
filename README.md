# SuperPaymaster

Collection repo for SuperPaymaster

## Components

- Contract：https://github.com/AAStarCommunity/SuperPaymaster-Contract

- Relay： this repo

- Bundler：this repo

## How to dev

1. git submodule add https://github.com/zerodevapp/ultra-relay
2. git submodule add git@github.com:eth-infinitism/bundler.git
3. install aastar sdk: pnpm install @aastar/sdk
4. pnpm run dev

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

## All tasks

- [ ] 1.4337基础流程完成
- [ ] 1.改进的签名流程完成
- [ ] 1.改进的erc777完成
- [ ] 2.ENS的完成
- [ ] 3.注册的完成
- [ ] 4.动态路由设计和开发完成
- [ ] 5.paymaster主合约完成；relay完成
- [ ] 6.bundler和合约完成
- [ ] 7.配合调试的account relay完成

## Reference

- viem范例：https://github.com/wevm/viem/blob/main/examples/ens/index.ts
- https://deepwiki.com/zerodevapp/ultra-relay/4.3-cicd-pipeline
