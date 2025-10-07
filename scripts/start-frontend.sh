#!/bin/bash

# Start the frontend development server
# Usage: ./scripts/start-frontend.sh

set -e

# Get the script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to frontend directory
cd "$PROJECT_ROOT/frontend"

echo "🚀 Starting SuperPaymaster Dashboard..."
echo "📍 URL: http://localhost:3000"
echo ""

# Check if node_modules exists
if [ ! -d "node_modules" ]; then
    echo "📦 Installing dependencies..."
    npm install
fi

# Start the development server
npm run dev