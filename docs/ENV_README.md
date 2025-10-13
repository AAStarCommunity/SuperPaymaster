# Shared Environment Configuration

## Overview

All projects in `/projects/` directory share a **single centralized .env file** located at:

```
/projects/env/.env
```

This ensures consistency across all AAStar projects and simplifies environment management.

## Projects Using Shared Environment

- **demo** (`/projects/demo/`) - AAStar Demo Playground
- **registry** (`/projects/registry/`) - SuperPaymaster Registry
- **faucet** (`/projects/faucet/`) - Faucet API
- **SuperPaymaster** (`/projects/SuperPaymaster/`) - Core smart contracts

## Environment Variables

### Blockchain Network
```bash
SEPOLIA_RPC_URL=https://...
SEPOLIA_CHAIN_ID=0xaa36a7
```

### Private Keys
```bash
# For contract deployment and faucet operations
SEPOLIA_PRIVATE_KEY=0x...
SEPOLIA_PRIVATE_KEY_NEW=0x...
```

### Contract Addresses (Sepolia)
```bash
# Account Abstraction
SIMPLE_ACCOUNT_FACTORY_ADDRESS=0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881
ENTRY_POINT_ADDRESS=0x...

# Tokens
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
USDT_CONTRACT_ADDRESS=0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc

# SuperPaymaster
PAYMASTER_V4_ADDRESS=0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
```

### API Configuration
```bash
FAUCET_API_URL=https://faucet.aastar.io/api
```

## Usage Notes

1. **Never commit** `/projects/env/.env` to git
2. Each project has `.env.example` for documentation
3. When deploying to Vercel, manually configure environment variables in the Vercel dashboard
4. For local development, ensure `/projects/env/.env` exists and is populated

## Setup Instructions

1. Create the shared env directory:
   ```bash
   mkdir -p /projects/env
   ```

2. Copy from example (if available):
   ```bash
   cp /projects/faucet/.env.example /projects/env/.env
   ```

3. Fill in actual values in `/projects/env/.env`

4. Projects will reference this file for local development

## Security

- The shared .env file is **gitignored** at repository root
- Never share private keys in public repositories
- Use Vercel environment variables for production deployments
- Rotate keys regularly for security
