# MySBT v2.3 Subgraph - Quick Deploy Guide

## ✅ Preparation Complete

- [x] Graph CLI installed (v0.98.1)
- [x] Dependencies installed
- [x] Schema updated (immutable attributes)
- [x] Code generated
- [x] Build successful

## 📋 Deployment Information

**Contract Details**:
- Address: `0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8`
- Network: Sepolia (11155111)
- Start Block: `9507735`
- Version: 2.3.0 (Security Enhanced)

## 🚀 Quick Deployment Steps

### Option 1: The Graph Studio (Recommended for Testing)

#### Step 1: Create Subgraph on Studio

1. Visit: https://thegraph.com/studio/
2. Connect your wallet (MetaMask)
3. Click "Create a Subgraph"
4. Name: `mysbt-v2-3`
5. Network: **Sepolia**
6. Copy your **Deploy Key**

#### Step 2: Authenticate

```bash
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster/subgraph

# Replace <DEPLOY_KEY> with your key from Studio
graph auth --studio <DEPLOY_KEY>
```

#### Step 3: Deploy

```bash
graph deploy --studio mysbt-v2-3

# When prompted:
# - Version Label: v2.3.0
# - Press Enter to confirm
```

#### Step 4: Test Deployment

Your subgraph URL will be:
```
https://api.studio.thegraph.com/query/<SUBGRAPH_ID>/mysbt-v2-3/v2.3.0
```

Test query:
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"query": "{ globalStat(id: \"global\") { totalSBTs totalActivities } }"}' \
  https://api.studio.thegraph.com/query/<SUBGRAPH_ID>/mysbt-v2-3/v2.3.0
```

### Option 2: Local Graph Node (Self-Hosted)

#### Requirements:
- Docker & Docker Compose
- Running Ethereum RPC node or Alchemy/Infura API

#### Setup:

```bash
# Clone Graph Node
git clone https://github.com/graphprotocol/graph-node
cd graph-node/docker

# Edit docker-compose.yml
# Update ethereum connection:
# ethereum: 'sepolia:https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY'

# Start services
docker-compose up -d

# Wait for services to be ready
docker-compose logs -f graph-node

# Create subgraph
graph create --node http://localhost:8020/ mysbt-v2-3

# Deploy
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster/subgraph
graph deploy \
  --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  mysbt-v2-3
```

#### Test Local Deployment:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"query": "{ globalStat(id: \"global\") { totalSBTs } }"}' \
  http://localhost:8000/subgraphs/name/mysbt-v2-3
```

## 🔍 Verify Indexing

### Check Indexing Status

```bash
# For Studio
curl https://api.thegraph.com/index-node/graphql \
  -X POST \
  -d '{"query": "{ indexingStatusForCurrentVersion(subgraphName: \"mysbt-v2-3\") { synced health chains { network latestBlock { number } } } }"}'

# For Local
curl http://localhost:8030/graphql \
  -X POST \
  -d '{"query": "{ indexingStatusForCurrentVersion(subgraphName: \"mysbt-v2-3\") { synced health } }"}'
```

### Trigger Test Activity

To generate data for indexing:

```bash
# Source environment variables
source ../.env

# Mint SBT (this will trigger events)
cast send 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8 \
  "mintOrAddMembership(address,string)" \
  $DEPLOYER_ADDRESS \
  "ipfs://test-metadata" \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL

# Wait 1-2 minutes for indexing
# Then query the subgraph
```

## 📊 Example Queries

### Get Global Statistics
```graphql
{
  globalStat(id: "global") {
    totalSBTs
    totalCommunities
    totalActivities
    totalMemberships
    lastUpdatedAt
  }
}
```

### Get SBT Details
```graphql
{
  sbt(id: "1") {
    holder
    firstCommunity
    mintedAt
    totalCommunities
    memberships {
      community { id }
      joinedAt
      isActive
      activityCount
    }
    activities(first: 10, orderBy: timestamp, orderDirection: desc) {
      week
      timestamp
      community { id }
    }
  }
}
```

### Get Community Reputation
```graphql
{
  reputationScores(
    where: { sbt: "1", community: "0x..." }
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
```

### Get Weekly Activity Stats
```graphql
{
  weeklyActivityStats(
    where: { sbt: "1" }
    orderBy: week
    orderDirection: desc
    first: 4
  ) {
    week
    community { id }
    activityCount
    firstActivityTime
    lastActivityTime
  }
}
```

## 🐛 Troubleshooting

### Issue: "Failed to deploy"

**Check**:
1. Verify auth key is correct: `graph auth --studio <KEY>`
2. Ensure contract address matches in subgraph.yaml
3. Check startBlock is correct (9507735)

### Issue: "Subgraph not syncing"

**Fix**:
1. Verify RPC endpoint is accessible
2. Check contract ABI matches deployed version
3. Ensure startBlock isn't too far in the past

### Issue: "Queries return empty"

**Reasons**:
1. No events emitted yet (mint an SBT first)
2. Indexing not complete (check `synced: true`)
3. Wrong entity ID

## 📈 Cost Estimates

**The Graph Studio (Testnet)**:
- ✅ FREE for testing on Sepolia
- No GRT tokens required
- Unlimited queries for development

**The Graph Decentralized Network (Mainnet)**:
- Initial: ~$20-50 (100 GRT for curation)
- Monthly: $25-500 depending on query volume
- Pay-per-query model

**Self-Hosted (Local)**:
- Server: $100-200/month
- RPC: $50-100/month
- Total: ~$150-300/month
- No per-query fees

## ✅ Deployment Checklist

- [ ] Subgraph built successfully
- [ ] The Graph Studio account created
- [ ] Deploy key obtained
- [ ] Authentication complete
- [ ] Subgraph deployed
- [ ] Indexing status shows `synced: true`
- [ ] Test queries returning data
- [ ] Frontend integration ready

## 🔗 Useful Links

- The Graph Studio: https://thegraph.com/studio/
- Graph CLI Docs: https://thegraph.com/docs/en/developing/creating-a-subgraph/
- Subgraph Explorer: https://thegraph.com/explorer
- Discord Support: https://discord.gg/graphprotocol

---

**Last Updated**: 2025-10-28
**Version**: v2.3.0
**Status**: Ready for Deployment 🚀
