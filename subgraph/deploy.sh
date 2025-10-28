#!/bin/bash

# MySBT v2.3 Subgraph Deployment Script
# This script helps deploy the subgraph to The Graph Studio

set -e

echo "════════════════════════════════════════════════════"
echo "  MySBT v2.3 Subgraph Deployment to The Graph Studio"
echo "════════════════════════════════════════════════════"
echo ""

# Check if we're in the right directory
if [ ! -f "subgraph.yaml" ]; then
    echo "❌ Error: subgraph.yaml not found!"
    echo "Please run this script from the subgraph directory"
    exit 1
fi

# Check if Graph CLI is installed
if ! command -v graph &> /dev/null; then
    echo "❌ Graph CLI not found!"
    echo "Installing @graphprotocol/graph-cli..."
    npm install -g @graphprotocol/graph-cli
fi

echo "✅ Graph CLI found: $(graph --version)"
echo ""

# Check authentication
echo "📋 Deployment Information:"
echo "  Subgraph Name: mysbt-v-2-3"
echo "  Contract: 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8"
echo "  Network: Sepolia (11155111)"
echo "  Start Block: 9507735"
echo "  Version: v2.3.0"
echo ""

# Ask for deploy key if not authenticated
if [ ! -f "$HOME/.graph/config.yml" ] || ! grep -q "api.studio.thegraph.com" "$HOME/.graph/config.yml" 2>/dev/null; then
    echo "⚠️  Not authenticated with The Graph Studio"
    echo ""
    echo "Please get your deploy key from:"
    echo "  https://thegraph.com/studio/subgraph/mysbt-v-2-3/endpoints"
    echo ""
    read -p "Enter your deploy key: " DEPLOY_KEY

    echo ""
    echo "🔐 Authenticating..."
    graph auth $DEPLOY_KEY
    echo ""
fi

echo "✅ Authenticated with The Graph Studio"
echo ""

# Check if build exists
if [ ! -d "build" ]; then
    echo "📦 Building subgraph..."
    graph codegen && graph build
    echo ""
fi

echo "✅ Build complete"
echo ""

# Deploy
echo "🚀 Deploying to The Graph Studio..."
echo ""
echo "When prompted:"
echo "  - Version Label: v2.3.0"
echo "  - Press Enter to confirm"
echo ""

read -p "Press Enter to start deployment..."

graph deploy mysbt-v-2-3

echo ""
echo "════════════════════════════════════════════════════"
echo "  ✅ Deployment Complete!"
echo "════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "1. Check deployment status at:"
echo "   https://thegraph.com/studio/subgraph/mysbt-v-2-3/"
echo ""
echo "2. Wait for indexing to complete (synced: true)"
echo ""
echo "3. Test queries at:"
echo "   https://thegraph.com/studio/subgraph/mysbt-v-2-3/playground"
echo ""
echo "4. Example query:"
echo "   { globalStat(id: \"global\") { totalSBTs totalActivities } }"
echo ""
