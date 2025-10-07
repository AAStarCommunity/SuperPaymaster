#!/bin/bash

# Compile singleton-paymaster contracts independently
# This script builds the singleton-paymaster contracts and extracts ABIs for frontend use

set -e

echo "🔧 Compiling singleton-paymaster contracts..."

# Get the script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to singleton-paymaster directory
cd "$PROJECT_ROOT/singleton-paymaster"

# Install dependencies
echo "📦 Installing singleton-paymaster dependencies..."
npm install 2>/dev/null || echo "npm install not needed or failed, continuing..."

# Compile using foundry in singleton-paymaster directory
echo "⚡ Building singleton-paymaster contracts..."
forge build

# Create output directory for frontend
FRONTEND_LIB_DIR="$PROJECT_ROOT/frontend/src/lib/singleton-compiled"
mkdir -p "$FRONTEND_LIB_DIR"

echo "📄 Extracting ABIs and bytecode for frontend..."

# Extract SingletonPaymasterV6 (if exists)
if [ -f "out/SingletonPaymasterV6.sol/SingletonPaymasterV6.json" ]; then
    echo "   - SingletonPaymasterV6"
    cp "out/SingletonPaymasterV6.sol/SingletonPaymasterV6.json" "$FRONTEND_LIB_DIR/"
fi

# Extract SingletonPaymasterV7 
if [ -f "out/SingletonPaymasterV7.sol/SingletonPaymasterV7.json" ]; then
    echo "   - SingletonPaymasterV7"
    cp "out/SingletonPaymasterV7.sol/SingletonPaymasterV7.json" "$FRONTEND_LIB_DIR/"
fi

# Extract SingletonPaymasterV8 (if exists)
if [ -f "out/SingletonPaymasterV8.sol/SingletonPaymasterV8.json" ]; then
    echo "   - SingletonPaymasterV8"  
    cp "out/SingletonPaymasterV8.sol/SingletonPaymasterV8.json" "$FRONTEND_LIB_DIR/"
fi

# Go back to project root
cd "$PROJECT_ROOT"

# Generate TypeScript interface
echo "🔥 Generating TypeScript interfaces..."
cat > "$FRONTEND_LIB_DIR/types.ts" << 'EOF'
export interface CompiledContract {
  abi: any[];
  bytecode: string;
  contractName: string;
  name: string;
  description: string;
  entryPoint: string;
}

export interface SingletonPaymasterContracts {
  v6?: CompiledContract;
  v7: CompiledContract;
  v8?: CompiledContract;
}
EOF

# Generate compiled contracts index
echo "📝 Generating compiled contracts index..."
cat > "$FRONTEND_LIB_DIR/index.ts" << 'EOF'
import { CompiledContract, SingletonPaymasterContracts } from './types';

// Import compiled contracts
let SingletonPaymasterV6: any = null;
let SingletonPaymasterV7: any = null; 
let SingletonPaymasterV8: any = null;

try {
  SingletonPaymasterV6 = require('./SingletonPaymasterV6.json');
} catch (e) {
  console.warn('SingletonPaymasterV6 not found');
}

try {
  SingletonPaymasterV7 = require('./SingletonPaymasterV7.json');
} catch (e) {
  console.warn('SingletonPaymasterV7 not found');
}

try {
  SingletonPaymasterV8 = require('./SingletonPaymasterV8.json');
} catch (e) {
  console.warn('SingletonPaymasterV8 not found');
}

// EntryPoint addresses
const ENTRY_POINTS = {
  v6: "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789",
  v7: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", 
  v8: "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
};

export const SINGLETON_PAYMASTER_CONTRACTS: SingletonPaymasterContracts = {};

// Add V6 if available
if (SingletonPaymasterV6) {
  SINGLETON_PAYMASTER_CONTRACTS.v6 = {
    abi: SingletonPaymasterV6.abi,
    bytecode: SingletonPaymasterV6.bytecode?.object || SingletonPaymasterV6.bytecode,
    contractName: 'SingletonPaymasterV6',
    name: 'Pimlico Singleton Paymaster V6',
    description: 'Pimlico singleton paymaster for EntryPoint v0.6',
    entryPoint: ENTRY_POINTS.v6
  };
}

// Add V7 if available
if (SingletonPaymasterV7) {
  SINGLETON_PAYMASTER_CONTRACTS.v7 = {
    abi: SingletonPaymasterV7.abi,
    bytecode: SingletonPaymasterV7.bytecode?.object || SingletonPaymasterV7.bytecode,
    contractName: 'SingletonPaymasterV7',
    name: 'Pimlico Singleton Paymaster V7',
    description: 'Pimlico singleton paymaster for EntryPoint v0.7',
    entryPoint: ENTRY_POINTS.v7
  };
}

// Add V8 if available  
if (SingletonPaymasterV8) {
  SINGLETON_PAYMASTER_CONTRACTS.v8 = {
    abi: SingletonPaymasterV8.abi,
    bytecode: SingletonPaymasterV8.bytecode?.object || SingletonPaymasterV8.bytecode,
    contractName: 'SingletonPaymasterV8',
    name: 'Pimlico Singleton Paymaster V8', 
    description: 'Pimlico singleton paymaster for EntryPoint v0.8',
    entryPoint: ENTRY_POINTS.v8
  };
}

export default SINGLETON_PAYMASTER_CONTRACTS;
EOF

echo "✅ Singleton paymaster compilation complete!"
echo "📁 Files generated in: $FRONTEND_LIB_DIR"
echo "🔗 Available contracts:"
ls -la "$FRONTEND_LIB_DIR" | grep -E '\.(json|ts)$'

echo ""
echo "🚀 To use in frontend, import:"
echo "   import { SINGLETON_PAYMASTER_CONTRACTS } from '@/lib/singleton-compiled';"