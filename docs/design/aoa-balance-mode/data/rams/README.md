# R-AMS-0 / R-AMS-1 证据（2026-10-22，CC-125 DSR d13dd9eb）

全部操作只读：不签名，不广播，不含私钥，不含 RPC URL。

## R-AMS-0：A3a v4 为什么在链上不可执行

`capture-11969744.json`，生成脚本 `script/evidence/rams-capture.py`：

| 项 | Alchemy（reth v2.7.0） | publicnode（reth v2.8.0） | Tenderly |
|---|---|---|---|
| chainId / 块 11,969,744 的哈希 | 0xaa36a7 / `0xc30a297c…` | 相同 | 相同 |
| `eth_config.current.activationTime` / forkId / `next` | 1791294816 / `0x6c1d9423` / null | 相同 | 不支持（-32601） |
| 部署者 nonce（该块 / pending） | 12131 / 12131 | 相同 | 相同 |
| Safe nonce | 1 | 1 | 1 |
| S1 / S2 / S3 `eth_estimateGas` | 48,938 / 9,307,838 / 9,257,602 | 相同 | 相同 |
| 按 v4 包内 gasLimit 执行 `eth_call` | revert / OOG / OOG | 相同 | 相同 |

激活时间 1791294816 对应 2026-10-06 13:53:36 UTC。systemContracts 中含 `BUILDER_DEPOSIT_CONTRACT_ADDRESS` / `BUILDER_EXIT_CONTRACT_ADDRESS`，这是 ePBS（EIP-7732）引入的合约，可据此判定为 Amsterdam。DSR 另行核对过 EF 的官方公告。

## R-AMS-1：与 Amsterdam 一致的执行引擎

判据：同一固定块上，对每个探针二分查找 **`eth_call` 能成功的最小 gas limit**。引擎的这个阈值必须与两个真实端点**逐一相等**。不比 `eth_estimateGas`，因为各家的估算算法不同：reth 的估算高于最小可行值，S1 高 297，S2 高 74,448。脚本：`script/evidence/rams-engine-probe.py`。

探针共 14 个：
- A3a S1/S2/S3 的真实 calldata；
- CREATE 空合约、256 字节 code deposit、构造期写新槽、新槽再写一次（暖）、冷账户 BALANCE、冷 CALL；
- 向新账户转 1 wei；
- 冷读 SP `owner()` / `version()`、Safe `getOwners()`、EntryPoint `balanceOf(SP)`。

| 引擎（`engine-versions.txt`） | 结果 | 文件 |
|---|---|---|
| **foundry nightly `926eb1d087523f1de437e3c0c49ea6d26407e827`（anvil 1.8.7-nightly）** | **14/14 一致**，exit 0 | `engine-probe-nightly-926eb1d-11969744.{json,log}` |
| foundry v1.8.6 稳定版（anvil 1.8.6） | **6/14**：所有涉及 CREATE 的探针都少约 183,600 gas，例如空 CREATE 链上 207,606、anvil 24,064。普通调用和向新账户转账一致 | `engine-probe-v1.8.6-11969744.{json,log}` |
| foundry v1.7.1（仓库锁定版本） | 不实现 Amsterdam：`--hardfork amsterdam` 直接 panic（`unimplemented Amsterdam`）；默认规则为旧规则 | DSR 另行实测 |

1.8.6 这一行同时是负对照：它说明这个探针能区分「一致」和「不一致」，而且偏差集中在 CREATE 新账户的状态 gas（EIP-8037）。

**工具固定方式**：nightly 安装在独立目录 `~/Dev/aastar/tools/foundry-rams/nightly-926eb1d/`，没有改动全局 foundry；`~/.foundry/bin` 仍是 1.7.1，CI 锁定版本也不变。tarball 的 sha256 为 `ba4e061a5d4ba2426ab43034eb80d618ce5fc44a6a10bc18abcb98541add5790`，与 release 附带的 `.sha256` 一致。

**范围说明**：本引擎只用于**运行时规则**（fork 演练、gas 测量）。编译产物仍是 rc.4 的 profile.default（solc 0.8.33，cancun），不用 `--evm-version` 改编译目标来冒充运行规则。

**仍未覆盖**：本轮探针**没有覆盖** EIP-8037 的 state reservoir 退款与 `gasleft()` 语义对 EntryPoint 计费的影响。这项属于 R-AMS-2，要用真实 EntryPoint 的费用流和 trace 来验证。

## 复现

```bash
B=<固定块>
~/Dev/aastar/tools/foundry-rams/nightly-926eb1d/anvil --fork-url <archive rpc> --fork-block-number $B --port 18550 --silent &
RPC_A=<archive rpc> RPC_B=https://ethereum-sepolia-rpc.publicnode.com ENGINE=http://127.0.0.1:18550 BLOCK=$B \
  python3 script/evidence/rams-engine-probe.py docs/release/a3a-precheck-v4/a3a-precheck.json > engine-probe.json
RPC_A=<archive rpc> RPC_B=https://ethereum-sepolia-rpc.publicnode.com RPC_C=https://sepolia.gateway.tenderly.co BLOCK=$B \
  python3 script/evidence/rams-capture.py docs/release/a3a-precheck-v4/a3a-precheck.json > capture.json
```

## 未审的执行器

`script/evidence/a3a-live-step.UNREVIEWED.py` 是 10-22 被闸门拦停时用的原型，**不得用于发链**。DSR d13dd9eb 指出的问题是：
- 缺少 R-AMS / fork 层级闸门；
- S2/S3/S7 的核对不完整：没查完整角色集合、runtime、cap、minter、supply，也没核 7 天关系；
- `--dry-run` 也会加载私钥并签名；
- 私钥经命令行参数传递；
- 失败时没有持久化的审计记录。

它保留在这里只作为失败证据，正式执行器会在 R-AMS-3 重写并单独送审。
