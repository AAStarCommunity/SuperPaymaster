# SuperPaymaster V3 Migration Plan

## Goal Description
Complete the migration of SuperPaymaster ecosystem to V3 architecture. This involves verifying the refactored contracts (Registry, MySBT, GTokenStaking), ensuring comprehensive test coverage, updating the shared configuration library, and refactoring the frontend application to support the new unified role-based architecture.

## User Review Required
> [!IMPORTANT]
> **Breaking Changes**: The V3 architecture unifies all registration flows into `registerRole` and `exitRole`. All V2 registration functions (`registerCommunity`, `registerPaymaster`, etc.) are removed.
> **Shared Config Update**: `aastar-shared-config` will be bumped to `0.3.9`.
> **Frontend**: Users will see a unified flow, but underlying data structures (Roles keys) are changing.

## Proposed Changes

### 1. SuperPaymaster Contracts (Testing & Verification)
Verify and test the V3 contracts which are already implemented but need comprehensive testing.

#### [MODIFY] [SuperPaymaster/test](file:///Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/test)
- Create/Update `RegistryV3.t.sol`: Test all role flows (EndUser, Community, Paymaster, Super).
- Create/Update `MySBTV3.t.sol`: Test `mintForRole` (auth check) and `burnForRole`.
- Create/Update `GTokenStakingV3.t.sol`: Test lock/unlock with roles and burn logic.
- Ensure 70+ tests as per Refactor Summary.

### 2. Shared Config Update
Update version to `0.3.9` and export new ABIs and constants.

#### [MODIFY] [aastar-shared-config/package.json](file:///Users/jason/Dev/mycelium/my-exploration/projects/aastar-shared-config/package.json)
- Bump version to `0.3.9`.

#### [MODIFY] [aastar-shared-config/src/index.ts](file:///Users/jason/Dev/mycelium/my-exploration/projects/aastar-shared-config/src/index.ts)
- Add V3 Role Constants: `ROLE_ENDUSER`, `ROLE_COMMUNITY`, `ROLE_PAYMASTER`, `ROLE_SUPER`.
- Export V3 ABIs (`RegistryV3`, `MySBTV3`, `GTokenStakingV3`).

### 3. Registry Frontend Refactor
Update React application to use new contracts and flows.

#### [MODIFY] [registry/src/pages/resources](file:///Users/jason/Dev/mycelium/my-exploration/projects/registry/src/pages/resources)
- `RegisterCommunity.tsx`: Switch to `registerRole(ROLE_COMMUNITY, ...)`.
- `LaunchPaymaster.tsx`: Switch to `registerRole(ROLE_PAYMASTER, ...)`.
- `ConfigureSuperPaymaster.tsx`: Switch to `registerRole(ROLE_SUPER, ...)`.
- `GetSBT.tsx`: Switch to `registerRole(ROLE_ENDUSER, ...)` for user registration.
- `MySBT.tsx`: Update to read data using `hasRole` or `userRoles`.

#### [MODIFY] [registry/src/hooks](file:///Users/jason/Dev/mycelium/my-exploration/projects/registry/src/hooks)
- Update contract hooks to use V3 ABIs and addresses.

## Verification Plan

### Automated Tests
- Run `forge test` in `SuperPaymaster` to ensure all contract logic is sound (Target: 100% pass on V3 tests).

### Manual Verification
- Deploy contracts to local anvil node (or use existing testnet if configured).
- Run `registry` frontend locally.
- Test flows:
    1. Register as EndUser (GetSBT).
    2. Register as Community.
    3. Register as Paymaster.
    4. Register as SuperPaymaster.
    5. Exit flows for each.

-----
✅ 合约开发完成 (SuperPaymaster V3)
⏭️ 部署新版本 (使用 env 变量 + 部署脚本)
⏭️ 同步 ABIs (shared-config repo 的脚本)
⏭️ 发布 npm 包 (shared-config)
⏭️ 前端重构 (registry，按 implementation_plan.md)
