# ERC-8004 Interface Definitions for SuperPaymaster

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Overview

This document defines the Solidity interfaces for **native ERC-8004 integration** in the SuperPaymaster ecosystem.

**Integration Approach**: Native Integration (no adapter layer)
- MySBT natively implements `IERC8004IdentityRegistry`
- ReputationAccumulator natively implements `IERC8004ReputationRegistry`
- JuryContract (in MyTask repo) implements `IERC8004ValidationRegistry`

## Core ERC-8004 Interfaces

### 1. Identity Registry Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IERC8004IdentityRegistry
 * @notice ERC-8004 Identity Registry interface for agent identification
 * @dev Based on ERC-721 with metadata extensions
 */
interface IERC8004IdentityRegistry {
    // ====================================
    // Data Structures
    // ====================================

    /// @notice Metadata entry for agent registration
    struct MetadataEntry {
        string key;
        bytes value;
    }

    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when an agent is registered
    event Registered(
        uint256 indexed agentId,
        string tokenURI,
        address indexed owner
    );

    /// @notice Emitted when metadata is set
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedKey,
        string key,
        bytes value
    );

    // ====================================
    // Registration Functions
    // ====================================

    /**
     * @notice Register a new agent with token URI and metadata
     * @param tokenURI URI pointing to agent registration JSON
     * @param metadata Array of metadata entries
     * @return agentId The newly registered agent ID
     */
    function register(
        string calldata tokenURI,
        MetadataEntry[] calldata metadata
    ) external returns (uint256 agentId);

    /**
     * @notice Register a new agent with token URI only
     * @param tokenURI URI pointing to agent registration JSON
     * @return agentId The newly registered agent ID
     */
    function register(string calldata tokenURI) external returns (uint256 agentId);

    /**
     * @notice Register a new agent with default settings
     * @return agentId The newly registered agent ID
     */
    function register() external returns (uint256 agentId);

    // ====================================
    // Metadata Functions
    // ====================================

    /**
     * @notice Get metadata value for agent
     * @param agentId The agent token ID
     * @param key The metadata key
     * @return value The metadata value as bytes
     */
    function getMetadata(
        uint256 agentId,
        string calldata key
    ) external view returns (bytes memory value);

    /**
     * @notice Set metadata for agent
     * @param agentId The agent token ID
     * @param key The metadata key
     * @param value The metadata value as bytes
     */
    function setMetadata(
        uint256 agentId,
        string calldata key,
        bytes calldata value
    ) external;

    // ====================================
    // View Functions (inherited from ERC-721)
    // ====================================

    /**
     * @notice Get agent owner
     * @param agentId The agent token ID
     * @return owner The owner address
     */
    function ownerOf(uint256 agentId) external view returns (address owner);

    /**
     * @notice Get token URI for agent
     * @param agentId The agent token ID
     * @return uri The token URI
     */
    function tokenURI(uint256 agentId) external view returns (string memory uri);
}
```

### 2. Reputation Registry Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IERC8004ReputationRegistry
 * @notice ERC-8004 Reputation Registry interface for agent feedback
 */
interface IERC8004ReputationRegistry {
    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when new feedback is given
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint8 score,
        bytes32 indexed tag1,
        bytes32 tag2,
        string fileuri,
        bytes32 filehash
    );

    /// @notice Emitted when feedback is revoked
    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 indexed feedbackIndex
    );

    /// @notice Emitted when response is appended
    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        address indexed responder,
        string responseUri
    );

    // ====================================
    // Write Functions
    // ====================================

    /**
     * @notice Give feedback for an agent
     * @param agentId The agent token ID
     * @param score Score from 0-100
     * @param tag1 Primary tag (category)
     * @param tag2 Secondary tag (subcategory)
     * @param fileuri URI to detailed feedback file
     * @param filehash KECCAK-256 hash of feedback file
     * @param feedbackAuth EIP-191 signed authorization
     */
    function giveFeedback(
        uint256 agentId,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        string calldata fileuri,
        bytes32 filehash,
        bytes calldata feedbackAuth
    ) external;

    /**
     * @notice Revoke previously given feedback
     * @param agentId The agent token ID
     * @param feedbackIndex Index of feedback to revoke
     */
    function revokeFeedback(
        uint256 agentId,
        uint64 feedbackIndex
    ) external;

    /**
     * @notice Append response to feedback
     * @param agentId The agent token ID
     * @param clientAddress Original feedback giver
     * @param feedbackIndex Feedback index to respond to
     * @param responseUri URI to response file
     * @param responseHash KECCAK-256 hash of response file
     */
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseUri,
        bytes32 responseHash
    ) external;

    // ====================================
    // Read Functions
    // ====================================

    /**
     * @notice Get reputation summary for agent
     * @param agentId The agent token ID
     * @param clientAddresses Filter by specific clients (empty for all)
     * @param tag1 Filter by primary tag (bytes32(0) for all)
     * @param tag2 Filter by secondary tag (bytes32(0) for all)
     * @return count Number of feedback entries
     * @return averageScore Average score (0-100)
     */
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 averageScore);

    /**
     * @notice Read specific feedback
     * @param agentId The agent token ID
     * @param clientAddress Feedback giver address
     * @param index Feedback index
     * @return score Feedback score
     * @return tag1 Primary tag
     * @return tag2 Secondary tag
     * @return isRevoked Whether feedback was revoked
     */
    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (
        uint8 score,
        bytes32 tag1,
        bytes32 tag2,
        bool isRevoked
    );

    /**
     * @notice Get all clients who gave feedback
     * @param agentId The agent token ID
     * @return clients Array of client addresses
     */
    function getClients(uint256 agentId) external view returns (address[] memory clients);

    /**
     * @notice Get last feedback index for client
     * @param agentId The agent token ID
     * @param clientAddress Client address
     * @return lastIndex Last feedback index
     */
    function getLastIndex(
        uint256 agentId,
        address clientAddress
    ) external view returns (uint64 lastIndex);

    /**
     * @notice Get identity registry address
     * @return registry Identity registry contract address
     */
    function getIdentityRegistry() external view returns (address registry);
}
```

### 3. Validation Registry Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IERC8004ValidationRegistry
 * @notice ERC-8004 Validation Registry interface for task verification
 */
interface IERC8004ValidationRegistry {
    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when validation is requested
    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string requestUri,
        bytes32 indexed requestHash
    );

    /// @notice Emitted when validation response is submitted
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseUri,
        bytes32 tag
    );

    // ====================================
    // Write Functions
    // ====================================

    /**
     * @notice Request validation from a validator
     * @param validatorAddress Validator to request from
     * @param agentId Agent requesting validation
     * @param requestUri URI to validation request details
     * @param requestHash Hash of request (optional for IPFS)
     */
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestUri,
        bytes32 requestHash
    ) external;

    /**
     * @notice Submit validation response
     * @param requestHash Hash of original request
     * @param response Validation result (0=failed, 100=passed, 1-99=partial)
     * @param responseUri URI to detailed response
     * @param responseHash Hash of response file
     * @param tag Category tag for validation
     */
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseUri,
        bytes32 responseHash,
        bytes32 tag
    ) external;

    // ====================================
    // Read Functions
    // ====================================

    /**
     * @notice Get validation status
     * @param requestHash Request hash to query
     * @return validatorAddress Assigned validator
     * @return agentId Agent who requested
     * @return response Validation response (0-100)
     * @return tag Validation category
     * @return lastUpdate Last update timestamp
     */
    function getValidationStatus(bytes32 requestHash)
        external view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 tag,
            uint256 lastUpdate
        );

    /**
     * @notice Get validation summary for agent
     * @param agentId Agent token ID
     * @param validatorAddresses Filter by validators (empty for all)
     * @param tag Filter by category tag
     * @return count Number of validations
     * @return avgResponse Average response score
     */
    function getSummary(
        uint256 agentId,
        address[] calldata validatorAddresses,
        bytes32 tag
    ) external view returns (uint64 count, uint8 avgResponse);

    /**
     * @notice Get all validation request hashes for agent
     * @param agentId Agent token ID
     * @return requestHashes Array of request hashes
     */
    function getAgentValidations(uint256 agentId)
        external view
        returns (bytes32[] memory requestHashes);

    /**
     * @notice Get all request hashes assigned to validator
     * @param validatorAddress Validator address
     * @return requestHashes Array of request hashes
     */
    function getValidatorRequests(address validatorAddress)
        external view
        returns (bytes32[] memory requestHashes);
}
```

---

## Native Integration Interfaces

### 4. MySBT v2.5.0 Extension (Identity Registry)

MySBT natively implements `IERC8004IdentityRegistry` on top of existing ERC-721 functionality.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IERC8004IdentityRegistry.sol";

/**
 * @title IMySBT_v2_5_0
 * @notice MySBT with native ERC-8004 Identity Registry support
 * @dev Extends existing MySBT functionality with ERC-8004 compliance
 *
 * Key Design:
 * - Token ID = Agent ID (1:1 mapping)
 * - Existing mint() preserved, new register() overloads added
 * - Metadata stored on-chain for discoverability
 */
interface IMySBT_v2_5_0 is IERC8004IdentityRegistry {
    // ====================================
    // Existing MySBT Functions (preserved)
    // ====================================

    /// @notice Existing mint function (unchanged)
    function mint(address to) external returns (uint256 tokenId);

    /// @notice Get next token ID
    function getNextTokenId() external view returns (uint256);

    /// @notice Check if address holds MySBT
    function hasMySBT(address account) external view returns (bool);

    // ====================================
    // ERC-8004 Extensions
    // ====================================

    /**
     * @notice Set token URI for existing token
     * @param tokenId Token/Agent ID
     * @param uri New token URI
     * @dev Only token owner can call
     */
    function setTokenURI(uint256 tokenId, string calldata uri) external;

    /**
     * @notice Batch set metadata
     * @param agentId Agent ID
     * @param entries Array of metadata entries
     */
    function batchSetMetadata(
        uint256 agentId,
        MetadataEntry[] calldata entries
    ) external;

    /**
     * @notice Get all metadata keys for agent
     * @param agentId Agent ID
     * @return keys Array of metadata keys
     */
    function getMetadataKeys(uint256 agentId) external view returns (string[] memory keys);

    /**
     * @notice Build agent card JSON
     * @param agentId Agent ID
     * @return json Agent card in JSON format
     * @dev Helper for off-chain discovery
     */
    function buildAgentCard(uint256 agentId) external view returns (string memory json);

    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when token URI is updated
    event TokenURIUpdated(
        uint256 indexed agentId,
        string oldUri,
        string newUri
    );

    /// @notice Emitted when batch metadata is set
    event BatchMetadataSet(
        uint256 indexed agentId,
        uint256 count
    );
}
```

### 5. ReputationAccumulator v2.0 Extension

ReputationAccumulator natively implements `IERC8004ReputationRegistry` while keeping existing dual-layer reputation.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IERC8004ReputationRegistry.sol";

/**
 * @title IMySBTReputationAccumulator_v2_0
 * @notice ReputationAccumulator with native ERC-8004 Reputation Registry support
 * @dev Maintains existing dual-layer (community + global) + adds ERC-8004 client feedback
 *
 * Reputation Sources:
 * 1. Community-based reputation (existing)
 * 2. Global activity scoring (existing)
 * 3. ERC-8004 client feedback (new)
 */
interface IMySBTReputationAccumulator_v2_0 is IERC8004ReputationRegistry {
    // ====================================
    // Existing Functions (preserved)
    // ====================================

    /// @notice Update reputation from activity
    function updateReputation(
        uint256 tokenId,
        address community,
        uint8 activityType,
        uint256 value
    ) external;

    /// @notice Get community-specific reputation
    function getCommunityReputation(
        uint256 tokenId,
        address community
    ) external view returns (uint256 score, uint256 level);

    /// @notice Get global reputation
    function getGlobalReputation(uint256 tokenId)
        external view returns (uint256 score, uint256 level);

    // ====================================
    // ERC-8004 Extensions
    // ====================================

    /**
     * @notice Get combined reputation (all sources)
     * @param agentId Agent ID
     * @return communityScore Community-based score
     * @return globalScore Global activity score
     * @return clientScore ERC-8004 client feedback score (0-100)
     * @return clientCount Number of client feedbacks
     */
    function getCombinedReputation(uint256 agentId)
        external view
        returns (
            uint256 communityScore,
            uint256 globalScore,
            uint8 clientScore,
            uint64 clientCount
        );

    /**
     * @notice Verify feedback authorization signature
     * @param agentId Agent ID
     * @param clientAddress Client giving feedback
     * @param feedbackAuth EIP-191 signature
     * @return isValid Whether signature is valid
     *
     * @dev Signature message format:
     *      keccak256(abi.encodePacked(
     *          "\x19Ethereum Signed Message:\n32",
     *          keccak256(abi.encode(agentId, clientAddress, "FEEDBACK_AUTH"))
     *      ))
     *      Signed by: Agent owner (MySBT holder)
     */
    function verifyFeedbackAuth(
        uint256 agentId,
        address clientAddress,
        bytes calldata feedbackAuth
    ) external view returns (bool isValid);

    /**
     * @notice Check if client has given feedback
     * @param agentId Agent ID
     * @param clientAddress Client address
     * @return hasFeedback Whether client has given feedback
     * @return feedbackCount Number of feedbacks from this client
     */
    function hasClientFeedback(
        uint256 agentId,
        address clientAddress
    ) external view returns (bool hasFeedback, uint64 feedbackCount);

    /**
     * @notice Get reputation by tag
     * @param agentId Agent ID
     * @param tag1 Primary tag
     * @param tag2 Secondary tag (bytes32(0) for any)
     * @return count Number of feedbacks
     * @return avgScore Average score
     */
    function getReputationByTag(
        uint256 agentId,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 avgScore);

    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when community reputation updated
    event CommunityReputationUpdated(
        uint256 indexed agentId,
        address indexed community,
        uint256 newScore,
        uint256 newLevel
    );

    /// @notice Emitted when global reputation updated
    event GlobalReputationUpdated(
        uint256 indexed agentId,
        uint256 newScore,
        uint256 newLevel
    );
}
```

### 6. JuryContract Interface (for MyTask Repo)

Full Validation Registry implementation with jury-based verification.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IERC8004ValidationRegistry.sol";

/**
 * @title IJuryContract
 * @notice Jury-based validation for ERC-8004 compliance
 * @dev Implements multi-party task verification with staking
 *
 * Deployment: MyTask repo (/Volumes/UltraDisk/Dev2/aastar/MyTask)
 * Integration: References MySBT for agent identity verification
 */
interface IJuryContract is IERC8004ValidationRegistry {
    // ====================================
    // Data Structures
    // ====================================

    /// @notice Task type enumeration
    enum TaskType {
        SIMPLE_VERIFICATION,    // Single jury vote
        CONSENSUS_REQUIRED,     // Multiple jury agreement
        CRYPTO_ECONOMIC,        // Stake-weighted voting
        TEE_ATTESTATION         // Trusted execution environment
    }

    /// @notice Task status
    enum TaskStatus {
        PENDING,
        IN_PROGRESS,
        COMPLETED,
        DISPUTED,
        CANCELLED
    }

    /// @notice Task parameters
    struct TaskParams {
        uint256 agentId;
        TaskType taskType;
        string evidenceUri;
        uint256 reward;
        uint256 deadline;
        uint256 minJurors;
        uint256 consensusThreshold;  // Basis points (6600 = 66%)
    }

    /// @notice Task data
    struct Task {
        uint256 agentId;
        bytes32 taskHash;
        string evidenceUri;
        TaskType taskType;
        uint256 reward;
        uint256 deadline;
        TaskStatus status;
        uint256 minJurors;
        uint256 consensusThreshold;
        uint256 totalVotes;
        uint256 positiveVotes;
        uint8 finalResponse;
    }

    /// @notice Juror vote
    struct Vote {
        address juror;
        uint8 response;
        string reasoning;
        uint256 timestamp;
        bool slashed;
    }

    // ====================================
    // Events
    // ====================================

    event TaskCreated(
        bytes32 indexed taskHash,
        uint256 indexed agentId,
        TaskType taskType,
        uint256 reward,
        uint256 deadline
    );

    event EvidenceSubmitted(
        bytes32 indexed taskHash,
        string evidenceUri,
        uint256 timestamp
    );

    event JurorVoted(
        bytes32 indexed taskHash,
        address indexed juror,
        uint8 response,
        uint256 timestamp
    );

    event TaskFinalized(
        bytes32 indexed taskHash,
        uint8 finalResponse,
        uint256 totalVotes,
        uint256 positiveVotes
    );

    event JurorSlashed(
        bytes32 indexed taskHash,
        address indexed juror,
        uint256 amount
    );

    event JurorRewarded(
        bytes32 indexed taskHash,
        address indexed juror,
        uint256 amount
    );

    // ====================================
    // Task Management
    // ====================================

    /**
     * @notice Create a new task for validation
     * @param params Task parameters
     * @return taskHash Unique task identifier
     */
    function createTask(TaskParams calldata params) external payable returns (bytes32 taskHash);

    /**
     * @notice Submit evidence for task
     * @param taskHash Task to submit evidence for
     * @param evidenceUri URI to evidence
     */
    function submitEvidence(bytes32 taskHash, string calldata evidenceUri) external;

    /**
     * @notice Vote on task as juror
     * @param taskHash Task to vote on
     * @param response Validation response (0-100)
     * @param reasoning URI to detailed reasoning
     */
    function vote(bytes32 taskHash, uint8 response, string calldata reasoning) external;

    /**
     * @notice Finalize task after voting period
     * @param taskHash Task to finalize
     */
    function finalizeTask(bytes32 taskHash) external;

    /**
     * @notice Cancel task (only creator before votes)
     * @param taskHash Task to cancel
     */
    function cancelTask(bytes32 taskHash) external;

    // ====================================
    // Jury Management
    // ====================================

    /**
     * @notice Register as juror
     * @param stakeAmount Amount to stake
     */
    function registerJuror(uint256 stakeAmount) external;

    /**
     * @notice Unregister juror (with cooldown)
     */
    function unregisterJuror() external;

    /**
     * @notice Check if address is active juror
     * @param juror Address to check
     * @return isActive Whether juror is active
     * @return stake Juror's stake amount
     */
    function isActiveJuror(address juror) external view returns (bool isActive, uint256 stake);

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get task details
     * @param taskHash Task hash
     * @return task Task data
     */
    function getTask(bytes32 taskHash) external view returns (Task memory task);

    /**
     * @notice Get votes for task
     * @param taskHash Task hash
     * @return votes Array of votes
     */
    function getVotes(bytes32 taskHash) external view returns (Vote[] memory votes);

    /**
     * @notice Get juror's vote for task
     * @param taskHash Task hash
     * @param juror Juror address
     * @return vote Juror's vote (if exists)
     * @return hasVoted Whether juror has voted
     */
    function getJurorVote(bytes32 taskHash, address juror)
        external view returns (Vote memory vote, bool hasVoted);

    // ====================================
    // Configuration
    // ====================================

    /**
     * @notice Get MySBT contract (Identity Registry)
     * @return mysbt MySBT contract address
     */
    function getMySBT() external view returns (address mysbt);

    /**
     * @notice Get minimum juror stake
     * @return minStake Minimum stake amount
     */
    function getMinJurorStake() external view returns (uint256 minStake);

    /**
     * @notice Get staking token
     * @return token Staking token address
     */
    function getStakingToken() external view returns (address token);
}
```

---

## Usage Examples

### Example 1: Register Agent with Metadata

```solidity
// Using MySBT v2.5.0 native registration
IMySBT_v2_5_0 mysbt = IMySBT_v2_5_0(MYSBT_ADDRESS);

// Register with token URI
uint256 agentId = mysbt.register("ipfs://QmAgentCard...");

// Set metadata
mysbt.setMetadata(agentId, "capabilities", abi.encode(["gasless-tx", "defi"]));
mysbt.setMetadata(agentId, "endpoint", abi.encode("https://api.agent.example"));
```

### Example 2: Give Feedback with Authorization

```solidity
// Client gives feedback after agent completes task
IMySBTReputationAccumulator_v2_0 reputation = IMySBTReputationAccumulator_v2_0(REPUTATION_ADDRESS);

// Agent owner signs authorization for client
bytes memory feedbackAuth = signFeedbackAuth(agentId, clientAddress);

// Client submits feedback
reputation.giveFeedback(
    agentId,
    85,                           // Score: 85/100
    keccak256("gasless"),         // tag1: service category
    keccak256("fast"),            // tag2: quality attribute
    "ipfs://QmFeedbackDetails",   // Detailed feedback
    0x...,                        // File hash
    feedbackAuth                  // EIP-191 signature
);
```

### Example 3: Create Validation Task (MyTask)

```solidity
// Create task for jury validation
IJuryContract jury = IJuryContract(JURY_ADDRESS);

bytes32 taskHash = jury.createTask(IJuryContract.TaskParams({
    agentId: agentId,
    taskType: IJuryContract.TaskType.CONSENSUS_REQUIRED,
    evidenceUri: "ipfs://QmEvidence...",
    reward: 1 ether,
    deadline: block.timestamp + 7 days,
    minJurors: 3,
    consensusThreshold: 6600  // 66%
}));

// Later: Get validation result
(,, uint8 response,,) = jury.getValidationStatus(taskHash);
```

### Example 4: Get Combined Reputation

```solidity
// Get all reputation sources for an agent
IMySBTReputationAccumulator_v2_0 reputation = IMySBTReputationAccumulator_v2_0(REPUTATION_ADDRESS);

(
    uint256 communityScore,
    uint256 globalScore,
    uint8 clientScore,
    uint64 clientCount
) = reputation.getCombinedReputation(agentId);

// Community score: from operator/community activities
// Global score: from on-chain activity tracking
// Client score: from ERC-8004 giveFeedback (0-100)
```

---

<a name="chinese"></a>

# SuperPaymaster ERC-8004 接口定义

**[English](#english)** | **[中文](#chinese)**

---

## 概述

本文档定义了 SuperPaymaster 生态系统**原生 ERC-8004 集成**所需的 Solidity 接口。

**集成方式**: 原生集成（无适配器层）
- MySBT 原生实现 `IERC8004IdentityRegistry`
- ReputationAccumulator 原生实现 `IERC8004ReputationRegistry`
- JuryContract（在 MyTask 仓库）实现 `IERC8004ValidationRegistry`

## 接口摘要

| 接口 | 用途 | 实现位置 |
|------|------|----------|
| `IERC8004IdentityRegistry` | ERC-8004 身份注册标准 | 核心标准接口 |
| `IERC8004ReputationRegistry` | ERC-8004 声誉反馈标准 | 核心标准接口 |
| `IERC8004ValidationRegistry` | ERC-8004 验证注册标准 | 核心标准接口 |
| `IMySBT_v2_5_0` | MySBT 原生扩展 | SuperPaymaster |
| `IMySBTReputationAccumulator_v2_0` | 声誉累加器原生扩展 | SuperPaymaster |
| `IJuryContract` | 陪审团验证合约 | MyTask 仓库 |

## 关键设计决策

### 1. Token ID = Agent ID

MySBT 的 token ID 直接作为 ERC-8004 的 agent ID，无需映射层。

### 2. 三层声誉系统

```
声誉来源:
├── 社区声誉 (Community)     ← 来自 operator/社区活动
├── 全局声誉 (Global)        ← 来自链上活动追踪
└── 客户反馈 (Client)        ← 来自 ERC-8004 giveFeedback
```

### 3. EIP-191 签名授权

防止垃圾反馈：
```
签名消息 = keccak256(agentId, clientAddress, "FEEDBACK_AUTH")
签名者 = Agent 所有者（MySBT 持有者）
```

只有获得 agent 授权的客户才能提交反馈。

## 使用示例

### 注册 Agent

```solidity
// 使用 MySBT v2.5.0 原生注册
IMySBT_v2_5_0 mysbt = IMySBT_v2_5_0(MYSBT_ADDRESS);

// 带 token URI 注册
uint256 agentId = mysbt.register("ipfs://QmAgentCard...");

// 设置元数据
mysbt.setMetadata(agentId, "capabilities", abi.encode(["gasless-tx"]));
```

### 提交反馈

```solidity
// Agent 所有者签名授权
bytes memory feedbackAuth = signFeedbackAuth(agentId, clientAddress);

// 客户提交反馈
reputation.giveFeedback(
    agentId,
    85,                           // 分数: 85/100
    keccak256("gasless"),         // tag1: 服务类别
    keccak256("fast"),            // tag2: 质量属性
    "ipfs://...",                 // 详细反馈
    0x...,                        // 文件哈希
    feedbackAuth                  // EIP-191 签名
);
```

### 获取综合声誉

```solidity
(
    uint256 communityScore,    // 社区声誉
    uint256 globalScore,       // 全局声誉
    uint8 clientScore,         // 客户反馈分数 (0-100)
    uint64 clientCount         // 反馈数量
) = reputation.getCombinedReputation(agentId);
```
