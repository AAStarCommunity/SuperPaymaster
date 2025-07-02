# Super-Relay Design Document (EN/中文)

## 1. Introduction

This document outlines the design for `super-relay`, a core component of the `SuperPaymaster` project. `super-relay` is an integrated Paymaster Relay service built upon the `rundler` ERC-4337 bundler.

The primary goal is to extend `rundler`'s functionality without altering its core logic. It will provide a Paymaster signing service that sponsors UserOperations according to configurable policies, and then submits them to the blockchain via `rundler`'s existing bundling infrastructure.

This service will be implemented as a new, independent module within the `rundler` workspace, ensuring modularity and maintainability. The design prioritizes compatibility with EntryPoint v0.7, while also supporting v0.6.

---

### **1. 简介**

本文档概述了 `SuperPaymaster` 项目核心组件 `super-relay` 的设计。`super-relay` 是一个集成的 Paymaster Relay 服务，它构建于 `rundler` ERC-4337 bundler 之上。

其主要目标是在不改变 `rundler` 核心逻辑的前提下扩展其功能。它将提供一个 Paymaster 签名服务，标准集成官方团队验证规则和未来要扩展的 reputation 机制（借鉴自 eth-infinitism 示例验证和 reputation 机制），根据可配置的策略来赞助（借鉴 zerodev 的 ultra-relay 的策略机制）UserOperation，然后通过 `rundler` 现有的打包基础设施将它们提交到区块链。

该服务将在 `rundler` 工作空间内实现为一个新的、独立的模块，以确保模块化和可维护性。设计优先兼容 EntryPoint v0.7，同时支持 v0.6。
备忘：签名机制目前 zerodev 是使用 AWS 的 KMS，我们先使用基于 node 本机的 key pair 签名，未来考虑使用 ARM 支持的 OP-TEE 来完成 KMS 模块。

## 2. Core Features

### 2.1. Paymaster Signing Service

This service exposes an RPC method to handle gas sponsorship for UserOperations.

- **RPC Method:** `pm_sponsorUserOperation`
- **Input:**
    - `userOperation`: `UserOperation` - The user's original, unsigned UserOperation.
    - `entryPoint`: `address` - The target EntryPoint contract address.
    - `policyId`: `string` (optional) - An identifier for a specific sponsorship policy.
- **Processing:**
    1.  **Validation:** The service first performs basic validation on the `userOperation`.
    2.  **Policy Check:** It checks the `userOperation` against a set of predefined sponsorship rules (see section 2.3). This determines if the operation is eligible for sponsorship.
    3.  **Signature Generation:** If eligible, the service calculates the `userOpHash` and signs it with the Paymaster's private key.
    4.  **PaymasterData Construction:** It constructs the `paymasterAndData` (for v0.6) or populates the `paymaster`, `paymasterData`, and other related fields (for v0.7).
- **Output:**
    - `sponsoredUserOperation`: `UserOperation` - The updated `UserOperation`, now including the `paymaster` data and ready for submission.

---

### **2. 核心功能**

#### **2.1. Paymaster 签名服务**

该服务暴露一个 RPC 方法来处理 UserOperation 的 Gas 赞助。

- **RPC 方法：** `pm_sponsorUserOperation`
- **输入：**
    - `userOperation`: `UserOperation` - 用户原始的、未签名的 UserOperation。
    - `entryPoint`: `address` - 目标 EntryPoint 合约地址。
    - `policyId`: `string` (可选) - 特定赞助策略的标识符。
- **处理流程：**
    1.  **验证：** 服务首先对 `userOperation` 执行基本验证。
    2.  **策略检查：** 服务根据一组预定义的赞助规则（见 2.3 节）检查 `userOperation`，以确定该操作是否有资格获得赞助。
    3.  **签名生成：** 如果符合条件，服务将计算 `userOpHash` 并使用 Paymaster 的私钥对其进行签名。
    4.  **PaymasterData 构建：** 服务构造 `paymasterAndData` (用于 v0.6) 或填充 `paymaster`、`paymasterData` 及其他相关字段 (用于 v0.7)。
- **输出：**
    - `sponsoredUserOperation`: `UserOperation` - 更新后的 `UserOperation`，现已包含 `paymaster` 数据并准备好提交。

### 2.2. Bundler Submission Integration

Instead of requiring the client to make a second call to `eth_sendUserOperation`, `super-relay` will offer a streamlined, one-shot process. The `pm_sponsorUserOperation` method will, after successfully signing the UserOperation, directly inject it into `rundler`'s transaction pool for bundling and on-chain submission.

- **Workflow:**
    1.  Client calls `pm_sponsorUserOperation`.
    2.  The service signs the `UserOperation` as described above.
    3.  The service internally calls `rundler`'s Pool service to add the sponsored `UserOperation` to the mempool.
    4.  `rundler`'s existing builder and sender logic handles the rest of the bundling and submission process.
- **Output:**
    - `userOpHash`: `bytes32` - The hash of the sponsored UserOperation that has been submitted to the mempool.

---

#### **2.2. Bundler 提交集成**

`super-relay` 将提供一个精简的、一步到位的流程，而不是要求客户端再调用一次 `eth_sendUserOperation`。`pm_sponsorUserOperation` 方法在成功签署 UserOperation 后，会将其直接注入 `rundler` 的交易池中，以便进行打包和上链提交。

- **工作流程：**
    1.  客户端调用 `pm_sponsorUserOperation`。
    2.  服务如上所述签署 `UserOperation`。
    3.  服务在内部调用 `rundler` 的 Pool 服务，将赞助的 `UserOperation` 添加到内存池中。
    4.  `rundler` 现有的 builder 和 sender 逻辑处理剩余的打包和提交过程。
- **输出：**
    - `userOpHash`: `bytes32` - 已提交到内存池的、被赞助的 UserOperation 的哈希。

### 2.3. Multi-Tenancy and Policy Management

`super-relay` will support multiple sponsors (tenants) and flexible sponsorship policies. This allows for fine-grained control over which transactions are sponsored.

- **Configuration:** Policies will be defined in a configuration file (e.g., `policies.json` or `policies.toml`).
- **Policy Structure (Example):**
    ```json
    {
      "policyId_1": {
        "name": "Default Policy",
        "paymasterAddress": "0x...",
        "allowedSenders": ["0x...", "0x..."],
        "maxGasLimit": "500000",
        "validUntil": "2024-12-31T23:59:59Z"
      },
      "policyId_2": {
        "name": "DApp Partner Policy",
        "paymasterAddress": "0x...",
        "targetContracts": ["0x..."],
        "rateLimitPerSender": {
            "count": 10,
            "interval": "hour"
        }
      }
    }
    ```
- **Management:** The service will load and cache these policies at startup. An administrative API (`pm_admin_reloadPolicies`) could be added to refresh policies without restarting the service.

---

#### **2.3. 多租户与策略管理**

`super-relay` 将支持多个赞助商（租户）和灵活的赞助策略，从而实现对哪些交易被赞助的精细控制。

- **配置：** 策略将在配置文件中定义（例如 `policies.json` 或 `policies.toml`）。
- **策略结构 (示例):**
    ```json
    {
      "policyId_1": {
        "name": "Default Policy",
        "paymasterAddress": "0x...",
        "allowedSenders": ["0x...", "0x..."],
        "maxGasLimit": "500000",
        "validUntil": "2024-12-31T23:59:59Z"
      },
      "policyId_2": {
        "name": "DApp Partner Policy",
        "paymasterAddress": "0x...",
        "targetContracts": ["0x..."],
        "rateLimitPerSender": {
            "count": 10,
            "interval": "hour"
        }
      }
    }
    ```
- **管理：** 服务将在启动时加载并缓存这些策略。可以添加一个管理 API (`pm_admin_reloadPolicies`) 来实现不重启服务即可刷新策略。

## 3. Technical Architecture

### 3.1. Integration with `rundler`

We will create a new Rust crate named `paymaster-relay` inside `rundler/crates/`. This ensures a clean separation of concerns from `rundler`'s core logic.

```mermaid
graph TD
    subgraph "Rundler Application"
        subgraph "New Crate: paymaster-relay"
            PR_Service["PaymasterRelayService<br/>Core sponsorship logic"]
            PR_Signer["SignerManager<br/>Handles private keys"]
            PR_Policy["PolicyEngine<br/>Manages sponsorship rules"]
        end

        subgraph "Existing Crates"
            RPC["RPC Task (jsonrpsee)"]
            EthAPI["EthApi"]
            Pool["Pool Task (Mempool)"]
            Builder["Builder Task"]
        end

        CLI["CLI Config"] -- "Loads config" --> PR_Service
        RPC -- "Routes pm_sponsorUserOperation" --> PaymasterRelayApi
        PaymasterRelayApi[/"PaymasterRelayApi<br/>Exposes RPC methods"/] --> PR_Service
        PR_Service --> PR_Signer
        PR_Service --> PR_Policy
        PR_Service -- "Submits UO" --> Pool
        Pool --> Builder
    end

    Client["External Client"] -- "Calls pm_sponsorUserOperation" --> RPC
```

---

### **3. 技术架构**

#### **3.1. 与 `rundler` 的集成**

我们将在 `rundler/crates/` 内部创建一个名为 `paymaster-relay` 的新 Rust crate。这确保了与 `rundler` 核心逻辑的清晰分离。

```mermaid
graph TD
    subgraph "Rundler 应用"
        subgraph "新 Crate: paymaster-relay"
            PR_Service["PaymasterRelayService<br/>核心赞助逻辑"]
            PR_Signer["SignerManager<br/>处理私钥"]
            PR_Policy["PolicyEngine<br/>管理赞助规则"]
        end

        subgraph "现有 Crates"
            RPC["RPC 任务 (jsonrpsee)"]
            EthAPI["EthApi"]
            Pool["Pool 任务 (Mempool)"]
            Builder["Builder 任务"]
        end

        CLI["CLI 配置"] -- "加载配置" --> PR_Service
        RPC -- "路由 pm_sponsorUserOperation" --> PaymasterRelayApi
        PaymasterRelayApi[/"PaymasterRelayApi<br/>暴露 RPC 方法"/] --> PR_Service
        PR_Service --> PR_Signer
        PR_Service --> PR_Policy
        PR_Service -- "提交 UO" --> Pool
        Pool --> Builder
    end

    Client["外部客户端"] -- "调用 pm_sponsorUserOperation" --> RPC
```

### 3.2. API Design (`jsonrpsee`)

We will extend `rundler`'s existing RPC server by adding a new API namespace, `pm`.

1.  **Define the API Trait:** In the `paymaster-relay` crate, we'll define the trait for our API.

    ```rust
    // crates/paymaster-relay/src/rpc.rs
    use jsonrpsee::proc_macros::rpc;
    use ethers::types::{Address, U256};
    use rundler_types::user_operation::UserOperation;

    #[rpc(server, client, namespace = "pm")]
    pub trait PaymasterRelayApi {
        #[method(name = "sponsorUserOperation")]
        async fn sponsor_user_operation(
            &self,
            user_op: UserOperation,
            entry_point: Address,
        ) -> RpcResult<UserOperation>;
    }
    ```

2.  **Integrate into `rundler`'s RPC:** We'll add the new API to `rundler`'s RPC builder.

    ```rust
    // crates/rpc/src/lib.rs
    // ... existing ApiSet struct ...
    pub struct ApiSet {
        // ... other APIs
        pub paymaster_relay: Option<impl PaymasterRelayApiServer>,
    }

    // ... in the builder function ...
    if let Some(paymaster_relay_api) = apis.paymaster_relay {
        module.merge(paymaster_relay_api.into_rpc())?;
    }
    ```

---

#### **3.2. API 设计 (`jsonrpsee`)**

我们将通过添加一个新的 API 命名空间 `pm` 来扩展 `rundler` 现有的 RPC 服务器。

1.  **定义 API Trait:** 在 `paymaster-relay` crate 中，我们将为我们的 API 定义 trait。

    ```rust
    // crates/paymaster-relay/src/rpc.rs
    use jsonrpsee::proc_macros::rpc;
    use ethers::types::{Address, U256};
    use rundler_types::user_operation::UserOperation;

    #[rpc(server, client, namespace = "pm")]
    pub trait PaymasterRelayApi {
        #[method(name = "sponsorUserOperation")]
        async fn sponsor_user_operation(
            &self,
            user_op: UserOperation,
            entry_point: Address,
        ) -> RpcResult<UserOperation>;
    }
    ```

2.  **集成到 `rundler` 的 RPC 中:** 我们将新的 API 添加到 `rundler` 的 RPC 构建器中。

    ```rust
    // crates/rpc/src/lib.rs
    // ... 现有的 ApiSet 结构体 ...
    pub struct ApiSet {
        // ... 其他 API
        pub paymaster_relay: Option<impl PaymasterRelayApiServer>,
    }

    // ... 在构建函数中 ...
    if let Some(paymaster_relay_api) = apis.paymaster_relay {
        module.merge(paymaster_relay_api.into_rpc())?;
    }
    ```

### 3.3. Signer Management

A `SignerManager` will be responsible for securely handling Paymaster private keys.
-   **Initialization:** It will load keys from a secure source specified in the configuration (e.g., environment variables, AWS KMS, or an encrypted file).
-   **Usage:** It will provide a simple interface for the `PaymasterRelayService` to request signatures for `userOpHash`.

---

#### **3.3. 签名器管理**

一个 `SignerManager` 将负责安全地处理 Paymaster 的私钥。
-   **初始化：** 它将从配置中指定的安全来源（如环境变量、AWS KMS 或加密文件）加载密钥。
-   **使用：** 它将为 `PaymasterRelayService` 提供一个简单的接口来请求对 `userOpHash` 的签名。

### 3.4. Configuration

New command-line arguments and configuration file options will be added to `rundler` to manage the `super-relay`.

```bash
# Example CLI arguments
./rundler --http \
    --paymaster.enabled \
    --paymaster.signer-key "env:PAYMASTER_PRIVATE_KEY" \
    --paymaster.policy-file "config/policies.toml"
```

These will be defined in `rundler/bin/rundler/src/cli/mod.rs` and plumbed into the `PaymasterRelayService` on startup.

---

#### **3.4. 配置**

新的命令行参数和配置文件选项将被添加到 `rundler` 中以管理 `super-relay`。

```bash
# 命令行参数示例
./rundler --http \
    --paymaster.enabled \
    --paymaster.signer-key "env:PAYMASTER_PRIVATE_KEY" \
    --paymaster.policy-file "config/policies.toml"
```

这些将在 `rundler/bin/rundler/src/cli/mod.rs` 中定义，并在启动时注入到 `PaymasterRelayService` 中。

## 4. Data Flow (End-to-End)

This sequence diagram illustrates the entire sponsorship and submission process.

```mermaid
sequenceDiagram
    participant Client
    participant SuperRelay (RPC)
    participant PaymasterRelayService
    participant PolicyEngine
    participant SignerManager
    participant RundlerMempool

    Client->>SuperRelay (RPC): pm_sponsorUserOperation(userOp, entryPoint)
    SuperRelay (RPC)->>PaymasterRelayService: process_sponsorship(userOp, entryPoint)
    PaymasterRelayService->>PolicyEngine: check_policy(userOp)
    PolicyEngine-->>PaymasterRelayService: PolicyCheckResult::Ok
    PaymasterRelayService->>SignerManager: sign_hash(userOpHash)
    SignerManager-->>PaymasterRelayService: signature
    PaymasterRelayService->>PaymasterRelayService: sponsored_op = construct_sponsored_op(userOp, signature)
    PaymasterRelayService->>RundlerMempool: add_user_operation(sponsored_op)
    RundlerMempool-->>PaymasterRelayService: AddResult::Added(userOpHash)
    PaymasterRelayService-->>SuperRelay (RPC): userOpHash
    SuperRelay (RPC)-->>Client: userOpHash
```

---

### **4. 数据流 (端到端)**

此序列图说明了整个赞助和提交流程。

```mermaid
sequenceDiagram
    participant Client as 客户端
    participant SuperRelay (RPC) as SuperRelay (RPC)
    participant PaymasterRelayService as 支付中继服务
    participant PolicyEngine as 策略引擎
    participant SignerManager as 签名管理器
    participant RundlerMempool as Rundler内存池

    Client->>SuperRelay (RPC): pm_sponsorUserOperation(userOp, entryPoint)
    SuperRelay (RPC)->>PaymasterRelayService: process_sponsorship(userOp, entryPoint)
    PaymasterRelayService->>PolicyEngine: check_policy(userOp)
    PolicyEngine-->>PaymasterRelayService: 策略检查结果::通过
    PaymasterRelayService->>SignerManager: sign_hash(userOpHash)
    SignerManager-->>PaymasterRelayService: 签名
    PaymasterRelayService->>PaymasterRelayService: sponsored_op = construct_sponsored_op(userOp, signature)
    PaymasterRelayService->>RundlerMempool: add_user_operation(sponsored_op)
    RundlerMempool-->>PaymasterRelayService: 添加结果::已添加(userOpHash)
    PaymasterRelayService-->>SuperRelay (RPC): userOpHash
    SuperRelay (RPC)-->>Client: userOpHash
```

## 5. Proposed Project Structure

```
rundler/
├── crates/
│   ├── ... (existing crates: rpc, pool, builder, etc.)
│   └── paymaster-relay/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs          # Main module definition
│           ├── rpc.rs          # jsonrpsee API trait and implementation
│           ├── service.rs      # Core PaymasterRelayService logic
│           ├── policy.rs       # PolicyEngine implementation
│           ├── signer.rs       # SignerManager implementation
│           └── error.rs        # Custom error types
└── bin/
    └── rundler/
        ├── src/
        │   ├── main.rs         # Modified to initialize and launch the PaymasterRelayService
        │   └── cli/
        │       └── mod.rs      # Modified to include new --paymaster.* args
        └── ...
```

This structure clearly separates the new `super-relay` functionality into its own crate, `paymaster-relay`, minimizing changes to the existing `rundler` codebase and simplifying future maintenance and upgrades.

---

### **5. 建议的项目结构**

```
rundler/
├── crates/
│   ├── ... (现有 crates: rpc, pool, builder, etc.)
│   └── paymaster-relay/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs          # 主模块定义
│           ├── rpc.rs          # jsonrpsee API trait 和实现
│           ├── service.rs      # 核心 PaymasterRelayService 逻辑
│           ├── policy.rs       # PolicyEngine 实现
│           ├── signer.rs       # SignerManager 实现
│           └── error.rs        # 自定义错误类型
└── bin/
    └── rundler/
        ├── src/
        │   ├── main.rs         # 修改以初始化并启动 PaymasterRelayService
        │   └── cli/
        │       └── mod.rs      # 修改以包含新的 --paymaster.* 参数
        └── ...
```

这种结构将新的 `super-relay` 功能清晰地分离到其自己的 crate `paymaster-relay` 中，最大限度地减少了对现有 `rundler` 代码库的更改，并简化了未来的维护和升级。 