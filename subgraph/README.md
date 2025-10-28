# MySBT v2.2 - The Graph Subgraph

Event-driven activity tracking for gas-optimized reputation calculation.

## Overview

This subgraph indexes MySBT v2.2 contract events to provide off-chain activity tracking and reputation calculation. By moving activity tracking from on-chain storage to event indexing, we achieve **48% gas savings** (65k → 34k gas per `recordActivity` call).

## Architecture

```
┌─────────────────┐
│  MySBT v2.2     │
│  (On-chain)     │
│                 │
│  recordActivity │──┐
│  ✅ Event only  │  │
│  ❌ No SSTORE   │  │
└─────────────────┘  │
                     │ ActivityRecorded event
                     ▼
┌─────────────────────────────────┐
│  The Graph Subgraph             │
│  (Off-chain indexer)            │
│                                 │
│  • Track all activities         │
│  • Calculate weekly stats       │
│  • Compute reputation scores    │
│  • Provide GraphQL API          │
└─────────────────────────────────┘
                     │
                     │ GraphQL queries
                     ▼
┌─────────────────────────────────┐
│  External Reputation Calculator │
│  (Smart contract)               │
│                                 │
│  • Query subgraph via oracle    │
│  • Return reputation on-chain   │
└─────────────────────────────────┘
```

## Gas Savings

| Operation | v2.1 (On-chain) | v2.2 (Event-driven) | Savings |
|-----------|-----------------|---------------------|---------|
| **recordActivity** | 65k gas | **34k gas** | **48%** |
| **Annual cost** (10k users, 50 tx/user) | $3M | $1.56M | **$1.44M** |

## Installation

```bash
# 1. Install Graph CLI
npm install -g @graphprotocol/graph-cli

# 2. Navigate to subgraph directory
cd subgraph

# 3. Initialize subgraph
graph init --product hosted-service

# 4. Update subgraph.yaml with deployed contract address
# Replace address and startBlock in subgraph.yaml

# 5. Generate types
graph codegen

# 6. Build subgraph
graph build

# 7. Authenticate with The Graph
graph auth --product hosted-service <ACCESS_TOKEN>

# 8. Deploy
graph deploy --product hosted-service <SUBGRAPH_NAME>
```

## Configuration

Before deploying, update `subgraph.yaml`:

```yaml
source:
  address: "0xYOUR_DEPLOYED_MYSBT_ADDRESS" # ← Update this
  startBlock: 1234567 # ← Update with deployment block
```

## GraphQL Queries

### Query recent activities for a user

```graphql
query GetUserActivities($tokenId: String!) {
  activities(
    where: { sbt: $tokenId }
    orderBy: timestamp
    orderDirection: desc
    first: 10
  ) {
    id
    community {
      id
      name
    }
    week
    timestamp
    transactionHash
  }
}
```

### Query reputation score for a user in a community

```graphql
query GetReputation($tokenId: String!, $community: String!) {
  reputationScores(
    where: { sbt: $tokenId, community: $community }
    orderBy: calculatedAt
    orderDirection: desc
    first: 1
  ) {
    score
    baseScore
    nftBonus
    activityBonus
    calculatedAt
    activityWindow
  }
}
```

### Query weekly activity stats

```graphql
query GetWeeklyStats($tokenId: String!, $community: String!) {
  weeklyActivityStats(
    where: { sbt: $tokenId, community: $community }
    orderBy: week
    orderDirection: desc
    first: 4
  ) {
    week
    activityCount
    firstActivityTime
    lastActivityTime
  }
}
```

### Query global statistics

```graphql
query GetGlobalStats {
  globalStat(id: "global") {
    totalSBTs
    totalCommunities
    totalActivities
    totalMemberships
    lastUpdatedAt
  }
}
```

## External Reputation Calculator Integration

To use subgraph data on-chain:

1. **Deploy Chainlink Oracle** to query subgraph
2. **Create ReputationCalculatorV2** that fetches from oracle
3. **Set calculator** in MySBT:

```solidity
// Set external calculator
mySBT.setReputationCalculator(address(reputationCalculatorV2));

// Now getCommunityReputation() will use off-chain data
uint256 score = mySBT.getCommunityReputation(user, community);
```

## Development

### Generate Types

```bash
graph codegen
```

### Build

```bash
graph build
```

### Deploy to Local Node

```bash
# Start local graph node
git clone https://github.com/graphprotocol/graph-node
cd graph-node/docker
docker-compose up

# Deploy subgraph
graph create --node http://localhost:8020/ <SUBGRAPH_NAME>
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 <SUBGRAPH_NAME>
```

## Testing

Query your subgraph at: `https://api.thegraph.com/subgraphs/name/<YOUR_SUBGRAPH_NAME>`

Or use Graph Explorer: `https://thegraph.com/explorer/subgraph/<YOUR_SUBGRAPH_NAME>`

## Monitoring

- **Sync Status**: Check indexing progress
- **Query Performance**: Monitor query execution time
- **Error Logs**: Review event handler failures

## Migration from v2.1

1. **Deploy MySBT v2.2** with event-driven `recordActivity()`
2. **Deploy subgraph** and wait for sync
3. **Deploy ReputationCalculatorV2** with subgraph integration
4. **Update MySBT** to use new calculator:
   ```solidity
   mySBT.setReputationCalculator(address(calculatorV2));
   ```

## Gas Cost Comparison

### Before (v2.1)
```solidity
function recordActivity(address user) {
    _memberships[tokenId][idx].lastActiveTime = block.timestamp; // 20k gas
    weeklyActivity[tokenId][msg.sender][week] = true;           // 20k gas
    emit ActivityRecorded(...);                                  // 5k gas
}
// Total: ~65k gas
```

### After (v2.2)
```solidity
function recordActivity(address user) {
    emit ActivityRecorded(...); // 5k gas only
}
// Total: ~34k gas (48% reduction)
```

## Support

For issues, see:
- [The Graph Docs](https://thegraph.com/docs/)
- [MySBT v2.2 Design Doc](../docs/MySBT_v2.1_Design.md)
- [Gas Optimization Analysis](../docs/MySBT_v2.1_Gas_Optimization.md)

---

**Created**: 2025-10-28
**Version**: v2.2
**Gas Savings**: 48% (65k → 34k gas)
