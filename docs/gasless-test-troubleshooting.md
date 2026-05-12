# Gasless / Transaction Test Troubleshooting (Real Experience Log)

**Last updated**: 2026-05-12 after v5.3.2 Sepolia verification  
**Companion**: `script/gasless-tests/README.md`（运行入口）+ `prepare-test`（部署后 setup 脚本）

本文档记录在 **Sepolia 真实链上**跑 transaction test 时遇到的每一个失败模式、根因、诊断方法、修复。每条都附今天踩坑的具体 tx hash / 链上数据为证。读这份文档前请先看 `script/gasless-tests/README.md` 了解整体结构。

---

## 0. 总览：5 种独立的失败模式（按出现顺序）

| # | 失败信号 | 根因 | 一句话修法 |
|--:|---------|------|-----------|
| 1 | "Zero balance, cannot test transfer" + 测试静默 PASS | AA 账户没业务 token | deployer 给 AA 转 100 aPNTs |
| 2 | EntryPoint revert `0xa18ee550` = `Paymaster__InsufficientBalance` | PaymasterV4 (push model) AA 账户没在 V4 内 `depositFor` 押 token gas 预算 | 调 `PMV4.depositFor(AA, token, amount)`，amount ≥ ~150 aPNTs |
| 3 | EntryPoint revert `AA32 paymaster expired or not due` | PaymasterV4 / SuperPaymaster 的 Chainlink 价格 cache 过期（默认 `priceStalenessThreshold = 4200s`） | 在 test 前调 `paymaster.updatePrice()` |
| 4 | EntryPoint revert `AA34 signature error`（user op simulation） | **不一定是签名问题**！SP 在多个 fail path 都返回 `_packValidationData(true, 0, 0)`（sigFailure=true）→ EntryPoint 报 AA34。常见原因：operator `aPNTsBalance < required` | 给 operator 在 SP 里 `deposit(N aPNTs)`，N ≥ ~150 × 预期 fail 次数 |
| 5 | `UserOperationRevertReason` 内 `0xad7954bc` = `PostOpReverted(empty bytes)` | SP 的 postOp 因 `paymasterPostOpGasLimit` 太低 OOG。100K 不够（含 burn 回退链）| paymasterPostOpGasLimit 设到 **200K** |

加上 1 个**测试设计 bug**（不是合约问题）：

| 6 | 测试 outer tx status=1 但 recipient 余额不变 | **operator 的 `xPNTsToken` 与 user 转账 token 不匹配**。例：operator=Anni 时 xPNTsToken=PNTs，但测试转 aPNTs → postOp 试图 burn PNTs from AA（AA 没 PNTs）→ revert | 让 operator 和被转 token 匹配。`test-case-2` 用 deployer operator (xPNTsToken=aPNTs)，`test-case-3` 用 Anni operator (xPNTsToken=PNTs) |

---

## 1. 详细诊断 + 修复（按失败模式编号）

### 1.1 ❌ "Zero balance, cannot test transfer" 静默 PASS（最危险）

**症状**:
```
[20] Gasless: PaymasterV4:
  Balance: 0.0 aPNTs
  ⚠️ Warning: Zero balance, cannot test transfer
  PASSED   ← 但实际没测到 gas-free transfer！
```

**根因**: AA 账户的 aPNTs 余额是 0。test-case-1/2/3 都会先 `balanceOf(AA)`，发现是 0 时 **early-return 并打印 warning**，runner 把这个当 PASS。

**为什么危险**: 看着报告 22/22 PASS，但实际三个最重要的 gasless transfer 测试都 **没跑**。我 2026-05-11 那次报告里就把这种"伪 PASS"当成真 PASS 写入了，被用户当场抓出来。

**诊断**:
```bash
APNTS=$(jq -r .aPNTs deployments/config.sepolia.json)
for aa in $TEST_AA_ACCOUNT_ADDRESS_A $TEST_AA_ACCOUNT_ADDRESS_B $TEST_AA_ACCOUNT_ADDRESS_C; do
    bal=$(cast call $APNTS "balanceOf(address)(uint256)" $aa --rpc-url $RPC_URL)
    echo "  $aa = $bal"
done
```

**修复**:
```bash
# deployer mint/transfer 100 aPNTs to each AA
AMT=100000000000000000000  # 100 aPNTs in wei
for aa in $TEST_AA_ACCOUNT_ADDRESS_A $TEST_AA_ACCOUNT_ADDRESS_B $TEST_AA_ACCOUNT_ADDRESS_C; do
    cast send $APNTS "transfer(address,uint256)" $aa $AMT \
        --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
done
```

**长期防御**:
- 测试脚本不应该把 "Zero balance, skip" 当 PASS。要么 `process.exit(1)`，要么 `prepare-test` 自动检测+充值。
- `prepare-test` 加入 step "ensure all AA accounts have ≥ 50 aPNTs"。

**今日证据**:
- Funding tx: [`0x5cbf8743…`](https://sepolia.etherscan.io/tx/0x5cbf8743ecf91424479aeafd673d633c080735855d60eb7264f784c5e3df6165)（AA_A），[`0x09a5b9a7…`](https://sepolia.etherscan.io/tx/0x09a5b9a70cd279941f137afa3f583bd39d3e3525b72e2423bc59681ba6152e9b)（AA_B），[`0x6d4ef85a…`](https://sepolia.etherscan.io/tx/0x6d4ef85a0927cebbb5e7c2c5059d54e1593066c69a4785204f38660922b7df14)（AA_C）

---

### 1.2 ❌ PaymasterV4 `Paymaster__InsufficientBalance` (`0xa18ee550`)

**症状**: PaymasterV4 gasless test 失败：
```
Error data: 0x65c8fd4d ... 41413333 (AA33 reverted) ... a18ee550 ...
```
内嵌 selector `0xa18ee550` = `Paymaster__InsufficientBalance()`。

**根因**: PaymasterV4 用 **push 模型** —— AA 账户必须先调用 `PMV4.depositFor(user, token, amount)` 把 token 押到 paymaster，paymaster 才能在 `validatePaymasterUserOp` 时从 `balances[user][token]` 扣 gas。

```solidity
// PaymasterBase.validatePaymasterUserOp
if (balances[user][token] < amountTokens) revert Paymaster__InsufficientBalance();
```

**诊断**:
```bash
PMV4=$(jq -r .paymasterV4Impl deployments/config.sepolia.json) # impl
# 实际 V4 proxy 地址在 PaymasterFactory.getPaymasterByOperator
cast call $PMV4_PROXY "balances(address,address)(uint256)" $AA_A $APNTS --rpc-url $RPC_URL
```

**修复**: 给每个 AA 押 ≥ 150 aPNTs（覆盖 1 个 userOp 的 maxCost）。我第一次只押 50，仍然不够（actual gas cost computed ~136 aPNTs at $0.02/aPNTs）：

```bash
# Approve + depositFor 500 aPNTs (留余量给重复测试)
cast send $APNTS "approve(address,uint256)" $PMV4 500000000000000000000 \
    --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
cast send $PMV4 "depositFor(address,address,uint256)" $AA_A $APNTS 500000000000000000000 \
    --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
```

**长期防御**: `prepare-test` 自动检测 PaymasterV4 的 `balances[AA][token] < 200 aPNTs` 并 top up。

**今日证据**:
- 我第一次只 deposit 50 aPNTs → `InsufficientBalance` revert
- bump 到 500 后成功 → tx [`0xcb044ca1…`](https://sepolia.etherscan.io/tx/0xcb044ca17fbd5864e394f6a67957aab67e7f8cae45e3ce1cd4ae2285eb41566a)

---

### 1.3 ❌ `AA32 paymaster expired or not due`

**症状**: EntryPoint revert with `FailedOp(0, "AA32 paymaster expired or not due")`。

**根因**: paymaster (V4 或 SP) 的 Chainlink 价格 cache 过期。SP / PMV4 在 `validatePaymasterUserOp` 返回 `validUntil = cachedPrice.updatedAt + priceStalenessThreshold`。如果 `block.timestamp > validUntil`，EntryPoint 拒收。

默认 `priceStalenessThreshold`：
- SP: 4200 秒（≈ 70 分钟）
- PMV4: 86400 秒（24h）—— 但本次升级后是 4200

**诊断**:
```bash
SP=$(jq -r .superPaymaster deployments/config.sepolia.json)
cast call $SP "cachedPrice()(int256,uint256,uint80,uint8)" --rpc-url $RPC_URL
#                                ^^^^^^^^ this is updatedAt
cast call $SP "priceStalenessThreshold()(uint256)" --rpc-url $RPC_URL
cast block latest --rpc-url $RPC_URL --field timestamp
# Compute: updatedAt + threshold vs timestamp
```

**修复**:
```bash
cast send $SP "updatePrice()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
# AND if testing PaymasterV4:
cast send $PMV4_PROXY "updatePrice()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
```

**长期防御**:
1. `prepare-test` 末尾自动 `updatePrice()` 两个 paymaster
2. 生产环境需要 keeper（建议每 1200s 自动调一次）
3. 测试脚本运行前可加 pre-flight check："如果 cachedPrice 过期则自动刷新"

**今日证据**:
- 我第一次跑 test-case-1 时收到 AA32，调用 PMV4.updatePrice() 后通过：tx [`0x95f0bf2b…`](https://sepolia.etherscan.io/tx/0x95f0bf2b2507f51b408983f6b319611332177a2221a0f8209772193d14e67823)
- 后来 test-case-2 也遇到，SP.updatePrice tx [`0x738fb6b9…`](https://sepolia.etherscan.io/tx/0x738fb6b9c296d4488dc69fa519f14f2f449abbbbc08bd282b2cd8cdce94a328e)

---

### 1.4 ❌ `AA34 signature error` —— 但不是签名问题

**症状**: EntryPoint revert with `FailedOp(0, "AA34 signature error")`，本地签名 recover 正确。

**陷阱**: AA34 字面意思是"签名错误"，但 **SuperPaymaster 的 `validatePaymasterUserOp` 在多处返回 `_packValidationData(true, 0, 0)`（sigFailure=true）也会触发同样的 EntryPoint 报错**。

SP 里返回 sigFailure=true 的 path（v5.3.2 源码）：

```solidity
if (!config.isConfigured) return ("", _packValidationData(true, 0, 0));
if (config.isPaused) return ("", _packValidationData(true, 0, 0));
if (!isEligibleForSponsorship(userOp.sender)) return ("", _packValidationData(true, 0, 0));
if (userState.isBlocked) return ("", _packValidationData(true, 0, 0));
if (uint256(config.exchangeRate) > maxRate) return ("", _packValidationData(true, 0, 0));
if (uint256(config.aPNTsBalance) < aPNTsAmount) return ("", _packValidationData(true, 0, 0));
```

**最常见**:
- 用户没 SBT (`isEligibleForSponsorship` 返回 false) → AA34
- **operator 在 SP 里 aPNTsBalance < 需要的 aPNTs** → AA34 ← 今天踩的坑

**诊断**:
```bash
# 1. 先 verify 签名本地是否能 recover (排除真签名问题)
node -e "
  const { ethers } = require('ethers');
  const sig = '0x...';
  const hash = '0x...';  // userOpHash from getUserOpHash
  const ethSignedHash = ethers.hashMessage(ethers.getBytes(hash));
  console.log(ethers.recoverAddress(ethSignedHash, sig));
"

# 2. 检查 isEligibleForSponsorship
cast call $SP "isEligibleForSponsorship(address)(bool)" $AA --rpc-url $RPC_URL

# 3. 检查 operator config + balance
cast call $SP "operators(address)(uint128,uint96,bool,bool,address,uint16,uint48,address,uint256,uint256)" $OPERATOR --rpc-url $RPC_URL
#                                 ^^^^^^^ aPNTsBalance ^^^^ isConfigured ^^ isPaused
# aPNTsBalance 需要 > userOp gas cost in aPNTs (典型 ~120-150 aPNTs at $0.02/token)

# 4. 检查 user blocked status
cast call $SP "userOpState(address,address)(uint48,bool)" $OPERATOR $AA --rpc-url $RPC_URL
```

**修复**:

如果是 aPNTsBalance 不足（最常见）：
```bash
# operator 调 SP.deposit(amount)
cast send $APNTS "approve(address,uint256)" $SP 500000000000000000000 \
    --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC_URL
cast send $SP "deposit(uint256)" 500000000000000000000 \
    --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC_URL
```

如果是 SBT 缺失：跑 `RegisterEnduser.s.sol` 由 community 注册。

**长期防御**:
- 测试脚本失败时打印 `isEligibleForSponsorship` + `operators(operator).aPNTsBalance` 而不是只报 "AA34"
- `prepare-test` 自动确保 deployer + Anni 在 SP 里都有 ≥ 500 aPNTs deposit

**今日证据**:
- AA_B 测试以 AA34 失败：fail 时 deployer aPNTsBalance 只剩 11 aPNTs（因为前面失败 attempt 累计扣了 188 aPNTs validate-time deduction）
- 补 500 后通过 → tx [`0x2834f2f3…`](https://sepolia.etherscan.io/tx/0x2834f2f374f119e3016002cb8c667092ed18e0d8ef59a9e72b97a1ab8854824b)
- 注意：**SP 在 validate 时是 optimistic deduction —— deducted 即使 postOp 失败也保留**（EntryPoint catches PostOpReverted but does not roll back validate deduction）

---

### 1.5 ❌ `PostOpReverted(bytes)` empty inner bytes

**症状**: tx status=1（outer success）但 inner `UserOperationRevertReason` log 显示 `0xad7954bc + 0x20 + 0x00`（PostOpReverted with empty inner bytes）。Recipient 余额不变。

**根因**: SP 的 postOp 因 **`paymasterPostOpGasLimit` 不够 OOG**。OOG 没有 return data，所以 PostOpReverted 携带空 bytes。

SP 的 postOp 工作量比 V4 大得多：
1. 解码 context 5 字段
2. 计算 `actualAPNTsCost` (含 protocolFee)
3. 处理 refund + 调 `_recordXPNTsDebt`
4. `_recordXPNTsDebt` 有 3 层 try/catch 回退：`burnFromWithOpHash → recordDebtWithOpHash → pendingDebts`
5. 每层都可能 emit event
6. xPNTsToken._update 还有 auto-repayment 逻辑（如果 from=0 + debt>0）

典型 gas 消耗：120–180K。100K 上限会 OOG。

**诊断**:
```bash
# 检查 tx 的 UserOperationRevertReason event
cast receipt $TX_HASH --rpc-url $RPC_URL --json | \
  jq '.logs[] | select(.topics[0] == "0xf62676f440ff169a3a9afdbf812e89e7f95975ee8e5c31214ffdef631c5f4792") | .data'
# 如果 data 含 ad7954bc + 0x20 + 0x00 → PostOpReverted with empty inner
```

**修复**: paymasterAndData 的 postOpGasLimit 设到 **200K**：

```javascript
// 测试代码
const pmVerificationGasLimit = 150000n;
const pmPostOpGasLimit = 200000n;  // ← was 100000n; OOG on Sepolia
const paymasterAndData = ethers.solidityPacked(
  ['address', 'uint128', 'uint128', 'address'],
  [SP, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddress]
);
```

**长期防御**: SDK 默认值改为 200K，并在文档/wizard 里说明 SP 比 V4 需要更多 postOp gas。

**今日证据**:
- Case 2 originally 100K → PostOpReverted empty → recipient unchanged
- bump to 200K → success → tx [`0x2834f2f3…`](https://sepolia.etherscan.io/tx/0x2834f2f374f119e3016002cb8c667092ed18e0d8ef59a9e72b97a1ab8854824b)

---

### 1.6 ❌ outer status=1 but recipient unchanged —— operator/token mismatch

**症状**: tx outer success，gasUsed 正常，但 recipient ERC20 余额不变。

**根因**（最容易写错的测试设计 bug）: SP 里 `operator.xPNTsToken` 与测试 transfer 的 token 不匹配。SP 的 postOp 总是 burn / debt 操作 **operator's xPNTsToken**，不管 user transfer 的是什么。

当 mismatch 时：
1. User AA 转账 X token （inner execute）
2. postOp 试图 `burnFromWithOpHash(Y token, AA, amount)` —— AA 没有 Y token → revert
3. `recordDebtWithOpHash` 也可能 revert
4. 最终 `pendingDebts[Y token][AA] += amount` 兜底
5. 但这个 pendingDebts 路径走得通，**postOp 不 revert**，整个 inner userOp 也"成功"。但是！inner transfer 实际上不一定真的发生了

**等等** —— 实际看起来 inner transfer 也被回滚了，原因是 `_recordXPNTsDebt` 的 try/catch 在每层失败时都会消耗 gas，最终 OOG。所以症状有时表现为 PostOpReverted（同 1.5），有时表现为 silent recipient-no-change。

**诊断**:
```bash
# 看 operator 的 xPNTsToken vs 测试用的 token
cast call $SP "operators(address)(uint128,uint96,bool,bool,address,uint16,uint48,address,uint256,uint256)" $OPERATOR --rpc-url $RPC_URL
#                                                          ^^^^^^^ xPNTsToken 在第 5 个位置

# 对比测试代码里的 XPNTS_TOKEN_ADDRESS
grep "XPNTS_TOKEN_ADDRESS\|config.aPNTs\|config.pnts" test-case-2-superpaymaster-xpnts1-fixed.js
```

**修复**: 测试代码里把 `XPNTS_TOKEN_ADDRESS` 和 `operatorAddress` 配对：

```javascript
// test-case-2 (xpnts1): SP aPNTs path
const XPNTS_TOKEN_ADDRESS = config.aPNTs;
const operatorAddress = process.env.OPERATOR_ADDRESS_APNTS || deployerWallet.address;
// deployer's SP-configured xPNTsToken == aPNTs ✓

// test-case-3 (xpnts2): SP PNTs path
const XPNTS_TOKEN_ADDRESS = config.pnts;
const operatorAddress = process.env.OPERATOR_ADDRESS_PNTS || ANNI_ADDRESS;
// Anni's SP-configured xPNTsToken == PNTs ✓
```

**长期防御**:
- 测试 assertion 不应该只检查 `tx.status==1`，必须检查 `recipientBalanceAfter > recipientBalanceBefore`，否则当成 FAIL
- `prepare-test` 把所有 operator 的 xPNTsToken 打印出来作为 doc
- README 添加"Operator → Token Matrix"明确列出哪个 operator 服务哪种 token

**今日证据**: 
- v5.3.2 升级前的 test-case-2 outer success 但 recipient unchanged，因为 OPERATOR_ADDRESS 默认 Anni (xPNTsToken=PNTs) 但测试用的是 aPNTs

---

## 2. 完整的 prepare-test 应有的步骤（推荐演进）

基于以上 6 个失败模式，**prepare-test** 应该做：

```
Phase 2.1 ─ Mint GT for Anni
Phase 2.2 ─ Register Anni as PAYMASTER_AOA + deploy V4 paymaster
Phase 2.3 ─ depositTo (EntryPoint) for Anni's V4 paymaster (0.05 ETH)
Phase 2.4 ─ NEW: Register 3 AA accounts as ENDUSER (via Anni community)
Phase 2.5 ─ NEW: Top up 3 AA accounts with 100 aPNTs each (avoid 1.1)
Phase 2.6 ─ NEW: deployer.PMV4.depositFor(AA_A, aPNTs, 500)  (avoid 1.2)
Phase 2.7 ─ NEW: deployer.SP.deposit(500 aPNTs)              (avoid 1.4)
Phase 2.8 ─ NEW: Anni.SP.deposit(500 aPNTs)                  (avoid 1.4)
Phase 2.9 ─ NEW: PMV4.updatePrice() + SP.updatePrice()       (avoid 1.3)
Phase 2.10 ─ Run Check09 verification
Phase 2.11 ─ NEW: 打印 "Operator → Token Matrix"             (avoid 1.6)
```

当前 `prepare-test` 只做 2.1-2.3 + Check09。其余都是 v5.4 应该补的自动化。

---

## 3. 完整的测试运行 checklist（运行前过一遍）

```bash
cd /Users/jason/Dev/aastar/SuperPaymaster
source .env.sepolia

# 1. Sanity: 链上版本
cast call $(jq -r .superPaymaster deployments/config.sepolia.json) "version()(string)" --rpc-url $RPC_URL
cast call $(jq -r .registry deployments/config.sepolia.json) "version()(string)" --rpc-url $RPC_URL

# 2. 价格 fresh
SP=$(jq -r .superPaymaster deployments/config.sepolia.json)
PMV4_PROXY=...  # 通过 PaymasterFactory.getPaymasterByOperator(deployer) 拿
cast send $SP "updatePrice()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
cast send $PMV4_PROXY "updatePrice()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL

# 3. AA SBT 状态 (≥1 必须为 true)
for aa in $TEST_AA_ACCOUNT_ADDRESS_A $TEST_AA_ACCOUNT_ADDRESS_B $TEST_AA_ACCOUNT_ADDRESS_C; do
    cast call $SP "isEligibleForSponsorship(address)(bool)" $aa --rpc-url $RPC_URL
done

# 4. AA aPNTs balances (≥50 each)
APNTS=$(jq -r .aPNTs deployments/config.sepolia.json)
for aa in $TEST_AA_ACCOUNT_ADDRESS_A $TEST_AA_ACCOUNT_ADDRESS_B $TEST_AA_ACCOUNT_ADDRESS_C; do
    cast call $APNTS "balanceOf(address)(uint256)" $aa --rpc-url $RPC_URL
done

# 5. PaymasterV4 user deposit balance for AA_A (≥200 aPNTs)
cast call $PMV4_PROXY "balances(address,address)(uint256)" $TEST_AA_ACCOUNT_ADDRESS_A $APNTS --rpc-url $RPC_URL

# 6. SP operator aPNTs balances (deployer + Anni ≥500 each)
cast call $SP "operators(address)(uint128,uint96,bool,bool,address,uint16,uint48,address,uint256,uint256)" $DEPLOYER --rpc-url $RPC_URL | head -1
cast call $SP "operators(address)(uint128,uint96,bool,bool,address,uint16,uint48,address,uint256,uint256)" $ANNI --rpc-url $RPC_URL | head -1

# 7. EntryPoint ETH deposits (PMV4 + SP ≥0.05 ETH each)
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
cast call $EP "balanceOf(address)(uint256)" $PMV4_PROXY --rpc-url $RPC_URL
cast call $EP "balanceOf(address)(uint256)" $SP --rpc-url $RPC_URL
```

---

## 4. Operator → xPNTsToken Matrix（critical reference）

| Operator | Address | SP `xPNTsToken` | 适用 test |
|---------|---------|----------------|----------|
| deployer | `0xb5600060…caadf0E` | aPNTs `0x4C4EC2e8…99C901` | test-case-1 (V4), test-case-2 (SP-aPNTs) |
| Anni | `0xEcAACb91…8733c9` | PNTs `0x83ca2b02…0E5cc8` | test-case-3 (SP-PNTs) |

任何 SP gasless test 必须满足 **被转 token == operator.xPNTsToken**。

---

## 5. 关键错误 selector 字典

| selector | error | 触发模块 | 含义 |
|---------|-------|---------|------|
| `0xa18ee550` | `Paymaster__InsufficientBalance()` | PaymasterV4 | V4 push model 余额不足 |
| `0xa18ee55b` | (不存在) | — | 看错了 last byte，是 `0xa18ee550` |
| `0xad7954bc` | `PostOpReverted(bytes)` | EntryPoint | SP postOp 失败（含 OOG / mismatch） |
| `0x220266b6` | `FailedOp(uint256,string)` | EntryPoint | 标准 fail，含 AA21/AA32/AA33/AA34/AA50 reason |
| `0x65c8fd4d` | `FailedOpWithRevert(uint256,string,bytes)` | EntryPoint | 同上但带 inner bytes |
| `0xe6c4247b` | `InvalidAddress()` | SP (v5.3.2 Fix-4) | `setXPNTsFactory(0)` revert |
| `0x49628fd1` | `UserOperationEvent(...)` | EntryPoint event | userOp 完整结束（success/fail）|
| `0xf62676f4` | `UserOperationRevertReason(...)` | EntryPoint event | inner execute revert 数据 |
| `0xbb47ee3e` | `BeforeExecution()` | EntryPoint event | userOp 验证完毕进入 execute |

---

## 6. 今日完整失败链 + 修复 timeline（写给后续工程师）

如果是新人接手，应该这样调试：

| 时间 | 操作 | 失败信号 | 修复 |
|-----|------|--------|------|
| T0 | 跑 test-case-1 (PMV4) | `Zero balance` | mint 100 aPNTs → AA_A |
| T0+2min | 跑 test-case-1 | `InsufficientBalance` (0xa18ee550) | depositFor 50 aPNTs |
| T0+3min | 跑 test-case-1 | `InsufficientBalance` 仍然 | 50 < 136 required, 改 deposit 500 aPNTs |
| T0+4min | 跑 test-case-1 | `AA32 paymaster expired` | PMV4.updatePrice() |
| T0+5min | 跑 test-case-1 | ✅ success, tx `0xcb044ca1…` | — |
| T0+6min | 跑 test-case-2 (SP-aPNTs) | outer success, recipient unchanged | 发现 OPERATOR=Anni 但 token=aPNTs，operator 改为 deployer |
| T0+8min | 跑 test-case-2 (fixed operator) | `PostOpReverted(empty)` | pmPostOpGasLimit 100K → 200K |
| T0+10min | 跑 test-case-2 | `AA34 signature error` | sign locally recover OK → 不是签名问题；查 deployer aPNTsBalance = 11 aPNTs → SP.deposit(500) |
| T0+12min | 跑 test-case-2 | ✅ success, tx `0x2834f2f3…` | — |
| 同时 | 跑 test-case-3 (SP-PNTs) | outer success, recipient unchanged | OPERATOR=Anni 但 token=aPNTs → 改 token 为 config.pnts |
| T0+15min | 跑 test-case-3 (token+postOp 200K) | ✅ success, tx `0xd965add0…` | — |

**总共 ≈ 15 分钟 + 12 次 Sepolia 真上链调试**。每次失败都教了一件事，这份文档保证未来不用重新踩一遍。

---

## 7. 链接到 v5.3.2 完整 transaction 记录

详细的 21 笔上链 tx（含 setup + 实际 gasless + MPC + x402 + UUPS 升级）记录在 `docs/2026-05-12-v5.3.2-transaction-test-results.md`，每条都有 Etherscan link。本文档关注**怎么调试**，那份关注**结果记录**。

---

*相关 PR / commit*:
- v5.3.2 Sepolia 升级 + test results: PR #193  
- test-case-2/3 operator + postOp gas fix: (本 PR)
