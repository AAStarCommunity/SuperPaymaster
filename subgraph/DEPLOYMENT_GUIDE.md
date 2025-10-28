# The Graph Deployment Guide - MySBT v2.2

Complete guide to deploy MySBT subgraph to The Graph Decentralized Network.

## Prerequisites

1. **Install Graph CLI**:
```bash
npm install -g @graphprotocol/graph-cli
```

2. **Get GRT tokens**:
- Buy GRT on Coinbase/Binance
- Transfer to your wallet
- Need ~100 GRT for deployment

3. **Setup wallet**:
```bash
# Connect wallet with private key
export PRIVATE_KEY="your_private_key_here"
```

---

## Step 1: Deploy MySBT Contract

```bash
# Deploy to Sepolia testnet
forge script script/DeployMySBT_v2.2.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# Note the deployed address
MYSBT_ADDRESS="0x..."
DEPLOY_BLOCK="12345678"
```

---

## Step 2: Update Subgraph Config

Edit `subgraph/subgraph.yaml`:

```yaml
dataSources:
  - kind: ethereum
    name: MySBT
    network: sepolia  # or mainnet
    source:
      address: "0xYOUR_MYSBT_ADDRESS"  # ← Update this
      abi: MySBT
      startBlock: 12345678  # ← Update this (deployment block)
```

---

## Step 3: Generate Code

```bash
cd subgraph

# Install dependencies
npm install

# Generate TypeScript types
graph codegen

# Verify no errors
graph build
```

Output:
```
✔ Generate types
✔ Compile subgraph
Build completed: build/MySBT/MySBT.wasm
```

---

## Step 4: Create Subgraph on The Graph Studio

1. Go to [https://thegraph.com/studio/](https://thegraph.com/studio/)
2. Connect wallet
3. Click "Create a Subgraph"
4. Name: `mysbt-v2`
5. Network: Sepolia (or Mainnet)
6. Copy the deploy command shown

---

## Step 5: Deploy to The Graph Network

### Deploy to Studio (Testnet - Free)

```bash
# Authenticate
graph auth --studio <DEPLOY_KEY>

# Deploy
graph deploy --studio mysbt-v2

# Follow prompts:
# Version Label: v0.0.1
# Deployment ID: auto-generated
```

### Deploy to Decentralized Network (Mainnet)

```bash
# 1. Publish to IPFS
graph deploy --node https://api.thegraph.com/deploy/ \
  --ipfs https://api.thegraph.com/ipfs/ \
  --access-token <YOUR_ACCESS_TOKEN> \
  mysbt-v2

# 2. Signal curation (optional, improves discovery)
# Go to The Graph Explorer
# Add GRT signal to your subgraph
```

---

## Step 6: Test Subgraph

### Get your subgraph URL

**Studio (testnet)**:
```
https://api.studio.thegraph.com/query/<SUBGRAPH_ID>/mysbt-v2/v0.0.1
```

**Decentralized Network**:
```
https://gateway.thegraph.com/api/<API_KEY>/subgraphs/id/<SUBGRAPH_ID>
```

### Test queries

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{ globalStat(id: \"global\") { totalSBTs totalActivities } }"
  }' \
  https://api.studio.thegraph.com/query/<ID>/mysbt-v2/v0.0.1
```

Expected response:
```json
{
  "data": {
    "globalStat": {
      "totalSBTs": 0,
      "totalActivities": "0"
    }
  }
}
```

---

## Step 7: Trigger Activity & Verify Indexing

### Mint SBT and record activity

```bash
# Use foundry to interact with contract
cast send $MYSBT_ADDRESS \
  "mintOrAddMembership(address,string)" \
  $USER_ADDRESS \
  "ipfs://metadata" \
  --private-key $PRIVATE_KEY
```

### Check indexing status

```bash
curl https://api.thegraph.com/index-node/graphql \
  -X POST \
  -d '{
    "query": "{ indexingStatusForCurrentVersion(subgraphName: \"mysbt-v2\") { health synced } }"
  }'
```

Wait for `"health": "healthy"` and `"synced": true`

---

## Step 8: Integrate with Frontend

### Install GraphQL client

```bash
npm install @apollo/client graphql
```

### Setup client

```typescript
// src/lib/graphql.ts
import { ApolloClient, InMemoryCache, gql } from '@apollo/client';

export const graphQLClient = new ApolloClient({
  uri: 'https://api.studio.thegraph.com/query/<ID>/mysbt-v2/v0.0.1',
  cache: new InMemoryCache(),
});

export const GET_REPUTATION = gql`
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
    }
  }
`;
```

### Use in component

```typescript
// src/pages/Profile.tsx
import { useQuery } from '@apollo/client';
import { GET_REPUTATION } from '@/lib/graphql';

function ProfilePage() {
  const { data, loading } = useQuery(GET_REPUTATION, {
    variables: {
      tokenId: "1",
      community: "0x..."
    }
  });

  if (loading) return <div>Loading reputation...</div>;

  const reputation = data.reputationScores[0];
  return (
    <div>
      <h2>Reputation Score: {reputation.score}</h2>
      <p>Base: {reputation.baseScore}</p>
      <p>NFT Bonus: {reputation.nftBonus}</p>
      <p>Activity Bonus: {reputation.activityBonus}</p>
    </div>
  );
}
```

---

## Cost Management

### Monitor Query Usage

```bash
# Check query count
curl https://api.thegraph.com/subgraphs/id/<SUBGRAPH_ID>/stats
```

### Optimize Query Costs

1. **Cache aggressively**:
```typescript
const client = new ApolloClient({
  cache: new InMemoryCache({
    typePolicies: {
      Query: {
        fields: {
          reputationScores: {
            // Cache for 5 minutes
            merge: true,
          }
        }
      }
    }
  }),
  defaultOptions: {
    watchQuery: {
      fetchPolicy: 'cache-first',
    },
  },
});
```

2. **Batch queries**:
```graphql
query GetUserData($tokenId: String!) {
  sbt(id: $tokenId) {
    holder
    totalCommunities
    memberships { community { name } }
    reputationScores(first: 10) { score }
  }
}
```

3. **Use subscriptions sparingly** (costs more):
```typescript
// ❌ Avoid
useSubscription(REPUTATION_SUBSCRIPTION);

// ✅ Poll instead
useQuery(GET_REPUTATION, { pollInterval: 30000 });
```

---

## Troubleshooting

### Issue: Subgraph not syncing

**Check**:
```bash
graph deploy --debug
```

**Common fixes**:
- Verify contract address and startBlock
- Check ABI matches deployed contract
- Ensure RPC URL is accessible

---

### Issue: Queries returning empty

**Check**:
1. Has any activity been recorded?
2. Is indexing complete? (check `synced: true`)
3. Try simpler query first:
```graphql
{ globalStat(id: "global") { totalSBTs } }
```

---

### Issue: High query costs

**Solutions**:
1. Reduce query frequency (polling)
2. Implement frontend caching
3. Use aggregated queries
4. Consider self-hosted graph-node

---

## Self-Hosted Option (Advanced)

### Setup Graph Node

```bash
git clone https://github.com/graphprotocol/graph-node
cd graph-node/docker

# Edit docker-compose.yml - add your Ethereum RPC
# ethereum: 'mainnet:https://eth-mainnet.alchemyapi.io/v2/<KEY>'

# Start services
docker-compose up -d

# Create subgraph
graph create --node http://localhost:8020/ mysbt-v2

# Deploy
graph deploy \
  --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  mysbt-v2 \
  subgraph.yaml
```

**Costs**:
- Server: $100-200/month (4 CPU, 8GB RAM)
- RPC: $50-100/month (Alchemy/Infura)
- Total: ~$150-300/month

**Pros**:
- ✅ No per-query fees
- ✅ Full control
- ✅ No GRT required

**Cons**:
- ❌ Centralized
- ❌ Higher maintenance
- ❌ No decentralized guarantees

---

## Production Checklist

- [ ] Contract deployed and verified
- [ ] Subgraph deployed to The Graph Network
- [ ] Queries tested and working
- [ ] Frontend integration complete
- [ ] Caching strategy implemented
- [ ] Monitoring setup (query costs)
- [ ] Backup RPC endpoints configured
- [ ] Documentation updated

---

## Cost Summary

| Deployment Option | Initial Cost | Monthly Cost | Decentralized |
|-------------------|--------------|--------------|---------------|
| **The Graph Network** | $20-50 (100 GRT) | $25-500 | ✅ Yes |
| **Self-Hosted** | $0 | $150-300 | ❌ No |
| **Hybrid** | $20 | $50-100 | ⚠️ Partial |

**Recommendation for MySBT**:
- **Testnet**: Use The Graph Studio (free)
- **Mainnet**: The Graph Network (decentralized, pay-as-you-go)
- **Enterprise**: Consider self-hosted if >1M queries/month

---

**Last Updated**: 2025-10-28
**Network**: Sepolia Testnet
**Status**: Ready for deployment
