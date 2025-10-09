# Faucet API Reference

This document describes all available API endpoints for the SuperPaymaster Faucet.

## Base URL

- **Development**: `http://localhost:3000/api`
- **Production**: `https://your-vercel-app.vercel.app/api`

## Authentication

All endpoints are public but rate-limited. Some admin operations require an `X-Admin-Key` header.

---

## Endpoints

### 1. Mint SBT/PNT Tokens

**Endpoint**: `POST /api/mint`

**Description**: Mints SBT (Soul Bound Token) or PNT (Points Token) to a user address.

**Rate Limit**: 2 requests per hour per address

**Request Body**:
```json
{
  "address": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "type": "sbt" | "pnt"
}
```

**Response**:
```json
{
  "success": true,
  "txHash": "0x...",
  "blockNumber": 12345,
  "amount": "1 SBT" | "100 PNT",
  "recipient": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "type": "sbt" | "pnt",
  "network": "Sepolia"
}
```

**Contract Addresses**:
- SBT: `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f`
- PNT: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180`

---

### 2. Mint Mock USDT

**Endpoint**: `POST /api/mint-usdt`

**Description**: Mints 10 Mock USDT (6 decimals) to a user address for testing.

**Rate Limit**: 5 requests per hour per address

**Request Body**:
```json
{
  "address": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb"
}
```

**Response**:
```json
{
  "success": true,
  "txHash": "0x...",
  "blockNumber": 12345,
  "amount": "10 USDT",
  "recipient": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "balance": "10.0",
  "network": "Sepolia"
}
```

**Contract Address**: `0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc`

---

### 3. Create SimpleAccount

**Endpoint**: `POST /api/create-account`

**Description**: Creates a new ERC-4337 SimpleAccount using the factory contract.

**Rate Limit**: 3 requests per hour per owner

**Request Body**:
```json
{
  "owner": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "salt": 123456  // Optional, random if not provided
}
```

**Response**:
```json
{
  "success": true,
  "txHash": "0x...",
  "blockNumber": 12345,
  "accountAddress": "0x...",
  "owner": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb",
  "salt": 123456,
  "alreadyDeployed": false,
  "network": "Sepolia"
}
```

**Contract Address**: `0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881`

---

### 4. Initialize PaymasterV4 Pool

**Endpoint**: `POST /api/init-pool`

**Description**: Initializes the PaymasterV4 liquidity pool by depositing ETH and USDT.

**Rate Limit**: 1 request per 24 hours (global)

**Admin Override**: Include `X-Admin-Key` header to bypass rate limit

**Request Body**:
```json
{
  "ethAmount": "0.01",      // Optional, default: 0.01 ETH
  "usdtAmount": "100",      // Optional, default: 100 USDT
  "priceMarkup": 11000      // Optional, default: 11000 (1.1x)
}
```

**Response**:
```json
{
  "success": true,
  "results": [
    {
      "step": "deposit_eth",
      "txHash": "0x...",
      "blockNumber": 12345,
      "amount": "0.01 ETH"
    },
    {
      "step": "transfer_usdt",
      "txHash": "0x...",
      "blockNumber": 12346,
      "amount": "100 USDT"
    },
    {
      "step": "add_token",
      "txHash": "0x...",
      "blockNumber": 12347,
      "token": "0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc",
      "priceMarkup": 11000
    }
  ],
  "finalBalances": {
    "paymasterEth": "0.01",
    "paymasterUsdt": "100.0"
  },
  "network": "Sepolia"
}
```

**Contract Addresses**:
- PaymasterV4: `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445`
- USDT Token: `0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc`

---

## Error Responses

All endpoints return standard error responses:

```json
{
  "success": false,
  "error": "Error message description"
}
```

**Common HTTP Status Codes**:
- `400`: Bad Request (invalid input)
- `403`: Forbidden (permission denied)
- `405`: Method Not Allowed (use POST)
- `429`: Rate Limit Exceeded
- `500`: Internal Server Error

---

## Environment Variables

Required environment variables for deployment:

```bash
# Sepolia Network
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Deployer Private Key
SEPOLIA_PRIVATE_KEY=0x...
SEPOLIA_PRIVATE_KEY_NEW=0x...  # Alternative key name

# Contract Addresses
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
USDT_CONTRACT_ADDRESS=0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc
SIMPLE_ACCOUNT_FACTORY_ADDRESS=0x9bD66892144FCf0BAF5B6946AEAFf38B0d967881
PAYMASTER_V4_ADDRESS=0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445

# Admin Key (optional, for bypassing rate limits)
ADMIN_KEY=your_secret_admin_key
```

---

## CORS

All endpoints support CORS with the following headers:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`

---

## Rate Limiting

Rate limits are tracked in-memory per Vercel serverless function instance. Limits reset when the function cold-starts.

**Production Recommendation**: Use Redis or similar persistent storage for rate limiting in production.

---

## Example Usage

### Using cURL

```bash
# Mint 10 USDT
curl -X POST https://your-app.vercel.app/api/mint-usdt \
  -H "Content-Type: application/json" \
  -d '{"address":"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb"}'

# Create SimpleAccount
curl -X POST https://your-app.vercel.app/api/create-account \
  -H "Content-Type: application/json" \
  -d '{"owner":"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb","salt":12345}'

# Initialize Pool (Admin)
curl -X POST https://your-app.vercel.app/api/init-pool \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: your_secret_key" \
  -d '{"ethAmount":"0.01","usdtAmount":"100"}'
```

### Using JavaScript

```javascript
// Mint USDT
const response = await fetch('https://your-app.vercel.app/api/mint-usdt', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ address: '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb' })
});
const result = await response.json();
console.log(result);
```

---

## Deployment

Deploy to Vercel:

```bash
# Install Vercel CLI
npm install -g vercel

# Login to Vercel
vercel login

# Deploy
vercel --prod
```

Configure environment variables in Vercel dashboard or via CLI:

```bash
vercel env add SEPOLIA_RPC_URL
vercel env add SEPOLIA_PRIVATE_KEY
# ... add other env vars
```
