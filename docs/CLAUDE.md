# Project Best Practices

## Environment Variables

### RPC URLs
- **Never hardcode RPC URLs** in source code
- Always use environment variables for RPC endpoints
- Example (Vite project):
  ```typescript
  const SEPOLIA_RPC_URL = import.meta.env.VITE_SEPOLIA_RPC_URL || "https://rpc.sepolia.org";
  ```
- Set in Vercel:
  ```bash
  echo "YOUR_RPC_URL" | vercel env add VITE_SEPOLIA_RPC_URL production
  echo "YOUR_RPC_URL" | vercel env add VITE_SEPOLIA_RPC_URL preview
  ```

### Why?
- Security: Prevents exposing API keys in public repositories
- Flexibility: Easy to switch RPC providers without code changes
- Performance: Can use different RPC providers for dev/staging/production

## Balance Queries

### Use Independent RPC Provider
- Query token balances using a dedicated `JsonRpcProvider` instance
- Do NOT rely on MetaMask's provider for read-only operations
- This ensures consistent and reliable data fetching regardless of user's MetaMask configuration

Example:
```typescript
const loadBalances = async () => {
  // Use dedicated RPC provider (independent of MetaMask)
  const rpcProvider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  
  const contract = new ethers.Contract(TOKEN_ADDRESS, ABI, rpcProvider);
  const balance = await contract.balanceOf(address);
};
```
