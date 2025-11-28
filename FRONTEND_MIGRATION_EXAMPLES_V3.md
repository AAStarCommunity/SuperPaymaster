# Frontend Migration Examples - Mycelium Protocol v3

## 1. 初始化和配置

### v2 初始化
```javascript
// v2 - 多个合约地址
const Registry = await ethers.getContractAt("Registry", REGISTRY_ADDRESS);
const MySBT = await ethers.getContractAt("MySBT", MYSBT_ADDRESS);
const GTokenStaking = await ethers.getContractAt("GTokenStaking", STAKING_ADDRESS);
```

### v3 初始化
```javascript
// v3 - 增加 SharedConfig
const Registry = await ethers.getContractAt("IRegistryV3", REGISTRY_V3_ADDRESS);
const MySBT = await ethers.getContractAt("MySBT_v3", MYSBT_V3_ADDRESS);
const GTokenStaking = await ethers.getContractAt("IGTokenStakingV3", STAKING_V3_ADDRESS);
const SharedConfig = await ethers.getContractAt("SharedConfig", SHARED_CONFIG_ADDRESS);

// 获取角色常量
const ROLE_ENDUSER = await SharedConfig.ROLE_ENDUSER();
const ROLE_COMMUNITY = await SharedConfig.ROLE_COMMUNITY();
const ROLE_PAYMASTER = await SharedConfig.ROLE_PAYMASTER();
const ROLE_SUPER = await SharedConfig.ROLE_SUPER();
```

## 2. 角色注册示例

### 2.1 注册为终端用户

#### v2 实现
```javascript
// v2 - 直接调用 registerEndUser
async function registerEndUser(userAddress) {
    const tx = await Registry.registerEndUser({
        from: userAddress,
        value: ethers.utils.parseEther("0.1") // 入场费
    });
    await tx.wait();
    console.log("User registered as EndUser");
}
```

#### v3 实现
```javascript
// v3 - 使用统一的 registerRole
async function registerEndUser(userAddress) {
    const roleData = ethers.utils.defaultAbiCoder.encode(
        ["string"],
        ["EndUser registration"]
    );

    const tx = await Registry.registerRole(
        ROLE_ENDUSER,
        userAddress,
        roleData
    );
    await tx.wait();
    console.log("User registered with ENDUSER role");
}
```

### 2.2 注册社区

#### v2 实现
```javascript
// v2 - 调用 registerCommunity
async function registerCommunity(profile, stakeAmount) {
    const tx = await Registry.registerCommunity(
        {
            name: profile.name,
            ensName: profile.ensName,
            xPNTsToken: profile.xPNTsToken,
            supportedSBTs: profile.supportedSBTs,
            nodeType: 2, // ANODE
            paymasterAddress: profile.paymasterAddress,
            community: profile.community,
            isActive: true,
            allowPermissionlessMint: true
        },
        stakeAmount
    );
    await tx.wait();
    console.log("Community registered");
}
```

#### v3 实现
```javascript
// v3 - 使用 registerRole 与 ROLE_COMMUNITY
async function registerCommunity(profile, stakeAmount) {
    // 编码社区配置数据
    const roleData = ethers.utils.defaultAbiCoder.encode(
        [
            "tuple(string name, string ensName, address xPNTsToken, address[] supportedSBTs, address paymasterAddress, bool allowPermissionlessMint)",
            "uint256"
        ],
        [
            {
                name: profile.name,
                ensName: profile.ensName,
                xPNTsToken: profile.xPNTsToken,
                supportedSBTs: profile.supportedSBTs,
                paymasterAddress: profile.paymasterAddress,
                allowPermissionlessMint: true
            },
            stakeAmount
        ]
    );

    const tx = await Registry.registerRole(
        ROLE_COMMUNITY,
        profile.community,
        roleData
    );
    await tx.wait();
    console.log("Community registered with v3 API");
}
```

### 2.3 注册 Paymaster

#### v2 实现
```javascript
// v2 - 调用 registerPaymaster
async function registerPaymaster(paymasterData) {
    const tx = await Registry.registerPaymaster(paymasterData);
    await tx.wait();
    console.log("Paymaster registered");
}
```

#### v3 实现
```javascript
// v3 - 使用 registerRole 与 ROLE_PAYMASTER
async function registerPaymaster(paymasterAddress, paymasterData) {
    const tx = await Registry.registerRole(
        ROLE_PAYMASTER,
        paymasterAddress,
        paymasterData
    );
    await tx.wait();
    console.log("Paymaster registered with v3 API");
}
```

## 3. 角色退出示例

### v2 退出实现
```javascript
// v2 - 不同角色不同函数
async function exitCommunity() {
    const tx = await Registry.exitCommunity();
    await tx.wait();
}

async function exitPaymaster() {
    const tx = await Registry.exitPaymaster();
    await tx.wait();
}
```

### v3 退出实现
```javascript
// v3 - 统一的 exitRole
async function exitRole(roleId) {
    const tx = await Registry.exitRole(roleId);
    await tx.wait();
    console.log(`Exited from role: ${roleId}`);
}

// 使用示例
await exitRole(ROLE_COMMUNITY);
await exitRole(ROLE_PAYMASTER);
await exitRole(ROLE_ENDUSER);
```

## 4. 查询功能迁移

### 4.1 检查用户角色

#### v2 查询
```javascript
// v2 - 查询特定类型
async function isCommunity(address) {
    const profile = await Registry.getCommunityProfile(address);
    return profile.registeredAt > 0;
}

async function isPaymaster(address) {
    const data = await Registry.getPaymasterData(address);
    return data.isActive;
}
```

#### v3 查询
```javascript
// v3 - 统一的角色查询
async function hasRole(roleId, userAddress) {
    return await Registry.hasRole(roleId, userAddress);
}

// 使用示例
const isCommunity = await hasRole(ROLE_COMMUNITY, address);
const isPaymaster = await hasRole(ROLE_PAYMASTER, address);
const isEndUser = await hasRole(ROLE_ENDUSER, address);

// 获取用户所有角色
async function getUserRoles(userAddress) {
    const roles = await Registry.getUserRoles(userAddress);
    return roles.map(role => {
        if (role === ROLE_COMMUNITY) return "COMMUNITY";
        if (role === ROLE_PAYMASTER) return "PAYMASTER";
        if (role === ROLE_ENDUSER) return "ENDUSER";
        if (role === ROLE_SUPER) return "SUPER";
        return "UNKNOWN";
    });
}
```

### 4.2 获取角色配置

#### v3 新功能
```javascript
// 获取角色配置参数
async function getRoleConfig(roleId) {
    const config = await Registry.getRoleConfig(roleId);
    return {
        minStake: ethers.utils.formatEther(config.minStake),
        entryBurn: ethers.utils.formatEther(config.entryBurn),
        exitFeePercent: config.exitFeePercent.toNumber(),
        minExitFee: ethers.utils.formatEther(config.minExitFee),
        allowPermissionlessMint: config.allowPermissionlessMint,
        isActive: config.isActive
    };
}

// 使用示例
const communityConfig = await getRoleConfig(ROLE_COMMUNITY);
console.log("Community minimum stake:", communityConfig.minStake, "GT");
```

## 5. MySBT 交互更新

### 5.1 铸造 SBT

#### v2 实现
```javascript
// v2 - 直接调用 MySBT
async function mintSBT(community, metadata) {
    const tx = await MySBT.safeMintAndJoin(
        community,
        ethers.utils.toUtf8Bytes(metadata)
    );
    await tx.wait();
}
```

#### v3 实现
```javascript
// v3 - MySBT_v3 with role validation
async function mintSBT(community, metadata) {
    // 首先检查社区是否有效
    const hasRole = await Registry.hasRole(ROLE_COMMUNITY, community);
    if (!hasRole) {
        throw new Error("Invalid community: no COMMUNITY role");
    }

    const tx = await MySBT.safeMintAndJoin(
        community,
        ethers.utils.toUtf8Bytes(metadata)
    );
    await tx.wait();
}
```

### 5.2 带质押的铸造

#### v3 实现
```javascript
async function mintSBTWithStake(community, metadata, stakeAmount) {
    // 批准 GToken
    const GToken = await ethers.getContractAt("IERC20", GTOKEN_ADDRESS);
    await GToken.approve(MYSBT_V3_ADDRESS, stakeAmount);

    // 铸造 SBT 并质押
    const tx = await MySBT.safeMintAndJoinWithAutoStake(
        community,
        ethers.utils.toUtf8Bytes(metadata),
        stakeAmount
    );
    await tx.wait();

    console.log("SBT minted with stake locked under ENDUSER role");
}
```

## 6. 事件监听更新

### v2 事件监听
```javascript
// v2 - 多个特定事件
Registry.on("CommunityRegistered", (community, name, nodeType, staked) => {
    console.log(`Community ${name} registered`);
});

Registry.on("PaymasterRegistered", (paymaster, data) => {
    console.log(`Paymaster ${paymaster} registered`);
});
```

### v3 事件监听
```javascript
// v3 - 统一的角色事件
Registry.on("RoleRegistered", (roleId, user, burnAmount, timestamp) => {
    let roleType = "Unknown";
    if (roleId === ROLE_COMMUNITY) roleType = "Community";
    else if (roleId === ROLE_PAYMASTER) roleType = "Paymaster";
    else if (roleId === ROLE_ENDUSER) roleType = "EndUser";
    else if (roleId === ROLE_SUPER) roleType = "SuperPaymaster";

    console.log(`${roleType} registered: ${user}`);
    console.log(`Burn amount: ${ethers.utils.formatEther(burnAmount)} GT`);
});

Registry.on("RoleExited", (roleId, user, exitFee, timestamp) => {
    console.log(`User ${user} exited role ${roleId}`);
    console.log(`Exit fee: ${ethers.utils.formatEther(exitFee)} GT`);
});
```

## 7. 批量操作示例

### v3 批量注册
```javascript
// v3 - 社区管理员批量空投 SBT
async function batchMintForRole(roleId, users, metadata) {
    const promises = users.map(async (user) => {
        const roleData = ethers.utils.defaultAbiCoder.encode(
            ["string"],
            [metadata]
        );

        return Registry.safeMintForRole(roleId, user, roleData);
    });

    const results = await Promise.all(promises);
    console.log(`Minted ${results.length} SBTs for role`);
}
```

## 8. Gas 优化技巧

### v3 批量查询优化
```javascript
// 批量查询用户角色状态
async function batchCheckRoles(users) {
    // 使用 multicall 减少 RPC 调用
    const multicall = await ethers.getContractAt("Multicall3", MULTICALL_ADDRESS);

    const calls = [];
    for (const user of users) {
        calls.push({
            target: REGISTRY_V3_ADDRESS,
            callData: Registry.interface.encodeFunctionData("getUserRoles", [user])
        });
    }

    const results = await multicall.aggregate3(calls);
    return results.map((r, i) => ({
        user: users[i],
        roles: Registry.interface.decodeFunctionResult("getUserRoles", r.returnData)[0]
    }));
}
```

## 9. 错误处理

### v3 错误处理示例
```javascript
async function safeRegisterRole(roleId, user, roleData) {
    try {
        // 检查配置
        const config = await Registry.getRoleConfig(roleId);
        if (!config.isActive) {
            throw new Error("Role is not active");
        }

        // 检查用户是否已有该角色
        const hasRole = await Registry.hasRole(roleId, user);
        if (hasRole) {
            throw new Error("User already has this role");
        }

        // 执行注册
        const tx = await Registry.registerRole(roleId, user, roleData);
        const receipt = await tx.wait();

        return {
            success: true,
            txHash: receipt.transactionHash
        };
    } catch (error) {
        console.error("Registration failed:", error.message);
        return {
            success: false,
            error: error.message
        };
    }
}
```

## 10. 完整迁移检查清单

### 前端代码迁移步骤
- [ ] 更新合约 ABI 文件为 v3 版本
- [ ] 添加 SharedConfig 合约地址和 ABI
- [ ] 替换所有 `registerCommunity()` 调用为 `registerRole(ROLE_COMMUNITY, ...)`
- [ ] 替换所有 `registerPaymaster()` 调用为 `registerRole(ROLE_PAYMASTER, ...)`
- [ ] 替换所有 `registerEndUser()` 调用为 `registerRole(ROLE_ENDUSER, ...)`
- [ ] 替换所有 `exitCommunity()` 调用为 `exitRole(ROLE_COMMUNITY)`
- [ ] 更新事件监听器使用新的事件名称
- [ ] 添加角色 ID 常量定义
- [ ] 更新错误处理逻辑
- [ ] 测试所有功能流程

### 测试要点
- [ ] 角色注册功能正常
- [ ] 角色退出功能正常
- [ ] 查询功能返回正确数据
- [ ] 事件正确触发和处理
- [ ] Gas 消耗符合预期（降低 70%）
- [ ] 错误处理正确响应
- [ ] 批量操作正常工作

---

*最后更新: 2024年11月*
*版本: v3.0.0*