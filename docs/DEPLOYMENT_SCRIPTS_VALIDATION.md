# Deployment Scripts Validation & Update Report

## 📋 Current Issue Analysis

在执行 Step 9 (Mint Initial Tokens) 时发现了一个严重问题：
- **地址混淆**: 由于早期部署失败（nonce 问题），实际部署的地址与预期不同
- **GToken 地址冲突**: `0xbf0DD4c529cA321bCa8FBE23644a64eFA1BeaeB6` 实际是 PaymasterFactoryV4，而非 GToken

## ✅ Already Verified Working Scripts

### Phase A: Core Components ✓
- [x] `01_DeployGToken.s.sol` - Works, but deployed address needs verification
- [x] `02_DeployGTokenStaking.s.sol` - Works
- [x] `03_DeployMySBT.s.sol` - Works  
- [x] `04_DeployRegistry.s.sol` - Works

### Phase B: Factory & SP ✓
- [x] `05_DeployFactory.s.sol` - Works
- [x] `06_DeployMockCommunityToken.s.sol` - Works
- [x] `07_DeploySuperPaymaster.s.sol` - Works

### Phase C: Auxiliary ✓
- [x] `07a_DeployReputationSystem.s.sol` - Created & Works
- [x] `07b_DeployBLSModules.s.sol` - Created & Works

### Phase D: Wiring ✓
- [x] `08a_WireUpFactory.s.sol` - Works
- [x] `08b_WireUpToken.s.sol` - Works
- [x] `08c_WireUpMySBT.s.sol` - Works
- [x] `08d_WireUpGTokenStaking.s.sol` - Works

### Phase E: V4 ✓
- [x] `DeployPaymasterFactoryV4.s.sol` - Works
- [x] `13_DeployPaymasterV4.s.sol` - Works (after version fix)

## ⚠️ Scripts Requiring Updates/Review

### Step 9: Mint Initial Tokens
**Status**: ❌ Blocked - Address confusion  
**Issue**: Need to verify actual deployed GToken address  
**Action**: Query Sepolia for the real GToken address from deployment transaction

### Step 10: Register Community  
**Status**: 🔄 Needs Interface Review  
**Files**:
- `10_RegisterCommunity.s.sol`
- `10_OneShotRegister.s.sol`
- `10_1_RegisterBreadCommunity.s.sol`

**Required Checks**:
1. Does `Registry.registerCommunity()` interface match?
2. Are role hash constants up-to-date?
3. Does it require GToken balance/staking first?

### Step 11: Configure Operator
**Status**: 🔄 Needs Interface Review  
**Files**:
- `11_ConfigureOperator.s.sol`
- `11_1_ConfigureBreadOperator.s.sol`

**Required Checks**:
1. Does `Registry.registerRoleSelf()` still exist?
2. Are operator role requirements updated?
3. Does staking logic align with current `GTokenStaking`?

## 🔍 Interface Changes to Verify

### Registry.sol
- [ ] `registerCommunity()` parameters
- [ ] `registerRoleSelf()` signature
- [ ] `ROLE_COMMUNITY` hash generation
- [ ] `ROLE_PAYMASTER_*` hash changes

### GTokenStaking.sol
- [ ] `lockStake()` requirements
- [ ] Minimum stake amounts
- [ ] `setRegistry()` already called

### SuperPaymaster.sol
- [ ] `setSuperPaymasterAddress()` vs `setPaymaster()`?
- [ ] Initial deposit requirements

## 📝 Recommended Actions

### Immediate (Phase D Completion)
1. **Find Real GToken Address**:
   ```bash
   cast logs --from-block <deployment_block> --to-block latest \
     "topic0==0x..." --rpc-url $SEPOLIA_RPC
   ```

2. **Update DEPLOYMENT_SUMMARY.md** with correct addresses

3. **Skip Step 9 for now** - Tokens可以通过 SDK 后期 mint

4. **Review Step 10 & 11 scripts** against current `Registry.sol`

### Medium Priority (Script Maintenance)
1. Create `scripts/deployment/ADDRESSES.json` with canonical addresses
2. Update all scripts to read from centralized config
3. Add pre-flight checks (e.g., "is this address a GToken?")

### Long-term (Post-Experiment)
1. Refactor all scripts to use a single `DeploymentConfig.sol` library
2. Add comprehensive test suite for deployment scripts
3. Document interface dependencies in each script header

## 🎯 Current Recommendation

**暂停 Phase D 的 Step 9-11**，原因：

1. **地址混乱**: 需要先clarify所有合约的真实地址
2. **接口变化**: Registry 和 Staking 可能经历了重构
3. **实验优先**: Step 9-11 可以通过 SDK 在实验setup阶段执行

**建议流程**：
1. 立即验证所有已部署合约的真实地址
2. 更新 `SEPOLIA_DEPLOYMENT_SUMMARY.md`
3. 跳过 Step 9-11 的 Foundry 脚本
4. 直接进入 SDK 环境准备，用 TypeScript 完成初始化
