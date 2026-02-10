# Deployment Strategy & Upgradability V3.1

This document outlines the strategy for achieving **Deterministic Deployment** (same address across networks) and sustainable **Upgradability** for the SuperPaymaster ecosystem.

## 1. The "One Address" Goal (Deterministic Deployment)
**Problem**: Using `new Contract()` depends on the deployer's nonce. If you deploy on Sepolia (nonce 5) and Optimism (nonce 1), the contract addresses will differ.
**Goal**: `SuperPaymaster` address on Sepolia == `SuperPaymaster` address on Optimism Mainnet.

### Solution: `CREATE2` Factory
We will switch from `new Contract(...)` to using a **Deterministic Deployer Factory**.

*   **Mechanism**: `address = keccak256(0xff ++ factoryAddr ++ salt ++ keccak256(initCode))`
*   **Key Factors**:
    1.  **Factory Address**: Must be consistent. We use the industry-standard "Nick's Factory" (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), available on almost all chains at the same address.
    2.  **Salt**: A user-defined unique ID (e.g., `keccak256("SuperPaymasterV3")`).
    3.  **InitCode**: The contract bytecode + constructor arguments.

### ⚠️ The "Constructor Argument" Trap
For `CREATE2` to produce the same address, **Constructor Arguments MUST be identical** on all chains.
*   **Observation**: Our current `SuperPaymaster` constructor takes `PriceFeed` address (`0x694...` on Sepolia vs `0x...` on Mainnet).
*   **Conflict**: Since `PriceFeed` address differs by network, the `InitCode` differs, so the `CREATE2` address **WILL DIFFER**.

**Strategy Fix: Initialize Pattern**
To keep the address consistent, we must remove network-specific args from the constructor.
1.  **Deploy Logic**:
    ```solidity
    // Constructor: Sets ONLY immutable variables that are constant across all chains (e.g., specific constants or 4337 version).
    constructor(IEntryPoint _entryPoint) { ... }
    ```
2.  **Setup Logic**:
    ```solidity
    // Initialize: Sets network-specific config (PriceFeed, Registry, Owner)
    function initialize(address _owner, address _priceFeed) external initializer { ... }
    ```
3.  **Result**: The contract code is identical -> Address is identical. Config is applied post-deployment.

---

## 2. Upgradability Architecture

We need to support bug fixes and feature additions without breaking integrations or changing addresses.

### 2.1 The "Singleton" Contracts (SuperPaymaster, Registry)
**Pattern: UUPS Proxy (Universal Upgradeable Proxy Standard)**
*   **Why**: More gas efficient than Transparent Proxy. Logic controls the upgrade.
*   **Structure**:
    *   **Proxy Contract**: The address everyone interacts with (Fixed).
    *   **Implementation Contract**: The logic (Changeable).
*   **Workflow**:
    1.  Deploy `ImplementationV1` (via CREATE2).
    2.  Deploy `ERC1967Proxy` pointing to V1 (via CREATE2, Salt="SuperPaymasterProxy").
    3.  **Upgrade**: Deploy `ImplementationV2`. Call `upgradeTo(V2)` on the Proxy. Address remains the same.

### 2.2 The "User" Contracts (PaymasterV4, xPNTs)
**Pattern: Beacon Proxy or Clone Factory**
*   **Why**: Users deploy many instances. Upgrading thousands of instances individually is expensive.
*   **Beacon Pattern**:
    *   **Beacon Contract**: Holds the address of the current Implementation.
    *   **User Proxies**: Point to the Beacon.
    *   **Upgrade**: Update the Beacon once -> All User Proxies instantly use new logic.
*   **Selectable Versions**:
    *   Our `PaymasterFactory` currently supports versioning (`v4.0`, `v4.2`). This is good. We keep this "Registry of Implementations" pattern so users can choose.

---

## 3. Deployment Workflow (The "Golden Key" Plan)

To achieve your goal of usage consistency with one account:

### Phase 1: Preparation
1.  **Deployer Key**: Use your `cast wallet` (e.g., `optimism-deployer`).
2.  **Safe (Multisig)**: Create a Gnosis Safe on each network (Optimism, Base, Mainnet). This will be the **Final Owner**.

### Phase 2: Deployment (Script Update)
1.  **Deploy Implementation**: `new SuperPaymaster{salt: salt}(...)`.
2.  **Deploy Proxy**: `new ERC1967Proxy{salt: salt}(impl, "initialize(...)")`.
    *   *Note*: The Proxy address will be `0x...AABBCC` on **ALL** networks.
3.  **Verify**: Etherscan verify.

### Phase 3: Handover
1.  **Transfer Ownership**: `proxy.transferOwnership(SafeAddress)`.
2.  **Multisig Control**: Future upgrades require Safe signatures.

## 4. Summary of Changes Needed

| Component | Current State | Target State | Benefit |
| :--- | :--- | :--- | :--- |
| **Deployment** | `new Contract()` | `new Contract{salt: ...}()` | Same Address everywhere. |
| **State Variables** | Constructor sets all args | Constructor minimal, `initialize()` sets args | Enables CREATE2 consistency. |
| **Governance** | EOA Owner | UUPS Proxy + Multisig Owner | Secure upgrades. |

### Next Steps for You
1.  **Refactor**: Modify `SuperPaymaster.sol` to use `Initializable` (OpenZeppelin) and move logic from `constructor` to `initialize`.
2.  **Script**: Update `DeployLive.s.sol` to use `CREATE2`.

**Recommendation**: Start this for **V3.0** (Next Major Version). For current `v2.x`, stick to current flow to avoid breaking changes, but adopt CREATE2 for new deployments if possible.
