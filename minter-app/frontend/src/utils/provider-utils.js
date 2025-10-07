import { ethers } from 'ethers';
import { getNetworkConfig } from '../config/aa-config.js';

/**
 * Create a network provider using direct RPC connection
 * TEMPORARY FIX: Using direct Alchemy RPC until backend proxy is fixed
 */
export function createNetworkProvider(chainId) {
  const networkConfig = getNetworkConfig(chainId);
  if (!networkConfig) {
    throw new Error(`Network ${chainId} not configured`);
  }
  
  // TEMPORARY: Direct Alchemy RPC for Sepolia
  if (chainId === 11155111) {
    const alchemyRpcUrl = "https://eth-sepolia.g.alchemy.com/v2/IIY_LZOlEuy66agzhxpYexmEaHuMskl-";
    return new ethers.JsonRpcProvider(alchemyRpcUrl);
  }
  
  throw new Error(`Direct RPC not configured for chain ${chainId}`);
}

/**
 * Create a hybrid provider that uses custom RPC for reads and MetaMask for transactions
 */
export function createHybridProvider(metaMaskProvider, chainId) {
  const networkProvider = createNetworkProvider(chainId);
  
  return {
    // Use network provider for reads
    getCode: (address) => networkProvider.getCode(address),
    getBalance: (address) => networkProvider.getBalance(address),
    call: (transaction) => networkProvider.call(transaction),
    
    // Use MetaMask provider for transactions
    getSigner: () => metaMaskProvider.getSigner(),
    getNetwork: () => metaMaskProvider.getNetwork(),
    
    // Pass through other methods to network provider
    ...networkProvider
  };
}

/**
 * Test if a provider can access a contract
 */
export async function testProviderAccess(provider, contractAddress) {
  try {
    const code = await provider.getCode(contractAddress);
    return {
      success: true,
      codeLength: code.length,
      hasContract: code.length > 2
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  }
}
