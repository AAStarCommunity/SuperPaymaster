# Admin Configuration Rights (SuperPaymaster V3.1)

This document outlines the administrative rights and interfaces available in the `Registry` contract for protocol administrators to manage role configurations and ownership.

## Overview

In the SuperPaymaster V3.1 architecture, the `Registry` contract serves as the central authority for roles and staking requirements. While individual roles can have their own "Role Owners" (e.g., a community DAO owning the `ROLE_COMMUNITY` config), the **Protocol Admin** (the `Ownable` owner of the `Registry`) retains ultimate control to ensure protocol safety and flexibility.

## Admin Interfaces

### 1. Unified Configuration Override
The `configureRole` function allows the protocol admin to modify any role's configuration, even if they are not the designated `roleOwner`.

```solidity
/**
 * @notice Configure role parameters
 * @dev Callable by either the roleOwner OR the Protocol Admin (Ownable owner)
 */
function configureRole(bytes32 roleId, RoleConfig calldata config) external;
```

**Key Parameters available for modification:**
- `minStake`: Minimum amount of GToken a user must stake.
- `entryBurn`: Amount of GToken burned upon registration.
- `exitFeePercent` / `minExitFee`: Parameters for the withdrawal fee mechanism.
- `isActive`: Emergency switch to enable/disable role registration.

### 2. Role Ownership Management
The protocol admin can transfer the ownership of a specific role to a different address (e.g., transitioning from a developer multisig to a community governance contract).

```solidity
/**
 * @notice Transfer role ownership (Protocol Admin only)
 * @param roleId Role to transfer
 * @param newOwner New owner address
 */
function setRoleOwner(bytes32 roleId, address newOwner) external onlyOwner;
```

### 3. Dynamic Role Creation
The admin can create entirely new roles at runtime with specific configurations and assigned owners.

```solidity
/**
 * @notice Create a new role (Protocol Admin only)
 */
function createNewRole(
    bytes32 roleId, 
    RoleConfig calldata config, 
    address roleOwner
) external onlyOwner;
```

## Security Considerations

- **Owner Rights**: The Protocol Admin always has the right to override community-set parameters. This is intended as a safety measure for protocol-wide updates or emergency interventions.
- **Staking Synchronization**: All changes to exit fees via these interfaces are automatically synchronized with the `GTokenStaking` contract to ensure consistency between the registry and the staking logic.
