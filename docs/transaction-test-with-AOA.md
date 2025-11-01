# Paymaster Test
我们使用部署和配置ok的AOA Paymaster和AOA+ SuperPaymaster地址来测试真实的ERC-4337标准的Simple Account的AB之间gasless的转账交易。
使用SuperPaymaster repo的js脚本，直接和entrypoint交互，无需bundler。

## 目标
Paymaster V4.1 AOA模式，社区独立部署的合约地址
地址：0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38，

AOA+模式，SuperPaymaster地址：0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a
和xPNTs（社区自己的Gas Token）：0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621

使用两种paymaster，完成完整的无gas交易

### 配置

SBT： 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8，来自于mysbt 2.3（需要验证
xPNTs token：0x13da8229f5ca3e1Ab2be3c010BBBb5dbAed85621，来自于xpnts（需要验证)
验证方式：从paymater v4.1合约地址接口获取

OWNER2_PRIVATE_KEY="0xc801db57d05466a8f16d645c39f50000000000000"
这个到env找完整的私钥

OWNER2_ADDRESS="0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"
TEST_AA_ACCOUNT_ADDRESS_A="0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584"
TEST_AA_ACCOUNT_ADDRESS_B="0x57b2e6f08399c276b2c1595825219d29990d0921"
TEST_AA_ACCOUNT_ADDRESS_C="0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce"
其中ABC都是owner2使用自己私钥创建的simple account

不需要approve gas token 给paymaster，因为 gas token工厂已经内置了approve给结算合约（AOA+模式下superpaymaster扮演结算合约，可以直接从用户账户扣除xpnts）

## 测试准备
### 检查
1. paymaster支持的sbt和xpnts是否和测试提供的地址一致
2. paymaster是否是xpnts合约的内置预approved地址，否则无法扣除测试账户的xpnts
3. xpnts和apnts的汇率是否设置
请补充完善我的检查项


### 测试账户要拥有的资产
mint sbt给测试账户
1. mint gtoken 1000 给测试账户，gtoken deployer就是OWNER2_ADDRESS
2. 测试账户要签名4337交易的private key从env/.env找
3. 和registry交互，注册到某个社区，stake 0.3, burn 0.1 GToken，获得sbt

mint xpnts：
1. 和该社区的xpnts合约交互，直接OWNER2_ADDRESS mint 1000 xpnts
2. （目前没有固定apnts合约地址），给测试账户mint 2000 apnts

拥有以上资产，可以在该社区支持的DApp内无gas交互。
也可以拥有其他社区的xpnts，从而在更多DApp和社区应用交互。
xpnts是自动选择，如果多个都可以支付gas的话。


## 核心过程
entrypoint 调用paymaster v4.1 的validateOps函数，或者Superpaymaster的函数，
进行如下操作：

1. 验证是否有sbt，sbt是否支持
2. 验证pnts余额（忘记是计算gas之后还是之前进行了）
3. 计算gas（是从ep获得还是自己计算？）
4. 使用chainlink获取实时eth usd价格
5. 转换为apnts（按0.02u，未来从gas token合约内部获取）
6. 转换为xpnts（gas token），汇率按xpnts合约设置的和apnts的汇率
7. 调用gas token合约从用户账户扣除对应数量的xpnts
8. 如果是superpaymaster，还要从内部账户扣除该paymater deposite的apnts
9. 完成
请根据代码，先一步步根据合约代码，验证我说的过程，并修正和完善，然后执行

禁止更改方案，必须用我说的流程

## 相关合约地址
V2核心系统（2025-10-24/25）

| 合约               | 地址                                         | 部署日期       | 功能              |
|------------------|--------------------------------------------|------------|-----------------|
| SuperPaymasterV2 | 0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a | 2025-10-25 | AOA+共享paymaster |
| Registry v2.1    | 0x529912C52a934fA02441f9882F50acb9b73A3c5B | 2025-10-27 | 注册中心+节点类型       |
| GToken           | 0x868F843723a98c6EECC4BF0aF3352C53d5004147 | 2025-10-24 | 治理代币            |
| GTokenStaking    | 0x92eD5b659Eec9D5135686C9369440D71e7958527 | 2025-10-24 | 质押管理            |

Token系统

| 合约           | 地址                                         | 部署日期       | 功能              |
|--------------|--------------------------------------------|------------|-----------------|
| xPNTsFactory | 0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6 | 2025-10-30 | 统一架构gas token工厂 |
| MySBT v2.3   | 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8 | 2025-10-28 | 白板SBT身份凭证       |

AOA模式

| 合约          | 地址                                         | 部署日期       | 功能                    |
|-------------|--------------------------------------------|------------|-----------------------|
| PaymasterV4 | 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 | 2025-10-15 | 独立paymaster（无需server） |

DVT监控系统

| 合约            | 地址                                         | 部署日期       | 功能      |
|---------------|--------------------------------------------|------------|---------|
| DVTValidator  | 0x8E03495A45291084A73Cee65B986f34565321fb1 | 2025-10-25 | 分布式验证节点 |
| BLSAggregator | 0xA7df6789218C5a270D6DF033979698CAB7D7b728 | 2025-10-25 | BLS签名聚合 |

官方依赖

| 合约              | 地址                                         | 说明               |
|-----------------|--------------------------------------------|------------------|
| EntryPoint v0.7 | 0x0000000071727De22E5E9d8BAf0edAc6f37da032 | ERC-4337官方（跨链统一） |

---

## 🔄 2025-10-31更新：当前状态与测试流程

### 最新合约地址（从 @aastar/shared-config v0.2.8获取）

**核心系统更新：**
- ✅ **GTokenStaking v2.0.0**: `0xDAD0EC96335f88A5A38aAd838daD4FE541744C2a`
  - **重大变更**: User-level slash + 1:1 shares model
  - **部署日期**: 2025-10-31
  - **与文档差异**: 文档中 `0x92eD5b659Eec9D5135686C9369440D71e7958527` 已过期

- ✅ **Registry v2.1.3**: `0xd8f50dcF723Fb6d0Ec555691c3a19E446a3bb765`
  - **新功能**: transferCommunityOwnership
  - **部署日期**: 2025-10-30
  - **与文档差异**: 文档中 `0x529912C52a934fA02441f9882F50acb9b73A3c5B` 已过期

- ✅ **MySBT v2.3.3**: `0x3cE0AB2a85Dc4b2B1976AA924CF8047F7afA9324`
  - **新功能**: burnSBT exit mechanism
  - **部署日期**: 2025-10-30
  - **与文档差异**: 文档中 `0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8` 已过期

**未变更的合约：**
- SuperPaymasterV2: `0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a` ✅
- GToken: `0x868F843723a98c6EECC4BF0aF3352C53d5004147` ✅
- xPNTsFactory: `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` ✅
- PaymasterV4: `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38` ✅

### 测试准备流程（基于当前合约状态）

#### 阶段1：部署与配置验证

**1.1 检查已部署合约配置**
```bash
# 使用 deployer (0x411BD567E46C0781248dbB6a9211891C032885e5)

# 检查 GTokenStaking locker配置
cast call 0xDAD0EC96335f88A5A38aAd838daD4FE541744C2a "lockerConfigs(address)(bool,uint256,uint256,uint256,uint256[],uint256[],address)" 0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a

# 检查 SuperPaymasterV2 配置
cast call 0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a "minOperatorStake()(uint256)"
cast call 0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a "aPNTsPriceUSD()(uint256)"
```

**1.2 部署社区xPNTs token**
- 使用 deployer 调用 `xPNTsFactory.deployToken()`
- 记录部署的 xPNTs 地址
- 更新到 `@aastar/shared-config`

#### 阶段2：准备测试账户资产

**测试账户信息：**
- **Deployer**: `0x411BD567E46C0781248dbB6a9211891C032885e5` (有PRIVATE_KEY)
- **Test User**: `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA` (OWNER2，有私钥)
- **Simple Accounts**:
  - A: `0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584`
  - B: `0x57b2e6f08399c276b2c1595825219d29990d0921`
  - C: `0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce`

**2.1 准备GToken + stGToken**
```javascript
// 基于历史脚本更新（scripts/mint-gtoken.js或类似）
1. deployer mint GToken 1000给测试账户
2. 测试账户approve GTokenStaking
3. 测试账户调用 GTokenStaking.stake(300 GT)
4. GTokenStaking自动lock到SuperPaymaster（如果需要AOA+）
```

**2.2 注册到Registry获得SBT**
```javascript
// 基于历史脚本更新（scripts/register-community.js或类似）
1. deployer注册社区到Registry（如果未注册）
2. 测试账户调用 MySBT.mintSBT(community)
3. 验证测试账户拥有SBT: balanceOf(testAccount) > 0
```

**2.3 Mint xPNTs给测试账户**
```javascript
// 基于历史脚本更新（scripts/mint-xpnts.js或类似）
1. deployer作为xPNTs owner
2. deployer.mint(testAccount, 1000 xPNTs)
3. 验证余额: xPNTs.balanceOf(testAccount)
4. xPNTs已内置approve给SuperPaymaster（工厂部署时设置）
```

#### 阶段3：SuperPaymaster运营方准备（AOA+模式）

**3.1 Deployer注册为运营方**
```javascript
// 如果deployer尚未注册
SuperPaymasterV2.registerOperator(
  stGTokenAmount: 30 ether,  // 最小质押
  supportedSBTs: [mySBT_address],
  xPNTsToken: deployed_xPNTs_address,
  treasury: deployer_address
)
```

**3.2 Deployer充值aPNTs**
```javascript
// aPNTs是抽象点数（不是真实ERC20）
// SuperPaymaster内部记账系统
SuperPaymasterV2.depositAPNTs(2000 ether)
// 注意：需要实际实现或模拟aPNTs充值机制
```

**3.3 配置xPNTs <-> aPNTs汇率**
```javascript
SuperPaymasterV2.setExchangeRate(
  operator: deployer,
  rate: 1 ether  // 1:1汇率
)
```

#### 阶段4：核心交易流程验证

**基于合约代码的实际流程：**

1. **EntryPoint调用Paymaster.validatePaymasterUserOp()**

2. **Paymaster验证流程（PaymasterV4 / SuperPaymasterV2）：**
   - ✅ 检查用户是否持有支持的SBT
   - ✅ 从paymasterAndData解析userSpecifiedGasToken（xPNTs地址）
   - ✅ 计算gas费用（从EntryPoint获取gas limits）
   - ✅ 获取ETH/USD实时价格（Chainlink）
   - ✅ 转换为aPNTs成本（按0.02 USD/aPNT）
   - ✅ 转换为xPNTs成本（按operator设置的汇率）
   - ✅ 检查用户xPNTs余额是否充足
   - ✅ **PaymasterV4**: 直接从用户账户扣除xPNTs
   - ✅ **SuperPaymasterV2**:
     - 从用户账户扣除xPNTs
     - 从operator内部账户扣除aPNTs
     - 记录到operator.totalSpent

3. **EntryPoint执行callData**（实际交易逻辑）

4. **postOp回调**（如有需要）

#### 阶段5：测试执行

**5.1 AOA模式测试（PaymasterV4）**
```javascript
// 基于 scripts/test-v4-transaction-report.js 更新
测试场景：Simple Account A 向 B 转账0.5 xPNTs
验证：
- A余额减少0.5 + gas fee（xPNTs计价）
- B余额增加0.5 xPNTs
- PaymasterV4 treasury收到gas fee
- A的ETH余额不变（gasless）
```

**5.2 AOA+模式测试（SuperPaymasterV2）**
```javascript
// 基于 scripts/e2e-test-v3.js 更新
测试场景：Simple Account A 向 B 转账0.5 xPNTs
验证：
- A余额减少0.5 + gas fee（xPNTs计价）
- B余额增加0.5 xPNTs
- Operator内部aPNTs余额减少
- SuperPaymaster treasury收到消耗的aPNTs
- A的ETH余额不变（gasless）
```

### 当前待办事项清单

**立即执行（deployer操作）：**
- [ ] 部署社区的xPNTs token
- [ ] 验证GTokenStaking locker配置（MySBT + SuperPaymaster）
- [ ] 检查deployer是否已在SuperPaymasterV2注册
- [ ] 准备测试账户资产（GToken, SBT, xPNTs）
- [ ] 配置SuperPaymaster运营方的aPNTs余额

**脚本更新（基于历史脚本）：**
- [ ] 更新 `scripts/e2e-test-v3.js` → AOA+测试
- [ ] 更新 `scripts/test-v4-transaction-report.js` → AOA测试
- [ ] 创建统一的准备脚本 `scripts/prepare-test-assets.js`（基于历史mint/stake脚本）

**文档更新：**
- [x] 追加最新合约地址和状态
- [ ] 更新核心流程（根据代码验证）
- [ ] 记录测试结果和问题

